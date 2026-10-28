use std::{
    collections::{BTreeMap, HashMap},
    path::PathBuf,
    sync::{
        Arc, OnceLock, Weak,
        atomic::{AtomicU64, Ordering},
    },
    time::Duration,
};

use async_trait::async_trait;
use mpp::{
    Address, MppError, PaymentChallenge, PaymentCredential,
    client::{
        AcceptPaymentPolicy, ClientEventSubscription, ClientEvents, DEFAULT_MAX_PAYMENT_RETRIES,
        Exchange, FlowError, ManagementFuture, ManagementTransport, PaymentContext,
        PaymentProvider, PendingPayment, TempoAccountsProvider,
        tempo::session::store::{SqliteChannelStore, SqliteChannelStoreOptions},
    },
    mcp::client::McpPayment,
    protocol::methods::tempo::{CHAIN_ID, USDC, machine_token},
};
use nanocode::{
    ClaudeModel, Model, Tool,
    codex::transport::host::{
        ConnectedHost, HostConnectRequest, HostError, HostFuture, HostHttpResponse, HostTransport,
        send_http,
    },
    http::{self as layer, BoxFuture, Event, EventHook, Layer, Next},
};
use nanocode_mcp_tools::{
    Mcp, McpPaymentManagement, McpPaymentProvider, McpPendingPayment, McpServer,
};
use nanocode_sync::Atom;
use reqwest::ResponseBuilderExt;
use serde::Serialize;
use serde_json::{Value, json};

use crate::{bridge::Host, config::McpServerConfig};

pub const MACH: u128 = 1_000_000;
const PREPAID_REQUESTS: u32 = 2;
const MODEL_DEPOSIT: u128 = MACH / 5;
const TOOL_DEPOSIT: u128 = MACH / 20;
const MCP_TIMEOUT: Duration = Duration::from_secs(20);
pub const MERCATOR: &str = "https://mercator.sh/mcp";
pub const GATEWAY: &str = "https://gateway.tempo-dev.workers.dev/mcp";

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Service {
    OpenAi,
    Anthropic,
}

impl Service {
    pub const fn url(self) -> &'static str {
        match self {
            Self::OpenAi => "https://openai.mpp.tempo.xyz/v1",
            Self::Anthropic => "https://anthropic.mpp.tempo.xyz/v1/messages",
        }
    }

    fn probe(self, url: &str) -> (String, &'static str) {
        match self {
            Self::OpenAi => (
                format!("{}/responses", url.trim_end_matches('/')),
                Model::Luna.as_str(),
            ),
            Self::Anthropic => (url.to_owned(), ClaudeModel::Haiku55.as_str()),
        }
    }
}

#[derive(Clone)]
pub struct Wallet {
    pub provider: TempoAccountsProvider,
    pub account: Address,
    pub key: Address,
    pub source: &'static str,
    pub shared_channels: bool,
    generation: u64,
}

#[derive(Clone, Default, Serialize)]
struct Spend {
    host: String,
    description: Option<String>,
    model: bool,
    symbol: String,
    spent: String,
    requests: u64,
    last: String,
    #[serde(skip)]
    spent_units: u128,
}

#[derive(Clone, Default)]
struct Ledger {
    services: BTreeMap<String, Spend>,
}

struct Inner {
    wallet: Atom<Option<Wallet>>,
    services: Atom<HashMap<String, (u64, TempoAccountsProvider)>>,
    generations: AtomicU64,
    events: ClientEvents,
    ledger: Atom<Ledger>,
    host: OnceLock<Weak<Host>>,
    channels: PathBuf,
    _observers: OnceLock<[ClientEventSubscription; 3]>,
}

#[derive(Clone)]
pub struct Payments(Arc<Inner>);

