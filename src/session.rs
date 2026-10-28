use std::{
    collections::HashMap,
    path::Path,
    sync::{
        Arc, Weak,
        atomic::{AtomicBool, Ordering},
    },
    time::Duration,
};

use nanocode::{
    ClaudeHarness, CodexHarness, ForkRequest, ModelSelection, ModelTransport, Nanocode,
    NanocodeError, Origin, SubagentControl, Thinking, Tool,
    agent::input::UserInput,
    backend::Prompt,
    backend::ToolCollection as _,
    durability::{
        InitialSettings, SessionRecord, SessionStore, Sql, SqlRow, SqlStatement, SqlStore,
        StoreError, StoreFuture,
    },
    session_host::{
        Driven, InboxError, InboxHost, LogEntry, LoggedEvent, MovedQueued, Replaced, SessionLog,
        Submission, Submitted, TurnInbox, TurnRecord,
    },
};
use nanocode_code_mode::embedded::HostFuture;
use nanocode_store_sqlite::SqliteSql;
use nanocode_sync::Atom;
use serde_json::{Map, Value, json};
use tokio::sync::Notify;

use crate::{
    approvals::{Gate, Mode},
    bridge::Host,
    config::{Configuration, Fork, Provider},
};

#[derive(Clone)]
pub struct Shared(Arc<SqliteSql>);

impl Sql for Shared {
    fn transaction<'a>(
        &'a self,
        operation: &'static str,
        statements: &'a [SqlStatement<'a>],
    ) -> StoreFuture<'a, Result<Vec<Vec<SqlRow>>, StoreError>> {
        self.0.transaction(operation, statements)
    }
}

pub struct Storage {
    sql: Shared,
    pub store: SessionStore,
}

impl Storage {
    pub async fn open(directory: &Path) -> Result<Self, String> {
        let sql = SqliteSql::open_async(directory.join("nanocode.sqlite"))
            .await
            .map_err(text)?;
        let sql = Shared(Arc::new(sql));
        let store = nanocode::session_store(SqlStore::new(sql.clone())).map_err(text)?;
        Ok(Self { sql, store })
    }

    pub fn log(&self, scope: &str) -> Arc<SessionLog<Shared>> {
        Arc::new(SessionLog::new(Arc::new(self.sql.clone()), scope))
    }
}

pub fn text(error: impl std::fmt::Display) -> String {
    error.to_string()
}

pub struct Session {
    pub id: String,
    pub inbox: TurnInbox<Shared>,
    pub model: ModelSelection,
    pub provider: Provider,
    wake: Notify,
    closed: AtomicBool,
    pub subagents: Option<SubagentControl>,
    gate: Option<Arc<Gate>>,
}

#[derive(Default)]
pub struct Sessions(Atom<HashMap<String, Arc<Session>>>);

impl Sessions {
    pub fn get(&self, id: &str) -> Result<Arc<Session>, String> {
        self.0
            .read(|sessions| sessions.get(id).cloned())
            .ok_or_else(|| format!("session {id} is not open"))
    }

    fn insert(&self, session: Arc<Session>) -> Option<Arc<Session>> {
        self.0
            .update(|sessions| sessions.insert(session.id.clone(), Arc::clone(&session)))
    }

    fn remove(&self, id: &str) -> Option<Arc<Session>> {
        self.0.update(|sessions| sessions.remove(id))
    }

    pub fn open_ids(&self) -> Vec<String> {
        self.0.read(|sessions| sessions.keys().cloned().collect())
    }

    pub async fn close_all(&self) {
        let sessions = self.0.update(std::mem::take);
        for session in sessions.into_values() {
            session.close().await;
        }
    }
}

struct AppInbox {
    host: Weak<Host>,
    session: String,
    live: bool,
}

