use std::{
    cell::RefCell,
    collections::{BTreeMap, HashMap},
    fs::{File, OpenOptions, Permissions},
    io::{ErrorKind, Write as _},
    os::unix::fs::PermissionsExt as _,
    path::{Path, PathBuf},
    rc::Rc,
    sync::{
        Arc, OnceLock, Weak,
        atomic::{AtomicBool, AtomicU64, Ordering},
        mpsc,
    },
    time::{Duration, Instant, UNIX_EPOCH},
};

use base64::{
    Engine as _,
    alphabet::STANDARD,
    engine::{
        DecodePaddingMode, GeneralPurpose, GeneralPurposeConfig,
        general_purpose::STANDARD as STANDARD_ENGINE,
    },
};
use flate2::{
    Compression,
    write::{DeflateDecoder, DeflateEncoder, GzDecoder, GzEncoder, ZlibDecoder, ZlibEncoder},
};
use nanocode_process_contracts::{
    ExecCommand, ExecCommandResult, ForegroundCommand, ForegroundExecutor, ForegroundOutput,
    ProcessFuture, ShellExecutor, WriteStdin, effective_token_limit, redact_and_limit,
};
use rand::RngCore as _;
use rquickjs::{
    ArrayBuffer, CatchResultExt as _, Context, Ctx, Exception, Function, Module, Object,
    Persistent, Runtime, Value, WriteOptions,
    function::{Func, IntoArgs, Opt},
    qjs,
};
use serde::{Deserialize, Serialize};
use serde_json::{Value as Json, json};
use tokio::sync::oneshot;

use crate::{bridge::Host, files::local, session::text};

mod wasm;

const LAZY: [&str; 4] = ["crypto", "extra", "intl", "web"];
const STACK: usize = 32 << 20;
const MEMORY: usize = 1 << 30;
const COMMAND_MEMORY: u64 = 256 << 20;
const WORKSPACE_TIMEOUT_MS: u64 = 600_000;
const STOPPED: &str = "the simulated shell stopped";

const LENIENT: GeneralPurpose = GeneralPurpose::new(
    &STANDARD,
    GeneralPurposeConfig::new()
        .with_decode_allow_trailing_bits(true)
        .with_decode_padding_mode(DecodePaddingMode::RequireNone),
);

#[derive(Debug, Deserialize, Serialize)]
pub struct Ran {
    pub stdout: String,
    pub stderr: String,
    pub exit_code: i32,
    pub truncated: bool,
}

enum Message {
    Run {
        id: u64,
        request: String,
        reply: oneshot::Sender<Result<Ran, String>>,
    },
    Abort(u64),
    Fetched {
        id: u64,
        result: Result<(Json, Vec<u8>), String>,
    },
    Python {
        id: u64,
        result: Result<String, String>,
    },
    Stop,
}

pub struct Shell {
    cwd: PathBuf,
    cache: PathBuf,
    sources: PathBuf,
    host: Arc<OnceLock<Weak<Host>>>,
    worker: OnceLock<Worker>,
    next: AtomicU64,
}

struct Worker {
    sender: mpsc::Sender<Message>,
    stopped: Arc<AtomicBool>,
}

struct Pending<'a> {
    sender: &'a mpsc::Sender<Message>,
    id: u64,
    done: bool,
}

impl Drop for Pending<'_> {
    fn drop(&mut self) {
        if !self.done {
            let _ = self.sender.send(Message::Abort(self.id));
        }
    }
}

impl Shell {
    pub fn new(cwd: PathBuf, cache: PathBuf, sources: PathBuf) -> Self {
        Self {
            cwd,
            cache,
            sources,
            host: Arc::new(OnceLock::new()),
            worker: OnceLock::new(),
            next: AtomicU64::new(1),
        }
    }

    pub fn attach(&self, host: Weak<Host>) {
        let _ = self.host.set(host);
    }

    pub async fn run(
        &self,
        script: &str,
        cwd: Option<&Path>,
        stdin: Option<&str>,
        timeout_ms: Option<u64>,
    ) -> Result<Ran, String> {
        let worker = self
            .worker
            .get_or_init(|| {
                Worker::spawn(
                    &self.cwd,
                    self.cache.clone(),
                    self.sources.clone(),
                    Arc::clone(&self.host),
                )
            });
        let id = self.next.fetch_add(1, Ordering::Relaxed);
        let request = json!({
            "script": script,
            "cwd": cwd.unwrap_or(self.cwd.as_path()).to_string_lossy(),
            "stdin": stdin,
            "timeout_ms": timeout_ms.unwrap_or(WORKSPACE_TIMEOUT_MS),
        })
        .to_string();
        let (reply, answer) = oneshot::channel();
        worker
            .sender
            .send(Message::Run { id, request, reply })
            .map_err(|_| STOPPED.to_owned())?;
        let mut pending = Pending {
            sender: &worker.sender,
            id,
            done: false,
        };
        let result = answer.await;
        pending.done = true;
        result.map_err(|_| STOPPED.to_owned())?
    }

    pub fn stop(&self) {
        if let Some(worker) = self.worker.get() {
            worker.stopped.store(true, Ordering::Relaxed);
            let _ = worker.sender.send(Message::Stop);
        }
    }
}

impl Drop for Shell {
    fn drop(&mut self) {
        self.stop();
    }
}

impl Worker {
    fn spawn(
        cwd: &Path,
        cache: PathBuf,
        sources: PathBuf,
        host: Arc<OnceLock<Weak<Host>>>,
    ) -> Self {
        let (sender, receiver) = mpsc::channel();
        let stopped = Arc::new(AtomicBool::new(false));
        let container = std::env::temp_dir().parent().map(Path::to_path_buf);
        let home = if cfg!(target_os = "ios") {
            container
        } else {
            std::env::var_os("HOME").map(PathBuf::from)
        }
        .unwrap_or_else(|| cwd.to_path_buf());
        let config = json!({
            "cwd": cwd.to_string_lossy(),
            "env": {"HOME": home.to_string_lossy()},
            "limits": {"maxMemoryBytes": COMMAND_MEMORY},
            "tmp": local(Path::new("/tmp")).to_string_lossy().trim_end_matches('/'),
        })
        .to_string();
        let network = Network::new(sender.clone(), host);
        let flag = Arc::clone(&stopped);
        let _ = std::thread::Builder::new()
            .name("nanocode-shell".to_owned())
            .stack_size(STACK)
            .spawn(move || work(&receiver, network, &flag, &config, &cache, &sources));
        Self { sender, stopped }
    }
}