impl Payments {
    pub fn new(_tempo_home: Option<PathBuf>, directory: PathBuf) -> Self {
        let payments = Self(Arc::new(Inner {
            wallet: Atom::default(),
            services: Atom::default(),
            generations: AtomicU64::new(1),
            events: ClientEvents::default(),
            ledger: Atom::default(),
            host: OnceLock::new(),
            channels: directory.join("channels.db"),
            _observers: OnceLock::new(),
        }));
        let (paid, deposited, updated) = (
            Arc::downgrade(&payments.0),
            Arc::downgrade(&payments.0),
            Arc::downgrade(&payments.0),
        );
        let observers = [
            payments.0.events.on_payment_response(move |context| {
                if let (Some(inner), Some(amount)) = (paid.upgrade(), context.amount) {
                    let funding = context.funding_currency.clone().or_else(|| {
                        Some(
                            context
                                .receipt
                                .as_deref()?
                                .extensions
                                .get("fundingCurrency")?
                                .as_str()?
                                .to_owned(),
                        )
                    });
                    Payments(inner).record(&context.url, &context.challenge, amount, funding);
                }
                async {}
            }),
            payments.0.events.on_deposit(move |context| {
                if let Some(inner) = deposited.upgrade() {
                    let host = context.url.host_str().unwrap_or_default();
                    let notice = if context.opened {
                        format!("opened a {} MACH session with {host}", mach(context.amount))
                    } else {
                        format!(
                            "topped up the {host} session by {} MACH",
                            mach(context.amount)
                        )
                    };
                    Payments(inner).notice(notice);
                }
                async {}
            }),
            payments.0.events.on_payment_update(move |context| {
                if let Some(inner) = updated.upgrade() {
                    Payments(inner).update(&context.url, context.change);
                }
                async {}
            }),
        ];
        let _ = payments.0._observers.set(observers);
        payments
    }

    pub fn attach(&self, host: &Arc<Host>) {
        let _ = self.0.host.set(Arc::downgrade(host));
    }

    pub fn machine() -> Result<Address, String> {
        machine_token::token(CHAIN_ID)
            .ok_or_else(|| "MACH is not deployed on Tempo mainnet".to_owned())
    }

    pub fn install(
        &self,
        provider: TempoAccountsProvider,
        account: Address,
        key: Address,
        source: &'static str,
        shared_channels: bool,
    ) -> Result<(), String> {
        let provider = provider
            .with_expected_chain_id(CHAIN_ID)
            .with_preferred_currency(Self::machine()?)
            .with_session_prepaid_requests(PREPAID_REQUESTS)
            .with_session_events(self.0.events.clone());
        let generation = self.0.generations.fetch_add(1, Ordering::Relaxed);
        self.0.wallet.set(Some(Wallet {
            provider,
            account,
            key,
            source,
            shared_channels,
            generation,
        }));
        self.0.services.set(HashMap::new());
        self.changed();
        Ok(())
    }

    pub fn forget(&self) {
        self.0.wallet.set(None);
        self.0.services.set(HashMap::new());
        self.changed();
    }

    pub fn wallet(&self) -> Option<Wallet> {
        self.0.wallet.read(Clone::clone)
    }

    fn service_wallet(
        &self,
        url: &reqwest::Url,
        deposit: u128,
    ) -> Result<Option<(u64, TempoAccountsProvider)>, String> {
        let Some(wallet) = self.wallet() else {
            return Ok(None);
        };
        let origin = url.origin().ascii_serialization();
        if let Some(found) = self.0.services.read(|services| {
            services
                .get(&origin)
                .filter(|(generation, _)| *generation == wallet.generation)
                .cloned()
        }) {
            return Ok(Some(found));
        }
        let store = SqliteChannelStore::open(SqliteChannelStoreOptions {
            namespace: origin.clone(),
            path: (!wallet.shared_channels).then(|| self.0.channels.clone()),
            request_url: Some(url.to_string()),
        })
        .map_err(|error| format!("open the payment channel store: {error}"))?;
        if let Some(parent) = self.0.channels.parent() {
            let _ = std::fs::create_dir_all(parent);
        }
        let provider = wallet
            .provider
            .clone()
            .with_session_default_deposit(deposit)
            .with_session_top_up_amount(deposit)
            .with_session_store(Arc::new(store));
        let entry = (wallet.generation, provider);
        self.0.services.update(|services| {
            services.insert(origin.clone(), entry.clone());
        });
        Ok(Some(entry))
    }