impl InboxHost for AppInbox {
    fn publish(&self, events: Vec<LoggedEvent>) -> HostFuture<'_, Result<(), String>> {
        if let Some(host) = self.host.upgrade() {
            publish(&host, &self.session, "logged", &events);
        }
        Box::pin(async { Ok(()) })
    }

    fn live_deltas(&self) -> bool {
        self.live
    }

    fn publish_live(&self, events: Vec<LoggedEvent>) -> HostFuture<'_, Result<(), String>> {
        if let Some(host) = self.host.upgrade() {
            publish(&host, &self.session, "live", &events);
        }
        Box::pin(async { Ok(()) })
    }
}

pub fn publish(host: &Host, session: &str, kind: &str, events: &[LoggedEvent]) {
    if events.is_empty() {
        return;
    }
    host.emit(&json!({"event": {"session": session, kind: events}}));
}

pub fn described(record: &TurnRecord) -> Result<Value, String> {
    Ok(json!({
        "report": record.report().map_err(text)?,
        "first_seq": record.first_seq,
        "last_seq": record.last_seq,
        "cancel_requested": record.cancel_requested,
        "metadata": record.metadata,
    }))
}

pub async fn open(host: &Arc<Host>, config: Configuration) -> Result<Value, String> {
    if config.fork.is_none()
        && let Ok(existing) = host.sessions.get(&config.session_id)
    {
        return Ok(summary(&existing));
    }
    let storage = host.storage().await?;
    let model = config.model()?;
    let thinking = config.thinking()?;
    let mut session_id = config.session_id.clone();
    let workspace = config
        .workspace
        .clone()
        .unwrap_or_else(|| host.data_dir.join("workspace"));
    tokio::fs::create_dir_all(&workspace)
        .await
        .map_err(|error| format!("create {}: {error}", workspace.display()))?;
    let gate = config
        .permission_mode
        .map(|mode| Gate::new(host, &workspace, mode));
    if !config.allow.is_empty() {
        host.rules.update(|rules| {
            for rule in &config.allow {
                if !rules.contains(rule) {
                    rules.push(rule.clone());
                }
            }
        });
    }
    let mut shared: Vec<Arc<dyn Tool>> = crate::tools::tools(host, config.tools.clone())
        .map(|tool| Arc::new(tool) as Arc<dyn Tool>)
        .collect();
    let mut servers = config.mcp_servers.clone();
    if config.paid_tools {
        servers.extend(crate::payments::Payments::paid_servers());
    }
    let mcp = host
        .payments
        .mcp_tools(&servers, crate::mcp::Credentials::of(host))
        .await?;
    shared.extend(mcp.into_iter().map(|tool| match &gate {
        Some(gate) => gate.wrap(tool),
        None => tool,
    }));
    let mut builder = Nanocode::builder();
    let claude_client = match config.provider {
        Provider::Claude => Some(crate::config::claude_client(host, &config, &host.payments)?),
        Provider::Codex => None,
    };
    if let Some(client) = &claude_client {
        let mut tools = config.workspace_tools(Provider::Claude)?;
        if let Some(gate) = &gate {
            tools = gate.tools(tools, workspace.clone(), false)?;
        }
        for tool in &shared {
            tools = tools.add_shared_tool(Arc::clone(tool)).map_err(text)?;
        }
        if config.web_search {
            tools = tools
                .add_shared_tool(Arc::new(nanocode::claude::web_search_tool(
                    client.clone(),
                    config.max_tokens,
                )))
                .map_err(text)?;
        }
        let environment = config.claude_environment();
        let max_tokens = config.max_tokens;
        let stream = config.stream_tool_input;
        let mut harness = ClaudeHarness::new(client.clone())
            .configure(move |claude| {
                let mut claude = claude.tool_input_deltas(stream);
                if let Some(environment) = &environment {
                    claude = claude.environment(environment.clone());
                }
                Ok(match max_tokens {
                    Some(max_tokens) => claude.max_tokens(max_tokens),
                    None => claude,
                })
            })
            .tools(tools);
        if let Some(instructions) = &config.instructions {
            harness = harness.instructions(instructions.clone());
        }
        builder = builder.claude(harness);
    }
    if config.provider == Provider::Codex {
        let Some(codex_model) = model.as_codex() else {
            return Err(format!("{model} is not a Codex model"));
        };
        let client =
            crate::config::codex_client(host, &config, codex_model, &host.payments).await?;
        let mut tools = config.workspace_tools(Provider::Codex)?;
        if let Some(gate) = &gate {
            tools = gate.tools(tools, workspace.clone(), true)?;
        }
        for tool in &shared {
            tools = tools.add_shared_tool(Arc::clone(tool)).map_err(text)?;
        }
        if config.web_search
            && let Some(search) = crate::config::codex_web_search(&config, &host.payments)?
        {
            tools = tools.add_shared_tool(search).map_err(text)?;
        }
        let environment = config.codex_environment();
        let mut harness = CodexHarness::new(client)
            .configure(move |codex| {
                Ok(match &environment {
                    Some(environment) => codex.execution_environment(environment.clone()),
                    None => codex,
                })
            })
            .tools(tools);
        if let Some(instructions) = &config.instructions {
            harness = harness.instructions(instructions.clone());
        }
        builder = builder.openai(harness);
    }
    if config.subagents == Some(false) {
        builder = builder.without_subagents();
    }
    builder = builder.workspace(workspace.clone());
    builder = if config.hands.is_empty() {
        builder.without_runners()
    } else {
        config
            .hands
            .iter()
            .fold(builder, |builder, hand| builder.runner(hand.runner()))
    };
    builder = builder.durability(storage.store.clone());
    let runtime = builder
        .build_async()
        .await
        .map_err(|error| format!("build runtime: {error}"))?;
    if let Some(fork) = &config.fork {
        session_id = match forked(host, &storage, &runtime, fork, model.clone(), thinking).await {
            Ok(id) => id,
            Err(error) => {
                let _ = runtime.shutdown().await;
                return Err(error);
            }
        };
    }
    let subagents = runtime.subagents().cloned();
    let inbox_host = Arc::new(AppInbox {
        host: Arc::downgrade(host),
        session: session_id.clone(),
        live: config.live_deltas,
    });
    let mut record = SessionRecord::root(&session_id, model.clone(), config.workspace.clone());
    record.initial =
        (thinking.is_some() || config.service_tier.is_some()).then(|| InitialSettings {
            thinking: thinking.unwrap_or_else(|| model.default_thinking()),
            service_tier: config.service_tier.unwrap_or_default(),
        });
    let log = storage.log(&session_id);
    log.migrate().await.map_err(text)?;
    let (inbox, pump) = match TurnInbox::open(
        (*runtime).clone(),
        &storage.store,
        record,
        log,
        inbox_host,
        Duration::from_millis(config.event_coalesce_ms),
    )
    .await
    {
        Ok(opened) => opened,
        Err(error) => {
            let _ = runtime.shutdown().await;
            return Err(match error {
                InboxError::Agent(NanocodeError::InvalidRequest(message)) => {
                    format!("configuration: {message}")
                }
                error => error.to_string(),
            });
        }
    };
    tokio::spawn(pump);
    let session = Arc::new(Session {
        id: session_id,
        inbox,
        model,
        provider: config.provider,
        wake: Notify::new(),
        closed: AtomicBool::new(false),
        subagents,
        gate,
    });
    if let Some(previous) = host.sessions.insert(Arc::clone(&session)) {
        previous.close().await;
    }
    let completions = Arc::clone(&session);
    tokio::spawn(async move { completions.inbox.deliver_completions().await });
    tokio::spawn(drive(Arc::downgrade(host), Arc::clone(&session)));
    Ok(summary(&session))
}