#[derive(Deserialize)]
struct Fetch {
    url: String,
    #[serde(default)]
    method: Option<String>,
    #[serde(default)]
    headers: BTreeMap<String, String>,
    #[serde(default)]
    body: Option<String>,
    #[serde(default)]
    body_ref: Option<u64>,
    #[serde(default)]
    redirect: Option<String>,
}

struct Network {
    sender: mpsc::Sender<Message>,
    host: Arc<OnceLock<Weak<Host>>>,
    handle: Option<tokio::runtime::Handle>,
    follow: Result<reqwest::Client, String>,
    manual: Result<reqwest::Client, String>,
}

impl Network {
    fn new(sender: mpsc::Sender<Message>, host: Arc<OnceLock<Weak<Host>>>) -> Self {
        let client = |policy| {
            reqwest::Client::builder()
                .redirect(policy)
                .connect_timeout(Duration::from_secs(30))
                .build()
                .map_err(text)
        };
        Self {
            sender,
            host,
            handle: tokio::runtime::Handle::try_current().ok(),
            follow: client(reqwest::redirect::Policy::limited(20)),
            manual: client(reqwest::redirect::Policy::none()),
        }
    }

    fn host(&self) -> Option<Arc<Host>> {
        self.host.get().and_then(Weak::upgrade)
    }

    fn pyodide(&self, id: u64, request: String) {
        let sender = self.sender.clone();
        let (Some(handle), Some(host)) = (&self.handle, self.host()) else {
            let _ = sender.send(Message::Python {
                id,
                result: Err("this app runs no Python".to_owned()),
            });
            return;
        };
        handle.spawn(async move {
            let result = host
                .call("python", json!({"request": request}))
                .await
                .and_then(|reply| match reply {
                    Json::String(reply) => Ok(reply),
                    other => Err(format!("Python answered {other}")),
                });
            let _ = sender.send(Message::Python { id, result });
        });
    }

    fn start(&self, id: u64, request: Fetch, body: Option<Vec<u8>>) {
        let sender = self.sender.clone();
        let Some(handle) = &self.handle else {
            let _ = sender.send(Message::Fetched {
                id,
                result: Err("network access is not available in this shell".to_owned()),
            });
            return;
        };
        let client = if request.redirect.as_deref() == Some("manual") {
            self.manual.clone()
        } else {
            self.follow.clone()
        };
        handle.spawn(async move {
            let result = fetch(client, request, body).await;
            let _ = sender.send(Message::Fetched { id, result });
        });
    }
}

fn chain(error: &reqwest::Error) -> String {
    let mut text = error.to_string();
    let mut source = std::error::Error::source(error);
    while let Some(cause) = source {
        text.push_str(": ");
        text.push_str(&cause.to_string());
        source = cause.source();
    }
    text
}

async fn fetch(
    client: Result<reqwest::Client, String>,
    request: Fetch,
    body: Option<Vec<u8>>,
) -> Result<(Json, Vec<u8>), String> {
    let method = request.method.as_deref().unwrap_or("GET");
    let method = reqwest::Method::from_bytes(method.as_bytes()).map_err(text)?;
    let mut builder = client?.request(method, request.url.as_str());
    for (name, value) in &request.headers {
        builder = builder.header(name.as_str(), value.as_str());
    }
    if let Some(body) = body {
        builder = builder.body(body);
    }
    let response = builder.send().await.map_err(|error| chain(&error))?;
    let status = response.status();
    let headers = response
        .headers()
        .iter()
        .map(|(name, value)| json!([name.as_str(), String::from_utf8_lossy(value.as_bytes())]))
        .collect::<Vec<_>>();
    let head = json!({
        "status": status.as_u16(),
        "status_text": status.canonical_reason().unwrap_or_default(),
        "url": response.url().as_str(),
        "headers": headers,
    });
    let bytes = response.bytes().await.map_err(|error| chain(&error))?;
    Ok((head, bytes.to_vec()))
}

trait Coder {
    fn push(&mut self, data: &[u8]) -> std::io::Result<Vec<u8>>;
    fn finish(self: Box<Self>) -> std::io::Result<Vec<u8>>;
}

macro_rules! coders {
    ($flush:literal; $($kind:ty),*) => {
        $(impl Coder for $kind {
            fn push(&mut self, data: &[u8]) -> std::io::Result<Vec<u8>> {
                self.write_all(data)?;
                if $flush {
                    self.flush()?;
                }
                Ok(std::mem::take(self.get_mut()))
            }

            fn finish(self: Box<Self>) -> std::io::Result<Vec<u8>> {
                (*self).finish()
            }
        })*
    };
}

coders!(true; GzDecoder<Vec<u8>>, ZlibDecoder<Vec<u8>>, DeflateDecoder<Vec<u8>>);
coders!(false; GzEncoder<Vec<u8>>, ZlibEncoder<Vec<u8>>, DeflateEncoder<Vec<u8>>);

fn coder(format: &str, decompress: bool) -> Option<Box<dyn Coder>> {
    let level = Compression::default();
    Some(match (format, decompress) {
        ("gzip", true) => Box::new(GzDecoder::new(Vec::new())),
        ("gzip", false) => Box::new(GzEncoder::new(Vec::new(), level)),
        ("deflate", true) => Box::new(ZlibDecoder::new(Vec::new())),
        ("deflate", false) => Box::new(ZlibEncoder::new(Vec::new(), level)),
        ("deflate-raw", true) => Box::new(DeflateDecoder::new(Vec::new())),
        ("deflate-raw", false) => Box::new(DeflateEncoder::new(Vec::new(), level)),
        _ => return None,
    })
}