    pub fn layer(&self, service: Service, url: &str) -> Result<Mpp, String> {
        Ok(Mpp {
            payments: self.clone(),
            probe: service.probe(url),
            client: reqwest::Client::builder()
                .redirect(reqwest::redirect::Policy::none())
                .build()
                .map_err(|error| error.to_string())?,
            warmed: Arc::new(AtomicU64::new(0)),
        })
    }

    pub fn paid_servers() -> Vec<McpServerConfig> {
        [("mercator", MERCATOR), ("gateway", GATEWAY)]
            .into_iter()
            .map(|(name, url)| McpServerConfig {
                name: name.to_owned(),
                url: url.to_owned(),
                headers: Default::default(),
                command: Vec::new(),
                env: Default::default(),
                bearer_token: None,
                paid: true,
            })
            .collect()
    }

    pub async fn mcp_tools(
        &self,
        servers: &[McpServerConfig],
    ) -> Result<Vec<Arc<dyn Tool>>, String> {
        if servers.is_empty() {
            return Ok(Vec::new());
        }
        let mut mcp = Mcp::builder();
        for config in servers {
            if let Some((program, arguments)) = config.command.split_first() {
                if cfg!(target_os = "ios") {
                    return Err(format!(
                        "MCP server {}: iOS apps cannot run local commands",
                        config.name
                    ));
                }
                let server = config.env.iter().fold(
                    McpServer::stdio(program.clone()).args(arguments.iter().cloned()),
                    |server, (name, value)| server.env(name.clone(), value.clone()),
                );
                mcp = mcp.server(config.name.clone(), server);
                continue;
            }
            let url: reqwest::Url = config
                .url
                .parse()
                .map_err(|error: url::ParseError| format!("MCP server {}: {error}", config.name))?;
            let mut server = McpServer::http(url.as_str());
            for (name, value) in &config.headers {
                server = server.header(name.clone(), value.clone());
            }
            if let Some(token) = &config.bearer_token {
                server = server.bearer_token(token.clone());
            }
            if config.paid {
                server = server.payment_provider(Arc::new(McpPayments {
                    payments: self.clone(),
                    url,
                }));
            }
            mcp = mcp.server(config.name.clone(), server);
        }
        let mcp = mcp.build().map_err(|error| error.to_string())?;
        let servers = mcp.prepared_servers(MCP_TIMEOUT).await;
        let mut tools: Vec<Arc<dyn Tool>> = Vec::new();
        for (name, prepared) in servers {
            match prepared {
                Ok(prepared) => tools.extend(
                    prepared
                        .into_iter()
                        .map(|tool| Arc::new(tool) as Arc<dyn Tool>),
                ),
                Err(error) => self.notice(format!("the {name} MCP server is unavailable: {error}")),
            }
        }
        Ok(tools)
    }

    fn record(
        &self,
        url: &reqwest::Url,
        challenge: &PaymentChallenge,
        amount: u128,
        funding: Option<String>,
    ) {
        let Some(host) = url.host_str().map(str::to_owned) else {
            return;
        };
        let model = host.ends_with(".mpp.tempo.xyz")
            && (host.starts_with("openai.") || host.starts_with("anthropic."));
        let currency = funding.or_else(|| {
            challenge
                .request
                .decode::<Value>()
                .ok()?
                .get("currency")?
                .as_str()
                .map(str::to_owned)
        });
        let symbol = currency.as_deref().map_or_else(String::new, symbol);
        let description = challenge
            .description
            .clone()
            .filter(|description| !model && !description.trim().is_empty());
        let key = match &description {
            Some(description) => format!("{host} · {description}"),
            None => host.clone(),
        };
        self.0.ledger.update(|ledger| {
            let entry = ledger.services.entry(key.clone()).or_insert_with(|| Spend {
                host: host.clone(),
                description: description.clone(),
                model,
                symbol: symbol.clone(),
                ..Spend::default()
            });
            entry.spent_units += amount;
            entry.spent = mach(entry.spent_units);
            entry.requests += 1;
            entry.last = mach(amount);
        });
        if !model {
            self.notice(format!("paid {} {symbol} to {key}", mach(amount)));
        }
        self.changed();
    }

