use std::sync::Arc;

use serde::Deserialize;
use serde_json::Value;

use crate::{
    bridge::Host,
    config::{Configuration, McpServerConfig},
    hand, mcp, runner, session, wallet,
};

#[derive(Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Command {
    Models {},
    Sessions {},
    Open(Box<Configuration>),
    Close {
        session: String,
    },
    Submit {
        session: String,
        request_id: String,
        prompt: String,
        #[serde(default)]
        images: Vec<String>,
        #[serde(default)]
        files: Vec<session::PromptFile>,
        #[serde(default)]
        metadata: Value,
    },
    Steer {
        session: String,
        request_id: String,
        prompt: String,
        #[serde(default)]
        images: Vec<String>,
        #[serde(default)]
        files: Vec<session::PromptFile>,
        #[serde(default)]
        into: Option<String>,
    },
    MoveQueued {
        session: String,
        request_id: String,
        #[serde(default)]
        into: Option<String>,
    },
    Replace {
        session: String,
        request_id: String,
        edit_id: String,
        text: String,
    },
    Cancel {
        session: String,
        request_id: String,
    },
    Turn {
        session: String,
        request_id: String,
    },
    Pending {
        session: String,
    },
    Page {
        session: String,
        #[serde(default)]
        after: u64,
        limit: usize,
        #[serde(default)]
        request_id: Option<String>,
        #[serde(default)]
        max_bytes: Option<usize>,
    },
    Settings {
        session: String,
        #[serde(default)]
        thinking: Option<String>,
        #[serde(default)]
        service_tier: Option<nanocode::ServiceTier>,
    },
    Compact {
        session: String,
    },
    Preconnect {
        session: String,
    },
    PermissionMode {
        session: String,
        mode: crate::approvals::Mode,
    },
    Checkpoint {
        session: String,
    },
    Settle {
        session: String,
    },
    InterruptSubagent {
        session: String,
        agent_id: u64,
    },
    CloseSubagent {
        session: String,
        agent_id: u64,
    },
    Reply {
        id: u64,
        #[serde(default)]
        ok: Option<Value>,
        #[serde(default)]
        error: Option<String>,
    },
    McpSignIn(McpServerConfig),
    McpSignInWait {
        server: String,
    },
    PlanSignIn {
        provider: crate::config::Provider,
        #[serde(default)]
        redirect_uri: Option<String>,
    },
    PlanSignInComplete {
        code: String,
    },
    PlanStatus {
        provider: crate::config::Provider,
    },
    PlanSignOut {
        provider: crate::config::Provider,
    },
    HandStart(Box<hand::Start>),
    HandStop {
        id: String,
    },
    HandStatus {},
    RunnerStart(Box<runner::Start>),
    RunnerStop {
        id: String,
    },
    RunnerStatus {},
    WalletConnect(wallet::Meta),
    WalletUse(wallet::Record),
    WalletCli {},
    WalletForget {},
    Payments {},
    FundingUrl {
        account: String,
    },
}

pub async fn execute(host: &Arc<Host>, command: Command) -> Result<Value, String> {
    match command {
        Command::Models {} => Ok(crate::catalog::models()),
        Command::Sessions {} => session::list(host).await,
        Command::Open(config) => session::open(host, *config).await,
        Command::Close { session } => session::close(host, &session).await,
        Command::Submit {
            session,
            request_id,
            prompt,
            images,
            files,
            metadata,
        } => {
            host.sessions
                .get(&session)?
                .submit(host, request_id, prompt, images, files, metadata)
                .await
        }
        Command::Steer {
            session,
            request_id,
            prompt,
            images,
            files,
            into,
        } => {
            host.sessions
                .get(&session)?
                .steer(&request_id, prompt, images, files, into.as_deref())
                .await
        }
        Command::MoveQueued {
            session,
            request_id,
            into,
        } => {
            host.sessions
                .get(&session)?
                .move_queued(&request_id, into.as_deref())
                .await
        }
        Command::Replace {
            session,
            request_id,
            edit_id,
            text,
        } => {
            host.sessions
                .get(&session)?
                .replace(host, &request_id, &edit_id, &text)
                .await
        }
        Command::Cancel {
            session,
            request_id,
        } => host.sessions.get(&session)?.cancel(&request_id).await,
        Command::Turn {
            session,
            request_id,
        } => host.sessions.get(&session)?.turn(&request_id).await,
        Command::Pending { session } => host.sessions.get(&session)?.pending().await,
        Command::Page {
            session,
            after,
            limit,
            request_id,
            max_bytes,
        } => {
            host.sessions
                .get(&session)?
                .page(after, limit, request_id.as_deref(), max_bytes)
                .await
        }
        Command::Settings {
            session,
            thinking,
            service_tier,
        } => {
            host.sessions
                .get(&session)?
                .settings(thinking, service_tier)
                .await
        }
        Command::Compact { session } => host.sessions.get(&session)?.compact().await,
        Command::Preconnect { session } => host.sessions.get(&session)?.preconnect().await,
        Command::PermissionMode { session, mode } => {
            host.sessions.get(&session)?.set_permission_mode(mode)
        }
        Command::Checkpoint { session } => host.sessions.get(&session)?.checkpoint().await,
        Command::Settle { session } => host
            .sessions
            .get(&session)?
            .inbox
            .settle()
            .await
            .map(Value::Bool)
            .map_err(session::text),
        Command::InterruptSubagent { session, agent_id } => {
            host.sessions
                .get(&session)?
                .interrupt_subagent(agent_id)
                .await
        }
        Command::CloseSubagent { session, agent_id } => {
            host.sessions.get(&session)?.close_subagent(agent_id).await
        }
        Command::Reply { id, ok, error } => {
            let result = match error {
                Some(error) => Err(error),
                None => Ok(ok.unwrap_or(Value::Null)),
            };
            Ok(Value::Bool(host.resolve(id, result)))
        }
        Command::McpSignIn(server) => mcp::sign_in(host, server).await,
        Command::McpSignInWait { server } => mcp::finish(host, &server).await,
        Command::PlanSignIn {
            provider,
            redirect_uri,
        } => crate::plans::sign_in(host, provider, redirect_uri).await,
        Command::PlanSignInComplete { code } => crate::plans::complete(host, &code).await,
        Command::PlanStatus { provider } => crate::plans::status(host, provider).await,
        Command::PlanSignOut { provider } => crate::plans::sign_out(host, provider).await,
        Command::HandStart(start) => hand::start(host, *start).await,
        Command::HandStop { id } => Ok(hand::stop(host, &id)),
        Command::HandStatus {} => Ok(hand::status(host)),
        Command::RunnerStart(start) => runner::start(host, *start).await,
        Command::RunnerStop { id } => runner::stop(host, &id).await,
        Command::RunnerStatus {} => Ok(runner::statuses(host)),
        Command::WalletConnect(meta) => wallet::connect(host, meta).await,
        Command::WalletUse(record) => wallet::install(&host.payments, &record),
        Command::WalletCli {} => wallet::install_cli(&host.payments),
        Command::WalletForget {} => {
            host.payments.forget();
            Ok(host.payments.status())
        }
        Command::Payments {} => Ok(host.payments.status()),
        Command::FundingUrl { account } => Ok(Value::String(wallet::funding_url(&account))),
    }
}