#[derive(Default)]
struct State {
    timers: BTreeMap<(Instant, u64), Persistent<Function<'static>>>,
    deadlines: HashMap<u64, Instant>,
    buffers: HashMap<u64, Vec<u8>>,
    coders: HashMap<u64, Box<dyn Coder>>,
    replies: HashMap<u64, oneshot::Sender<Result<Ran, String>>>,
    next: u64,
}

impl State {
    fn id(&mut self) -> u64 {
        self.next += 1;
        self.next
    }

    fn put(&mut self, bytes: Vec<u8>) -> u64 {
        let id = self.id();
        self.buffers.insert(id, bytes);
        id
    }

    fn due(&mut self, now: Instant) -> Option<Persistent<Function<'static>>> {
        let key = *self.timers.keys().next().filter(|(due, _)| *due <= now)?;
        self.deadlines.remove(&key.1);
        self.timers.remove(&key)
    }

    fn clear(&mut self) {
        self.timers.clear();
        self.deadlines.clear();
        self.buffers.clear();
        self.coders.clear();
        self.replies.clear();
    }
}

fn failure<'js>(ctx: &Ctx<'js>, error: &std::io::Error) -> rquickjs::Error {
    let code = match (error.raw_os_error(), error.kind()) {
        (Some(libc::ELOOP), _) => "ELOOP",
        (_, ErrorKind::NotFound) => "ENOENT",
        (_, ErrorKind::PermissionDenied) => "EACCES",
        (_, ErrorKind::AlreadyExists) => "EEXIST",
        (_, ErrorKind::NotADirectory) => "ENOTDIR",
        (_, ErrorKind::IsADirectory) => "EISDIR",
        (_, ErrorKind::DirectoryNotEmpty) => "ENOTEMPTY",
        (_, ErrorKind::ReadOnlyFilesystem) => "EROFS",
        (_, ErrorKind::CrossesDevices) => "EXDEV",
        (_, ErrorKind::ResourceBusy) => "EBUSY",
        (_, ErrorKind::FileTooLarge) => "EFBIG",
        (_, ErrorKind::InvalidInput) => "EINVAL",
        (_, ErrorKind::StorageFull) => "ENOSPC",
        _ => "EIO",
    };
    let mut reason = error.to_string();
    if let Some(at) = reason.find(" (os error") {
        reason.truncate(at);
    }
    Exception::throw_message(ctx, &format!("{code}:{reason}"))
}

fn missing(error: &std::io::Error) -> bool {
    matches!(error.kind(), ErrorKind::NotFound | ErrorKind::NotADirectory)
        || error.raw_os_error() == Some(libc::ELOOP)
}

fn described<'js>(
    ctx: &Ctx<'js>,
    metadata: &std::fs::Metadata,
    target: Option<String>,
) -> rquickjs::Result<Value<'js>> {
    let object = Object::new(ctx.clone())?;
    let kind = if metadata.file_type().is_symlink() {
        "symlink"
    } else if metadata.is_dir() {
        "directory"
    } else {
        "file"
    };
    let mtime = metadata
        .modified()
        .ok()
        .and_then(|time| time.duration_since(UNIX_EPOCH).ok())
        .map_or(0.0, |elapsed| elapsed.as_millis() as f64);
    object.set("kind", kind)?;
    object.set(
        "size",
        if metadata.is_dir() {
            4096.0
        } else if metadata.is_file() || metadata.file_type().is_symlink() {
            metadata.len() as f64
        } else {
            0.0
        },
    )?;
    object.set("mtime", mtime)?;
    object.set("mode", metadata.permissions().mode() & 0o7777)?;
    if let Some(target) = target {
        object.set("target", target)?;
    }
    Ok(object.into_value())
}

fn stat<'js>(ctx: &Ctx<'js>, path: &str, follow: bool) -> rquickjs::Result<Value<'js>> {
    let real = local(Path::new(path));
    let metadata = if follow {
        std::fs::metadata(&real)
    } else {
        std::fs::symlink_metadata(&real)
    };
    match metadata {
        Ok(metadata) => {
            let target = metadata
                .file_type()
                .is_symlink()
                .then(|| std::fs::read_link(&real).ok())
                .flatten()
                .map(|target| target.to_string_lossy().into_owned());
            described(ctx, &metadata, target)
        }
        Err(error) if missing(&error) => Ok(Value::new_null(ctx.clone())),
        Err(error) => Err(failure(ctx, &error)),
    }
}

fn view<'a, 'js>(
    ctx: &Ctx<'js>,
    buffer: &'a ArrayBuffer<'js>,
    offset: Opt<usize>,
    length: Opt<usize>,
) -> rquickjs::Result<&'a [u8]> {
    let all = unsafe { buffer.as_bytes() }
        .ok_or_else(|| Exception::throw_type(ctx, "the ArrayBuffer is detached"))?;
    let start = offset.0.unwrap_or(0);
    let end = length
        .0
        .map_or(Some(all.len()), |length| start.checked_add(length))
        .filter(|end| *end <= all.len() && start <= *end)
        .ok_or_else(|| Exception::throw_range(ctx, "byte range is outside the ArrayBuffer"))?;
    Ok(&all[start..end])
}

fn utf8(text: rquickjs::String<'_>) -> rquickjs::Result<Vec<u8>> {
    let text = text.to_cstring()?;
    let mut bytes = AsRef::<[u8]>::as_ref(&text).to_vec();
    let mut index = 0;
    while index + 2 < bytes.len() {
        if bytes[index] == 0xed && bytes[index + 1] >= 0xa0 {
            bytes[index..index + 3].copy_from_slice("\u{fffd}".as_bytes());
            index += 3;
        } else {
            index += 1;
        }
    }
    Ok(bytes)
}