    fn update(&self, url: &reqwest::Url, change: i128) {
        let Some(host) = url.host_str().map(str::to_owned) else {
            return;
        };
        self.0.ledger.update(|ledger| {
            if let Some(entry) = ledger.services.get_mut(&host) {
                entry.spent_units = entry.spent_units.saturating_add_signed(change);
                entry.spent = mach(entry.spent_units);
            }
        });
        self.changed();
    }

    fn notice(&self, notice: String) {
        if let Some(host) = self.0.host.get().and_then(Weak::upgrade) {
            host.emit(&json!({"payments": {"notice": notice}}));
        }
    }

    pub fn status(&self) -> Value {
        let wallet = self.wallet();
        let services = self
            .0
            .ledger
            .read(|ledger| ledger.services.values().cloned().collect::<Vec<_>>());
        let total: u128 = services.iter().map(|spend| spend.spent_units).sum();
        json!({
            "wallet": wallet.map(|wallet| json!({
                "account": wallet.account.to_string(),
                "key": wallet.key.to_string(),
                "source": wallet.source,
            })),
            "total": mach(total),
            "services": services,
        })
    }

    fn changed(&self) {
        if let Some(host) = self.0.host.get().and_then(Weak::upgrade) {
            host.emit(&json!({"payments": {"status": self.status()}}));
        }
    }
}

pub fn mach(amount: u128) -> String {
    format!("{}.{:06}", amount / MACH, amount % MACH)
}

fn symbol(currency: &str) -> String {
    let machine = Payments::machine().ok();
    match currency.parse::<Address>() {
        Ok(currency) if Some(currency) == machine => "MACH".to_owned(),
        Ok(currency) if USDC.parse() == Ok(currency) => "USDC.e".to_owned(),
        _ => currency.to_owned(),
    }
}

const WALLET_REQUIRED: &str = "tempo_wallet_required: this model is paid with Tempo machine payments and no Tempo Wallet is connected, so nothing was sent. Connect a Tempo Wallet in the app, then send the message again.";

#[derive(Clone)]
pub struct Mpp {
    payments: Payments,
    probe: (String, &'static str),
    client: reqwest::Client,
    warmed: Arc<AtomicU64>,
}

impl Mpp {
    async fn preconnect(&self, generation: u64, wallet: &TempoAccountsProvider) {
        if self.warmed.swap(generation, Ordering::AcqRel) == generation {
            return;
        }
        let (url, model) = &self.probe;
        let body = json!({ "model": model }).to_string();
        let _ = wallet.preconnect(&self.client, url, body).await;
    }
}

impl Layer for Mpp {
    fn send<'a>(
        &'a self,
        request: layer::Request,
        next: Next<'a>,
    ) -> BoxFuture<'a, Result<layer::Response, layer::Error>> {
        Box::pin(async move {
            let url = reqwest::Url::parse(&request.url)
                .map_err(|error| layer::Error::new(error.to_string()).unsent(true))?;
            let Some((generation, wallet)) = self
                .payments
                .service_wallet(&url, MODEL_DEPOSIT)
                .map_err(|error| layer::Error::new(error).unsent(true))?
            else {
                return Err(layer::Error::new(WALLET_REQUIRED).unsent(true));
            };
            self.preconnect(generation, &wallet).await;
            let mut paid = reqwest::Request::new(request.method, url);
            *paid.headers_mut() = request.headers;
            *paid.body_mut() = Some(request.body.into());
            let mut exchange = NextExchange {
                next,
                client: self.client.clone(),
                body: None,
            };
            let response = mpp::client::send_with_exchange(
                &mut exchange,
                paid,
                &wallet,
                &AcceptPaymentPolicy::Always,
                &self.payments.0.events,
                DEFAULT_MAX_PAYMENT_RETRIES,
            )
            .await
            .map_err(|error| match error {
                FlowError::Send(error) => error,
                FlowError::Payment(error) => layer::Error::new(explain(&error.to_string())),
            })?;
            let body = exchange
                .body
                .ok_or_else(|| layer::Error::new("the payment flow returned no response"))?;
            Ok(
                layer::Response::new(response.status(), response.headers().clone(), body)
                    .with_events(StreamPayments {
                        wallet,
                        client: self.client.clone(),
                        url: request.url,
                    }),
            )
        })
    }
}

