use std::{
    collections::HashMap,
    path::PathBuf,
    sync::{Arc, Weak},
};

use nanocode::{Tool, backend::ToolCollection as _};
use nanocode_sync::Atom;
use nanocode_tool_runtime::attachment::{
    Attachment, AttachmentEvent, AttachmentMachine, AttachmentMetadata, AttachmentStatus,
    AttachmentTarget,
};
use serde::Deserialize;
use serde_json::{Value, json};

use crate::{bridge::Host, config::WorkspaceTools, session::text, tools::HostTool};

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Machine {
    pub id: String,
    pub name: String,
    #[serde(default)]
    pub workspace: Option<String>,
    #[serde(default)]
    pub capabilities: Vec<String>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Start {
    pub id: String,
    pub url: String,
    pub token: String,
    #[serde(default)]
    pub machine: Option<Machine>,
    #[serde(default)]
    pub workspace: Option<PathBuf>,
    #[serde(default)]
    pub workspace_tools: WorkspaceTools,
    #[serde(default)]
    pub tools: Vec<HostTool>,
}

struct Running {
    attachment: Attachment,
    url: String,
}

#[derive(Default)]
pub struct Runners(Atom<HashMap<String, Arc<Running>>>);

impl Runners {
    pub async fn stop_all(&self) {
        let runners = self.0.update(std::mem::take);
        for runner in runners.into_values() {
            let _ = runner.attachment.clone().detach().await;
        }
    }
}

fn event(event: AttachmentEvent) -> Value {
    match event {
        AttachmentEvent::Connecting => json!({"state": "connecting"}),
        AttachmentEvent::Retrying { reason, delay_ms } => {
            json!({"state": "retrying", "reason": reason, "delay_ms": delay_ms})
        }
        AttachmentEvent::Attached => json!({"state": "connected"}),
        AttachmentEvent::CatalogPublished { tool_count } => {
            json!({"state": "catalog", "tool_count": tool_count})
        }
        AttachmentEvent::CallStarted { call_id, name } => {
            json!({"state": "call_started", "call_id": call_id, "name": name})
        }
        AttachmentEvent::CallCompleted { call_id, outcome } => {
            json!({"state": "call_completed", "call_id": call_id, "outcome": format!("{outcome:?}")})
        }
        AttachmentEvent::Detached { reason } => json!({"state": "disconnected", "reason": reason}),
        AttachmentEvent::Fenced { reason } => json!({"state": "fenced", "reason": reason}),
        other => json!({"state": "other", "detail": format!("{other:?}")}),
    }
}

fn status(status: &AttachmentStatus) -> &'static str {
    match status {
        AttachmentStatus::Connecting => "connecting",
        AttachmentStatus::Ready => "ready",
        AttachmentStatus::Disconnected => "disconnected",
        AttachmentStatus::Fenced => "fenced",
        _ => "other",
    }
}

pub async fn start(host: &Arc<Host>, start: Start) -> Result<Value, String> {
    let directory = start
        .workspace
        .unwrap_or_else(|| host.data_dir.join("hand"));
    tokio::fs::create_dir_all(&directory)
        .await
        .map_err(|error| format!("create {}: {error}", directory.display()))?;
    let mut tools = crate::hand::workspace_tools(&directory, start.workspace_tools, &host.shell)?;
    for tool in crate::tools::tools(host, start.tools) {
        tools = tools
            .add_shared_tool(Arc::new(tool) as Arc<dyn Tool>)
            .map_err(text)?;
    }
    let target = AttachmentTarget::new(start.url.clone(), start.token).map_err(text)?;
    let mut connector = tools.attach(target);
    if let Some(machine) = start.machine {
        let workspace = machine
            .workspace
            .unwrap_or_else(|| directory.to_string_lossy().into_owned());
        let capabilities = if machine.capabilities.is_empty() {
            vec!["shell".to_owned()]
        } else {
            machine.capabilities
        };
        let machine = AttachmentMachine::new(machine.id, machine.name, workspace, capabilities)
            .map_err(text)?;
        connector = connector.metadata(AttachmentMetadata::machine(machine));
    }
    let (attachment, mut events) = connector.start().map_err(text)?;
    let running = Arc::new(Running {
        attachment: attachment.clone(),
        url: start.url,
    });
    let id = start.id;
    if let Some(previous) = host
        .runners
        .0
        .update(|runners| runners.insert(id.clone(), Arc::clone(&running)))
    {
        drop(previous.attachment.clone().detach());
    }
    let weak: Weak<Host> = Arc::downgrade(host);
    let events_id = id.clone();
    let events_host = weak.clone();
    tokio::spawn(async move {
        while let Some(happened) = events.recv().await {
            let Some(host) = events_host.upgrade() else {
                return;
            };
            host.emit(&json!({"runner": {"id": events_id, "event": event(happened)}}));
        }
    });
    let closed_id = id.clone();
    let closed = Arc::clone(&running);
    tokio::spawn(async move {
        let result = closed.attachment.closed().await;
        if let Some(host) = weak.upgrade() {
            host.runners.0.update(|runners| {
                if runners
                    .get(&closed_id)
                    .is_some_and(|current| Arc::ptr_eq(current, &closed))
                {
                    runners.remove(&closed_id);
                }
            });
            host.emit(&json!({"runner": {"id": closed_id, "stopped": result.err().map(|error| error.to_string())}}));
        }
    });
    Ok(json!({"id": id, "status": status(&attachment.status())}))
}

pub async fn stop(host: &Host, id: &str) -> Result<Value, String> {
    if let Some(running) = host.runners.0.update(|runners| runners.remove(id)) {
        running.attachment.clone().detach().await.map_err(text)?;
    }
    Ok(Value::Null)
}

pub fn statuses(host: &Host) -> Value {
    Value::Array(host.runners.0.read(|runners| {
        runners
            .iter()
            .map(|(id, running)| {
                json!({"id": id, "url": running.url, "status": status(&running.attachment.status())})
            })
            .collect()
    }))
}