fn escaped<'js>(ctx: &Ctx<'js>, bytes: &[u8]) -> rquickjs::Result<rquickjs::String<'js>> {
    if let Ok(text) = std::str::from_utf8(bytes) {
        return rquickjs::String::from_str(ctx.clone(), text);
    }
    let mut wtf8 = Vec::with_capacity(bytes.len() * 2);
    let mut rest = bytes;
    loop {
        match std::str::from_utf8(rest) {
            Ok(valid) => {
                wtf8.extend_from_slice(valid.as_bytes());
                break;
            }
            Err(error) => {
                let (valid, after) = rest.split_at(error.valid_up_to());
                wtf8.extend_from_slice(valid);
                let invalid = error.error_len().unwrap_or(after.len());
                for &byte in &after[..invalid] {
                    let unit = 0xdc00 + u32::from(byte);
                    wtf8.extend_from_slice(&[
                        0xe0 | (unit >> 12) as u8,
                        0x80 | ((unit >> 6) & 0x3f) as u8,
                        0x80 | (unit & 0x3f) as u8,
                    ]);
                }
                rest = &after[invalid..];
            }
        }
    }
    let value = unsafe {
        Value::from_raw(
            ctx.clone(),
            qjs::JS_NewStringLen(ctx.as_raw().as_ptr(), wtf8.as_ptr().cast(), wtf8.len() as _),
        )
    };
    if value.is_exception() {
        return Err(rquickjs::Error::Exception);
    }
    value
        .into_string()
        .ok_or_else(|| Exception::throw_internal(ctx, "the decoded text is not a string"))
}

fn unescaped(text: rquickjs::String<'_>) -> rquickjs::Result<Vec<u8>> {
    let text = text.to_cstring()?;
    let wtf8 = AsRef::<[u8]>::as_ref(&text);
    let mut bytes = Vec::with_capacity(wtf8.len());
    let mut index = 0;
    while index < wtf8.len() {
        if wtf8[index] == 0xed && index + 2 < wtf8.len() && wtf8[index + 1] >= 0xa0 {
            let unit = (u32::from(wtf8[index] & 0x0f) << 12)
                | (u32::from(wtf8[index + 1] & 0x3f) << 6)
                | u32::from(wtf8[index + 2] & 0x3f);
            if (0xdc80..=0xdcff).contains(&unit) {
                bytes.push((unit - 0xdc00) as u8);
            } else {
                bytes.extend_from_slice("\u{fffd}".as_bytes());
            }
            index += 3;
        } else {
            bytes.push(wtf8[index]);
            index += 1;
        }
    }
    Ok(bytes)
}

fn forgiving(text: &str) -> Option<Vec<u8>> {
    let mut data = text
        .bytes()
        .filter(|byte| !matches!(byte, b'\t' | b'\n' | b'\x0c' | b'\r' | b' '))
        .collect::<Vec<_>>();
    if data.len() % 4 == 0 {
        for _ in 0..2 {
            if data.last() == Some(&b'=') {
                data.pop();
            }
        }
    }
    let alphabet = |byte: &u8| byte.is_ascii_alphanumeric() || matches!(byte, b'+' | b'/');
    if data.len() % 4 == 1 || !data.iter().all(alphabet) {
        return None;
    }
    LENIENT.decode(&data).ok()
}

fn source<'js>(
    ctx: &Ctx<'js>,
    value: &Value<'js>,
    offset: Opt<usize>,
    length: Opt<usize>,
) -> rquickjs::Result<Vec<u8>> {
    if let Some(text) = value.as_string() {
        return utf8(text.clone());
    }
    let buffer = ArrayBuffer::from_value(value.clone())
        .ok_or_else(|| Exception::throw_type(ctx, "expected a string or an ArrayBuffer"))?;
    Ok(view(ctx, &buffer, offset, length)?.to_vec())
}

fn decoded<'js>(
    ctx: &Ctx<'js>,
    bytes: &[u8],
    fatal: bool,
) -> rquickjs::Result<rquickjs::String<'js>> {
    match std::str::from_utf8(bytes) {
        Ok(text) => rquickjs::String::from_str(ctx.clone(), text),
        Err(_) if fatal => Err(Exception::throw_type(
            ctx,
            "The encoded data was not valid utf-8",
        )),
        Err(_) => rquickjs::String::from_str(ctx.clone(), &String::from_utf8_lossy(bytes)),
    }
}

