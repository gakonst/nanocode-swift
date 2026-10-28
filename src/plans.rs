use std::{
    future::Future,
    pin::Pin,
    sync::{Arc, Weak},
};

use nanocode::claude::{
    ClaudeAuthProvider,
    subscription::{
        ClaudeLoginMode, ClaudeSubscription, ClaudeSubscriptionCommit, ClaudeSubscriptionConfig,
        ClaudeSubscriptionHost, ClaudeSubscriptionHostError, ClaudeSubscriptionHttpRequest,
        ClaudeSubscriptionHttpResponse, ClaudeSubscriptionStatus, ClaudeSubscriptionStoreValue,
    },
};
use nanocode::oai::auth::{
    ChatGptLoginStatus, ChatGptSubscription, ChatGptSubscriptionHost, OpenAiAuth,
    SubscriptionCommit, SubscriptionHostError, SubscriptionHttpRequest, SubscriptionHttpResponse,
    SubscriptionStoreValue,
};
use serde_json::{Value, json};

use crate::{bridge::Host, config::Provider, session::text};

type BoxFuture<'a, T> = Pin<Box<dyn Future<Output = T> + Send + 'a>>;

const CLAUDE_KEY: &str = "claude";
const CHATGPT_KEY: &str = "chatgpt";
const CHATGPT_ISSUER: &str = "https://auth.openai.com";

#[derive(Clone)]
struct Store {
    host: Weak<Host>,
    http: reqwest::Client,
}

impl Store {
    fn of(host: &Arc<Host>) -> Self {
        Self {
            host: Arc::downgrade(host),
            http: reqwest::Client::new(),
        }
    }

    async fn call(&self, body: Value) -> Result<Value, String> {
        let Some(host) = self.host.upgrade() else {
            return Err("the app stopped".into());
        };
        host.call("subscription_store", body).await
    }

    async fn load(&self, key: &str) -> Result<(u64, Option<String>), String> {
        let value = self.call(json!({"load": {"key": key}})).await?;
        Ok((
            value["revision"].as_u64().unwrap_or_default(),
            value["payload"].as_str().map(str::to_owned),
        ))
    }

    async fn compare_and_swap(
        &self,
        key: &str,
        revision: u64,
        payload: &str,
    ) -> Result<Option<u64>, String> {
        let value = self
            .call(
                json!({"compare_and_swap": {"key": key, "revision": revision, "payload": payload}}),
            )
            .await?;
        Ok(value.as_u64())
    }

    async fn send(
        &self,
        method: &str,
        url: &str,
        headers: reqwest::header::HeaderMap,
        body: String,
    ) -> Option<(u16, String)> {
        let method = reqwest::Method::from_bytes(method.as_bytes()).ok()?;
        let mut request = self.http.request(method, url).headers(headers);
        if !body.is_empty() {
            request = request.body(body);
        }
        let response = request.send().await.ok()?;
        let status = response.status().as_u16();
        Some((status, response.text().await.ok()?))
    }
}

impl ClaudeSubscriptionHost for Store {
    fn load<'a>(
        &'a self,
        key: &'a str,
    ) -> BoxFuture<'a, Result<ClaudeSubscriptionStoreValue, ClaudeSubscriptionHostError>> {
        Box::pin(async move {
            let (revision, payload) = Store::load(self, key)
                .await
                .map_err(|_| ClaudeSubscriptionHostError)?;
            Ok(ClaudeSubscriptionStoreValue { revision, payload })
        })
    }

    fn compare_and_swap<'a>(
        &'a self,
        key: &'a str,
        expected_revision: u64,
        payload: &'a str,
    ) -> BoxFuture<'a, Result<ClaudeSubscriptionCommit, ClaudeSubscriptionHostError>> {
        Box::pin(async move {
            match Store::compare_and_swap(self, key, expected_revision, payload)
                .await
                .map_err(|_| ClaudeSubscriptionHostError)?
            {
                Some(revision) => Ok(ClaudeSubscriptionCommit::Committed(revision)),
                None => Ok(ClaudeSubscriptionCommit::Conflict(expected_revision)),
            }
        })
    }

    fn request(
        &self,
        request: ClaudeSubscriptionHttpRequest,
    ) -> BoxFuture<'_, Result<ClaudeSubscriptionHttpResponse, ClaudeSubscriptionHostError>> {
        Box::pin(async move {
            let mut headers = request.headers().clone();
            if !request.body().is_empty() {
                headers.insert(
                    reqwest::header::CONTENT_TYPE,
                    reqwest::header::HeaderValue::from_static(request.content_type()),
                );
            }
            let (status, body) = self
                .send(
                    request.method(),
                    request.url(),
                    headers,
                    request.body().to_owned(),
                )
                .await
                .ok_or(ClaudeSubscriptionHostError)?;
            Ok(ClaudeSubscriptionHttpResponse { status, body })
        })
    }
}