pub fn explain(text: &str) -> String {
    if text.contains("insufficient funds for gas")
        || (text.contains("InsufficientBalance")
            && text.to_lowercase().contains(&USDC.to_lowercase()))
    {
        return format!(
            "Publishing the key needs a little USDC.e for its fee, and the wallet holds too little. Add USDC.e in Tempo Wallet, then try again. ({text})"
        );
    }
    if text.contains("InsufficientBalance") {
        return format!(
            "The Tempo Wallet holds too little MACH for this payment. Add MACH in Tempo Wallet, then try again. ({text})"
        );
    }
    if text.contains("SpendingLimitExceeded") {
        return format!(
            "The access key's limit is spent. Disconnect and connect the Tempo Wallet again to approve another key. ({text})"
        );
    }
    format!("payment failed: {text}")
}

struct StreamPayments {
    wallet: TempoAccountsProvider,
    client: reqwest::Client,
    url: String,
}

impl EventHook for StreamPayments {
    fn event(&mut self, event: Event<'_>) -> Option<BoxFuture<'static, Result<(), layer::Error>>> {
        let work = self
            .wallet
            .stream_event(&self.client, &self.url, event.name?, event.data)?;
        Some(Box::pin(async move {
            work.await
                .map_err(|error| layer::Error::new(format!("MPP session stream: {error}")))
        }))
    }
}

struct NextExchange<'a> {
    next: Next<'a>,
    client: reqwest::Client,
    body: Option<layer::Body>,
}

impl Exchange for NextExchange<'_> {
    type Error = layer::Error;

    fn http_client(&self) -> Option<reqwest::Client> {
        Some(self.client.clone())
    }

    async fn send(&mut self, request: reqwest::Request) -> Result<reqwest::Response, layer::Error> {
        let sent = layer::Request {
            method: request.method().clone(),
            url: request.url().to_string(),
            headers: request.headers().clone(),
            body: request
                .body()
                .and_then(reqwest::Body::as_bytes)
                .map(<[u8]>::to_vec)
                .unwrap_or_default(),
        };
        let (status, headers, body, _) = self.next.send(sent).await?.into_parts();
        self.body = Some(body);
        let mut response = http::Response::builder()
            .status(status)
            .url(request.url().clone())
            .body(reqwest::Body::from(Vec::new()))
            .map_err(|error| layer::Error::new(error.to_string()))?;
        *response.headers_mut() = headers;
        Ok(response.into())
    }
}

pub struct Transport<L> {
    layer: L,
    client: reqwest::Client,
}

impl<L: Layer> Transport<L> {
    pub fn new(layer: L) -> Self {
        Self {
            layer,
            client: reqwest::Client::new(),
        }
    }
}

struct Layered<'a, L> {
    layer: &'a L,
    client: &'a reqwest::Client,
}

impl<L: Layer> layer::Sender for Layered<'_, L> {
    fn send(
        &self,
        request: layer::Request,
    ) -> BoxFuture<'_, Result<layer::Response, layer::Error>> {
        Box::pin(async move {
            let sender = nanocode_http::ReqwestSender::new(self.client);
            self.layer.send(request, Next::new(&sender)).await
        })
    }
}

impl<L: Layer> HostTransport for Transport<L> {
    fn connect<'a>(
        &'a self,
        _request: HostConnectRequest<'a>,
    ) -> HostFuture<'a, Result<ConnectedHost, HostError>> {
        Box::pin(async {
            Err(HostError::new(
                "this host sends web search requests over HTTPS only",
            ))
        })
    }

    fn http<'a>(
        &'a self,
        request: HostConnectRequest<'a>,
        body: &'a str,
    ) -> HostFuture<'a, Result<HostHttpResponse, HostError>> {
        Box::pin(async move {
            let sender = Layered {
                layer: &self.layer,
                client: &self.client,
            };
            send_http(&sender, request, body).await
        })
    }

    fn sleep<'a>(&'a self, _session_id: &'a str, duration: Duration) -> HostFuture<'a, ()> {
        Box::pin(tokio::time::sleep(duration))
    }
}

#[derive(Clone)]
pub struct Headers(pub http::HeaderMap);

