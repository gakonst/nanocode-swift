use std::time::{Duration, SystemTime, UNIX_EPOCH};

use base64::{Engine as _, engine::general_purpose::URL_SAFE_NO_PAD};
use mpp::{
    Address, PrivateKeySigner,
    client::TempoAccountsProvider,
    protocol::methods::tempo::{CHAIN_ID, USDC},
};
use rand::RngCore as _;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use sha2::{Digest as _, Sha256};
use tempo_alloy::accounts::{TempoAccountsKeyAuthorization, TempoAccountsWallet};

use crate::{bridge::Host, payments::Payments};

const DEVICE: &str = "https://wallet.tempo.xyz/api/auth/device";
const ALLOWANCE: u128 = 2_000_000;
const FEE_ALLOWANCE: u128 = 100_000;
const LIFETIME: Duration = Duration::from_secs(86_400);
const ESCROW: &str = "0x4d50500000000000000000000000000000000000";
const SWAPPER: &str = "0xF72E5107c32C655ffA7539a3C8e97B7C3cE16A3F";
const POLL_TIMEOUT: Duration = Duration::from_secs(30);
const APPROVAL_TIMEOUT: Duration = Duration::from_secs(600);

const APPROVE: &str = "0x095ea7b3";
const OPEN: &str = "0xedc53b00";
const REQUEST_CLOSE: &str = "0x675402e5";
const SWAP_TO: &str = "0x34189fed";
const TOP_UP: &str = "0xdc48471e";
const TRANSFER_WITH_MEMO: &str = "0x95777d59";
const WITHDRAW: &str = "0x41e2c664";

#[derive(Clone, Deserialize, Serialize)]
pub struct Record {
    pub account: String,
    pub key: String,
    pub key_address: String,
    pub expiry: u64,
    pub authorization: Value,
}

#[derive(Deserialize)]
pub struct Meta {
    #[serde(default)]
    pub name: Option<String>,
    #[serde(default)]
    pub website: Option<String>,
    #[serde(default)]
    pub icon: Option<String>,
}

fn now() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |elapsed| elapsed.as_secs())
}

fn hex(bytes: &[u8]) -> String {
    let mut text = String::with_capacity(2 + bytes.len() * 2);
    text.push_str("0x");
    for byte in bytes {
        text.push_str(&format!("{byte:02x}"));
    }
    text
}

fn quantity(value: u128) -> String {
    format!("0x{value:x}")
}

pub fn install(payments: &Payments, record: &Record) -> Result<Value, String> {
    if record.expiry <= now() {
        return Err("the access key expired; connect the Tempo Wallet again".into());
    }
    let signer: PrivateKeySigner = record
        .key
        .parse()
        .map_err(|error| format!("access key: {error}"))?;
    let account: Address = record
        .account
        .parse()
        .map_err(|error| format!("account: {error}"))?;
    let authorization: TempoAccountsKeyAuthorization =
        serde_json::from_value(record.authorization.clone())
            .map_err(|error| format!("key authorization: {error}"))?;
    let key = signer.address();
    let wallet =
        TempoAccountsWallet::from_secp256k1(account, signer, Some(authorization.into_signed()));
    payments.install(
        TempoAccountsProvider::new(wallet),
        account,
        key,
        "app",
        false,
    )?;
    Ok(payments.status())
}

pub fn install_cli(payments: &Payments) -> Result<Value, String> {
    let wallet = TempoAccountsWallet::try_from_default_store()
        .map_err(|error| error.to_string())?
        .ok_or_else(|| "no Tempo CLI wallet here; run 'tempo wallet login' first".to_owned())?;
    let account = wallet.active_account().map_err(|error| error.to_string())?;
    let key = wallet.key_id().map_err(|error| error.to_string())?;
    payments.install(
        TempoAccountsProvider::new(wallet),
        account,
        key,
        "tempo-cli",
        true,
    )?;
    Ok(payments.status())
}

fn verifier() -> String {
    let mut bytes = [0_u8; 32];
    rand::rng().fill_bytes(&mut bytes);
    URL_SAFE_NO_PAD.encode(bytes)
}

fn challenge(verifier: &str) -> String {
    URL_SAFE_NO_PAD.encode(Sha256::digest(verifier.as_bytes()))
}

fn error_of(body: &Value) -> Option<&str> {
    body.get("error").and_then(Value::as_str)
}

fn description(body: &Value) -> String {
    body.get("error_description")
        .and_then(Value::as_str)
        .map_or_else(|| body.to_string(), str::to_owned)
}