async fn forked(
    host: &Host,
    storage: &Storage,
    runtime: &Nanocode,
    fork: &Fork,
    model: ModelSelection,
    thinking: Option<Thinking>,
) -> Result<String, String> {
    let parent = host.sessions.get(&fork.session)?;
    let agent = parent.inbox.agent();
    let (child, _) = match (&fork.checkpoint, &fork.before) {
        (Some(checkpoint), Some(_)) => agent.fork(ForkRequest::at(checkpoint.clone())).await,
        (None, None) => runtime.switch(agent, model, thinking).await,
        _ => return Err("fork takes a checkpoint and the turn it precedes together".into()),
    }
    .map_err(text)?;
    let id = child.session_id().to_owned();
    child.shutdown().await.map_err(text)?;
    let end = match &fork.before {
        Some(request_id) => {
            parent
                .inbox
                .log()
                .turn(request_id)
                .await
                .map_err(text)?
                .ok_or_else(|| format!("turn {request_id} is not in session {}", fork.session))?
                .first_seq
        }
        None => u64::MAX,
    };
    let log = storage.log(&id);
    log.migrate().await.map_err(text)?;
    let mut after = 0;
    loop {
        let page = parent.inbox.log().page(after, 500).await.map_err(text)?;
        let entries: Vec<LogEntry> = page
            .events
            .iter()
            .take_while(|event| event.seq < end)
            .map(|event| LogEntry {
                request_id: event.request_id.clone(),
                event: event.event.clone(),
            })
            .collect();
        log.append(&entries).await.map_err(text)?;
        if !page.has_more || entries.len() < page.events.len() {
            return Ok(id);
        }
        after = page.next_cursor;
    }
}