impl ChatGptSubscriptionHost for Store {
    fn load<'a>(
        &'a self,
        key: &'a str,
    ) -> BoxFuture<'a, Result<SubscriptionStoreValue, SubscriptionHostError>> {
        Box::pin(async move {
            let (revision, payload) = Store::load(self, key)
                .await
                .map_err(SubscriptionHostError::new)?;
            Ok(SubscriptionStoreValue { revision, payload })
        })
    }

    fn compare_and_swap<'a>(
        &'a self,
        key: &'a str,
        expected_revision: u64,
        payload: &'a str,
    ) -> BoxFuture<'a, Result<SubscriptionCommit, SubscriptionHostError>> {
        Box::pin(async move {
            match Store::compare_and_swap(self, key, expected_revision, payload)
                .await
                .map_err(SubscriptionHostError::new)?
            {
                Some(revision) => Ok(SubscriptionCommit::Committed(revision)),
                None => Ok(SubscriptionCommit::Conflict(expected_revision)),
            }
        })
    }

    fn request<'a>(
        &'a self,
        request: SubscriptionHttpRequest,
    ) -> BoxFuture<'a, Result<SubscriptionHttpResponse, SubscriptionHostError>> {
        Box::pin(async move {
            let mut headers = reqwest::header::HeaderMap::new();
            if let Ok(value) = reqwest::header::HeaderValue::from_str(request.content_type()) {
                headers.insert(reqwest::header::CONTENT_TYPE, value);
            }
            let (status, body) = self
                .send(
                    request.method(),
                    request.url(),
                    headers,
                    request.body().to_owned(),
                )
                .await
                .ok_or_else(|| SubscriptionHostError::new("the request failed"))?;
            Ok(SubscriptionHttpResponse { status, body })
        })
    }
}

fn claude(host: &Arc<Host>) -> Result<ClaudeSubscription, String> {
    ClaudeSubscription::new(
        Arc::new(Store::of(host)),
        CLAUDE_KEY,
        ClaudeSubscriptionConfig::default(),
    )
    .map_err(text)
}

async fn chatgpt(host: &Arc<Host>) -> Result<ChatGptSubscription, String> {
    ChatGptSubscription::open_with_issuer(Store::of(host), CHATGPT_KEY, None, CHATGPT_ISSUER)
        .await
        .map_err(text)
}

pub fn claude_provider(host: &Arc<Host>) -> Result<Arc<dyn ClaudeAuthProvider>, String> {
    Ok(Arc::new(claude(host)?))
}

pub async fn chatgpt_auth(host: &Arc<Host>) -> Result<OpenAiAuth, String> {
    chatgpt(host).await?.authorization().await.map_err(text)
}

pub async fn sign_in(
    host: &Arc<Host>,
    provider: Provider,
    redirect_uri: Option<String>,
) -> Result<Value, String> {
    match provider {
        Provider::Claude => {
            let mode = redirect_uri.map_or(ClaudeLoginMode::Manual, |redirect_uri| {
                ClaudeLoginMode::Callback { redirect_uri }
            });
            let login = claude(host)?.begin_login(mode).await.map_err(text)?;
            Ok(
                json!({"authorization_url": login.authorization_url, "expires_at_ms": login.expires_at}),
            )
        }
        Provider::Codex => Ok(chatgpt_status(
            chatgpt(host).await?.start_login().await.map_err(text)?,
        )),
    }
}

pub async fn complete(host: &Arc<Host>, code: &str) -> Result<Value, String> {
    Ok(claude_status(
        claude(host)?.complete_login(code).await.map_err(text)?,
    ))
}

pub async fn status(host: &Arc<Host>, provider: Provider) -> Result<Value, String> {
    match provider {
        Provider::Claude => Ok(claude_status(claude(host)?.status().await.map_err(text)?)),
        Provider::Codex => Ok(chatgpt_status(
            chatgpt(host).await?.status().await.map_err(text)?,
        )),
    }
}

pub async fn sign_out(host: &Arc<Host>, provider: Provider) -> Result<Value, String> {
    match provider {
        Provider::Claude => claude(host)?.logout().await.map_err(text)?,
        Provider::Codex => chatgpt(host).await?.logout().await.map_err(text)?,
    }
    Ok(Value::Null)
}

fn claude_status(status: ClaudeSubscriptionStatus) -> Value {
    match status {
        ClaudeSubscriptionStatus::SignedOut => json!({"state": "signed_out"}),
        ClaudeSubscriptionStatus::AccountOnHold => json!({"state": "account_on_hold"}),
        ClaudeSubscriptionStatus::Pending { expires_at } => {
            json!({"state": "pending", "expires_at_ms": expires_at})
        }
        ClaudeSubscriptionStatus::Expired => json!({"state": "expired"}),
        ClaudeSubscriptionStatus::ExchangeUncertain => json!({"state": "exchange_uncertain"}),
        ClaudeSubscriptionStatus::Validating => json!({"state": "validating"}),
        ClaudeSubscriptionStatus::Authenticated {
            account_id,
            expires_at,
            ..
        } => {
            json!({"state": "authenticated", "account_id": account_id, "expires_at_ms": expires_at})
        }
    }
}

fn chatgpt_status(status: ChatGptLoginStatus) -> Value {
    match status {
        ChatGptLoginStatus::SignedOut => json!({"state": "signed_out"}),
        ChatGptLoginStatus::Expired => json!({"state": "expired"}),
        ChatGptLoginStatus::Pending {
            verification_url,
            user_code,
            expires_at,
            ..
        } => json!({
            "state": "pending",
            "verification_url": verification_url,
            "user_code": user_code,
            "expires_at_ms": expires_at,
        }),
        ChatGptLoginStatus::Authenticated {
            account_id,
            expires_at,
        } => {
            json!({"state": "authenticated", "account_id": account_id, "expires_at_ms": expires_at})
        }
    }
}