fn install_files<'js>(shell: &Object<'js>) -> rquickjs::Result<()> {
    shell.set(
        "stat",
        Func::from(|ctx: Ctx<'js>, path: String| stat(&ctx, &path, true)),
    )?;
    shell.set(
        "lstat",
        Func::from(|ctx: Ctx<'js>, path: String| stat(&ctx, &path, false)),
    )?;
    shell.set(
        "read",
        Func::from(
            |ctx: Ctx<'js>, path: String| -> rquickjs::Result<ArrayBuffer<'js>> {
                let real = local(Path::new(&path));
                let special = std::fs::metadata(&real)
                    .is_ok_and(|metadata| !metadata.is_file() && !metadata.is_dir());
                let bytes = if special {
                    Vec::new()
                } else {
                    std::fs::read(real).map_err(|error| failure(&ctx, &error))?
                };
                ArrayBuffer::new(ctx, bytes)
            },
        ),
    )?;
    shell.set(
        "write",
        Func::from(
            |ctx: Ctx<'js>,
             path: String,
             buffer: ArrayBuffer<'js>,
             offset: Opt<usize>,
             length: Opt<usize>,
             append: Opt<bool>|
             -> rquickjs::Result<()> {
                let append = append.0.unwrap_or(false);
                let data = view(&ctx, &buffer, offset, length)?;
                OpenOptions::new()
                    .create(true)
                    .write(true)
                    .append(append)
                    .truncate(!append)
                    .open(local(Path::new(&path)))
                    .and_then(|mut file| file.write_all(data))
                    .map_err(|error| failure(&ctx, &error))
            },
        ),
    )?;
    shell.set(
        "list",
        Func::from(
            |ctx: Ctx<'js>, path: String| -> rquickjs::Result<Vec<String>> {
                let mut names = std::fs::read_dir(local(Path::new(&path)))
                    .and_then(|entries| {
                        entries
                            .map(|entry| {
                                entry.map(|entry| entry.file_name().to_string_lossy().into_owned())
                            })
                            .collect::<std::io::Result<Vec<_>>>()
                    })
                    .map_err(|error| failure(&ctx, &error))?;
                names.sort();
                Ok(names)
            },
        ),
    )?;
    shell.set(
        "mkdir",
        Func::from(|ctx: Ctx<'js>, path: String| -> rquickjs::Result<()> {
            std::fs::create_dir(local(Path::new(&path))).map_err(|error| failure(&ctx, &error))
        }),
    )?;
    shell.set(
        "remove",
        Func::from(|ctx: Ctx<'js>, path: String| -> rquickjs::Result<()> {
            let real = local(Path::new(&path));
            std::fs::symlink_metadata(&real)
                .and_then(|metadata| {
                    if metadata.is_dir() {
                        std::fs::remove_dir(&real)
                    } else {
                        std::fs::remove_file(&real)
                    }
                })
                .map_err(|error| failure(&ctx, &error))
        }),
    )?;
    shell.set(
        "rename",
        Func::from(
            |ctx: Ctx<'js>, from: String, to: String| -> rquickjs::Result<()> {
                std::fs::rename(local(Path::new(&from)), local(Path::new(&to)))
                    .map_err(|error| failure(&ctx, &error))
            },
        ),
    )?;
    shell.set(
        "chmod",
        Func::from(
            |ctx: Ctx<'js>, path: String, mode: u32| -> rquickjs::Result<()> {
                std::fs::set_permissions(local(Path::new(&path)), Permissions::from_mode(mode))
                    .map_err(|error| failure(&ctx, &error))
            },
        ),
    )?;
    shell.set(
        "utimes",
        Func::from(
            |ctx: Ctx<'js>, path: String, mtime: f64| -> rquickjs::Result<()> {
                let time = UNIX_EPOCH + Duration::from_millis(mtime.max(0.0) as u64);
                File::open(local(Path::new(&path)))
                    .and_then(|file| file.set_modified(time))
                    .map_err(|error| failure(&ctx, &error))
            },
        ),
    )?;
    shell.set(
        "symlink",
        Func::from(
            |ctx: Ctx<'js>, target: String, path: String| -> rquickjs::Result<()> {
                let target = if target.starts_with('/') {
                    local(Path::new(&target))
                } else {
                    PathBuf::from(target)
                };
                std::os::unix::fs::symlink(target, local(Path::new(&path)))
                    .map_err(|error| failure(&ctx, &error))
            },
        ),
    )?;
    shell.set(
        "readlink",
        Func::from(
            |ctx: Ctx<'js>, path: String| -> rquickjs::Result<Value<'js>> {
                match std::fs::read_link(local(Path::new(&path))) {
                    Ok(target) => rquickjs::String::from_str(ctx, &target.to_string_lossy())
                        .map(rquickjs::String::into_value),
                    Err(error) if missing(&error) || error.kind() == ErrorKind::InvalidInput => {
                        Ok(Value::new_null(ctx))
                    }
                    Err(error) => Err(failure(&ctx, &error)),
                }
            },
        ),
    )
}

fn install_bytes<'js>(ctx: &Ctx<'js>, state: &Rc<RefCell<State>>) -> rquickjs::Result<()> {
    let bytes = Object::new(ctx.clone())?;
    let buffers = Rc::clone(state);
    bytes.set(
        "put",
        Func::from(
            move |ctx: Ctx<'js>,
                  value: Value<'js>,
                  offset: Opt<usize>,
                  length: Opt<usize>|
                  -> rquickjs::Result<f64> {
                let data = source(&ctx, &value, offset, length)?;
                Ok(buffers.borrow_mut().put(data) as f64)
            },
        ),
    )?;
    let buffers = Rc::clone(state);
    bytes.set(
        "take",
        Func::from(
            move |ctx: Ctx<'js>, id: f64| -> rquickjs::Result<ArrayBuffer<'js>> {
                let data = buffers.borrow_mut().buffers.remove(&(id as u64));
                let data = data.ok_or_else(|| {
                    Exception::throw_reference(&ctx, &format!("byte buffer {id} is gone"))
                })?;
                ArrayBuffer::new(ctx, data)
            },
        ),
    )?;
    let buffers = Rc::clone(state);
    bytes.set(
        "text",
        Func::from(
            move |ctx: Ctx<'js>,
                  id: f64,
                  fatal: Opt<bool>|
                  -> rquickjs::Result<rquickjs::String<'js>> {
                let data = buffers.borrow_mut().buffers.remove(&(id as u64));
                let data = data.ok_or_else(|| {
                    Exception::throw_reference(&ctx, &format!("byte buffer {id} is gone"))
                })?;
                decoded(&ctx, &data, fatal.0.unwrap_or(false))
            },
        ),
    )?;
    let buffers = Rc::clone(state);
    bytes.set(
        "discard",
        Func::from(move |id: f64| {
            buffers.borrow_mut().buffers.remove(&(id as u64));
        }),
    )?;
    bytes.set(
        "decode",
        Func::from(
            |ctx: Ctx<'js>,
             buffer: ArrayBuffer<'js>,
             offset: Opt<usize>,
             length: Opt<usize>,
             fatal: Opt<bool>|
             -> rquickjs::Result<rquickjs::String<'js>> {
                let data = view(&ctx, &buffer, offset, length)?;
                decoded(&ctx, data, fatal.0.unwrap_or(false))
            },
        ),
    )?;
    bytes.set(
        "encode",
        Func::from(
            |ctx: Ctx<'js>, value: Value<'js>| -> rquickjs::Result<ArrayBuffer<'js>> {
                let data = source(&ctx, &value, Opt(None), Opt(None))?;
                ArrayBuffer::new(ctx, data)
            },
        ),
    )?;
    bytes.set(
        "toBase64",
        Func::from(
            |ctx: Ctx<'js>,
             buffer: ArrayBuffer<'js>,
             offset: Opt<usize>,
             length: Opt<usize>|
             -> rquickjs::Result<rquickjs::String<'js>> {
                let encoded = STANDARD_ENGINE.encode(view(&ctx, &buffer, offset, length)?);
                rquickjs::String::from_str(ctx, &encoded)
            },
        ),
    )?;
    bytes.set(
        "fromBase64",
        Func::from(
            |ctx: Ctx<'js>, encoded: String| -> rquickjs::Result<ArrayBuffer<'js>> {
                let mut clean = encoded
                    .bytes()
                    .filter_map(|byte| match byte {
                        b'-' => Some(b'+'),
                        b'_' => Some(b'/'),
                        b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'+' | b'/' => Some(byte),
                        _ => None,
                    })
                    .collect::<Vec<_>>();
                if clean.len() % 4 == 1 {
                    clean.pop();
                }
                let data = LENIENT.decode(&clean).map_err(|error| {
                    Exception::throw_type(&ctx, &format!("invalid base64: {error}"))
                })?;
                ArrayBuffer::new(ctx, data)
            },
        ),
    )?;
    bytes.set(
        "random",
        Func::from(
            |ctx: Ctx<'js>, length: usize| -> rquickjs::Result<ArrayBuffer<'js>> {
                let mut data = vec![0; length];
                rand::rng().fill_bytes(&mut data);
                ArrayBuffer::new(ctx, data)
            },
        ),
    )?;
    bytes.set(
        "digest",
        Func::from(
            |ctx: Ctx<'js>,
             algorithm: String,
             buffer: ArrayBuffer<'js>,
             offset: Opt<usize>,
             length: Opt<usize>|
             -> rquickjs::Result<ArrayBuffer<'js>> {
                let data = view(&ctx, &buffer, offset, length)?;
                let digest = match algorithm.as_str() {
                    "SHA-1" => <sha1::Sha1 as sha1::Digest>::digest(data).to_vec(),
                    "SHA-256" => <sha2::Sha256 as sha2::Digest>::digest(data).to_vec(),
                    "SHA-384" => <sha2::Sha384 as sha2::Digest>::digest(data).to_vec(),
                    "SHA-512" => <sha2::Sha512 as sha2::Digest>::digest(data).to_vec(),
                    _ => {
                        return Err(Exception::throw_type(
                            &ctx,
                            &format!("unsupported digest {algorithm}"),
                        ));
                    }
                };
                ArrayBuffer::new(ctx, digest)
            },
        ),
    )?;
    ctx.globals().set("__nanocodeBytes", bytes)
}

