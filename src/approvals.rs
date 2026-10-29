use std::{
    collections::HashSet,
    future::Future,
    path::{Path, PathBuf},
    pin::Pin,
    sync::{Arc, Weak},
};

use nanocode::backend::ToolCollection as _;
use nanocode_sync::Atom;
use nanocode_tool_runtime::{
    Tool, ToolContext, ToolDefinition, ToolInput, ToolOutput, ToolResult, Tools, WorkspaceTools,
    workspace_runtime::{WorkspaceExecutor, WorkspaceToolFactory},
};
use serde::Deserialize;
use serde_json::{Value, json};

use crate::{bridge::Host, session::text};

type BoxFuture<'a, T> = Pin<Box<dyn Future<Output = T> + Send + 'a>>;

#[derive(Clone, Copy, Debug, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum Mode {
    Plan,
    ReadOnly,
    Auto,
    FullAccess,
}

#[derive(Deserialize)]
#[serde(rename_all = "snake_case")]
enum Decision {
    Allow,
    AllowAlways(String),
    Deny(Option<String>),
}

enum Verdict {
    Run,
    Sandbox(PathBuf),
    Refuse(String),
}

#[derive(Debug, PartialEq)]
enum Action {
    Read,
    Command(String),
    Edit(Vec<PathBuf>),
    Continue,
}

pub struct Gate {
    host: Weak<Host>,
    workspace: PathBuf,
    sandbox: Option<(PathBuf, PathBuf)>,
    observe: bool,
    mode: Atom<Mode>,
    allowed_mcp: Atom<HashSet<String>>,
}

impl Gate {
    pub fn new(
        host: &Arc<Host>,
        workspace: &Path,
        mode: Mode,
        observe: bool,
        sandboxed: bool,
    ) -> Arc<Self> {
        Arc::new(Self {
            host: Arc::downgrade(host),
            sandbox: sandboxed
                .then(|| crate::sandbox::profiles(workspace))
                .flatten(),
            observe,
            workspace: std::fs::canonicalize(workspace).unwrap_or_else(|_| workspace.to_owned()),
            mode: Atom::new(mode),
            allowed_mcp: Atom::default(),
        })
    }

    pub fn set_mode(&self, mode: Mode) {
        self.mode.update(|current| *current = mode);
    }

    fn rules(&self) -> Vec<String> {
        self.host
            .upgrade()
            .map(|host| host.rules.read(Clone::clone))
            .unwrap_or_default()
    }

    pub fn wrap(self: &Arc<Self>, tool: Arc<dyn Tool>) -> Arc<dyn Tool> {
        Arc::new(Gated {
            inner: tool,
            gate: Arc::clone(self),
        })
    }

    pub fn tools(
        self: &Arc<Self>,
        tools: Tools,
        root: PathBuf,
        codex: bool,
    ) -> Result<Tools, String> {
        if tools.workspace_enabled() && !codex {
            return Ok(tools);
        }
        if tools.workspace_enabled() {
            let source = WorkspaceTools::with_factory(
                root.clone(),
                GatedFactory {
                    inner: nanocode::tools::WorkspaceTools::new(root).into_source(),
                    gate: Arc::clone(self),
                },
            );
            return Ok(tools.with_workspace_source(source));
        }
        let mut gated = Tools::builder().without_defaults().build().map_err(text)?;
        for tool in tools.registered_tools() {
            gated = gated
                .add_shared_tool(self.wrap(Arc::clone(tool)))
                .map_err(text)?;
        }
        for policy in tools.code_mode_policies() {
            gated = gated.with_code_mode_policy(policy);
        }
        Ok(gated)
    }

