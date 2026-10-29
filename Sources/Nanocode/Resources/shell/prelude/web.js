const { TextDecoder, TextEncoder, byteView, decodeBytes, encodeText, fromBase64, fromHex, fromLatin1, fromUtf8, joinBytes, randomBytes, toBase64, toHex, toLatin1, utf8 } = core;
class Buffer extends Uint8Array {
  static from(value, encodingOrOffset, length) {
    if (typeof value === "string") return Buffer.wrap(encodeText(value, encodingOrOffset));
    if (value instanceof ArrayBuffer) { const offset = encodingOrOffset ?? 0; return new Buffer(value, offset, length ?? value.byteLength - offset); }
    if (ArrayBuffer.isView(value)) return Buffer.wrap(new Uint8Array(value.buffer, value.byteOffset, value.byteLength).slice());
    if (Array.isArray(value)) return Buffer.wrap(Uint8Array.from(value));
    if (value !== null && typeof value === "object" && value.type === "Buffer" && Array.isArray(value.data)) return Buffer.wrap(Uint8Array.from(value.data));
    throw new TypeError("Buffer.from expects a string, an array, an ArrayBuffer or a typed array");
  }
  static wrap(bytes) { return new Buffer(bytes.buffer, bytes.byteOffset, bytes.byteLength); }
  static alloc(size, fill = 0, encoding) { const buffer = new Buffer(size); if (typeof fill === "string") { const bytes = encodeText(fill, encoding); for (let index = 0; index < size && bytes.length; index++) buffer[index] = bytes[index % bytes.length]; } else if (fill) buffer.fill(fill); return buffer; }
  static allocUnsafe(size) { return new Buffer(size); }
  static isBuffer(value) { return value instanceof Buffer; }
  static isEncoding(encoding) { return /^(utf-?8|hex|base64(url)?|latin1|binary|ascii|utf-?16le|ucs-?2)$/i.test(String(encoding)); }
  static byteLength(value, encoding) { return typeof value === "string" ? encodeText(value, encoding).length : value.byteLength; }
  static concat(list, total) { const joined = joinBytes(list.map((item) => byteView(item))); return Buffer.wrap(total === undefined ? joined : joined.slice(0, total)); }
  static compare(a, b) { for (let index = 0; index < Math.min(a.length, b.length); index++) if (a[index] !== b[index]) return a[index] < b[index] ? -1 : 1; return Math.sign(a.length - b.length); }
  toString(encoding = "utf8", start = 0, end = this.length) { return decodeBytes(new Uint8Array(this.buffer, this.byteOffset, this.byteLength).subarray(start, end), encoding); }
  toJSON() { return { type: "Buffer", data: Array.from(this) }; }
  equals(other) { return Buffer.compare(this, other) === 0; }
  compare(other) { return Buffer.compare(this, other); }
  slice(start, end) { return this.subarray(start, end); }
  write(text, offset = 0, length, encoding) { if (typeof offset === "string") { encoding = offset; offset = 0; } const bytes = encodeText(text, encoding).subarray(0, length ?? this.length - offset); this.set(bytes.subarray(0, this.length - offset), offset); return Math.min(bytes.length, this.length - offset); }
  copy(target, targetStart = 0, start = 0, end = this.length) { const bytes = this.subarray(start, end); target.set(bytes.subarray(0, target.length - targetStart), targetStart); return Math.min(bytes.length, target.length - targetStart); }
  readUIntBE(offset, length) { let value = 0; for (let index = 0; index < length; index++) value = value * 256 + this[offset + index]; return value; }
  readUIntLE(offset, length) { let value = 0; for (let index = length - 1; index >= 0; index--) value = value * 256 + this[offset + index]; return value; }
}
for (const [name, getter, setter, size, little] of [["UInt8", "getUint8", "setUint8", 1], ["Int8", "getInt8", "setInt8", 1], ["UInt16LE", "getUint16", "setUint16", 2, true], ["UInt16BE", "getUint16", "setUint16", 2, false], ["Int16LE", "getInt16", "setInt16", 2, true], ["Int16BE", "getInt16", "setInt16", 2, false], ["UInt32LE", "getUint32", "setUint32", 4, true], ["UInt32BE", "getUint32", "setUint32", 4, false], ["Int32LE", "getInt32", "setInt32", 4, true], ["Int32BE", "getInt32", "setInt32", 4, false], ["FloatLE", "getFloat32", "setFloat32", 4, true], ["FloatBE", "getFloat32", "setFloat32", 4, false], ["DoubleLE", "getFloat64", "setFloat64", 8, true], ["DoubleBE", "getFloat64", "setFloat64", 8, false], ["BigUInt64LE", "getBigUint64", "setBigUint64", 8, true], ["BigUInt64BE", "getBigUint64", "setBigUint64", 8, false], ["BigInt64LE", "getBigInt64", "setBigInt64", 8, true], ["BigInt64BE", "getBigInt64", "setBigInt64", 8, false]]) {
  const view = (buffer) => new DataView(buffer.buffer, buffer.byteOffset, buffer.byteLength);
  Buffer.prototype["read" + name] = function (offset = 0) { return view(this)[getter](offset, little); };
  Buffer.prototype["write" + name] = function (value, offset = 0) { view(this)[setter](offset, value, little); return offset + size; };
  if (name.startsWith("UInt")) {
    Buffer.prototype["readUint" + name.slice(4)] = Buffer.prototype["read" + name];
    Buffer.prototype["writeUint" + name.slice(4)] = Buffer.prototype["write" + name];
  }
}
const cloneError = (message) => new DOMException(message, "DataCloneError");
const structuredClone = (value) => {
  const memo = new Map();
  const clone = (item) => {
    if (typeof item === "symbol") throw cloneError(item.toString() + " could not be cloned.");
    if (typeof item === "function") throw cloneError((item.name || "function") + " could not be cloned.");
    if (item === null || typeof item !== "object") return item;
    if (memo.has(item)) return memo.get(item);
    let copy;
    if (Array.isArray(item)) { copy = new Array(item.length); memo.set(item, copy); for (const key of Object.keys(item)) copy[key] = clone(item[key]); return copy; }
    if (item instanceof Date) copy = new Date(item.getTime());
    else if (item instanceof RegExp) copy = new RegExp(item.source, item.flags);
    else if (item instanceof ArrayBuffer) copy = item.slice(0);
    else if (item instanceof DataView) copy = new DataView(clone(item.buffer), item.byteOffset, item.byteLength);
    else if (ArrayBuffer.isView(item)) { const Kind = Object.getPrototypeOf(Object.getPrototypeOf(item)) === Object.getPrototypeOf(Uint8Array.prototype) ? item.constructor : Uint8Array; copy = new Kind(clone(item.buffer), item.byteOffset, item.length); }
    else if (item instanceof Map) { copy = new Map(); memo.set(item, copy); for (const [key, entry] of item) copy.set(clone(key), clone(entry)); return copy; }
    else if (item instanceof Set) { copy = new Set(); memo.set(item, copy); for (const entry of item) copy.add(clone(entry)); return copy; }
    else if (item instanceof Error) { const Kind = { EvalError, RangeError, ReferenceError, SyntaxError, TypeError, URIError }[item.name] ?? Error; copy = new Kind(item.message); memo.set(item, copy); if (item.stack !== undefined) copy.stack = item.stack; if (item.cause !== undefined) copy.cause = clone(item.cause); return copy; }
    else if (item instanceof Boolean || item instanceof Number || item instanceof String) copy = Object(item.valueOf());
    else if (item instanceof Blob) copy = item;
    else if (item instanceof Promise || item instanceof WeakMap || item instanceof WeakSet || (typeof WeakRef === "function" && item instanceof WeakRef)) throw cloneError(Object.prototype.toString.call(item) + " could not be cloned.");
    else { copy = {}; memo.set(item, copy); for (const key of Object.keys(item)) copy[key] = clone(item[key]); return copy; }
    memo.set(item, copy);
    return copy;
  };
  return clone(value);
};
const blobBytes = new WeakMap();
const partBytes = (part) => part instanceof Blob ? blobBytes.get(part) : byteView(part) ?? utf8(String(part));
class Blob {
  constructor(parts = [], options = {}) {
    blobBytes.set(this, joinBytes([...parts].map(partBytes)));
    this.type = String(options.type ?? "").toLowerCase();
  }
  get size() { return blobBytes.get(this).length; }
  async text() { return fromUtf8(blobBytes.get(this)); }
  async arrayBuffer() { return blobBytes.get(this).slice().buffer; }
  async bytes() { return blobBytes.get(this).slice(); }
  slice(start = 0, end = this.size, type = "") { return new Blob([blobBytes.get(this).slice(start, end)], { type }); }
  stream() { const bytes = blobBytes.get(this); return new ReadableStream({ start(controller) { if (bytes.length) controller.enqueue(bytes.slice()); controller.close(); } }); }
}
class File extends Blob {
  constructor(parts, name, options = {}) {
    super(parts, options);
    this.name = String(name);
    this.lastModified = options.lastModified ?? Date.now();
  }
}
class FormData {
  #list = [];
  #entry(name, value, filename) {
    if (value instanceof Blob) return [String(name), value instanceof File && filename === undefined ? value : new File([value], filename ?? (value instanceof File ? value.name : "blob"), { type: value.type })];
    return [String(name), String(value)];
  }
  append(name, value, filename) { this.#list.push(this.#entry(name, value, filename)); }
  set(name, value, filename) {
    const entry = this.#entry(name, value, filename);
    const at = this.#list.findIndex(([key]) => key === entry[0]);
    this.#list = this.#list.filter(([key], index) => key !== entry[0] || index === at);
    if (at < 0) this.#list.push(entry); else this.#list[this.#list.findIndex(([key]) => key === entry[0])] = entry;
  }
  get(name) { return this.#list.find(([key]) => key === String(name))?.[1] ?? null; }
  getAll(name) { return this.#list.filter(([key]) => key === String(name)).map(([, value]) => value); }
  has(name) { return this.#list.some(([key]) => key === String(name)); }
  delete(name) { this.#list = this.#list.filter(([key]) => key !== String(name)); }
  entries() { return this.#list.map((entry) => [...entry])[Symbol.iterator](); }
  keys() { return this.#list.map(([key]) => key)[Symbol.iterator](); }
  values() { return this.#list.map(([, value]) => value)[Symbol.iterator](); }
  forEach(callback, self) { for (const [key, value] of this.#list) callback.call(self, value, key, this); }
  [Symbol.iterator]() { return this.entries(); }
}
const multipart = (form) => {
  const boundary = "----nanocodeFormBoundary" + toHex(randomBytes(12));
  const quoteName = (name) => name.replace(/"/g, "%22").replace(/\r/g, "%0D").replace(/\n/g, "%0A");
  const chunks = [];
  for (const [name, value] of form) {
    let head = "--" + boundary + "\r\nContent-Disposition: form-data; name=\"" + quoteName(name) + "\"";
    if (value instanceof File) head += "; filename=\"" + quoteName(value.name) + "\"\r\nContent-Type: " + (value.type || "application/octet-stream");
    chunks.push(utf8(head + "\r\n\r\n"), value instanceof Blob ? blobBytes.get(value) : utf8(value), utf8("\r\n"));
  }
  chunks.push(utf8("--" + boundary + "--\r\n"));
  return { bytes: joinBytes(chunks), type: "multipart/form-data; boundary=" + boundary };
};
const formEncode = (text) => {
  const bytes = utf8(String(text));
  let out = "";
  for (const byte of bytes) {
    if ((byte >= 48 && byte <= 57) || (byte >= 65 && byte <= 90) || (byte >= 97 && byte <= 122) || byte === 42 || byte === 45 || byte === 46 || byte === 95) out += String.fromCharCode(byte);
    else if (byte === 32) out += "+";
    else out += "%" + (byte < 16 ? "0" : "") + byte.toString(16).toUpperCase();
  }
  return out;
};
const percentDecode = (text) => {
  if (!text.includes("%")) return text;
  const bytes = utf8(text);
  const decoded = [];
  for (let index = 0; index < bytes.length; index++) {
    if (bytes[index] === 37 && index + 2 < bytes.length) {
      const value = parseInt(String.fromCharCode(bytes[index + 1], bytes[index + 2]), 16);
      if (!Number.isNaN(value) && /^[0-9a-f]{2}$/i.test(String.fromCharCode(bytes[index + 1], bytes[index + 2]))) { decoded.push(value); index += 2; continue; }
    }
    decoded.push(bytes[index]);
  }
  return fromUtf8(Uint8Array.from(decoded));
};
const searchOwners = new WeakMap();
class URLSearchParams {
  #list = [];
  constructor(init = "") {
    if (init instanceof URLSearchParams) this.#list = [...init].map((entry) => [...entry]);
    else if (typeof init === "string" || init === undefined || init === null) this.#parse(String(init ?? ""));
    else if (typeof init[Symbol.iterator] === "function") {
      for (const pair of init) {
        const entry = [...pair];
        if (entry.length !== 2) throw new TypeError("URLSearchParams expects pairs of [name, value]");
        this.#list.push([String(entry[0]), String(entry[1])]);
      }
    } else if (typeof init === "object") for (const [key, value] of Object.entries(init)) this.#list.push([key, String(value)]);
    else this.#parse(String(init));
  }
  #parse(text) {
    this.#list = [];
    for (const piece of text.replace(/^\?/, "").split("&")) {
      if (!piece) continue;
      const at = piece.indexOf("=");
      const name = at < 0 ? piece : piece.slice(0, at), value = at < 0 ? "" : piece.slice(at + 1);
      this.#list.push([percentDecode(name.replace(/\+/g, " ")), percentDecode(value.replace(/\+/g, " "))]);
    }
  }
  #changed() { searchOwners.get(this)?.(this.toString()); }
  get size() { return this.#list.length; }
  append(name, value) { this.#list.push([String(name), String(value)]); this.#changed(); }
  delete(name, value) { this.#list = this.#list.filter(([key, entry]) => key !== String(name) || (value !== undefined && entry !== String(value))); this.#changed(); }
  get(name) { return this.#list.find(([key]) => key === String(name))?.[1] ?? null; }
  getAll(name) { return this.#list.filter(([key]) => key === String(name)).map(([, value]) => value); }
  has(name, value) { return this.#list.some(([key, entry]) => key === String(name) && (value === undefined || entry === String(value))); }
  set(name, value) {
    const at = this.#list.findIndex(([key]) => key === String(name));
    if (at < 0) this.#list.push([String(name), String(value)]);
    else { this.#list[at] = [String(name), String(value)]; this.#list = this.#list.filter(([key], index) => key !== String(name) || index === at); }
    this.#changed();
  }
  sort() { this.#list = this.#list.map((entry, index) => [entry, index]).sort(([a, i], [b, j]) => a[0] < b[0] ? -1 : a[0] > b[0] ? 1 : i - j).map(([entry]) => entry); this.#changed(); }
  toString() { return this.#list.map(([key, value]) => formEncode(key) + "=" + formEncode(value)).join("&"); }
  forEach(callback, self) { for (const [key, value] of this.#list) callback.call(self, value, key, this); }
  keys() { return this.#list.map(([key]) => key)[Symbol.iterator](); }
  values() { return this.#list.map(([, value]) => value)[Symbol.iterator](); }
  entries() { return this.#list.map((entry) => [...entry])[Symbol.iterator](); }
  [Symbol.iterator]() { return this.entries(); }
  reset(text) { this.#parse(text); }
}
const specialPorts = { "ftp:": "21", "file:": "", "http:": "80", "https:": "443", "ws:": "80", "wss:": "443" };
const encodeSet = (text, extra) => {
  let out = "";
  for (const character of text) {
    const code = character.codePointAt(0);
    if (code > 0x20 && code < 0x7f && !extra.includes(character)) out += character;
    else for (const byte of utf8(character)) out += "%" + (byte < 16 ? "0" : "") + byte.toString(16).toUpperCase();
  }
  return out;
};
const pathSet = " \"#<>?^\x60{}";
const querySet = " \"#<>";
const fragmentSet = " \"<>\x60";
const userSet = " \"#<>?^\x60{}/:;=@[\\]|";
const normalizePath = (path, special) => {
  const segments = (special ? path.replace(/\\/g, "/") : path).split("/");
  const out = [];
  segments.forEach((segment, index) => {
    const last = index === segments.length - 1;
    if (/^(\.|%2e)$/i.test(segment)) { if (last) out.push(""); return; }
    if (/^(\.|%2e){2}$/i.test(segment)) { if (out.length > 1) out.pop(); if (last) out.push(""); return; }
    out.push(encodeSet(segment, pathSet));
  });
  const joined = out.join("/");
  return joined.startsWith("/") ? joined : "/" + joined;
};
const parseUrl = (input, base) => {
  const text = String(input).replace(/^[\u0000-\u0020]+|[\u0000-\u0020]+$/g, "").replace(/[\t\n\r]/g, "");
  const scheme = /^([a-zA-Z][a-zA-Z0-9+.-]*):/.exec(text);
  const parts = { protocol: "", username: "", password: "", hostname: "", port: "", pathname: "", search: "", hash: "", opaque: false, hasHost: false };
  const split = (rest, special) => {
    const hashAt = rest.indexOf("#");
    if (hashAt >= 0) { parts.hash = "#" + encodeSet(rest.slice(hashAt + 1), fragmentSet); rest = rest.slice(0, hashAt); }
    const queryAt = rest.indexOf("?");
    if (queryAt >= 0) { parts.search = "?" + encodeSet(rest.slice(queryAt + 1), special ? querySet + "'" : querySet); rest = rest.slice(0, queryAt); }
    if (parts.search === "?") parts.search = "";
    if (parts.hash === "#") parts.hash = "";
    return rest;
  };
  const authority = (rest, special) => {
    const end = rest.search(special ? /[\/\\?#]/ : /[\/?#]/);
    const auth = end < 0 ? rest : rest.slice(0, end);
    const remainder = end < 0 ? "" : rest.slice(end);
    const at = auth.lastIndexOf("@");
    if (at >= 0) {
      const info = auth.slice(0, at), colon = info.indexOf(":");
      parts.username = encodeSet(colon < 0 ? info : info.slice(0, colon), userSet);
      parts.password = colon < 0 ? "" : encodeSet(info.slice(colon + 1), userSet);
    }
    const hostPort = at >= 0 ? auth.slice(at + 1) : auth;
    const match = /^(\[[0-9a-fA-F:.]+\]|[^:]*)(?::(\d*))?$/.exec(hostPort);
    if (!match) return null;
    let hostname = percentDecode(match[1]);
    if (special) hostname = hostname.toLowerCase();
    if (/[\u0000-\u0020#%\/:<>?@\[\\\]^|]/.test(hostname.replace(/^\[.*\]$/, "")) ) return null;
    if (special && !hostname && parts.protocol !== "file:") return null;
    if (match[2] !== undefined && match[2] !== "") {
      const port = Number(match[2]);
      if (port > 65535) return null;
      parts.port = String(port) === specialPorts[parts.protocol] ? "" : String(port);
    }
    parts.hostname = hostname;
    parts.hasHost = true;
    return remainder;
  };
  if (scheme) {
    parts.protocol = scheme[1].toLowerCase() + ":";
    const special = parts.protocol in specialPorts;
    let rest = text.slice(scheme[0].length);
    if (special) {
      if (base && base.protocol === parts.protocol && !/^[\/\\]/.test(rest)) return parseUrl(rest, base);
      rest = rest.replace(/^[\/\\]*/, "");
      if (parts.protocol === "file:") { rest = split(rest, true); const slash = rest.search(/[\/\\]/); parts.hasHost = true; parts.hostname = slash < 0 ? rest.toLowerCase() : rest.slice(0, slash).toLowerCase(); if (/^[a-z]:$/i.test(parts.hostname)) { parts.hostname = ""; parts.pathname = normalizePath("/" + rest, true); } else parts.pathname = normalizePath(slash < 0 ? "/" : rest.slice(slash), true); return parts; }
      rest = split(rest, true);
      const remainder = authority(rest, true);
      if (remainder === null) return null;
      parts.pathname = normalizePath(remainder || "/", true);
      return parts;
    }
    rest = split(rest, false);
    if (rest.startsWith("//")) {
      const remainder = authority(rest.slice(2), false);
      if (remainder === null) return null;
      parts.pathname = remainder ? normalizePath(remainder, false) : "";
      return parts;
    }
    if (rest.startsWith("/")) { parts.pathname = normalizePath(rest, false); return parts; }
    parts.opaque = true;
    parts.pathname = encodeSet(rest, "").replace(/%20/g, " ");
    return parts;
  }
  if (!base) return null;
  const special = base.protocol in specialPorts;
  parts.protocol = base.protocol;
  if (base.opaque) {
    if (!text.startsWith("#")) return null;
    Object.assign(parts, base, { hash: "" });
    split(text, special);
    return parts;
  }
  if (/^[\/\\]{2}/.test(text) && (special || text.startsWith("//"))) {
    const rest = split(text.slice(2), special);
    const remainder = authority(rest, special);
    if (remainder === null) return null;
    parts.pathname = normalizePath(remainder || "/", special);
    return parts;
  }
  Object.assign(parts, { username: base.username, password: base.password, hostname: base.hostname, port: base.port, hasHost: base.hasHost });
  const rest = split(text, special);
  if (!rest) {
    parts.pathname = base.pathname;
    if (!text.includes("?")) parts.search = text.startsWith("#") || text === "" ? base.search : parts.search;
    return parts;
  }
  if (/^[\/]/.test(rest) || (special && rest.startsWith("\\"))) { parts.pathname = normalizePath(rest, special); return parts; }
  const directory = base.pathname.slice(0, base.pathname.lastIndexOf("/") + 1);
  parts.pathname = normalizePath(directory + rest, special);
  return parts;
};
class URL {
  #parts;
  #query;
  constructor(url, base) {
    const baseParts = base === undefined ? undefined : base instanceof URL ? base.#parts : new URL(String(base)).#parts;
    const parts = parseUrl(url instanceof URL ? url.href : String(url), baseParts);
    if (!parts) throw new TypeError("Invalid URL: " + String(url) + (base === undefined ? "" : " (base " + String(base) + ")"));
    this.#parts = parts;
    this.#query = new URLSearchParams(parts.search);
    searchOwners.set(this.#query, (search) => { this.#parts.search = search ? "?" + search : ""; });
  }
  static canParse(url, base) { try { new URL(url, base); return true; } catch { return false; } }
  static parse(url, base) { try { return new URL(url, base); } catch { return null; } }
  static createObjectURL() { throw new Error("URL.createObjectURL is not available in Code Mode cells"); }
  static revokeObjectURL() {}
  get protocol() { return this.#parts.protocol; }
  set protocol(value) { const next = String(value).replace(/:.*$/, "").toLowerCase() + ":"; if ((next in specialPorts) === (this.#parts.protocol in specialPorts)) { this.#parts.protocol = next; if (this.#parts.port === specialPorts[next]) this.#parts.port = ""; } }
  get username() { return this.#parts.username; }
  set username(value) { this.#parts.username = encodeSet(String(value), userSet); }
  get password() { return this.#parts.password; }
  set password(value) { this.#parts.password = encodeSet(String(value), userSet); }
  get hostname() { return this.#parts.hostname; }
  set hostname(value) { if (!this.#parts.opaque) this.#parts.hostname = this.#parts.protocol in specialPorts ? String(value).toLowerCase() : String(value); }
  get port() { return this.#parts.port; }
  set port(value) { const port = String(value) === "" ? "" : String(parseInt(String(value), 10)); if (port === "" || (Number(port) >= 0 && Number(port) <= 65535)) this.#parts.port = port === specialPorts[this.#parts.protocol] ? "" : port; }
  get host() { return this.#parts.hostname + (this.#parts.port ? ":" + this.#parts.port : ""); }
  set host(value) { const [hostname, port] = String(value).split(":"); this.hostname = hostname; if (port !== undefined) this.port = port; }
  get origin() { return this.#parts.protocol in specialPorts && this.#parts.protocol !== "file:" ? this.#parts.protocol + "//" + this.host : "null"; }
  get pathname() { return this.#parts.pathname; }
  set pathname(value) { if (!this.#parts.opaque) this.#parts.pathname = normalizePath(String(value), this.#parts.protocol in specialPorts); }
  get search() { return this.#parts.search; }
  set search(value) { const search = String(value).replace(/^\?/, ""); this.#parts.search = search ? "?" + encodeSet(search, querySet) : ""; this.#query.reset(search); }
  get searchParams() { return this.#query; }
  get hash() { return this.#parts.hash; }
  set hash(value) { const hash = String(value).replace(/^#/, ""); this.#parts.hash = hash ? "#" + encodeSet(hash, fragmentSet) : ""; }
  get href() {
    const parts = this.#parts;
    const credentials = parts.username || parts.password ? parts.username + (parts.password ? ":" + parts.password : "") + "@" : "";
    return parts.protocol + (parts.hasHost ? "//" + credentials + this.host : "") + parts.pathname + parts.search + parts.hash;
  }
  set href(value) { const next = new URL(value); this.#parts = next.#parts; this.#query.reset(next.#parts.search); }
  toString() { return this.href; }
  toJSON() { return this.href; }
}
class ReadableStream {
  #queue = [];
  #waiters = [];
  #closed = false;
  #error;
  #failed = false;
  #source;
  #controller;
  #pulling;
  locked = false;
  constructor(source = {}) {
    this.#source = source;
    this.#controller = {
      enqueue: (chunk) => { if (this.#closed) throw new TypeError("the stream is closed"); const waiter = this.#waiters.shift(); if (waiter) waiter.resolve({ value: chunk, done: false }); else this.#queue.push(chunk); },
      close: () => { this.#closed = true; this.#settle(); },
      error: (error) => { this.#failed = true; this.#error = error ?? new Error("the stream errored"); this.#settle(); },
      get desiredSize() { return 1; },
    };
    this.#pulling = Promise.resolve(source.start?.(this.#controller)).catch((error) => this.#controller.error(error));
  }
  #settle() {
    if (this.#queue.length) return;
    for (const waiter of this.#waiters.splice(0)) this.#failed ? waiter.reject(this.#error) : waiter.resolve({ value: undefined, done: true });
  }
  async #read() {
    await this.#pulling;
    if (this.#queue.length) return { value: this.#queue.shift(), done: false };
    if (this.#failed) throw this.#error;
    if (this.#closed) return { value: undefined, done: true };
    const next = new Promise((resolve, reject) => this.#waiters.push({ resolve, reject }));
    if (this.#source.pull) {
      this.#pulling = Promise.resolve(this.#source.pull(this.#controller)).catch((error) => this.#controller.error(error));
      await this.#pulling;
      if (!this.#queue.length && !this.#closed && !this.#failed && this.#waiters.length) {
        const pending = this.#waiters.length;
        await Promise.resolve();
        if (this.#waiters.length === pending && this.#source.pull) return Promise.race([next, this.#read().then((result) => { this.#waiters.pop(); return result; })]);
      }
    }
    return next;
  }
  getReader() {
    if (this.locked) throw new TypeError("ReadableStream is locked to a reader");
    this.locked = true;
    let resolveClosed;
    const closed = new Promise((resolve) => { resolveClosed = resolve; });
    return {
      read: async () => { const result = await this.#read(); if (result.done) resolveClosed(); return result; },
      releaseLock: () => { this.locked = false; },
      cancel: (reason) => this.cancel(reason, true),
      closed,
    };
  }
  async cancel(reason) { this.#closed = true; this.#queue = []; this.#settle(); await this.#source.cancel?.(reason); }
  values() {
    const reader = this.getReader();
    return { next: () => reader.read(), return: async () => { reader.releaseLock(); return { value: undefined, done: true }; }, [Symbol.asyncIterator]() { return this; } };
  }
  [Symbol.asyncIterator]() { return this.values(); }
  pipeThrough(transform) { this.pipeTo(transform.writable).catch(() => {}); return transform.readable; }
  async pipeTo(writable) {
    const writer = writable.getWriter();
    try { for await (const chunk of this) await writer.write(chunk); await writer.close(); }
    catch (error) { await writer.abort(error); throw error; }
  }
  tee() {
    const reader = this.getReader();
    const branches = [[], []];
    const controllers = [];
    let reading;
    const pump = () => reading ??= reader.read().then((result) => { reading = undefined; controllers.forEach((controller) => result.done ? controller.close() : controller.enqueue(result.value)); });
    return [0, 1].map((index) => new ReadableStream({ start(controller) { controllers[index] = controller; }, pull: () => pump() }));
  }
  static from(iterable) {
    const iterator = (iterable[Symbol.asyncIterator] ?? iterable[Symbol.iterator]).call(iterable);
    return new ReadableStream({ async pull(controller) { const { value, done } = await iterator.next(); if (done) controller.close(); else controller.enqueue(value); } });
  }
}
class WritableStream {
  #sink;
  locked = false;
  constructor(sink = {}) { this.#sink = sink; sink.start?.({ error() {} }); }
  getWriter() {
    const sink = this.#sink;
    this.locked = true;
    return {
      write: async (chunk) => { await sink.write?.(chunk, { error() {} }); },
      close: async () => { await sink.close?.(); },
      abort: async (reason) => { await sink.abort?.(reason); },
      releaseLock: () => { this.locked = false; },
      ready: Promise.resolve(),
      closed: Promise.resolve(),
      desiredSize: 1,
    };
  }
  async close() { await this.#sink.close?.(); }
  async abort(reason) { await this.#sink.abort?.(reason); }
}
class TransformStream {
  constructor(transformer = {}) {
    let target;
    this.readable = new ReadableStream({ start(controller) { target = controller; } });
    const controller = { enqueue: (chunk) => target.enqueue(chunk), error: (error) => target.error(error), terminate: () => target.close(), desiredSize: 1 };
    transformer.start?.(controller);
    this.writable = new WritableStream({
      write: (chunk) => transformer.transform ? transformer.transform(chunk, controller) : controller.enqueue(chunk),
      close: async () => { await transformer.flush?.(controller); target.close(); },
      abort: (reason) => target.error(reason),
    });
  }
}
class TextDecoderStream extends TransformStream {
  constructor(label, options) {
    const decoder = new TextDecoder(label, options);
    super({ transform(chunk, controller) { const text = decoder.decode(chunk, { stream: true }); if (text) controller.enqueue(text); }, flush(controller) { const text = decoder.decode(); if (text) controller.enqueue(text); } });
    this.encoding = decoder.encoding;
  }
}
class TextEncoderStream extends TransformStream {
  constructor() { const encoder = new TextEncoder(); super({ transform(chunk, controller) { controller.enqueue(encoder.encode(chunk)); } }); this.encoding = "utf-8"; }
}
const readAll = async (stream) => {
  const chunks = [];
  for await (const chunk of stream) chunks.push(typeof chunk === "string" ? utf8(chunk) : byteView(chunk) ?? utf8(String(chunk)));
  return joinBytes(chunks);
};
return { Blob, Buffer, File, FormData, ReadableStream, TextDecoderStream, TextEncoderStream, TransformStream, URL, URLSearchParams, WritableStream, blobBytes, multipart, readAll, structuredClone };