fn install<'js>(
    ctx: &Ctx<'js>,
    state: &Rc<RefCell<State>>,
    network: &Rc<Network>,
) -> rquickjs::Result<()> {
    let shell = Object::new(ctx.clone())?;
    install_files(&shell)?;
    install_bytes(ctx, state)?;
    wasm::install(ctx)?;
    let python = Rc::clone(network);
    shell.set(
        "pyodide",
        Func::from(move |id: f64, request: String| python.pyodide(id as u64, request)),
    )?;
    let timers = Rc::clone(state);
    ctx.globals().set(
        "setTimeout",
        Func::from(
            move |ctx: Ctx<'js>, callback: Function<'js>, delay: Opt<f64>| -> f64 {
                let delay = delay.0.filter(|delay| delay.is_finite() && *delay > 0.0);
                let due = Instant::now() + Duration::from_secs_f64(delay.unwrap_or(0.0) / 1000.0);
                let mut timers = timers.borrow_mut();
                let id = timers.id();
                timers
                    .timers
                    .insert((due, id), Persistent::save(&ctx, callback));
                timers.deadlines.insert(id, due);
                id as f64
            },
        ),
    )?;
    let timers = Rc::clone(state);
    ctx.globals().set(
        "clearTimeout",
        Func::from(move |id: Opt<Value<'js>>| {
            let Some(id) = id.0.and_then(|id| id.as_number()) else {
                return;
            };
            let id = id as u64;
            let mut timers = timers.borrow_mut();
            if let Some(due) = timers.deadlines.remove(&id) {
                timers.timers.remove(&(due, id));
            }
        }),
    )?;
    let fetches = Rc::clone(state);
    let network = Rc::clone(network);
    shell.set(
        "fetch",
        Func::from(
            move |ctx: Ctx<'js>, id: f64, request: String| -> rquickjs::Result<()> {
                let request: Fetch = serde_json::from_str(&request)
                    .map_err(|error| Exception::throw_type(&ctx, &error.to_string()))?;
                let body = match request.body_ref {
                    Some(reference) => {
                        let body = fetches.borrow_mut().buffers.remove(&reference);
                        Some(body.ok_or_else(|| {
                            Exception::throw_reference(&ctx, "the fetch body is gone")
                        })?)
                    }
                    None => request.body.clone().map(String::into_bytes),
                };
                network.start(id as u64, request, body);
                Ok(())
            },
        ),
    )?;
    let coders = Rc::clone(state);
    shell.set(
        "coder",
        Func::from(
            move |ctx: Ctx<'js>, format: String, decompress: bool| -> rquickjs::Result<f64> {
                let made = coder(&format, decompress).ok_or_else(|| {
                    Exception::throw_type(
                        &ctx,
                        &format!("Unsupported compression format: '{format}'"),
                    )
                })?;
                let mut state = coders.borrow_mut();
                let id = state.id();
                state.coders.insert(id, made);
                Ok(id as f64)
            },
        ),
    )?;
    let coders = Rc::clone(state);
    shell.set(
        "push",
        Func::from(
            move |ctx: Ctx<'js>,
                  id: f64,
                  buffer: ArrayBuffer<'js>,
                  offset: Opt<usize>,
                  length: Opt<usize>|
                  -> rquickjs::Result<ArrayBuffer<'js>> {
                let data = view(&ctx, &buffer, offset, length)?;
                let mut state = coders.borrow_mut();
                let id = id as u64;
                let coder = state.coders.get_mut(&id).ok_or_else(|| {
                    Exception::throw_reference(&ctx, "the compression stream is closed")
                })?;
                match coder.push(data) {
                    Ok(output) => {
                        drop(state);
                        ArrayBuffer::new(ctx, output)
                    }
                    Err(error) => {
                        state.coders.remove(&id);
                        Err(Exception::throw_type(
                            &ctx,
                            &format!("The compressed data was not valid: {error}"),
                        ))
                    }
                }
            },
        ),
    )?;
    let coders = Rc::clone(state);
    shell.set(
        "finish",
        Func::from(
            move |ctx: Ctx<'js>, id: f64| -> rquickjs::Result<ArrayBuffer<'js>> {
                let coder = coders.borrow_mut().coders.remove(&(id as u64));
                let coder = coder.ok_or_else(|| {
                    Exception::throw_reference(&ctx, "the compression stream is closed")
                })?;
                let output = coder.finish().map_err(|error| {
                    Exception::throw_type(
                        &ctx,
                        &format!("The compressed data was not valid: {error}"),
                    )
                })?;
                ArrayBuffer::new(ctx, output)
            },
        ),
    )?;
    let coders = Rc::clone(state);
    shell.set(
        "release",
        Func::from(move |id: f64| {
            coders.borrow_mut().coders.remove(&(id as u64));
        }),
    )?;
    shell.set(
        "escaped",
        Func::from(
            |ctx: Ctx<'js>,
             buffer: ArrayBuffer<'js>,
             offset: Opt<usize>,
             length: Opt<usize>|
             -> rquickjs::Result<rquickjs::String<'js>> {
                escaped(&ctx, view(&ctx, &buffer, offset, length)?)
            },
        ),
    )?;
    shell.set(
        "fromBase64",
        Func::from(
            |ctx: Ctx<'js>, text: String| -> rquickjs::Result<ArrayBuffer<'js>> {
                let data = forgiving(&text).ok_or_else(|| {
                    Exception::throw_type(
                        &ctx,
                        "The string to be decoded is not correctly encoded.",
                    )
                })?;
                ArrayBuffer::new(ctx, data)
            },
        ),
    )?;
    shell.set(
        "unescaped",
        Func::from(
            |ctx: Ctx<'js>, text: rquickjs::String<'js>| -> rquickjs::Result<ArrayBuffer<'js>> {
                ArrayBuffer::new(ctx, unescaped(text)?)
            },
        ),
    )?;
    let replies = Rc::clone(state);
    shell.set(
        "done",
        Func::from(move |id: f64, result: String| {
            let reply = replies.borrow_mut().replies.remove(&(id as u64));
            if let Some(reply) = reply {
                let _ = reply.send(finished(&result));
            }
        }),
    )?;
    ctx.globals().set("__shell", shell)
}

