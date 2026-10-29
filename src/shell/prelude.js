const callFetch = (input) => call("fetch", input);
const callBash = (input) => call("bash", input);
const callFile = (input) => call("file", input);
const nativeBytes = globalThis.__nanocodeBytes;
delete globalThis.__nanocodeBytes;
const callWasm = (input) => call("wasm", input).catch((error) => { throw new Error(typeof error === "string" ? error : error?.message ?? JSON.stringify(error)); });
const host = {};
const hostFunction = (name) => host[name] ??= globalThis[name];
const toLatin1 = (bytes) => {
  let out = "";
  for (let index = 0; index < bytes.length; index += 8192) out += String.fromCharCode.apply(null, bytes.subarray(index, index + 8192));
  return out;
};
const fromLatin1 = (text) => {
  const bytes = new Uint8Array(text.length);
  for (let index = 0; index < text.length; index++) bytes[index] = text.charCodeAt(index) & 255;
  return bytes;
};
const toBase64 = (bytes) => nativeBytes.toBase64(bytes.buffer, bytes.byteOffset, bytes.byteLength);
const fromBase64 = (text) => new Uint8Array(nativeBytes.fromBase64(String(text)));
const toHex = (bytes) => {
  let out = "";
  for (let index = 0; index < bytes.length; index++) out += (bytes[index] < 16 ? "0" : "") + bytes[index].toString(16);
  return out;
};
const fromHex = (text) => {
  const clean = String(text).length % 2 ? String(text).slice(0, -1) : String(text);
  const bytes = new Uint8Array(clean.length / 2);
  let at = 0;
  for (; at < bytes.length; at++) {
    const value = parseInt(clean.substr(at * 2, 2), 16);
    if (Number.isNaN(value)) break;
    bytes[at] = value;
  }
  return bytes.subarray(0, at);
};
const utf8 = (text) => {
  try { return new Uint8Array(nativeBytes.encode(text)); } catch {}
  const bytes = new Uint8Array(text.length * 3);
  let at = 0;
  for (let index = 0; index < text.length; index++) {
    let code = text.charCodeAt(index);
    if (code < 0x80) { bytes[at++] = code; continue; }
    if (code >= 0xd800 && code < 0xdc00 && index + 1 < text.length && text.charCodeAt(index + 1) >= 0xdc00 && text.charCodeAt(index + 1) < 0xe000) code = 0x10000 + ((code - 0xd800) << 10) + (text.charCodeAt(++index) - 0xdc00);
    else if (code >= 0xd800 && code < 0xe000) code = 0xfffd;
    if (code < 0x800) { bytes[at++] = 0xc0 | (code >> 6); bytes[at++] = 0x80 | (code & 63); }
    else if (code < 0x10000) { bytes[at++] = 0xe0 | (code >> 12); bytes[at++] = 0x80 | ((code >> 6) & 63); bytes[at++] = 0x80 | (code & 63); }
    else { bytes[at++] = 0xf0 | (code >> 18); bytes[at++] = 0x80 | ((code >> 12) & 63); bytes[at++] = 0x80 | ((code >> 6) & 63); bytes[at++] = 0x80 | (code & 63); }
  }
  return bytes.slice(0, at);
};
const fromUtf8 = (bytes, fatal = false) => {
  if (bytes instanceof Uint8Array) return nativeBytes.decode(bytes.buffer, bytes.byteOffset, bytes.byteLength, fatal);
  const parts = [];
  let units = [];
  for (let index = 0; index < bytes.length;) {
    const a = bytes[index];
    if (a < 0x80) units.push(a), index++;
    else {
      const size = a >= 0xc2 && a < 0xe0 ? 2 : a >= 0xe0 && a < 0xf0 ? 3 : a >= 0xf0 && a < 0xf5 ? 4 : 0;
      let code = size === 2 ? a & 31 : size === 3 ? a & 15 : a & 7;
      let valid = size > 0 && index + size <= bytes.length;
      for (let next = 1; valid && next < size; next++) {
        const b = bytes[index + next];
        if ((b & 0xc0) !== 0x80) valid = false;
        else code = (code << 6) | (b & 63);
      }
      if (valid && ((size === 3 && (code < 0x800 || (code >= 0xd800 && code < 0xe000))) || (size === 4 && (code < 0x10000 || code > 0x10ffff)))) valid = false;
      if (!valid) {
        if (fatal) throw new TypeError("The encoded data was not valid utf-8");
        units.push(0xfffd);
        index++;
      } else {
        if (code > 0xffff) units.push(0xd800 + ((code - 0x10000) >> 10), 0xdc00 + ((code - 0x10000) & 1023));
        else units.push(code);
        index += size;
      }
    }
    if (units.length >= 8192) { parts.push(String.fromCharCode.apply(null, units)); units = []; }
  }
  parts.push(String.fromCharCode.apply(null, units));
  return parts.join("");
};
const incompleteTail = (bytes) => {
  for (let back = 1; back <= 3 && back <= bytes.length; back++) {
    const byte = bytes[bytes.length - back];
    if ((byte & 0xc0) === 0x80) continue;
    if (byte < 0xc0) return 0;
    const size = byte >= 0xf0 ? 4 : byte >= 0xe0 ? 3 : 2;
    return size > back ? back : 0;
  }
  return 0;
};
const byteView = (value) => value instanceof Uint8Array ? value : value instanceof ArrayBuffer ? new Uint8Array(value) : ArrayBuffer.isView(value) ? new Uint8Array(value.buffer, value.byteOffset, value.byteLength) : undefined;
const putBytes = (data) => {
  if (typeof data !== "string") return nativeBytes.put(data.buffer, data.byteOffset, data.byteLength);
  try { return nativeBytes.put(data); } catch { return putBytes(utf8(data)); }
};
const takeBytes = (id) => new Uint8Array(nativeBytes.take(id));
const takeText = (id) => nativeBytes.text(id, false);
const unread = typeof FinalizationRegistry === "function" ? new FinalizationRegistry((id) => nativeBytes.discard(id)) : undefined;
const adopt = Symbol("adopt");
const ownedBodies = new WeakSet();
const joinBytes = (chunks) => {
  const out = new Uint8Array(chunks.reduce((total, chunk) => total + chunk.length, 0));
  let at = 0;
  for (const chunk of chunks) { out.set(chunk, at); at += chunk.length; }
  return out;
};
const randomBytes = (length) => new Uint8Array(nativeBytes.random(length));
const digestBytes = (name, bytes) => new Uint8Array(nativeBytes.digest(name, bytes.buffer, bytes.byteOffset, bytes.byteLength));
class TextEncoder {
  get encoding() { return "utf-8"; }
  encode(text = "") { return utf8(String(text)); }
  encodeInto(text, target) {
    const source = String(text);
    let read = 0, written = 0;
    for (const character of source) {
      const bytes = utf8(character);
      if (written + bytes.length > target.length) break;
      target.set(bytes, written);
      written += bytes.length;
      read += character.length;
    }
    return { read, written };
  }
}
class TextDecoder {
  #pending = new Uint8Array(0);
  #started = false;
  constructor(label = "utf-8", options = {}) {
    const name = String(label).trim().toLowerCase();
    if (!/^(utf-?8|unicode-1-1-utf-8)$/.test(name)) {
      if (!/^(latin1|iso-8859-1|ascii|us-ascii|windows-1252)$/.test(name)) throw new RangeError("TextDecoder supports utf-8 and latin1 here, not " + label);
      this.latin1 = true;
    }
    this.fatal = Boolean(options.fatal);
    this.ignoreBOM = Boolean(options.ignoreBOM);
  }
  get encoding() { return this.latin1 ? "windows-1252" : "utf-8"; }
  decode(input, options = {}) {
    let bytes = input === undefined ? new Uint8Array(0) : byteView(input);
    if (!bytes) throw new TypeError("TextDecoder.decode expects an ArrayBuffer or a typed array");
    if (this.latin1) return toLatin1(bytes);
    if (this.#pending.length) { bytes = joinBytes([this.#pending, bytes]); this.#pending = new Uint8Array(0); }
    if (options.stream) {
      const cut = incompleteTail(bytes);
      if (cut) { this.#pending = bytes.slice(bytes.length - cut); bytes = bytes.subarray(0, bytes.length - cut); }
    }
    let text = fromUtf8(bytes, this.fatal);
    if (!this.ignoreBOM && !this.#started && text.charCodeAt(0) === 0xfeff) text = text.slice(1);
    this.#started = options.stream ? this.#started || text.length > 0 : false;
    return text;
  }
}
const setTimeoutWithArgs = (callback, delay, ...args) => {
  if (typeof callback !== "function") throw new TypeError("setTimeout expects a function callback, got " + typeof callback);
  return hostFunction("setTimeout")(args.length ? () => callback(...args) : callback, delay);
};
const intervals = new Map();
let nextInterval = 1 << 30;
const setInterval = (callback, delay, ...args) => {
  if (typeof callback !== "function") throw new TypeError("setInterval expects a function callback, got " + typeof callback);
  const id = nextInterval++;
  const period = Math.max(1, Number(delay) || 0);
  const tick = () => {
    if (!intervals.has(id)) return;
    intervals.set(id, hostFunction("setTimeout")(tick, period));
    callback(...args);
  };
  intervals.set(id, hostFunction("setTimeout")(tick, period));
  return id;
};
const clearAnyTimer = (id) => {
  if (intervals.has(id)) { hostFunction("clearTimeout")(intervals.get(id)); intervals.delete(id); }
  else if (id !== undefined && id !== null) hostFunction("clearTimeout")(id);
};
const clearInterval = clearAnyTimer;
const setImmediate = (callback, ...args) => setTimeoutWithArgs(callback, 0, ...args);
const clearImmediate = clearAnyTimer;
const encodeText = (text, encoding = "utf8") => {
  const name = String(encoding).toLowerCase().replace("-", "");
  if (name === "utf8") return utf8(text);
  if (name === "hex") return fromHex(text);
  if (name === "base64" || name === "base64url") return fromBase64(text);
  if (name === "latin1" || name === "binary" || name === "ascii") return fromLatin1(text);
  if (name === "utf16le" || name === "ucs2") { const bytes = new Uint8Array(text.length * 2); for (let index = 0; index < text.length; index++) { bytes[index * 2] = text.charCodeAt(index) & 255; bytes[index * 2 + 1] = text.charCodeAt(index) >> 8; } return bytes; }
  throw new TypeError("Unknown encoding: " + encoding);
};
const decodeBytes = (bytes, encoding = "utf8") => {
  const name = String(encoding).toLowerCase().replace("-", "");
  if (name === "utf8") return fromUtf8(bytes);
  if (name === "hex") return toHex(bytes);
  if (name === "base64") return toBase64(bytes);
  if (name === "base64url") return toBase64(bytes).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
  if (name === "latin1" || name === "binary") return toLatin1(bytes);
  if (name === "ascii") return toLatin1(bytes.map((byte) => byte & 127));
  if (name === "utf16le" || name === "ucs2") { let text = ""; for (let index = 0; index + 1 < bytes.length; index += 2) text += String.fromCharCode(bytes[index] | (bytes[index + 1] << 8)); return text; }
  throw new TypeError("Unknown encoding: " + encoding);
};
const headerList = (headers) => {
  if (!headers) return [];
  if (Array.isArray(headers)) return headers.map(([name, value]) => [String(name), String(value)]);
  if (typeof headers[Symbol.iterator] === "function") return [...headers].map(([name, value]) => [String(name), String(value)]);
  return Object.entries(headers).filter(([, value]) => value !== undefined).map(([name, value]) => [name, String(value)]);
};
class Headers {
  #list = [];
  constructor(init) { for (const [name, value] of headerList(init)) this.append(name, value); }
  append(name, value) { this.#list.push([String(name).toLowerCase(), String(value).trim()]); }
  get(name) { const found = this.#list.filter(([key]) => key === String(name).toLowerCase()); return found.length ? found.map(([, value]) => value).join(", ") : null; }
  getSetCookie() { return this.#list.filter(([key]) => key === "set-cookie").map(([, value]) => value); }
  has(name) { return this.#list.some(([key]) => key === String(name).toLowerCase()); }
  set(name, value) { this.delete(name); this.append(name, value); }
  delete(name) { this.#list = this.#list.filter(([key]) => key !== String(name).toLowerCase()); }
  entries() {
    const names = [...new Set(this.#list.map(([key]) => key))].sort();
    return names.flatMap((name) => name === "set-cookie" ? this.getSetCookie().map((value) => [name, value]) : [[name, this.get(name)]])[Symbol.iterator]();
  }
  keys() { return [...this.entries()].map(([key]) => key)[Symbol.iterator](); }
  values() { return [...this.entries()].map(([, value]) => value)[Symbol.iterator](); }
  forEach(callback, self) { for (const [key, value] of this.entries()) callback.call(self, value, key, this); }
  [Symbol.iterator]() { return this.entries(); }
}
const extractBody = (body) => {
  if (body === undefined || body === null) return {};
  if (typeof body === "string") return { text: body };
  const web = modules.web;
  if (web && body instanceof web.URLSearchParams) return { text: body.toString(), type: "application/x-www-form-urlencoded;charset=UTF-8" };
  if (web && body instanceof web.FormData) return web.multipart(body);
  if (web && body instanceof web.Blob) return { bytes: web.blobBytes.get(body), type: body.type || undefined };
  if (web && body instanceof web.ReadableStream) return { stream: body };
  const view = byteView(body);
  if (view) return { bytes: view };
  if (typeof body === "object") return { text: JSON.stringify(body), type: "application/json" };
  return { text: String(body) };
};
class Body {
  #state;
  #stream;
  constructor(body) { this.#state = extractBody(body); this.bodyUsed = false; }
  [adopt](id) { this.#state = { ref: id }; unread?.register(this, id, this.#state); }
  #claim() {
    const state = this.#state;
    if (state.ref === undefined) return undefined;
    unread?.unregister(state);
    this.#state = {};
    return state.ref;
  }
  #settle() {
    const id = this.#claim();
    if (id !== undefined) this.#state = { bytes: takeBytes(id) };
    return this.#state;
  }
  async #take() {
    this.bodyUsed = true;
    if (this.#state.stream) this.#state = { bytes: await load("web").readAll(this.#state.stream), type: this.#state.type };
    return this.#settle();
  }
  get body() {
    if (this.#state.text === undefined && this.#state.bytes === undefined && this.#state.stream === undefined && this.#state.ref === undefined) return null;
    return this.#stream ??= new (load("web").ReadableStream)({ pull: async (controller) => { const bytes = await this.bytes(); if (bytes.length) controller.enqueue(bytes); controller.close(); } });
  }
  async text() {
    const id = this.#claim();
    if (id !== undefined) { this.bodyUsed = true; this.#state = { text: takeText(id) }; return this.#state.text; }
    const state = await this.#take();
    return state.text ?? fromUtf8(state.bytes ?? new Uint8Array(0));
  }
  async json() {
    const text = await this.text();
    try { return JSON.parse(text); }
    catch { throw new SyntaxError("response from " + (this.url || "fetch") + (this.status === undefined ? "" : " (HTTP " + this.status + ")") + " is not JSON: " + (text.trim().slice(0, 300) || "empty body")); }
  }
  async bytes() { const state = await this.#take(); return state.bytes ? (ownedBodies.delete(this) ? state.bytes : state.bytes.slice()) : utf8(state.text ?? ""); }
  async arrayBuffer() { return (await this.bytes()).buffer; }
  async blob() { return new (load("web").Blob)([await this.bytes()], { type: this.headers.get("content-type") ?? "" }); }
  async formData() {
    const type = this.headers.get("content-type") ?? "";
    if (!/application\/x-www-form-urlencoded/i.test(type)) throw new TypeError("formData() reads only application/x-www-form-urlencoded bodies here, not " + (type || "an untyped body"));
    const web = load("web");
    const form = new web.FormData();
    for (const [key, value] of new web.URLSearchParams(await this.text())) form.append(key, value);
    return form;
  }
  bodyInit() { this.#settle(); return this.#state.stream ?? this.#state.bytes ?? this.#state.text ?? null; }
  bodyType() { return this.#state.type; }
}
class Request extends Body {
  constructor(input, init = {}) {
    const base = input instanceof Request ? input : null;
    super(init.body !== undefined ? init.body : base ? base.bodyInit() : null);
    this.url = base ? base.url : String(input);
    this.method = String(init.method ?? base?.method ?? "GET").toUpperCase();
    this.headers = new Headers(init.headers ?? base?.headers);
    if (!this.headers.has("content-type") && this.bodyType()) this.headers.set("content-type", this.bodyType());
    this.signal = init.signal ?? base?.signal ?? null;
    this.redirect = init.redirect ?? base?.redirect ?? "follow";
    this.credentials = init.credentials ?? base?.credentials ?? "same-origin";
    this.mode = init.mode ?? base?.mode ?? "cors";
    this.cache = init.cache ?? base?.cache ?? "default";
    this.referrer = "about:client";
    this.keepalive = Boolean(init.keepalive);
  }
  clone() { return new Request(this); }
}
class Response extends Body {
  constructor(body = null, init = {}) {
    super(body);
    this.status = init.status ?? 200;
    this.statusText = init.statusText ?? "";
    this.ok = this.status >= 200 && this.status < 300;
    this.headers = new Headers(init.headers);
    if (!this.headers.has("content-type") && typeof body === "string") this.headers.set("content-type", "text/plain;charset=UTF-8");
    else if (!this.headers.has("content-type") && this.bodyType()) this.headers.set("content-type", this.bodyType());
    this.url = init.url ?? "";
    this.type = init.type ?? "default";
    this.redirected = false;
  }
  clone() { ownedBodies.delete(this); return new Response(this.bodyInit(), { status: this.status, statusText: this.statusText, headers: this.headers, url: this.url, type: this.type }); }
  static json(data, init = {}) { const headers = new Headers(init.headers); if (!headers.has("content-type")) headers.set("content-type", "application/json"); return new Response(JSON.stringify(data), { ...init, headers }); }
  static error() { return new Response(null, { status: 0, type: "error" }); }
  static redirect(url, status = 302) { return new Response(null, { status, headers: { location: String(url) } }); }
}
const aborted = (signal) => new Promise((resolve, reject) => {
  if (signal.aborted) reject(signal.reason);
  else signal.addEventListener("abort", () => reject(signal.reason), { once: true });
});
const fetch = async (input, init = {}) => {
  const request = input instanceof Request ? input : null;
  const url = request ? request.url : typeof input === "object" && input !== null && input.url !== undefined ? String(input.url) : String(input);
  const signal = init.signal ?? request?.signal;
  if (signal?.aborted) throw signal.reason;
  const headers = new Headers(init.headers ?? request?.headers ?? (request ? undefined : input?.headers));
  const source = init.body !== undefined ? init.body : request ? request.bodyInit() : input?.body;
  let body = extractBody(source);
  if (body.stream) body = { bytes: await load("web").readAll(body.stream) };
  if (body.type && !headers.has("content-type")) headers.set("content-type", body.type);
  const message = { url, method: String(init.method ?? request?.method ?? input?.method ?? "GET").toUpperCase(), headers: Object.fromEntries(headers) };
  if (body.bytes) {
    let decoded;
    if (body.bytes.length < 65536) try { decoded = fromUtf8(body.bytes, true); } catch {}
    if (decoded !== undefined) message.body = decoded;
    else message.body_ref = putBytes(body.bytes);
  } else if (body.text !== undefined && body.text.length < 65536) message.body = body.text;
  else if (body.text !== undefined) message.body_ref = putBytes(body.text);
  const pending = callFetch(message).then((reply) => {
    if (signal?.aborted) { nativeBytes.discard(reply.body_ref); throw signal.reason; }
    return reply;
  }, (error) => { throw new TypeError(typeof error === "string" ? error : error?.message ?? JSON.stringify(error)); });
  const reply = signal ? await Promise.race([pending, aborted(signal)]) : await pending;
  const response = new Response(null, { status: reply.status, statusText: reply.status_text ?? "", headers: reply.headers, url: reply.url || url, type: "basic" });
  response[adopt](reply.body_ref);
  ownedBodies.add(response);
  return response;
};
const foldBase = (text) => String(text).normalize("NFD").replace(/[\u0300-\u036f]/g, "").toLowerCase();
const compareText = (a, b, options = {}) => {
  const o = { sensitivity: options?.sensitivity ?? "variant", numeric: Boolean(options?.numeric), caseFirst: options?.caseFirst ?? "false" };
  const split = (text) => o.numeric ? String(text).split(/(\d+)/) : [String(text)];
  const left = split(a), right = split(b);
  for (let index = 0; index < Math.max(left.length, right.length); index++) {
    const x = left[index] ?? "", y = right[index] ?? "";
    if (o.numeric && index % 2 === 1 && x !== y) { const difference = Number(x) - Number(y); if (difference) return Math.sign(difference); }
    const fx = foldBase(x), fy = foldBase(y);
    if (fx !== fy) return fx < fy ? -1 : 1;
  }
  if (o.sensitivity === "base") return 0;
  const ax = String(a).normalize("NFD").toLowerCase(), ay = String(b).normalize("NFD").toLowerCase();
  if (ax !== ay) return ax < ay ? -1 : 1;
  if (o.sensitivity === "accent") return 0;
  if (String(a) === String(b)) return 0;
  for (let index = 0; index < Math.min(String(a).length, String(b).length); index++) {
    const x = String(a)[index], y = String(b)[index];
    if (x !== y) return x === x.toLowerCase() ? (o.caseFirst === "upper" ? 1 : -1) : (o.caseFirst === "upper" ? -1 : 1);
  }
  return Math.sign(String(a).length - String(b).length);
};
const bigIntBits = (bits) => {
  const count = Number(bits);
  if (!Number.isInteger(count) || count < 0 || count > 2 ** 53 - 1) throw new RangeError("Invalid value: not (convertible to) a safe integer");
  return BigInt(count);
};
BigInt.asUintN = (bits, value) => {
  const size = 1n << bigIntBits(bits);
  const number = BigInt(value);
  return ((number % size) + size) % size;
};
BigInt.asIntN = (bits, value) => {
  const count = bigIntBits(bits);
  if (count === 0n) return 0n;
  const size = 1n << count;
  const number = ((BigInt(value) % size) + size) % size;
  return number >= size >> 1n ? number - size : number;
};
Number.prototype.toLocaleString = function (locales, options) { return load("intl").Intl.NumberFormat(locales, options).format(Number(this)); };
BigInt.prototype.toLocaleString = function (locales, options) { return load("intl").Intl.NumberFormat(locales, options).format(this.valueOf()); };
Date.prototype.toLocaleString = function (locales, options) { return load("intl").localeDate(this, locales, options, "any"); };
Date.prototype.toLocaleDateString = function (locales, options) { return load("intl").localeDate(this, locales, options, "date"); };
Date.prototype.toLocaleTimeString = function (locales, options) { return load("intl").localeDate(this, locales, options, "time"); };
String.prototype.localeCompare = function (that, locales, options) { return compareText(String(this), String(that), options); };
const quote = (value) => {
  const text = typeof value === "string" ? value : typeof value === "number" || typeof value === "boolean" ? String(value) : JSON.stringify(value) ?? "";
  return /^[\w@%+=:,.\/-]+$/.test(text) ? text : "'" + text.replace(/'/g, "'\\''") + "'";
};
const run = async (script, stdin, timeout) => {
  const input = { script };
  if (stdin !== undefined) input.stdin = stdin;
  if (timeout !== undefined) input.timeout_ms = timeout;
  const result = await callBash(input);
  const shown = { stdout: result.stdout, stderr: result.stderr, exitCode: result.exit_code };
  if (result.truncated) shown.truncated = true;
  Object.defineProperty(shown, "output", { get: () => shown.stdout + shown.stderr });
  Object.defineProperty(shown, "toString", { value: () => shown.stdout + shown.stderr });
  return shown;
};
const template = (strings, values) => strings.reduce((out, part, index) => out + part + (index < values.length ? (Array.isArray(values[index]) ? values[index].map(quote).join(" ") : quote(values[index])) : ""), "");
const unescape = (strings) => strings.raw.map((part) => part.replace(/\\([\\\x60$])/g, "$1"));
const commandOf = (input) => {
  if (typeof input === "string") return input;
  if (Array.isArray(input)) return input.map(quote).join(" ");
  const command = input?.command ?? input?.cmd ?? input?.script ?? input?.code;
  if (typeof command === "string") return command;
  if (Array.isArray(command)) return command.map(quote).join(" ");
  throw new TypeError("bash expects a command string, a tagged template (bash\x60ls \${dir}\x60) or { command, cwd?, stdin?, env?, timeout? }, got " + (JSON.stringify(input) ?? String(input)));
};
const shell = async (input, options = {}) => {
  const settings = input !== null && typeof input === "object" && !Array.isArray(input) ? { ...input, ...options } : options;
  let script = commandOf(input);
  const env = settings.env !== null && typeof settings.env === "object" ? Object.entries(settings.env) : [];
  if (env.length) script = env.map(([name, value]) => "export " + name + "=" + quote(String(value))).join("; ") + "; " + script;
  const cwd = settings.cwd ?? settings.workdir ?? settings.dir;
  if (typeof cwd === "string" && cwd) script = "cd " + quote(cwd) + " && {\n" + script + "\n}";
  const stdin = settings.stdin ?? settings.input;
  const timeout = settings.timeout_ms ?? settings.timeoutMs ?? (typeof settings.timeout === "number" ? (settings.timeout > 1000 ? settings.timeout : settings.timeout * 1000) : undefined);
  return run(script, stdin === undefined ? undefined : typeof stdin === "string" ? stdin : byteView(stdin) ? fromUtf8(byteView(stdin)) : String(stdin), typeof timeout === "number" && timeout > 0 ? Math.round(timeout) : undefined);
};
const bash = (script, ...values) => Array.isArray(script) && Array.isArray(script.raw)
  ? run(template(unescape(script), values))
  : shell(script, values[0] !== null && typeof values[0] === "object" ? values[0] : {});
const readRef = async (path) => (await callFile({ op: "read", path: String(path) })).bytes_ref;
bash.readFile = async (path, options) => {
  const encoding = typeof options === "string" ? options : options !== null && typeof options === "object" ? (options.encoding === undefined ? "utf8" : options.encoding) : options === null ? null : "utf8";
  const name = encoding === null ? "buffer" : String(encoding).toLowerCase().replace("-", "");
  const id = await readRef(path);
  if (name === "utf8") return takeText(id);
  const bytes = takeBytes(id);
  if (name === "buffer" || name === "bytes" || name === "uint8array") return load("web").Buffer.wrap(bytes);
  return decodeBytes(bytes, name);
};
const contentOf = async (content) => {
  if (modules.web && content instanceof modules.web.Blob) return modules.web.blobBytes.get(content);
  const bytes = byteView(content);
  if (bytes) return bytes;
  if (content !== null && typeof content === "object" && !(content instanceof String)) return JSON.stringify(content, null, 2);
  return String(content);
};
const writeTo = async (path, content, op) => {
  const data = await contentOf(content);
  await callFile({ op, path: String(path), bytes_ref: putBytes(data) });
};
bash.writeFile = (path, content) => writeTo(path, content, "write");
bash.appendFile = (path, content) => writeTo(path, content, "append");
const aliases = {};
for (const name of ["exec_command", "write_stdin", "apply_patch"]) {
  if (!Object.keys(tools).includes(name)) continue;
  aliases[name] = name === "exec_command"
    ? (input, options) => tools.exec_command(typeof input === "string" ? { cmd: input, ...(options ?? {}) } : input?.cmd === undefined && typeof input?.command === "string" ? { ...input, cmd: input.command, command: undefined } : input)
    : name === "apply_patch" ? (input) => tools.apply_patch(typeof input === "string" ? input : input?.input ?? input?.patch ?? input)
    : (input) => tools[name](input);
}
const core = { TextDecoder, TextEncoder, byteView, callWasm, digestBytes, hostFunction, setTimeoutWithArgs, compareText, decodeBytes, encodeText, fromBase64, fromHex, fromLatin1, fromUtf8, joinBytes, putBytes, randomBytes, toBase64, toHex, toLatin1, utf8 };
const modules = {};
const load = (name) => modules[name] ??= new Function("core", lazySources[name])(core);
const lazyClass = (module, name) => {
  const real = () => load(module)[name];
  const proxy = new Proxy(function () {}, {
    construct: (_, args, target) => Reflect.construct(real(), args, target === proxy ? real() : target),
    apply: (_, self, args) => Reflect.apply(real(), self, args),
    get: (_, key) => Reflect.get(real(), key),
    set: (_, key, value) => Reflect.set(real(), key, value),
    has: (_, key) => key in real(),
  });
  return proxy;
};
const lazyObject = (module, name) => new Proxy({}, {
  get: (_, key) => Reflect.get(load(module)[name], key),
  has: (_, key) => key in load(module)[name],
  ownKeys: () => Reflect.ownKeys(load(module)[name]),
  getOwnPropertyDescriptor: (_, key) => { const descriptor = Reflect.getOwnPropertyDescriptor(load(module)[name], key); if (descriptor) descriptor.configurable = true; return descriptor; },
});
const webClasses = Object.fromEntries(["Blob", "Buffer", "File", "FormData", "ReadableStream", "TextDecoderStream", "TextEncoderStream", "TransformStream", "URL", "URLSearchParams", "WritableStream"].map((name) => [name, lazyClass("web", name)]));
const extraClasses = Object.fromEntries(["AbortController", "AbortSignal", "CustomEvent", "Event", "EventTarget"].map((name) => [name, lazyClass("extra", name)]));
const globals = { ...webClasses, ...extraClasses, Headers, Intl: lazyObject("intl", "Intl"), Request, Response, TextDecoder, TextEncoder, WebAssembly: lazyObject("extra", "WebAssembly"), bash, clearImmediate, clearInterval, crypto: lazyObject("crypto", "crypto"), fetch, process: lazyObject("extra", "process"), require: (name) => load("extra").require(name), setImmediate, setInterval, structuredClone: (value, options) => load("web").structuredClone(value, options), wasm: lazyObject("extra", "wasm"), ...aliases };
return globals;
