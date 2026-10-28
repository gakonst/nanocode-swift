use std::sync::{Arc, Weak};

use async_trait::async_trait;
use nanocode_mcp::oauth::ClientAuthentication;
use nanocode_mcp_tools::{Mcp, McpOAuthCredentials, McpOAuthStore, McpServer};
use nanocode_sync::Slot;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use crate::{bridge::Host, config::McpServerConfig, session::text};

#[derive(Serialize, Deserialize)]
struct Stored {
    client_id: String,
    client_secret: Option<String>,
    secret_in_body: bool,
    access_token: String,
    refresh_token: Option<String>,
    issuer: Option<String>,
    expires_at_millis: Option<u64>,
    scopes: Vec<String>,
    token_endpoint: Option<String>,
    resource: Option<String>,
}

impl From<&McpOAuthCredentials> for Stored {
    fn from(credentials: &McpOAuthCredentials) -> Self {
        let client = credentials.client_authentication();
        Self {
            client_id: client.client_id,
            client_secret: client.client_secret,
            secret_in_body: client.secret_in_body,
            access_token: credentials.access_token().to_owned(),
            refresh_token: credentials.refresh_token_value().map(str::to_owned),
            issuer: credentials.authorization_issuer().map(str::to_owned),
            expires_at_millis: credentials.expires_at(),
            scopes: credentials.granted_scopes().to_vec(),
            token_endpoint: credentials.stored_token_endpoint().map(str::to_owned),
            resource: credentials.resource_indicator().map(str::to_owned),
        }
    }
}

impl From<Stored> for McpOAuthCredentials {
    fn from(stored: Stored) -> Self {
        let mut credentials = McpOAuthCredentials::new(&stored.client_id, stored.access_token)
            .client(ClientAuthentication {
                client_id: stored.client_id,
                client_secret: stored.client_secret,
                secret_in_body: stored.secret_in_body,
            })
            .scopes(stored.scopes);
        if let Some(token) = stored.refresh_token {
            credentials = credentials.refresh_token(token);
        }
        if let Some(issuer) = stored.issuer {
            credentials = credentials.issuer(issuer);
        }
        if let Some(expires) = stored.expires_at_millis {
            credentials = credentials.expires_at_millis(expires);
        }
        if let Some(endpoint) = stored.token_endpoint {
            credentials = credentials.token_endpoint(endpoint);
        }
        if let Some(resource) = stored.resource {
            credentials = credentials.resource(resource);
        }
        credentials
    }
}

pub struct Credentials(Weak<Host>);

impl Credentials {
    pub fn of(host: &Arc<Host>) -> Arc<dyn McpOAuthStore> {
        Arc::new(Self(Arc::downgrade(host)))
    }

    async fn call(&self, body: Value) -> Result<Value, String> {
        let Some(host) = self.0.upgrade() else {
            return Err("the app stopped".into());
        };
        host.call("mcp_credentials", body).await
    }
}

#[async_trait]
impl McpOAuthStore for Credentials {
    async fn load(
        &self,
        server_name: &str,
        server_url: &str,
    ) -> Result<Option<McpOAuthCredentials>, String> {
        let stored = self
            .call(json!({"load": {"server": server_name, "url": server_url}}))
            .await?;
        if stored.is_null() {
            return Ok(None);
        }
        let stored: Stored = serde_json::from_value(stored).map_err(text)?;
        Ok(Some(stored.into()))
    }

    async fn save(
        &self,
        server_name: &str,
        server_url: &str,
        credentials: &McpOAuthCredentials,
    ) -> Result<(), String> {
        self.call(json!({"save": {
            "server": server_name,
            "url": server_url,
            "credentials": Stored::from(credentials),
        }}))
        .await
        .map(drop)
    }
}

pub async fn sign_in(host: &Arc<Host>, config: McpServerConfig) -> Result<Value, String> {
    let server = config.headers.iter().fold(
        McpServer::http(config.url.as_str()),
        |server, (name, value)| server.header(name.clone(), value.clone()),
    );
    let mcp = Mcp::builder()
        .server(config.name.clone(), server)
        .oauth_store(Credentials::of(host))
        .build()
        .map_err(text)?;
    let login = mcp.handle().login(&config.name).await.map_err(text)?;
    let url = login.authorization_url().to_owned();
    let login = Arc::new(Slot::new(Some(login)));
    host.logins.update(|logins| {
        logins.insert(config.name.clone(), Arc::clone(&login));
    });
    Ok(json!({"authorization_url": url}))
}

pub async fn finish(host: &Host, server: &str) -> Result<Value, String> {
    let login = host
        .logins
        .update(|logins| logins.remove(server))
        .and_then(|slot| slot.take())
        .ok_or_else(|| format!("no sign-in to {server} is in progress"))?;
    let tools = login.wait().await.map_err(text)?;
    Ok(json!({"tools": tools}))
}