fn summary(session: &Session) -> Value {
    json!({
        "session_id": session.inbox.session_id(),
        "model": session.inbox.model(),
        "provider": match session.provider { Provider::Claude => "claude", Provider::Codex => "codex" },
    })
}

const IDLE_POLL: Duration = Duration::from_millis(50);
const FIRST_RETRY: Duration = Duration::from_millis(500);
const LAST_RETRY: Duration = Duration::from_secs(30);

async fn drive(host: Weak<Host>, session: Arc<Session>) {
    let mut retry = FIRST_RETRY;
    let state = |driving: bool| {
        if let Some(host) = host.upgrade() {
            host.emit(&json!({"event": {"session": session.id, "driving": driving}}));
        }
    };
    loop {
        if session.closed.load(Ordering::Acquire) {
            return;
        }
        state(true);
        let driven = session.inbox.drive(None).await;
        let Some(live) = host.upgrade() else {
            return;
        };
        match driven {
            Ok(Driven::Idle) => {
                retry = FIRST_RETRY;
                state(false);
                drop(live);
                session.wake.notified().await;
            }
            Ok(Driven::Busy) => {
                drop(live);
                tokio::time::sleep(IDLE_POLL).await;
            }
            Ok(Driven::Finished(record)) => {
                retry = FIRST_RETRY;
                if let Ok(turn) = described(&record) {
                    live.emit(&json!({"event": {"session": session.id, "turn": turn}}));
                }
            }
            Ok(Driven::Resumed(request_id)) => {
                live.emit(&json!({"event": {"session": session.id, "resumed": request_id}}));
            }
            Ok(Driven::Waiting(request_id) | Driven::Interrupted(request_id)) => {
                live.emit(&json!({"event": {"session": session.id, "waiting": request_id, "retry_ms": retry.as_millis()}}));
                drop(live);
                let _ = tokio::time::timeout(retry, session.wake.notified()).await;
                retry = (retry * 2).min(LAST_RETRY);
            }
            Err(error) => {
                live.emit(&json!({"event": {"session": session.id, "error": error.to_string()}}));
                drop(live);
                let _ = tokio::time::timeout(retry, session.wake.notified()).await;
                retry = (retry * 2).min(LAST_RETRY);
            }
        }
    }
}

impl Session {
    pub async fn close(&self) {
        if self.closed.swap(true, Ordering::AcqRel) {
            return;
        }
        self.wake.notify_one();
        let _ = self.inbox.shutdown().await;
    }