    async fn check(&self, tool: &str, input: &Value, patch: &str, call: Call<'_>) -> Verdict {
        if tool.starts_with("mcp__") {
            return refused(self.check_mcp(tool, input, call).await);
        }
        let mode = self.mode.read(|mode| *mode);
        if mode == Mode::FullAccess {
            return Verdict::Run;
        }
        let (kind, summary, rule) = match classify(tool, input, patch) {
            Action::Read | Action::Continue => return Verdict::Run,
            Action::Command(command) => {
                let read_only = is_read_only(&command);
                match (mode, &self.sandbox) {
                    _ if mode != Mode::Plan && allowed_by(&self.rules(), &command) => {
                        return Verdict::Run;
                    }
                    (Mode::Auto, Some((writable, _))) => return Verdict::Sandbox(writable.clone()),
                    (_, Some((_, read_only_profile))) if read_only => {
                        return Verdict::Sandbox(read_only_profile.clone());
                    }
                    (_, None) if read_only => return Verdict::Run,
                    (Mode::Plan, _) => {
                        return Verdict::Refuse(format!(
                            "Plan mode allows only read-only commands, so `{command}` did not run."
                        ));
                    }
                    _ => {
                        let rule = suggested_rule(&command);
                        ("command", command, rule)
                    }
                }
            }
            Action::Edit(paths) => {
                let outside = paths.iter().any(|path| !self.is_inside(path));
                let names = paths
                    .iter()
                    .map(|path| path.display().to_string())
                    .collect::<Vec<_>>()
                    .join(", ");
                match mode {
                    Mode::Plan => {
                        return Verdict::Refuse("Plan mode does not allow edits.".to_owned());
                    }
                    Mode::Auto if !outside => return Verdict::Run,
                    _ if !outside && allowed_by(&self.rules(), "Edit") => return Verdict::Run,
                    _ if outside => ("outside_workspace", names, String::new()),
                    _ => ("edit", names, "Edit".to_owned()),
                }
            }
        };
        let arguments = if patch.is_empty() {
            input.to_string()
        } else {
            patch.to_owned()
        };
        refused(
            self.ask(kind, summary, rule, tool, "", arguments, call)
                .await,
        )
    }

    async fn run_sandboxed(
        &self,
        tool: &dyn Tool,
        input: ToolInput,
        json: &Value,
        context: ToolContext<'_>,
        profile: &Path,
    ) -> ToolResult {
        let name = tool.definition().name().to_owned();
        let key = if name == "exec_command" {
            "cmd"
        } else {
            "command"
        };
        let Some(command) = json[key].as_str() else {
            return tool.execute(input, context).await;
        };
        let mut wrapped = json.clone();
        wrapped[key] = Value::String(crate::sandbox::wrap(command, profile));
        let wrapped = serde_json::value::to_raw_value(&wrapped).map_err(text)?;
        let output = tool.execute(ToolInput::Function(wrapped), context).await?;
        let shown = serde_json::to_string(&output.output).unwrap_or_default();
        if !crate::sandbox::denied(&shown) {
            return Ok(output);
        }
        let call = Call {
            id: context.call_id(),
            session: context.session_id(),
        };
        let rule = suggested_rule(command);
        match self
            .ask(
                "outside_sandbox",
                command.to_owned(),
                rule,
                &name,
                "",
                json.to_string(),
                call,
            )
            .await
        {
            None => tool.execute(input, context).await,
            Some(refusal) => Ok(ToolOutput::error(format!(
                "The sandbox refused this command, and {}\n\nSandboxed output:\n{shown}",
                refusal
                    .trim_end_matches('.')
                    .replacen("The user", "the user", 1)
            ))),
        }
    }

    async fn check_mcp(&self, tool: &str, input: &Value, call: Call<'_>) -> Option<String> {
        let mode = self.mode.read(|mode| *mode);
        if mode == Mode::FullAccess {
            return None;
        }
        let key = tool.to_owned();
        if mode != Mode::Plan
            && (mcp_allowed_by(&self.rules(), tool)
                || self.allowed_mcp.read(|allowed| allowed.contains(&key)))
        {
            return None;
        }
        let (server, summary) = tool["mcp__".len()..].split_once("__").unwrap_or(("", tool));
        let rule = if mode == Mode::Plan {
            String::new()
        } else {
            tool.to_owned()
        };
        let refusal = self
            .ask(
                "mcp",
                summary.to_owned(),
                rule,
                tool,
                server,
                input.to_string(),
                call,
            )
            .await;
        if refusal.is_none() && mode != Mode::Plan {
            self.allowed_mcp.update(|allowed| {
                allowed.insert(key.clone());
            });
        }
        refusal
    }

