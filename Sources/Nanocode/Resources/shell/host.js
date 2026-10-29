(() => {
  const native = globalThis.__shell;
  const machine = globalThis.__wasm;
  const bytes = globalThis.__nanocodeBytes;
  const timer = globalThis.setTimeout;
  delete globalThis.__shell;
  delete globalThis.__wasm;
  const skipped = new Set(["WebAssembly", "bash", "process", "require", "wasm"]);
  const pythons = new Map();
  const python = (home, tmp) => (request, signal) => {
    const mounts = [[home, home], [tmp, "/tmp"]];
    for (const root of request.roots) {
      const directory = root === request.filename ? root.slice(0, Math.max(1, root.lastIndexOf("/"))) : root;
      if (!mounts.some(([, point]) => inside(directory, point))) mounts.push([directory, directory]);
    }
    const id = next++;
    return new Promise((resolve, reject) => {
      pythons.set(id, { resolve, reject });
      signal.addEventListener("abort", () => {
        pythons.delete(id);
        native.pyodide(next++, JSON.stringify({ cancel: id }));
        reject(signal.reason);
      }, { once: true });
      native.pyodide(id, JSON.stringify({ ...request, id, home, mounts }));
    });
  };
  const fetches = new Map();
  const runs = new Map();
  let next = 1;
  let redirect = "follow";
  let globals;
  let ready;

  const call = (name, input) => {
    if (name !== "fetch") return Promise.reject(new Error(name + " is not available in this shell"));
    const id = next++;
    const request = JSON.stringify({ ...input, redirect });
    return new Promise((resolve, reject) => {
      fetches.set(id, { resolve, reject });
      native.fetch(id, request);
    });
  };

  const fetch = (input, init = {}) => {
    const mode = init?.redirect ?? (input instanceof globals.Request ? input.redirect : undefined);
    redirect = mode === "manual" ? "manual" : "follow";
    try {
      return globals.fetch(input, init);
    } finally {
      redirect = "follow";
    }
  };

  const failure = (error, path) => {
    const text = String(error?.message ?? error);
    const at = text.indexOf(":");
    const code = at < 0 ? text : text.slice(0, at);
    const failed = new NanocodeBash.FsError(code, path);
    if (at >= 0 && failed.message === path + ": " + code) failed.message = path + ": " + text.slice(at + 1);
    return failed;
  };

  const guard = (path, operation) => {
    try {
      return operation();
    } catch (error) {
      throw failure(error, path);
    }
  };

  const fs = {
    stat: async (path) => guard(path, () => native.stat(path)),
    lstat: async (path) => guard(path, () => native.lstat(path)),
    read: async (path) => new Uint8Array(guard(path, () => native.read(path))),
    write: async (path, data, append = false) => guard(path, () => native.write(path, data.buffer, data.byteOffset, data.byteLength, append)),
    list: async (path) => guard(path, () => native.list(path)),
    mkdir: async (path) => guard(path, () => native.mkdir(path)),
    remove: async (path) => guard(path, () => native.remove(path)),
    rename: async (from, to) => guard(from, () => native.rename(from, to)),
    chmod: async (path, mode) => guard(path, () => native.chmod(path, mode)),
    utimes: async (path, mtime) => guard(path, () => native.utimes(path, mtime)),
    symlink: async (target, path) => guard(path, () => native.symlink(target, path)),
    readlink: async (path) => guard(path, () => native.readlink(path)),
  };

  const released = new FinalizationRegistry((id) => native.release(id));

  const coder = (format, decompress) => {
    const kind = String(format);
    if (!["gzip", "deflate", "deflate-raw"].includes(kind)) throw new TypeError("Unsupported compression format: '" + kind + "'");
    const id = native.coder(kind, decompress);
    const enqueue = (controller, buffer) => {
      if (buffer.byteLength) controller.enqueue(new Uint8Array(buffer));
    };
    const transformer = {
      transform(chunk, controller) {
        const view = ArrayBuffer.isView(chunk) ? chunk : chunk instanceof ArrayBuffer ? new Uint8Array(chunk) : undefined;
        if (!view) throw new TypeError("The provided value is not of type '(ArrayBuffer or ArrayBufferView)'");
        enqueue(controller, native.push(id, view.buffer, view.byteOffset, view.byteLength));
      },
      flush(controller) {
        enqueue(controller, native.finish(id));
      },
    };
    released.register(transformer, id);
    return new globals.TransformStream(transformer);
  };

  class CompressionStream {
    constructor(format) {
      const { readable, writable } = coder(format, false);
      this.readable = readable;
      this.writable = writable;
    }
  }

  class DecompressionStream {
    constructor(format) {
      const { readable, writable } = coder(format, true);
      this.readable = readable;
      this.writable = writable;
    }
  }

  class CompileError extends Error {
    constructor(message) {
      super(message);
      this.name = "CompileError";
    }
  }

  class LinkError extends Error {
    constructor(message) {
      super(message);
      this.name = "LinkError";
    }
  }

  class RuntimeError extends Error {
    constructor(message) {
      super(message);
      this.name = "RuntimeError";
    }
  }

  const sealed = Symbol("sealed");
  const compiled = new WeakMap();
  const exportedFunctions = new WeakMap();
  const freed = new FinalizationRegistry(([kind, id]) => machine.release(kind, id));
  const kinds = { func: "function", memory: "memory", table: "table", global: "global" };

  const toWasm = (code, value) => {
    if (code === "I") {
      if (typeof value === "number") throw new TypeError("Cannot convert " + value + " to a BigInt");
      return BigInt.asIntN(64, BigInt(value));
    }
    if (typeof value === "bigint") throw new TypeError("Cannot convert a BigInt value to a number");
    if (code === "i") return Number(value) | 0;
    if (code === "f") return Math.fround(Number(value));
    return Number(value);
  };

  const hosted = (fn, results) => (...args) => {
    const value = fn(...args);
    if (!results.length) return [];
    const values = results.length === 1 ? [value] : [...value];
    return [...results].map((code, index) => toWasm(code, values[index]));
  };

  const moduleOf = (module) => {
    const found = compiled.get(module);
    if (!found) throw new TypeError("WebAssembly.Instance(): Argument 0 must be a WebAssembly.Module");
    return found;
  };

  const sourceBytes = (source) => {
    const view = ArrayBuffer.isView(source) ? source : source instanceof ArrayBuffer ? new Uint8Array(source) : undefined;
    if (!view) throw new TypeError("WebAssembly.Module(): Argument 0 must be a buffer source");
    return view;
  };

  class Module {
    constructor(source) {
      const view = sourceBytes(source);
      const result = JSON.parse(machine.compile(view.buffer, view.byteOffset, view.byteLength));
      if (result.error !== undefined) throw new CompileError("WebAssembly.Module(): " + result.error);
      compiled.set(this, result);
      freed.register(this, ["module", result.id]);
    }

    static imports(module) {
      return moduleOf(module).imports.map(([space, name, kind]) => ({ module: space, name, kind: kinds[kind] ?? kind }));
    }

    static exports(module) {
      return moduleOf(module).exports.map(([name, kind]) => ({ name, kind: kinds[kind] ?? kind }));
    }

    static customSections() {
      return [];
    }
  }

  class Memory {
    #id;
    #name;
    #owner;

    constructor(token, owner, id, name) {
      if (token !== sealed) throw new TypeError("WebAssembly.Memory can only come from an instance's exports here");
      this.#owner = owner;
      this.#id = id;
      this.#name = name;
    }

    get buffer() {
      return machine.memory(this.#id, this.#name);
    }

    grow(delta) {
      const old = machine.grow(this.#id, this.#name, Number(delta) >>> 0);
      if (old < 0) throw new RangeError("WebAssembly.Memory.grow(): Maximum memory size exceeded");
      return old;
    }
  }

  class Table {
    #id;
    #name;
    #owner;
    #entries = new Map();

    constructor(token, owner, id, name) {
      if (token !== sealed) throw new TypeError("WebAssembly.Table can only come from an instance's exports here");
      this.#owner = owner;
      this.#id = id;
      this.#name = name;
    }

    get length() {
      return machine.tableSize(this.#id, this.#name);
    }

    get(index) {
      return this.#entries.get(Number(index)) ?? null;
    }

    set(index, value) {
      const target = exportedFunctions.get(value);
      if (!target) throw new TypeError("WebAssembly.Table.set(): Argument 1 must be an exported WebAssembly function");
      machine.tableSet(this.#id, this.#name, Number(index) >>> 0, hosted(value, target.results), target);
      this.#entries.set(Number(index), value);
    }

    grow() {
      throw new RangeError("WebAssembly.Table.grow() is not supported by this host");
    }
  }

  class Global {
    #id;
    #name;
    #owner;

    constructor(token, owner, id, name, type) {
      if (token !== sealed) throw new TypeError("WebAssembly.Global can only come from an instance's exports here");
      this.#owner = owner;
      this.#id = id;
      this.#name = name;
      this.type = type;
    }

    get value() {
      return machine.global(this.#id, this.#name);
    }

    set value(value) {
      machine.global(this.#id, this.#name, toWasm(this.type, value));
    }

    valueOf() {
      return this.value;
    }
  }

  class Instance {
    constructor(module, imports = {}) {
      const description = moduleOf(module);
      const functions = description.imports.map(([space, name, kind, , results], index) => {
        const value = imports?.[space]?.[name];
        const label = "WebAssembly.Instance(): Import #" + index + " " + JSON.stringify(space) + " " + JSON.stringify(name);
        if (kind !== "func") throw new LinkError(label + ": this host links only function imports, not a " + kind);
        if (typeof value !== "function") throw new LinkError(label + ": function import requires a callable");
        return hosted(value, results);
      });
      const result = machine.instantiate(description.id, functions);
      if (result.link !== undefined) throw new LinkError("WebAssembly.Instance(): " + result.link);
      if (result.trap !== undefined) throw new RuntimeError(result.trap);
      const id = result.id;
      freed.register(this, ["instance", id]);
      const exports = Object.create(null);
      for (const [name, kind, params, results] of description.exports) {
        if (kind === "func") {
          const fn = (...args) => {
            const values = [...params].map((code, index) => toWasm(code, args[index]));
            const returned = machine.call(id, name, values);
            if (returned !== null && typeof returned === "object" && !Array.isArray(returned) && "trap" in returned) throw new RuntimeError(returned.trap);
            return returned;
          };
          exportedFunctions.set(fn, { instance: id, name, params, results, owner: this });
          exports[name] = fn;
        } else if (kind === "memory") exports[name] = new Memory(sealed, this, id, name);
        else if (kind === "table") exports[name] = new Table(sealed, this, id, name);
        else if (kind === "global") exports[name] = new Global(sealed, this, id, name, params);
      }
      this.exports = Object.freeze(exports);
    }
  }

  const instantiate = async (source, imports) => {
    if (source instanceof Module) return new Instance(source, imports);
    const module = new Module(await source);
    return { module, instance: new Instance(module, imports) };
  };

  const WebAssembly = {
    CompileError,
    Global,
    Instance,
    LinkError,
    Memory,
    Module,
    RuntimeError,
    Table,
    compile: async (source) => new Module(await source),
    compileStreaming: async (response) => new Module(new Uint8Array(await (await response).arrayBuffer())),
    instantiate,
    instantiateStreaming: async (response, imports) => instantiate(new Uint8Array(await (await response).arrayBuffer()), imports),
    validate: (source) => {
      try {
        new Module(source);
        return true;
      } catch {
        return false;
      }
    },
  };

  globalThis.__install = (prelude) => {
    globals = prelude({}, call);
    for (const [name, value] of Object.entries(globals)) if (!skipped.has(name)) globalThis[name] = value;
    globalThis.setTimeout = (callback, delay, ...args) => timer(args.length ? () => callback(...args) : callback, delay);
    globalThis.console ??= { debug() {}, error() {}, info() {}, log() {}, warn() {} };
    globalThis.CompressionStream = CompressionStream;
    globalThis.DecompressionStream = DecompressionStream;
    globalThis.WebAssembly = WebAssembly;
    delete globalThis.__install;
  };

  const inside = (path, root) => path === root || path.startsWith(root === "/" ? "/" : root + "/");

  globalThis.__open = (config) => {
    const options = JSON.parse(config);
    ready = NanocodeBash.create({
      codec: {
        encode: (text) => new Uint8Array(native.unescaped(text)),
        decode: (data) => native.escaped(data.buffer, data.byteOffset, data.byteLength),
        toBase64: (data) => bytes.toBase64(data.buffer, data.byteOffset, data.byteLength),
        fromBase64: (text) => new Uint8Array(native.fromBase64(text)),
      },
      fs,
      fetch,
      cwd: options.cwd,
      env: options.env,
      limits: options.limits,
      wasm: { rootDepth: -1 },
      python: { remote: python(options.env.HOME, options.tmp), shared: true },
    });
    ready.catch(() => {});
    delete globalThis.__open;
  };

  globalThis.__run = (id, request) => {
    const input = JSON.parse(request);
    const controller = new AbortController();
    runs.set(id, controller);
    ready
      .then((shell) => shell.exec(input.script, {
        cwd: input.cwd,
        signal: controller.signal,
        timeoutMs: input.timeout_ms,
        ...(typeof input.stdin === "string" ? { stdin: input.stdin } : {}),
      }))
      .then(
        (result) => JSON.stringify({ stdout: result.stdout, stderr: result.stderr, exit_code: result.exitCode, truncated: result.truncated }),
        (error) => JSON.stringify({ error: error instanceof Error ? error.message : String(error) }),
      )
      .then((result) => {
        runs.delete(id);
        native.done(id, result);
      });
  };

  globalThis.__abort = (id) => runs.get(id)?.abort("execution aborted");

  globalThis.__python = (id, failed, reply) => {
    const pending = pythons.get(id);
    if (!pending) return;
    pythons.delete(id);
    if (failed === null) pending.resolve(JSON.parse(reply));
    else pending.reject(new Error(failed));
  };

  globalThis.__fetched = (id, failed, head) => {
    const pending = fetches.get(id);
    if (!pending) {
      if (failed === null) bytes.discard(JSON.parse(head).body_ref);
      return;
    }
    fetches.delete(id);
    if (failed === null) pending.resolve(JSON.parse(head));
    else pending.reject(failed);
  };
})();