impl Layer for Headers {
    fn send<'a>(
        &'a self,
        mut request: layer::Request,
        next: Next<'a>,
    ) -> BoxFuture<'a, Result<layer::Response, layer::Error>> {
        for (name, value) in &self.0 {
            request.headers.insert(name, value.clone());
        }
        next.send(request)
    }
}

struct McpPayments {
    payments: Payments,
    url: reqwest::Url,
}

#[async_trait]
impl McpPaymentProvider for McpPayments {
    async fn prepare(
        &self,
        payment_required: &Value,
    ) -> Result<Option<Box<dyn McpPendingPayment>>, String> {
        self.pay(payment_required, None).await
    }

    async fn prepare_with_management(
        &self,
        payment_required: &Value,
        management: &dyn McpPaymentManagement,
    ) -> Result<Option<Box<dyn McpPendingPayment>>, String> {
        self.pay(payment_required, Some(&ToolCall(management)))
            .await
    }
}

impl McpPayments {
    async fn pay(
        &self,
        payment_required: &Value,
        management: Option<&ToolCall<'_>>,
    ) -> Result<Option<Box<dyn McpPendingPayment>>, String> {
        let Some(challenges) = mpp::mcp::extract_challenges_from_data(payment_required) else {
            return Ok(None);
        };
        let Some((_, wallet)) = self.payments.service_wallet(&self.url, TOOL_DEPOSIT)? else {
            return Err(WALLET_REQUIRED.replace("this model", "this tool"));
        };
        let payment = McpPayment::new(
            wallet.clone(),
            PaymentContext {
                url: self.url.clone(),
                headers: Default::default(),
                http_client: None,
            },
        );
        let pending = match management {
            Some(management) => {
                payment
                    .prepare_with_management(&challenges, management)
                    .await
            }
            None => payment.prepare(&challenges).await,
        }
        .map_err(|error| explain(&error.to_string()))?;
        let Some(pending) = pending else {
            return Ok(None);
        };
        Ok(Some(Box::new(McpPending {
            credential: mpp::mcp::credential_value(pending.credential())
                .map_err(|error| error.to_string())?,
            pending,
            payment,
            wallet,
            receipt: None,
            url: self.url.clone(),
            payments: self.payments.clone(),
        })))
    }
}

struct ToolCall<'a>(&'a dyn McpPaymentManagement);

impl ManagementTransport for ToolCall<'_> {
    fn send<'a>(
        &'a self,
        _challenge: &'a PaymentChallenge,
        credential: &'a PaymentCredential,
    ) -> ManagementFuture<'a> {
        Box::pin(async move {
            let receipt = self
                .0
                .send(mpp::mcp::credential_value(credential)?)
                .await
                .map_err(MppError::Http)?;
            Ok(receipt.and_then(|receipt| serde_json::from_value(receipt).ok()))
        })
    }
}

struct McpPending {
    wallet: TempoAccountsProvider,
    pending: PendingPayment<TempoAccountsProvider>,
    payment: McpPayment<TempoAccountsProvider>,
    credential: Value,
    receipt: Option<Value>,
    url: reqwest::Url,
    payments: Payments,
}

#[async_trait]
impl McpPendingPayment for McpPending {
    fn credential(&self) -> &Value {
        &self.credential
    }

    fn receipt(&mut self, receipt: &Value) {
        self.receipt = Some(receipt.clone());
    }

    async fn commit(self: Box<Self>) -> Result<(), String> {
        let challenge = self.pending.challenge();
        let charged = self
            .receipt
            .clone()
            .and_then(|receipt| serde_json::from_value(receipt).ok())
            .and_then(|receipt| self.payment.record_receipt(challenge, &receipt));
        let amount = charged.or_else(|| {
            challenge
                .request
                .decode::<Value>()
                .ok()
                .and_then(|request| request.get("amount")?.as_str()?.parse().ok())
        });
        if let Some(amount) = amount {
            self.payments.record(
                &self.url,
                challenge,
                amount,
                self.wallet.funding_currency(challenge),
            );
        }
        self.pending
            .commit()
            .await
            .map_err(|error| error.to_string())
    }

    async fn rollback(self: Box<Self>) -> Result<(), String> {
        self.pending
            .rollback()
            .await
            .map_err(|error| error.to_string())
    }
}