    #[allow(clippy::too_many_arguments)]
    async fn ask(
        &self,
        kind: &str,
        summary: String,
        rule: String,
        tool: &str,
        server: &str,
        arguments: String,
        call: Call<'_>,
    ) -> Option<String> {
        let Some(host) = self.host.upgrade() else {
            return Some("the app stopped".into());
        };
        let body = json!({
            "id": call.id,
            "session_id": call.session,
            "tool": tool,
            "kind": kind,
            "summary": summary,
            "server": server,
            "arguments": arguments,
            "suggested_rule": rule,
        });
        let decision = host
            .call("approval", body)
            .await
            .and_then(|reply| serde_json::from_value(reply).map_err(|error| error.to_string()));
        match decision {
            Ok(Decision::Allow) => None,
            Ok(Decision::AllowAlways(rule)) => {
                host.rules.update(|rules| rules.push(rule.clone()));
                None
            }
            Ok(Decision::Deny(Some(feedback))) if !feedback.trim().is_empty() => {
                Some(format!("The user denied this call: {feedback}"))
            }
            Ok(Decision::Deny(_)) => Some("The user denied this call.".to_owned()),
            Err(error) => Some(format!("The approval failed: {error}")),
        }
    }

    async fn will_edit(&self, tool: &str, input: &Value, patch: &str, call: Call<'_>) {
        if !self.observe {
            return;
        }
        let (Action::Edit(paths), Some(host)) = (classify(tool, input, patch), self.host.upgrade())
        else {
            return;
        };
        let paths: Vec<String> = paths
            .iter()
            .map(|path| self.workspace.join(path).display().to_string())
            .collect();
        let _ = host
            .call(
                "will_edit",
                json!({"session_id": call.session, "paths": paths}),
            )
            .await;
    }

    fn is_inside(&self, path: &Path) -> bool {
        let path = if path.is_absolute() {
            path.to_path_buf()
        } else {
            self.workspace.join(path)
        };
        let resolved = std::fs::canonicalize(&path)
            .or_else(|_| {
                let parent = path.parent().unwrap_or(&path);
                std::fs::canonicalize(parent)
                    .map(|parent| parent.join(path.file_name().unwrap_or_default()))
            })
            .unwrap_or(path);
        resolved.starts_with(&self.workspace)
    }
}

#[derive(Clone, Copy)]
struct Call<'a> {
    id: &'a str,
    session: &'a str,
}

struct Gated {
    inner: Arc<dyn Tool>,
    gate: Arc<Gate>,
}

impl Tool for Gated {
    fn definition(&self) -> ToolDefinition {
        self.inner.definition()
    }

    fn supports_parallel_tool_calls(&self) -> bool {
        self.inner.supports_parallel_tool_calls()
    }

    fn end_turn<'a, 'b, 'c, 'd, 'async_trait>(
        &'a self,
        session_id: &'b str,
        turn_id: &'c str,
        hook_event_name: &'d str,
    ) -> BoxFuture<'async_trait, Result<(), nanocode_tool_runtime::contract::ToolError>>
    where
        'a: 'async_trait,
        'b: 'async_trait,
        'c: 'async_trait,
        'd: 'async_trait,
        Self: 'async_trait,
    {
        self.inner.end_turn(session_id, turn_id, hook_event_name)
    }

    fn execute<'a, 'b, 'async_trait>(
        &'a self,
        input: ToolInput,
        context: ToolContext<'b>,
    ) -> BoxFuture<'async_trait, ToolResult>
    where
        'a: 'async_trait,
        'b: 'async_trait,
        Self: 'async_trait,
    {
        Box::pin(async move {
            let name = self.inner.definition().name().to_owned();
            let (json, patch) = match &input {
                ToolInput::Function(json) => {
                    (serde_json::from_str(json.get()).unwrap_or_default(), "")
                }
                ToolInput::Freeform(text) => (Value::Null, text.as_str()),
            };
            let call = Call {
                id: context.call_id(),
                session: context.session_id(),
            };
            match self.gate.check(&name, &json, patch, call).await {
                Verdict::Run => {
                    self.gate.will_edit(&name, &json, patch, call).await;
                    self.inner.execute(input, context).await
                }
                Verdict::Refuse(refusal) => Ok(ToolOutput::error(refusal)),
                Verdict::Sandbox(profile) => {
                    self.gate
                        .run_sandboxed(self.inner.as_ref(), input, &json, context, &profile)
                        .await
                }
            }
        })
    }
}