fn finished(result: &str) -> Result<Ran, String> {
    let value: Json = serde_json::from_str(result).map_err(text)?;
    if let Some(error) = value.get("error").and_then(Json::as_str) {
        return Err(error.to_owned());
    }
    serde_json::from_value(value).map_err(text)
}

struct Sources {
    host: String,
    prelude: String,
    bash: String,
}

impl Sources {
    fn load(directory: &Path) -> Result<Self, String> {
        let read = |name: &str| {
            std::fs::read_to_string(directory.join(name))
                .map_err(|error| format!("read {}: {error}", directory.join(name).display()))
        };
        let lazy = LAZY
            .iter()
            .map(|name| {
                read(&format!("prelude/{name}.js"))
                    .map(|source| format!("{name}: {}", Json::String(source)))
            })
            .collect::<Result<Vec<_>, _>>()?
            .join(",\n");
        Ok(Self {
            host: read("host.js")?,
            prelude: format!(
                "(function (tools, call) {{\nconst lazySources = {{\n{lazy}\n}};\n{}\n}})",
                read("prelude.js")?
            ),
            bash: read("bash.js")?,
        })
    }
}

fn call<'js, A: IntoArgs<'js>>(ctx: &Ctx<'js>, name: &str, arguments: A) -> Result<(), String> {
    let function: Function = ctx
        .globals()
        .get(name)
        .catch(ctx)
        .map_err(|error| error.to_string())?;
    function
        .call::<A, ()>(arguments)
        .catch(ctx)
        .map_err(|error| error.to_string())
}

fn bundle<'js>(ctx: &Ctx<'js>, cache: &Path, bash: &str) -> rquickjs::Result<()> {
    let digest = <sha2::Sha256 as sha2::Digest>::digest(bash.as_bytes());
    let name = digest[..8]
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect::<String>();
    let file = cache.join(format!("bash-{name}.qjsbc"));
    if let Ok(bytes) = std::fs::read(&file)
        && let Ok(module) = unsafe { Module::load(ctx.clone(), &bytes) }
        && module
            .eval()
            .and_then(|(_, done)| done.finish::<Value>())
            .is_ok()
    {
        return Ok(());
    }
    let module = Module::declare(
        ctx.clone(),
        "nanocode:bash",
        format!("{bash}\nglobalThis.NanocodeBash = NanocodeBash;\n"),
    )?;
    if let Ok(bytes) = module.write(WriteOptions::default()) {
        let part = file.with_extension("part");
        if std::fs::create_dir_all(cache).is_ok() && std::fs::write(&part, bytes).is_ok() {
            let _ = std::fs::rename(&part, &file);
        }
    }
    let (_, done) = module.eval()?;
    done.finish::<Value>().map(drop)
}

fn open<'js>(
    ctx: &Ctx<'js>,
    state: &Rc<RefCell<State>>,
    network: &Rc<Network>,
    config: &str,
    cache: &Path,
    sources: &Path,
) -> Result<(), String> {
    let caught = |error: rquickjs::CaughtError<'_>| error.to_string();
    let sources = Sources::load(sources)?;
    install(ctx, state, network).catch(ctx).map_err(caught)?;
    ctx.eval::<Value, _>(sources.host).catch(ctx).map_err(caught)?;
    let prelude: Function = ctx.eval(sources.prelude).catch(ctx).map_err(caught)?;
    call(ctx, "__install", (prelude,))?;
    bundle(ctx, cache, &sources.bash).catch(ctx).map_err(caught)?;
    call(ctx, "__open", (config.to_owned(),))
}

fn settle(runtime: &Runtime, stopped: &AtomicBool) {
    while !stopped.load(Ordering::Relaxed) {
        match runtime.execute_pending_job() {
            Ok(true) | Err(_) => {}
            Ok(false) => return,
        }
    }
}

