use std::{
    collections::HashMap,
    ffi::c_void,
    path::PathBuf,
    sync::{
        Arc,
        atomic::{AtomicU64, Ordering},
    },
};

use nanocode_sync::{Atom, Slot};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use tokio::sync::{OnceCell, oneshot};

use crate::{
    command::{self, Command},
    hand::Hands,
    payments::Payments,
    session::{Sessions, Storage},
};

pub type Callback = unsafe extern "C" fn(context: *mut c_void, data: *const u8, length: usize);

#[derive(Clone, Copy)]
struct Outlet {
    callback: Callback,
    context: usize,
}

unsafe impl Send for Outlet {}
unsafe impl Sync for Outlet {}

impl Outlet {
    fn send(&self, bytes: &[u8]) {
        unsafe { (self.callback)(self.context as *mut c_void, bytes.as_ptr(), bytes.len()) }
    }
}

type Pending = oneshot::Sender<Result<Value, String>>;

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Start {
    pub data_dir: PathBuf,
    #[serde(default)]
    pub tempo_home: Option<PathBuf>,
}

pub struct Host {
    outlet: Outlet,
    calls: Atom<HashMap<u64, Arc<Slot<Pending>>>>,
    next: AtomicU64,
    pub data_dir: PathBuf,
    pub storage: OnceCell<Arc<Storage>>,
    pub sessions: Sessions,
    pub hands: Hands,
    pub payments: Payments,
}

struct Forget<'a>(&'a Host, u64);

impl Drop for Forget<'_> {
    fn drop(&mut self) {
        let id = self.1;
        self.0.calls.update(|calls| {
            calls.remove(&id);
        });
    }
}

impl Host {
    pub fn emit(&self, message: &impl Serialize) {
        match serde_json::to_vec(message) {
            Ok(bytes) => self.outlet.send(&bytes),
            Err(error) => {
                let fallback =
                    json!({"log": format!("could not encode a message for the host: {error}")});
                if let Ok(bytes) = serde_json::to_vec(&fallback) {
                    self.outlet.send(&bytes);
                }
            }
        }
    }

    pub async fn call(&self, kind: &str, body: Value) -> Result<Value, String> {
        let id = self.next.fetch_add(1, Ordering::Relaxed);
        let (sender, receiver) = oneshot::channel();
        let slot = Arc::new(Slot::new(Some(sender)));
        self.calls.update(|calls| {
            calls.insert(id, Arc::clone(&slot));
        });
        let _forget = Forget(self, id);
        self.emit(&json!({"call": {"id": id, "kind": kind, "body": body}}));
        receiver
            .await
            .map_err(|_| format!("the app did not answer its {kind} call"))?
    }

    pub fn resolve(&self, id: u64, result: Result<Value, String>) -> bool {
        let Some(slot) = self.calls.read(|calls| calls.get(&id).cloned()) else {
            return false;
        };
        slot.take()
            .is_some_and(|sender| sender.send(result).is_ok())
    }

    pub async fn storage(&self) -> Result<Arc<Storage>, String> {
        self.storage
            .get_or_try_init(|| async {
                tokio::fs::create_dir_all(&self.data_dir)
                    .await
                    .map_err(|error| format!("create {}: {error}", self.data_dir.display()))?;
                Storage::open(&self.data_dir).await.map(Arc::new)
            })
            .await
            .cloned()
    }
}

pub struct Handle {
    host: Arc<Host>,
    runtime: tokio::runtime::Runtime,
}

#[derive(Deserialize)]
struct Envelope {
    #[serde(default)]
    id: Option<u64>,
    command: Command,
}

#[derive(Serialize)]
struct Reply<'a> {
    reply: u64,
    #[serde(skip_serializing_if = "Option::is_none")]
    ok: Option<&'a Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    error: Option<&'a str>,
}

fn start(start: Start, outlet: Outlet) -> Result<Handle, String> {
    nanocode::codex::transport::install_default_rustls_crypto_provider();
    let runtime = tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .thread_name("nanocode")
        .build()
        .map_err(|error| error.to_string())?;
    let payments = Payments::new(start.tempo_home.clone(), start.data_dir.join("payments"));
    let host = Arc::new(Host {
        outlet,
        calls: Atom::default(),
        next: AtomicU64::new(1),
        data_dir: start.data_dir,
        storage: OnceCell::new(),
        sessions: Sessions::default(),
        hands: Hands::default(),
        payments,
    });
    host.payments.attach(&host);
    Ok(Handle { host, runtime })
}

fn receive(handle: &Handle, bytes: &[u8]) {
    let host = Arc::clone(&handle.host);
    let envelope = match serde_json::from_slice::<Envelope>(bytes) {
        Ok(envelope) => envelope,
        Err(error) => {
            let id = serde_json::from_slice::<Value>(bytes)
                .ok()
                .and_then(|value| value.get("id").and_then(Value::as_u64));
            match id {
                Some(id) => host.emit(&Reply {
                    reply: id,
                    ok: None,
                    error: Some(&format!("command: {error}")),
                }),
                None => host.emit(&json!({"log": format!("unreadable command: {error}")})),
            }
            return;
        }
    };
    handle.runtime.spawn(async move {
        let result = command::execute(&host, envelope.command).await;
        if let Some(id) = envelope.id {
            match &result {
                Ok(value) => host.emit(&Reply {
                    reply: id,
                    ok: Some(value),
                    error: None,
                }),
                Err(error) => host.emit(&Reply {
                    reply: id,
                    ok: None,
                    error: Some(error),
                }),
            }
        }
    });
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn nanocode_start(
    config: *const u8,
    length: usize,
    callback: Callback,
    context: *mut c_void,
) -> *mut Handle {
    let outlet = Outlet {
        callback,
        context: context as usize,
    };
    let bytes = if config.is_null() {
        &[][..]
    } else {
        unsafe { std::slice::from_raw_parts(config, length) }
    };
    let started = serde_json::from_slice::<Start>(bytes)
        .map_err(|error| format!("start configuration: {error}"))
        .and_then(|config| start(config, outlet));
    match started {
        Ok(handle) => Box::into_raw(Box::new(handle)),
        Err(error) => {
            if let Ok(bytes) = serde_json::to_vec(&json!({"fatal": error})) {
                outlet.send(&bytes);
            }
            std::ptr::null_mut()
        }
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn nanocode_send(handle: *mut Handle, data: *const u8, length: usize) {
    let Some(handle) = (unsafe { handle.as_ref() }) else {
        return;
    };
    let bytes = if data.is_null() {
        &[][..]
    } else {
        unsafe { std::slice::from_raw_parts(data, length) }
    };
    receive(handle, bytes);
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn nanocode_stop(handle: *mut Handle) {
    if handle.is_null() {
        return;
    }
    let handle = unsafe { Box::from_raw(handle) };
    let host = Arc::clone(&handle.host);
    handle.runtime.block_on(async move {
        host.hands.stop_all().await;
        host.sessions.close_all().await;
    });
    handle
        .runtime
        .shutdown_timeout(std::time::Duration::from_secs(2));
}