struct GatedFactory {
    inner: WorkspaceTools,
    gate: Arc<Gate>,
}

impl WorkspaceToolFactory for GatedFactory {
    fn create(
        &self,
        _root: PathBuf,
        environment: Vec<(std::ffi::OsString, std::ffi::OsString)>,
        max_wire_bytes: Option<u64>,
    ) -> Arc<dyn WorkspaceExecutor> {
        Arc::new(GatedExecutor {
            inner: self.inner.create(environment, max_wire_bytes),
            gate: Arc::clone(&self.gate),
        })
    }

    fn code_mode_policy(&self) -> Option<Arc<dyn nanocode_tool_runtime::CodeModeToolPolicy>> {
        self.inner.code_mode_policy()
    }
}

struct GatedExecutor {
    inner: Arc<dyn WorkspaceExecutor>,
    gate: Arc<Gate>,
}

impl WorkspaceExecutor for GatedExecutor {
    fn tools(&self) -> Vec<Arc<dyn Tool>> {
        self.inner
            .tools()
            .into_iter()
            .map(|tool| self.gate.wrap(tool))
            .collect()
    }

    fn timeout_ms(&self, name: &str) -> Option<u64> {
        self.inner.timeout_ms(name)
    }

    fn cancel<'a>(&'a self) -> BoxFuture<'a, ()> {
        self.inner.cancel()
    }
}

fn refused(refusal: Option<String>) -> Verdict {
    refusal.map_or(Verdict::Run, Verdict::Refuse)
}

fn classify(tool: &str, input: &Value, patch: &str) -> Action {
    let string = |key: &str| input[key].as_str().unwrap_or_default().to_owned();
    match tool {
        "Read" | "view_image" | "Glob" | "Grep" => Action::Read,
        "Bash" => Action::Command(string("command")),
        "exec_command" => Action::Command(string("cmd")),
        "Edit" | "Write" | "MultiEdit" => Action::Edit(vec![PathBuf::from(string("file_path"))]),
        "NotebookEdit" => Action::Edit(vec![PathBuf::from(string("notebook_path"))]),
        "apply_patch" => Action::Edit(patch_paths(if patch.is_empty() {
            input["input"].as_str().unwrap_or_default()
        } else {
            patch
        })),
        _ => Action::Continue,
    }
}

fn patch_paths(patch: &str) -> Vec<PathBuf> {
    patch
        .lines()
        .filter_map(|line| {
            [
                "*** Add File: ",
                "*** Delete File: ",
                "*** Update File: ",
                "*** Move to: ",
            ]
            .iter()
            .find_map(|prefix| line.strip_prefix(prefix))
        })
        .map(|path| PathBuf::from(path.trim()))
        .collect()
}

struct Parsed {
    commands: Vec<Vec<String>>,
    complex: bool,
}