pub async fn connect(host: &Host, meta: Meta) -> Result<Value, String> {
    let signer = PrivateKeySigner::random();
    let key_address = signer.address();
    let public = signer.credential().verifying_key().to_encoded_point(false);
    let expiry = now() + LIFETIME.as_secs();
    let machine = Payments::machine()?.to_string();
    let scopes = [
        json!({"address": machine, "selector": TRANSFER_WITH_MEMO}),
        json!({"address": machine, "recipients": [SWAPPER], "selector": APPROVE}),
        json!({"address": SWAPPER, "selector": SWAP_TO}),
    ]
    .into_iter()
    .chain(
        [OPEN, TOP_UP, REQUEST_CLOSE, WITHDRAW]
            .map(|selector| json!({"address": ESCROW, "selector": selector})),
    )
    .collect::<Vec<_>>();
    let request = json!({
        "address": key_address.to_string(),
        "chainId": quantity(u128::from(CHAIN_ID)),
        "expiry": expiry,
        "keyType": "secp256k1",
        "limits": [
            {"limit": quantity(ALLOWANCE), "token": machine},
            {"limit": quantity(FEE_ALLOWANCE), "token": USDC.to_lowercase()},
        ],
        "publicKey": hex(public.as_bytes()),
        "scopes": scopes,
    });
    let envelope = json!({
        "type": "rpc-requests",
        "payload": [{
            "jsonrpc": "2.0",
            "id": 1,
            "method": "wallet_connect",
            "params": [{"capabilities": {"authorizeAccessKey": request}, "chainId": CHAIN_ID}],
            "context": {"chainId": CHAIN_ID},
        }],
    });
    let verifier = verifier();
    let mut meta_json = json!({"name": meta.name.unwrap_or_else(|| "nanocode".into())});
    if let Some(website) = meta.website {
        meta_json["website_url"] = Value::String(website);
    }
    if let Some(icon) = meta.icon {
        meta_json["icon"] = Value::String(icon);
    }
    let client = reqwest::Client::builder()
        .timeout(POLL_TIMEOUT)
        .build()
        .map_err(|error| error.to_string())?;
    let registered = client
        .post(format!("{DEVICE}/register"))
        .json(&json!({
            "code_challenge": challenge(&verifier),
            "code_challenge_method": "S256",
            "message": envelope,
            "meta": meta_json,
        }))
        .send()
        .await
        .map_err(|error| format!("Tempo Wallet device registration failed: {error}"))?;
    let status = registered.status();
    let body: Value = registered.json().await.unwrap_or(Value::Null);
    if !status.is_success() {
        return Err(format!(
            "Tempo Wallet refused the device registration ({status}): {}",
            description(&body)
        ));
    }
    let field = |name: &str| body.get(name).and_then(Value::as_str).map(str::to_owned);
    let (Some(device_code), Some(user_code), Some(verification_uri)) = (
        field("device_code"),
        field("user_code"),
        field("verification_uri"),
    ) else {
        return Err(format!(
            "Tempo Wallet answered the registration without a device code: {body}"
        ));
    };
    let mut interval = Duration::from_secs(
        body.get("interval")
            .and_then(Value::as_u64)
            .unwrap_or(5)
            .max(1),
    );
    host.emit(&json!({"wallet": {"prompt": {
        "user_code": user_code,
        "verification_uri": verification_uri,
        "verification_uri_complete": field("verification_uri_complete"),
        "expires_in": body.get("expires_in").and_then(Value::as_u64).unwrap_or(600),
    }}}));
    let deadline = tokio::time::Instant::now() + APPROVAL_TIMEOUT;
    let envelope = loop {
        if tokio::time::Instant::now() >= deadline {
            return Err(format!(
                "Timed out waiting for approval of code {user_code}."
            ));
        }
        tokio::time::sleep(interval).await;
        let polled = client
            .post(format!("{DEVICE}/token"))
            .json(&json!({
                "code_verifier": verifier,
                "device_code": device_code,
                "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
            }))
            .send()
            .await
            .map_err(|error| format!("polling Tempo Wallet failed: {error}"))?;
        let status = polled.status();
        let body: Value = polled.json().await.unwrap_or(Value::Null);
        if status.is_success() {
            break body;
        }
        match error_of(&body) {
            Some("authorization_pending") => {}
            Some("slow_down") => interval += Duration::from_secs(5),
            Some("access_denied") => {
                return Err("The connection was denied in Tempo Wallet.".into());
            }
            Some("expired_token") => {
                return Err("The device code expired before it was approved.".into());
            }
            _ => {
                return Err(format!(
                    "Tempo Wallet answered {status}: {}",
                    description(&body)
                ));
            }
        }
    };
    let response = envelope
        .get("payload")
        .and_then(Value::as_array)
        .and_then(|payload| payload.first())
        .ok_or_else(|| format!("Tempo Wallet returned no response: {envelope}"))?;
    if let Some(error) = response.get("error") {
        let message = error
            .get("message")
            .and_then(Value::as_str)
            .unwrap_or("the request failed");
        return Err(format!("Tempo Wallet: {message}"));
    }
    let account = response
        .pointer("/result/accounts/0")
        .ok_or_else(|| format!("Tempo Wallet returned no account: {response}"))?;
    let address = account
        .get("address")
        .and_then(Value::as_str)
        .ok_or("Tempo Wallet returned an account without an address")?;
    let authorization = account
        .pointer("/capabilities/keyAuthorization")
        .cloned()
        .ok_or("Tempo Wallet returned no key approval")?;
    let record = Record {
        account: address.to_owned(),
        key: hex(&signer.credential().to_bytes()),
        key_address: key_address.to_string(),
        expiry,
        authorization,
    };
    install(&host.payments, &record)?;
    serde_json::to_value(record).map_err(|error| error.to_string())
}

pub fn funding_url(account: &str) -> String {
    format!(
        "https://wallet.tempo.xyz/agent?action=fund&intent=mach&address={account}&chainId={CHAIN_ID}"
    )
}
