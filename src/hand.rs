use std::{
    collections::{BTreeMap, HashMap},
    path::{Path, PathBuf},
    sync::{Arc, Weak},
};

use nanocode::{
    Tool, Tools,
    backend::ToolCollection as _,
    hand::{Hand, HandEvent},
};
use nanocode_sync::Atom;
use nanocode_tool_runtime::remote::{BusyKind, HandActivity};
use serde::Deserialize;
use serde_json::{Value, json};

use crate::{bridge::Host, files::NativeFiles, session::text, tools::HostTool};

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Start {
    pub id: String,
    pub url: String,
    pub token: String,
    #[serde(default)]
    pub name: Option<String>,
    #[serde(default)]
    pub workspace: Option<PathBuf>,
    #[serde(default)]
    pub shell: Option<bool>,
    #[serde(default)]
    pub tools: Vec<HostTool>,
    #[serde(default)]
    pub headers: BTreeMap<String, String>,
    #[serde(default)]
    pub environment: Option<nanocode::HandEnvironment>,
    #[serde(default)]
    pub capabilities: Vec<crate::capabilities::Spec>,
    #[serde(default)]
    pub tools_only: bool,
}

pub struct Running {
    task: tokio::task::AbortHandle,
    activity: HandActivity,
    name: Option<String>,
    url: String,
    directory: PathBuf,
}

#[derive(Default)]
pub struct Hands(Atom<HashMap<String, Arc<Running>>>);

impl Hands {
    pub async fn stop_all(&self) {
        let hands = self.0.update(std::mem::take);
        for hand in hands.into_values() {
            hand.task.abort();
        }
    }

    fn remove(&self, id: &str, running: &Arc<Running>) {
        self.0.update(|hands| {
            if hands
                .get(id)
                .is_some_and(|current| Arc::ptr_eq(current, running))
            {
                hands.remove(id);
            }
        });
    }
}

fn merge(mut into: Tools, from: Tools) -> Result<Tools, String> {
    for policy in from.code_mode_policies() {
        into = into.with_code_mode_policy(policy);
    }
    for tool in from.registered_tools() {
        into = into.add_shared_tool(Arc::clone(tool)).map_err(text)?;
    }
    Ok(into)
}

fn file_tools(directory: &Path) -> Result<Tools, String> {
    let files = Arc::new(NativeFiles);
    let claude =
        nanocode::claude::host_file_tools(directory.to_path_buf(), files.clone()).map_err(text)?;
    let codex =
        nanocode::codex_tools::host_file_tools(directory.to_path_buf(), files).map_err(text)?;
    merge(claude, codex)
}

pub fn workspace_tools(directory: &Path, shell: Option<bool>) -> Result<Tools, String> {
    if shell.unwrap_or(cfg!(target_os = "macos")) && cfg!(target_os = "macos") {
        nanocode::hand::tools(directory.to_path_buf()).map_err(text)
    } else {
        file_tools(directory)
    }
}

fn event(event: HandEvent) -> Value {
    match event {
        HandEvent::Connecting { endpoint } => json!({"state": "connecting", "endpoint": endpoint}),
        HandEvent::Connected { endpoint } => json!({"state": "connected", "endpoint": endpoint}),
        HandEvent::Listening { endpoint } => json!({"state": "listening", "endpoint": endpoint}),
        HandEvent::BrainConnected { peer } => {
            json!({"state": "brain_connected", "peer": peer.to_string()})
        }
        HandEvent::Disconnected { reason } => json!({"state": "disconnected", "reason": reason}),
        HandEvent::Retrying { delay } => {
            json!({"state": "retrying", "delay_ms": delay.as_millis()})
        }
        HandEvent::Revoked => json!({"state": "revoked"}),
        HandEvent::Replaced => json!({"state": "replaced"}),
        HandEvent::Rejected { status } => json!({"state": "rejected", "status": status}),
        other => json!({"state": "other", "detail": format!("{other:?}")}),
    }
}

pub async fn start(host: &Arc<Host>, start: Start) -> Result<Value, String> {
    let directory = match start.workspace {
        Some(directory) => directory,
        None => host.data_dir.join("hand"),
    };
    tokio::fs::create_dir_all(&directory)
        .await
        .map_err(|error| format!("create {}: {error}", directory.display()))?;
    let mut tools = workspace_tools(&directory, start.shell)?;
    for tool in crate::tools::tools(host, start.tools) {
        tools = tools
            .add_shared_tool(Arc::new(tool) as Arc<dyn Tool>)
            .map_err(text)?;
    }
    let mut hand =
        Hand::connect(start.url.clone(), start.token, tools).directory(directory.clone());
    if let Some(name) = &start.name {
        hand = hand.name(name.clone());
    }
    for (name, value) in start.headers {
        hand = hand.header(name, value);
    }
    if let Some(environment) = start.environment {
        hand = hand.environment(environment);
    }
    if !start.capabilities.is_empty() {
        hand = hand.capabilities(Arc::new(crate::capabilities::Device::new(
            host,
            start.id.clone(),
            start.capabilities,
        )));
    }
    if start.tools_only {
        hand = hand.tools_only();
    }
    let activity = hand.activity();
    let id = start.id.clone();
    let weak: Weak<Host> = Arc::downgrade(host);
    let events = weak.clone();
    let event_id = id.clone();
    let run = hand.run(move |happened| {
        if let Some(host) = events.upgrade() {
            host.emit(&json!({"hand": {"id": event_id, "event": event(happened)}}));
        }
    });
    let (ready, started) = tokio::sync::oneshot::channel::<Arc<Running>>();
    let finished_id = id.clone();
    let task = tokio::spawn(async move {
        let result = run.await;
        let running = started.await.ok();
        if let Some(host) = weak.upgrade() {
            if let Some(running) = &running {
                host.hands.remove(&finished_id, running);
            }
            host.emit(&json!({"hand": {"id": finished_id, "stopped": result.err().map(|error| error.to_string())}}));
        }
    });
    let running = Arc::new(Running {
        task: task.abort_handle(),
        activity,
        name: start.name,
        url: start.url,
        directory,
    });
    let previous = host
        .hands
        .0
        .update(|hands| hands.insert(id.clone(), Arc::clone(&running)));
    if let Some(previous) = previous {
        previous.task.abort();
    }
    let _ = ready.send(Arc::clone(&running));
    Ok(status_of(&id, &running))
}

pub fn stop(host: &Host, id: &str) -> Value {
    if let Some(running) = host.hands.0.update(|hands| hands.remove(id)) {
        running.task.abort();
        host.emit(&json!({"hand": {"id": id, "stopped": null}}));
    }
    Value::Null
}

fn status_of(id: &str, running: &Running) -> Value {
    let items = running
        .activity
        .items()
        .into_iter()
        .map(|item| {
            json!({
                "kind": match item.kind {
                    BusyKind::Cell => "cell",
                    BusyKind::Call => "call",
                    BusyKind::Task => "task",
                    BusyKind::Request => "request",
                    BusyKind::Reply => "reply",
                },
                "id": item.id,
                "label": item.label,
                "session_id": item.session_id,
                "silent_ms": item.silent_for.as_millis(),
            })
        })
        .collect::<Vec<_>>();
    json!({
        "id": id,
        "name": running.name,
        "url": running.url,
        "directory": running.directory,
        "busy": running.activity.busy(),
        "items": items,
    })
}

pub fn status(host: &Host) -> Value {
    Value::Array(host.hands.0.read(|hands| {
        hands
            .iter()
            .map(|(id, running)| status_of(id, running))
            .collect()
    }))
}