fn parse(line: &str) -> Parsed {
    let mut commands = vec![Vec::new()];
    let mut word = String::new();
    let mut in_word = false;
    let mut quote: Option<char> = None;
    let mut complex = false;
    let mut chars = line.chars().peekable();
    let end_word = |word: &mut String, in_word: &mut bool, commands: &mut Vec<Vec<String>>| {
        if *in_word {
            if let Some(command) = commands.last_mut() {
                command.push(std::mem::take(word));
            }
            *in_word = false;
        }
    };
    while let Some(c) = chars.next() {
        match (quote, c) {
            (Some(q), c) if c == q => quote = None,
            (Some('"'), '$') if chars.peek() == Some(&'(') => {
                complex = true;
                word.push(c);
            }
            (Some('"'), '`') => {
                complex = true;
                word.push(c);
            }
            (Some(_), c) => word.push(c),
            (None, '\'' | '"') => {
                quote = Some(c);
                in_word = true;
            }
            (None, '\\') => {
                if let Some(next) = chars.next() {
                    word.push(next);
                    in_word = true;
                }
            }
            (None, c) if c.is_whitespace() && c != '\n' => {
                end_word(&mut word, &mut in_word, &mut commands)
            }
            (None, ';' | '\n' | '|' | '&') => {
                end_word(&mut word, &mut in_word, &mut commands);
                if c == '&' && chars.peek() != Some(&'&') {
                    complex = true;
                }
                if matches!(chars.peek(), Some('&' | '|')) && c != ';' && c != '\n' {
                    chars.next();
                }
                commands.push(Vec::new());
            }
            (None, '>' | '<' | '`') => {
                complex = true;
                end_word(&mut word, &mut in_word, &mut commands);
            }
            (None, '$') if chars.peek() == Some(&'(') => {
                complex = true;
                word.push(c);
                in_word = true;
            }
            (None, c) => {
                word.push(c);
                in_word = true;
            }
        }
    }
    end_word(&mut word, &mut in_word, &mut commands);
    let commands = commands
        .into_iter()
        .map(|words| {
            words
                .into_iter()
                .skip_while(|word| {
                    word.split_once('=').is_some_and(|(name, _)| {
                        !name.is_empty() && name.chars().all(|c| c.is_alphanumeric() || c == '_')
                    })
                })
                .collect::<Vec<_>>()
        })
        .filter(|words| !words.is_empty())
        .collect();
    Parsed { commands, complex }
}

const READ_ONLY: &[&str] = &[
    "ls", "cat", "rg", "grep", "head", "tail", "wc", "pwd", "which", "file", "stat", "tree",
    "echo", "du", "df", "date", "whoami", "uname", "basename", "dirname", "realpath", "sort",
    "uniq", "cut", "diff",
];
const READ_ONLY_GIT: &[&str] = &[
    "status",
    "diff",
    "log",
    "show",
    "branch",
    "rev-parse",
    "blame",
    "ls-files",
    "remote",
];

fn is_read_only(line: &str) -> bool {
    let parsed = parse(line);
    !parsed.complex
        && !parsed.commands.is_empty()
        && parsed.commands.iter().all(|words| {
            let program = words[0].rsplit('/').next().unwrap_or_default();
            match program {
                "git" => words
                    .get(1)
                    .is_some_and(|sub| READ_ONLY_GIT.contains(&sub.as_str())),
                "find" => !words
                    .iter()
                    .any(|word| ["-exec", "-execdir", "-delete", "-ok"].contains(&word.as_str())),
                "sed" => !words.iter().any(|word| word.starts_with("-i")),
                _ => READ_ONLY.contains(&program),
            }
        })
}

fn allowed_by(rules: &[String], line: &str) -> bool {
    if line == "Edit" {
        return rules.iter().any(|rule| rule == "Edit");
    }
    let parsed = parse(line);
    !parsed.complex
        && !parsed.commands.is_empty()
        && parsed.commands.iter().all(|words| {
            rules.iter().any(|rule| {
                let rule = parse(rule).commands.into_iter().next().unwrap_or_default();
                match rule.split_last() {
                    Some((last, prefix)) if last == "*" => words.starts_with(prefix),
                    _ => !rule.is_empty() && *words == rule,
                }
            })
        })
}

fn mcp_allowed_by(rules: &[String], tool: &str) -> bool {
    rules.iter().any(|rule| match rule.strip_suffix('*') {
        Some(prefix) => prefix.starts_with("mcp__") && tool.starts_with(prefix),
        None => rule == tool,
    })
}

fn suggested_rule(line: &str) -> String {
    let parsed = parse(line);
    match parsed.commands.as_slice() {
        [words] if !parsed.complex => words.join(" "),
        _ => String::new(),
    }
}
