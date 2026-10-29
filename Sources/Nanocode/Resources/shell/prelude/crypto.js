const { byteView, digestBytes, fromBase64, randomBytes, toBase64, toHex } = core;
const hashes = { "SHA-1": [20, 64], "SHA-256": [32, 64], "SHA-384": [48, 128], "SHA-512": [64, 128] };
const algorithmName = (algorithm) => String(typeof algorithm === "string" ? algorithm : algorithm?.name ?? "").toUpperCase().replace(/^SHA(\d)/, "SHA-$1");
const hashOf = (algorithm) => {
  const name = algorithmName(algorithm);
  const found = hashes[name];
  if (!found) throw new DOMException("Unrecognized hash algorithm " + JSON.stringify(typeof algorithm === "string" ? algorithm : algorithm?.name) + ": Code Mode cells support SHA-1, SHA-256, SHA-384 and SHA-512", "NotSupportedError");
  return [(bytes) => digestBytes(name, bytes), ...found];
};
const bufferSource = (data) => {
  const bytes = byteView(data);
  if (!bytes) throw new TypeError("expected an ArrayBuffer or a typed array, got " + (typeof data === "string" ? "a string (encode it with new TextEncoder().encode(text))" : typeof data));
  return bytes;
};
const hmac = (hashName, key, data) => {
  const [hash, size, block] = hashOf(hashName);
  const secret = key.length > block ? hash(key) : key;
  const padded = new Uint8Array(block);
  padded.set(secret);
  const inner = new Uint8Array(block + data.length), outer = new Uint8Array(block + size);
  for (let i = 0; i < block; i++) { inner[i] = padded[i] ^ 0x36; outer[i] = padded[i] ^ 0x5c; }
  inner.set(data, block);
  outer.set(hash(inner), block);
  return hash(outer);
};
const keys = new WeakMap();
const unsupported = (name) => async () => { throw new DOMException("crypto.subtle." + name + " is not available in Code Mode cells: they support digest (SHA-1, SHA-256, SHA-384, SHA-512) and HMAC importKey, sign and verify", "NotSupportedError"); };
const subtle = {
  digest: async (algorithm, data) => hashOf(algorithm)[0](bufferSource(data)).buffer,
  importKey: async (format, keyData, algorithm, extractable = false, usages = []) => {
    if (algorithmName(algorithm) !== "HMAC") return unsupported("importKey for " + algorithmName(algorithm))();
    const hash = algorithmName(algorithm.hash ?? "SHA-256");
    hashOf(hash);
    const bytes = format === "raw" ? bufferSource(keyData).slice() : format === "jwk" ? fromBase64(keyData.k) : null;
    if (!bytes) return unsupported("importKey with format " + format)();
    const key = { type: "secret", extractable, usages: [...usages], algorithm: { name: "HMAC", hash: { name: hash }, length: bytes.length * 8 } };
    keys.set(key, bytes);
    return key;
  },
  exportKey: async (format, key) => { if (!key.extractable) throw new DOMException("key is not extractable", "InvalidAccessError"); return format === "raw" ? keys.get(key).slice().buffer : { kty: "oct", k: toBase64(keys.get(key)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, ""), alg: "HS" + key.algorithm.hash.name.slice(4), ext: true }; },
  sign: async (algorithm, key, data) => { if (algorithmName(algorithm) !== "HMAC" || !keys.has(key)) return unsupported("sign for " + algorithmName(algorithm))(); return hmac(key.algorithm.hash.name, keys.get(key), bufferSource(data)).buffer; },
  verify: async (algorithm, key, signature, data) => { const expected = new Uint8Array(await subtle.sign(algorithm, key, data)); const given = bufferSource(signature); return expected.length === given.length && expected.every((byte, i) => byte === given[i]); },
  generateKey: unsupported("generateKey"),
  encrypt: unsupported("encrypt"),
  decrypt: unsupported("decrypt"),
  deriveBits: unsupported("deriveBits"),
  deriveKey: unsupported("deriveKey"),
  wrapKey: unsupported("wrapKey"),
  unwrapKey: unsupported("unwrapKey"),
};
const crypto = {
  getRandomValues: (array) => {
    if (!ArrayBuffer.isView(array) || array instanceof DataView || array instanceof Float32Array || array instanceof Float64Array) throw new DOMException("getRandomValues expects an integer typed array", "TypeMismatchError");
    if (array.byteLength > 65536) throw new DOMException("getRandomValues accepts at most 65536 bytes", "QuotaExceededError");
    new Uint8Array(array.buffer, array.byteOffset, array.byteLength).set(randomBytes(array.byteLength));
    return array;
  },
  randomUUID: () => {
    const bytes = randomBytes(16);
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    const hex = toHex(bytes);
    return hex.slice(0, 8) + "-" + hex.slice(8, 12) + "-" + hex.slice(12, 16) + "-" + hex.slice(16, 20) + "-" + hex.slice(20);
  },
  subtle,
};
return { crypto };