fn refuse(receiver: &mpsc::Receiver<Message>, error: &str) {
    while let Ok(message) = receiver.recv() {
        match message {
            Message::Run { reply, .. } => {
                let _ = reply.send(Err(error.to_owned()));
            }
            Message::Stop => return,
            _ => {}
        }
    }
}

fn work(
    receiver: &mpsc::Receiver<Message>,
    network: Network,
    stopped: &Arc<AtomicBool>,
    config: &str,
    cache: &Path,
    sources: &Path,
) {
    let runtime = match Runtime::new() {
        Ok(runtime) => runtime,
        Err(error) => return refuse(receiver, &format!("start QuickJS: {error}")),
    };
    runtime.set_max_stack_size(STACK - (4 << 20));
    runtime.set_memory_limit(MEMORY);
    let flag = Arc::clone(stopped);
    runtime.set_interrupt_handler(Some(Box::new(move || flag.load(Ordering::Relaxed))));
    let context = match Context::full(&runtime) {
        Ok(context) => context,
        Err(error) => return refuse(receiver, &format!("start QuickJS: {error}")),
    };
    let state = Rc::new(RefCell::new(State::default()));
    let network = Rc::new(network);
    let opened = context.with(|ctx| open(&ctx, &state, &network, config, cache, sources));
    while !stopped.load(Ordering::Relaxed) {
        settle(&runtime, stopped);
        let now = Instant::now();
        let timer = state.borrow_mut().due(now);
        if let Some(timer) = timer {
            context.with(|ctx| {
                if let Ok(callback) = timer.restore(&ctx) {
                    let _ = callback.call::<_, ()>(()).catch(&ctx);
                }
            });
            continue;
        }
        let next = state.borrow().timers.keys().next().map(|(due, _)| *due);
        let message = match next {
            Some(due) => match receiver.recv_timeout(due.saturating_duration_since(now)) {
                Ok(message) => message,
                Err(mpsc::RecvTimeoutError::Timeout) => continue,
                Err(mpsc::RecvTimeoutError::Disconnected) => break,
            },
            None => match receiver.recv() {
                Ok(message) => message,
                Err(_) => break,
            },
        };
        match message {
            Message::Run { id, request, reply } => {
                if let Err(error) = &opened {
                    let _ = reply.send(Err(error.clone()));
                    continue;
                }
                state.borrow_mut().replies.insert(id, reply);
                let started = context.with(|ctx| call(&ctx, "__run", (id as f64, request)));
                if let Err(error) = started {
                    let reply = state.borrow_mut().replies.remove(&id);
                    if let Some(reply) = reply {
                        let _ = reply.send(Err(error));
                    }
                }
            }
            Message::Abort(id) => {
                let _ = context.with(|ctx| call(&ctx, "__abort", (id as f64,)));
            }
            Message::Fetched { id, result } => {
                let _ = context.with(|ctx| match result {
                    Ok((mut head, body)) => {
                        head["body_ref"] = state.borrow_mut().put(body).into();
                        call(
                            &ctx,
                            "__fetched",
                            (id as f64, Value::new_null(ctx.clone()), head.to_string()),
                        )
                    }
                    Err(error) => call(&ctx, "__fetched", (id as f64, error)),
                });
            }
            Message::Python { id, result } => {
                let _ = context.with(|ctx| match result {
                    Ok(reply) => call(
                        &ctx,
                        "__python",
                        (id as f64, Value::new_null(ctx.clone()), reply),
                    ),
                    Err(error) => call(&ctx, "__python", (id as f64, error)),
                });
            }
            Message::Stop => break,
        }
    }
    state.borrow_mut().clear();
    wasm::clear();
    drop(context);
    drop(runtime);
}

pub struct Simulated(pub Arc<Shell>);

impl ForegroundExecutor for Simulated {
    fn execute<'a>(
        &'a self,
        command: ForegroundCommand<'a>,
    ) -> ProcessFuture<'a, Result<ForegroundOutput, String>> {
        Box::pin(async move {
            let timeout = u64::try_from(command.timeout.as_millis()).unwrap_or(u64::MAX);
            let ran = self
                .0
                .run(
                    command.command,
                    Some(command.workspace),
                    None,
                    Some(timeout),
                )
                .await?;
            let (stdout, stdout_cut) = redact_and_limit(ran.stdout, &[], command.max_stdout);
            let (stderr, stderr_cut) = redact_and_limit(ran.stderr, &[], command.max_stderr);
            Ok(ForegroundOutput {
                stdout,
                stderr,
                exit_code: ran.exit_code,
                truncated: ran.truncated || stdout_cut || stderr_cut,
            })
        })
    }
}

impl ShellExecutor for Simulated {
    fn execute<'a>(
        &'a self,
        command: ExecCommand,
        workspace: &'a Path,
    ) -> ProcessFuture<'a, ExecCommandResult> {
        Box::pin(async move {
            let started = Instant::now();
            let cwd = command.workdir.as_deref().map_or_else(
                || workspace.to_path_buf(),
                |workdir| workspace.join(workdir),
            );
            match self.0.run(&command.script, Some(&cwd), None, None).await {
                Ok(ran) => {
                    let mut output = ran.stdout;
                    output.push_str(&ran.stderr);
                    let original = output.len().saturating_add(3) / 4;
                    let (output, _) = redact_and_limit(
                        output,
                        &[],
                        effective_token_limit(command.max_output_tokens),
                    );
                    ExecCommandResult {
                        error: None,
                        chunk_id: None,
                        wall_time_seconds: started.elapsed().as_secs_f64(),
                        exit_code: Some(ran.exit_code),
                        session_id: None,
                        original_token_count: Some(original),
                        output,
                    }
                }
                Err(error) => ExecCommandResult::failed(started.elapsed(), error),
            }
        })
    }

    fn write_stdin(&self, request: WriteStdin) -> ProcessFuture<'_, ExecCommandResult> {
        Box::pin(async move {
            ExecCommandResult::failed(
                Duration::ZERO,
                format!(
                    "session {} is not running: this host's commands finish before exec_command returns",
                    request.session_id
                ),
            )
        })
    }

    fn terminate_all(&self) -> ProcessFuture<'_, ()> {
        Box::pin(async {})
    }
}