    pub async fn submit(
        &self,
        host: &Host,
        request_id: String,
        prompt: String,
        images: Vec<String>,
        metadata: Value,
    ) -> Result<Value, String> {
        let submission = Submission {
            request_id,
            prompt: prompt_of(prompt, images),
            hand: None,
            metadata: serde_json::value::to_raw_value(&metadata).map_err(text)?,
        };
        let (status, record) = match self.inbox.log().submit(&submission).await.map_err(text)? {
            Submitted::Accepted { record, event } => {
                publish(host, &self.id, "logged", &[event]);
                ("accepted", record)
            }
            Submitted::Existing(record) => ("existing", record),
            Submitted::Conflict(record) => ("conflict", record),
            Submitted::TooLarge { bytes, limit } => {
                return Ok(json!({"submitted": "too_large", "bytes": bytes, "limit": limit}));
            }
        };
        self.wake.notify_one();
        Ok(json!({"submitted": status, "turn": described(&record)?}))
    }

    pub async fn steer(
        &self,
        request_id: &str,
        prompt: String,
        images: Vec<String>,
        into: Option<&str>,
    ) -> Result<Value, String> {
        let steered = self
            .inbox
            .steer(into, request_id, prompt_of(prompt, images))
            .await
            .map_err(text)?;
        Ok(Value::Bool(steered))
    }

    pub async fn cancel(&self, request_id: &str) -> Result<Value, String> {
        let cancelled = self
            .inbox
            .cancel(request_id, &Map::new())
            .await
            .map_err(text)?;
        self.wake.notify_one();
        Ok(match cancelled {
            Some((record, dequeued)) => json!({"turn": described(&record)?, "dequeued": dequeued}),
            None => json!({"turn": null}),
        })
    }

    pub async fn move_queued(&self, request_id: &str, into: Option<&str>) -> Result<Value, String> {
        let moved = self
            .inbox
            .move_queued(request_id, into)
            .await
            .map_err(text)?;
        Ok(json!({"moved": match moved {
            MovedQueued::Moved => "moved",
            MovedQueued::NotQueued => "not_queued",
            MovedQueued::NotRunning => "not_running",
            MovedQueued::Conflict => "conflict",
            MovedQueued::Unknown => "unknown",
        }}))
    }

    pub async fn replace(
        &self,
        host: &Host,
        request_id: &str,
        edit_id: &str,
        edited: &str,
    ) -> Result<Value, String> {
        let status = match self
            .inbox
            .log()
            .replace_queued(request_id, edit_id, edited)
            .await
            .map_err(text)?
        {
            Replaced::Applied(Some(event)) => {
                publish(host, &self.id, "logged", &[event]);
                "applied"
            }
            Replaced::Applied(None) => "already_applied",
            Replaced::NotQueued => "not_queued",
            Replaced::Conflict => "conflict",
            Replaced::TooLarge { bytes, limit } => {
                return Ok(json!({"replaced": "too_large", "bytes": bytes, "limit": limit}));
            }
        };
        Ok(json!({"replaced": status}))
    }

    pub async fn page(
        &self,
        after: u64,
        limit: usize,
        request_id: Option<&str>,
        max_bytes: Option<usize>,
    ) -> Result<Value, String> {
        let log = self.inbox.log();
        let page = match (request_id, max_bytes) {
            (Some(request_id), Some(bytes)) => {
                log.turn_page_bounded(request_id, after, limit, bytes).await
            }
            (Some(request_id), None) => log.turn_page(request_id, after, limit).await,
            (None, Some(bytes)) => log.page_bounded(after, limit, bytes).await,
            (None, None) => log.page(after, limit).await,
        }
        .map_err(text)?;
        serde_json::to_value(page).map_err(text)
    }

    pub async fn turn(&self, request_id: &str) -> Result<Value, String> {
        let record = self.inbox.log().turn(request_id).await.map_err(text)?;
        Ok(json!({"turn": record.as_ref().map(described).transpose()?}))
    }

    pub async fn pending(&self) -> Result<Value, String> {
        let records = self.inbox.log().pending().await.map_err(text)?;
        Ok(json!({"turns": records.iter().map(described).collect::<Result<Vec<_>, _>>()?}))
    }

    pub async fn settings(
        &self,
        thinking: Option<String>,
        service_tier: Option<nanocode::ServiceTier>,
    ) -> Result<Value, String> {
        let thinking = thinking
            .map(|thinking| thinking.parse::<Thinking>())
            .transpose()
            .map_err(text)?;
        let capabilities = self.model.capabilities(ModelTransport::Native);
        if let Some(thinking) = thinking {
            capabilities.check_thinking(thinking).map_err(text)?;
        }
        if let Some(service_tier) = service_tier {
            capabilities
                .check_service_tier(service_tier)
                .map_err(text)?;
        }
        let agent = self.inbox.agent();
        if let Some(thinking) = thinking {
            agent.set_thinking(thinking).await.map_err(text)?;
        }
        if let Some(service_tier) = service_tier {
            agent.set_service_tier(service_tier).await.map_err(text)?;
        }
        Ok(Value::Null)
    }

    pub fn set_permission_mode(&self, mode: Mode) -> Result<Value, String> {
        let gate = self
            .gate
            .as_ref()
            .ok_or("the session was opened without a permission mode")?;
        gate.set_mode(mode);
        Ok(Value::Null)
    }

    pub async fn checkpoint(&self) -> Result<Value, String> {
        let checkpoint = self.inbox.agent().checkpoint().await.map_err(text)?;
        serde_json::to_value(checkpoint).map_err(text)
    }

    pub async fn preconnect(&self) -> Result<Value, String> {
        self.inbox.agent().preconnect().await.map_err(text)?;
        Ok(Value::Null)
    }

    fn subagents(&self) -> Result<&SubagentControl, String> {
        self.subagents
            .as_ref()
            .ok_or_else(|| "the session has no subagents".into())
    }

    pub async fn interrupt_subagent(&self, agent_id: u64) -> Result<Value, String> {
        self.subagents()?
            .interrupt(self.inbox.session_id(), nanocode::AgentId::new(agent_id))
            .await
            .map_err(text)
            .and_then(|agents| serde_json::to_value(agents).map_err(text))
    }

    pub async fn close_subagent(&self, agent_id: u64) -> Result<Value, String> {
        self.subagents()?
            .close(self.inbox.session_id(), nanocode::AgentId::new(agent_id))
            .await
            .map_err(text)
            .and_then(|agents| serde_json::to_value(agents).map_err(text))
    }

    pub async fn compact(&self) -> Result<Value, String> {
        let admitted = !self.inbox.log().pending().await.map_err(text)?.is_empty();
        if admitted || !self.inbox.settle().await.map_err(text)? {
            return Ok(json!({"busy": true}));
        }
        self.inbox.agent().compact().await.map_err(text)?;
        self.inbox.settle().await.map_err(text)?;
        Ok(json!({"compacted": true}))
    }
}

fn prompt_of(prompt: String, images: Vec<String>) -> Prompt {
    if images.is_empty() {
        Prompt::from(prompt)
    } else {
        Prompt::content(std::iter::once(UserInput::Text { text: prompt }).chain(
            images.into_iter().map(|image_url| UserInput::Image {
                image_url,
                detail: None,
            }),
        ))
    }
}

pub async fn close(host: &Host, id: &str) -> Result<Value, String> {
    if let Some(session) = host.sessions.remove(id) {
        session.close().await;
    }
    Ok(Value::Null)
}

pub async fn list(host: &Host) -> Result<Value, String> {
    let storage = host.storage().await?;
    let sessions = storage.store.list().await.map_err(text)?;
    let open = host.sessions.open_ids();
    Ok(Value::Array(
        sessions
            .into_iter()
            .filter(|summary| {
                summary.record.lineage.parent_session_id.is_none()
                    || summary.record.lineage.origin == Origin::Fork
            })
            .map(|summary| {
                let id = summary.record.session_id.clone();
                json!({
                    "session_id": id,
                    "model": summary.record.model.as_str(),
                    "family": summary.record.model.family().as_str(),
                    "title": summary.record.title,
                    "preview": summary.preview,
                    "created_at_ms": summary.record.created_at_ms,
                    "updated_at_ms": summary.record.updated_at_ms,
                    "open": open.contains(&id),
                })
            })
            .collect(),
    ))
}
