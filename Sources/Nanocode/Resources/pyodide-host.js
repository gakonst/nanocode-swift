(() => {
  const scheme = location.protocol;
  const index = NanocodePython.pyodideUrl.replace("https:", scheme);
  const native = window.fetch.bind(window);
  const proxied = (url) => /^https:\/\/(pypi\.org|files\.pythonhosted\.org)\//.test(url) ? "/__proxy__/" + url.slice("https://".length) : url;
  let wheels = null;
  window.fetch = (input, init) => {
    const requested = input instanceof Request ? input.url : String(input);
    const url = proxied(requested);
    if (wheels && new URL(url, location.href).pathname.endsWith(".whl")) wheels.push(requested);
    if (input instanceof Request) return native(url === input.url ? input : new Request(url, input), init);
    return native(url, init);
  };

  const errors = { ENOENT: 44, EEXIST: 20, ENOTDIR: 54, EISDIR: 31, ENOTEMPTY: 55, EACCES: 2, EPERM: 63, EINVAL: 28, EXDEV: 75, ENOSPC: 51, ELOOP: 32, EBUSY: 10, EROFS: 69, EFBIG: 22, ENAMETOOLONG: 37, EIO: 29 };
  const BLOCK = 1 << 20;
  const PENDING = 4 << 20;
  const decoder = new TextDecoder();
  let FS;
  const stats = new Map();
  const dirty = new Set();

  const bytes = (xhr) => {
    const text = xhr.responseText;
    const out = new Uint8Array(text.length);
    for (let index = 0; index < text.length; index++) out[index] = text.charCodeAt(index) & 255;
    return out;
  };

  const host = (op, params, body) => {
    const xhr = new XMLHttpRequest();
    const query = Object.entries(params).map(([key, value]) => key + "=" + encodeURIComponent(value)).join("&");
    xhr.open(body ? "POST" : "GET", "/__fs__/" + op + "?" + query, false);
    xhr.overrideMimeType("text/plain; charset=x-user-defined");
    xhr.send(body ?? null);
    const failed = xhr.getResponseHeader("X-Nanocode-Error");
    if (failed) throw new FS.ErrnoError(errors[failed] ?? 29);
    return xhr;
  };

  const json = (xhr) => JSON.parse(decoder.decode(bytes(xhr)));
  const join = (base, name) => (base === "/" ? "" : base) + "/" + name;

  const changed = () => stats.clear();

  const flushAll = () => {
    for (const stream of [...dirty]) flush(stream);
  };

  const flush = (stream) => {
    const pending = stream.pending;
    if (!pending) return;
    stream.pending = null;
    dirty.delete(stream);
    const data = new Uint8Array(pending.length);
    let at = 0;
    for (const chunk of pending.chunks) {
      data.set(chunk, at);
      at += chunk.length;
    }
    host("write", { p: HOSTFS.realPath(stream.node), o: pending.position }, data);
    stream.node.blocks = null;
    changed();
  };

  const stat = (path) => {
    flushAll();
    let info = stats.get(path);
    if (!info) {
      info = json(host("stat", { p: path }));
      stats.set(path, info);
    }
    return info;
  };

  const op = (kind, params) => {
    flushAll();
    changed();
    return host("op", { k: kind, ...params });
  };

  const HOSTFS = {
    mount(mount) {
      return HOSTFS.createNode(null, "/", json(host("stat", { p: mount.opts.root, f: 1 })).mode);
    },
    createNode(parent, name, mode) {
      const node = FS.createNode(parent, name, mode);
      node.node_ops = HOSTFS.node_ops;
      node.stream_ops = HOSTFS.stream_ops;
      return node;
    },
    realPath(node) {
      const parts = [];
      while (node.parent !== node) {
        parts.push(node.name);
        node = node.parent;
      }
      let path = node.mount.opts.root;
      for (let index = parts.length - 1; index >= 0; index--) path = join(path, parts[index]);
      return path;
    },
    attr(node, info) {
      return {
        dev: 1, ino: node.id, mode: info.mode, nlink: info.nlink ?? 1, uid: 0, gid: 0, rdev: 0, size: info.size,
        atime: new Date(info.atime), mtime: new Date(info.mtime), ctime: new Date(info.ctime), blksize: 4096,
        blocks: Math.ceil(info.size / 4096),
      };
    },
    node_ops: {
      getattr(node) {
        return HOSTFS.attr(node, stat(HOSTFS.realPath(node)));
      },
      setattr(node, attr) {
        const path = HOSTFS.realPath(node);
        if (attr.mode !== undefined) {
          op("chmod", { p: path, m: attr.mode & 4095 });
          node.mode = (node.mode & ~4095) | (attr.mode & 4095);
        }
        if (typeof (attr.atime ?? attr.mtime) === "number") {
          const info = stat(path);
          op("utime", { p: path, a: attr.atime ?? info.atime, m: attr.mtime ?? info.mtime });
        }
        if (attr.size !== undefined) {
          op("truncate", { p: path, n: attr.size });
          node.blocks = null;
        }
      },
      lookup(parent, name) {
        return HOSTFS.createNode(parent, name, stat(join(HOSTFS.realPath(parent), name)).mode);
      },
      mknod(parent, name, mode) {
        const node = HOSTFS.createNode(parent, name, mode);
        op(FS.isDir(mode) ? "mkdir" : "create", { p: HOSTFS.realPath(node), m: mode & 4095 });
        return node;
      },
      rename(node, directory, name) {
        op("rename", { p: HOSTFS.realPath(node), q: join(HOSTFS.realPath(directory), name) });
        node.name = name;
      },
      unlink(parent, name) {
        op("unlink", { p: join(HOSTFS.realPath(parent), name) });
      },
      rmdir(parent, name) {
        op("rmdir", { p: join(HOSTFS.realPath(parent), name) });
      },
      readdir(node) {
        flushAll();
        const path = HOSTFS.realPath(node);
        const entries = json(host("list", { p: path }));
        for (const [name, info] of entries) stats.set(join(path, name), info);
        return [".", "..", ...entries.map(([name]) => name)];
      },
      symlink(parent, name, target) {
        op("symlink", { p: join(HOSTFS.realPath(parent), name), q: target });
      },
      readlink(node) {
        return json(op("readlink", { p: HOSTFS.realPath(node) })).target;
      },
    },
    stream_ops: {
      open(stream) {
        stream.pending = null;
      },
      close(stream) {
        flush(stream);
      },
      dup() {},
      fsync(stream) {
        flush(stream);
      },
      read(stream, buffer, offset, length, position) {
        flushAll();
        const node = stream.node;
        const size = stat(HOSTFS.realPath(node)).size;
        const end = Math.min(size, position + length);
        let at = position;
        node.blocks ??= new Map();
        while (at < end) {
          const block = Math.floor(at / BLOCK);
          let data = node.blocks.get(block);
          if (!data) {
            data = bytes(host("read", { p: HOSTFS.realPath(node), o: block * BLOCK, n: BLOCK }));
            node.blocks.set(block, data);
          }
          const start = at - block * BLOCK;
          const count = Math.min(data.length - start, end - at);
          if (count <= 0) break;
          buffer.set(data.subarray(start, start + count), offset + (at - position));
          at += count;
        }
        return at - position;
      },
      write(stream, buffer, offset, length, position) {
        const chunk = new Uint8Array(buffer.buffer, buffer.byteOffset + offset, length).slice();
        const pending = stream.pending;
        if (pending && pending.position + pending.length === position && pending.length + length <= PENDING) {
          pending.chunks.push(chunk);
          pending.length += length;
        } else {
          flush(stream);
          stream.pending = { position, chunks: [chunk], length };
          dirty.add(stream);
        }
        stream.node.blocks = null;
        return length;
      },
      llseek(stream, offset, whence) {
        let position = offset;
        if (whence === 1) position += stream.position;
        else if (whence === 2 && FS.isFile(stream.node.mode)) position += stat(HOSTFS.realPath(stream.node)).size;
        if (position < 0) throw new FS.ErrnoError(28);
        return position;
      },
      mmap() {
        throw new FS.ErrnoError(43);
      },
    },
  };

  const mount = (root, point) => {
    try {
      FS.unmount(point);
    } catch {}
    FS.mkdirTree(point);
    FS.mount(HOSTFS, { root }, point);
  };

  const canonical = (name) => name.toLowerCase().replace(/[-_.]+/g, "-");
  const wheelName = (url) => canonical(decodeURIComponent(url.slice(url.lastIndexOf("/") + 1)).split("-")[0]);

  const installs = async () => {
    const response = await native("/__nanocode__/pip");
    if (!response.ok) throw new Error("could not read the installed wheels: " + response.status);
    return response.json();
  };

  const remember = async (list) => {
    const response = await native("/__nanocode__/pip", { method: "POST", body: JSON.stringify(list) });
    if (!response.ok) throw new Error("could not save the installed wheels: " + response.status);
  };

  const reinstall = async (pyodide, python, installed) => {
    const failures = [];
    const strict = { messageCallback: () => {}, errorCallback: (message) => failures.push(message) };
    const shipped = installed.filter((wheel) => proxied(wheel.url) === wheel.url).map((wheel) => wheel.name);
    const fetched = installed.filter((wheel) => proxied(wheel.url) !== wheel.url).map((wheel) => wheel.url);
    if (shipped.length) await pyodide.loadPackage(shipped, strict);
    if (fetched.length) {
      await pyodide.loadPackage("micropip", strict);
      python.micropip = true;
      if (!failures.length) await pyodide.pyimport("micropip").install.callKwargs(pyodide.toPy(fetched), { deps: false });
    }
    if (failures.length) throw new Error("could not reinstall the wheels pip installed: " + failures.join("; "));
  };

  const quietly = { messageCallback: () => {}, errorCallback: () => {} };
  let started;
  let queue = Promise.resolve();

  const boot = () => (started ??= (async () => {
    const module = await import(index + "pyodide.mjs");
    const pyodide = await module.loadPyodide({ indexURL: index });
    FS = pyodide.FS;
    const namespace = pyodide.globals.get("dict")();
    pyodide.runPython(NanocodePython.HELPER, { globals: namespace });
    const python = { pyodide, start: namespace.get("start"), cancel: namespace.get("cancel"), micropip: false };
    await reinstall(pyodide, python, await installs());
    return python;
  })());

  const text = (chunks) => {
    const out = new Uint8Array(chunks.reduce((total, chunk) => total + chunk.length, 0));
    let at = 0;
    for (const chunk of chunks) {
      out.set(chunk, at);
      at += chunk.length;
    }
    return decoder.decode(out);
  };

  let running = null;

  const cancelled = (id) => {
    const xhr = new XMLHttpRequest();
    xhr.open("GET", "/__nanocode__/cancelled?run=" + id, false);
    xhr.send(null);
    return xhr.responseText === "1";
  };

  window.nanocodeCancel = (id) => {
    if (running?.id === id) running.stop();
  };

  const parent = (path) => path.slice(0, Math.max(1, path.lastIndexOf("/")));

  const execute = async (request) => {
    const python = await boot();
    const { pyodide } = python;
    if (request.kind === "version") return { status: 0, stdout: "Python " + pyodide.runPython("import sys; sys.version.split()[0]") + "\n", stderr: "" };
    changed();
    for (const [root, point] of request.mounts) mount(root, point);
    const out = [];
    const err = [];
    const note = (message) => err.push(new TextEncoder().encode(message));
    let target = request.target;
    if (request.kind === "file") {
      try {
        target = FS.readFile(request.filename, { encoding: "utf8" });
      } catch (error) {
        if (error?.errno !== 44) throw error;
        return { status: 2, stdout: "", stderr: request.name + ": can't open file '" + request.filename + "': [Errno 2] No such file or directory\n" };
      }
    }
    const messages = { messageCallback: () => {}, errorCallback: (message) => note(message + "\n") };
    try {
      if (request.kind === "pip" && !python.micropip) {
        await pyodide.loadPackage("micropip", messages);
        python.micropip = true;
      }
      if (request.kind === "module") await pyodide.loadPackagesFromImports("import " + target, messages);
      else if (request.kind !== "pip") await pyodide.loadPackagesFromImports(target, messages);
    } catch (error) {
      note(request.name + ": " + (error?.message ?? String(error)) + "\n");
    }
    const input = new TextEncoder().encode(request.kind === "stdin" ? "" : request.stdin);
    let offset = 0;
    const sink = (chunks) => ({ isatty: false, write: (buffer) => (chunks.push(buffer.slice()), buffer.length) });
    pyodide.setStdin({
      isatty: false,
      read(buffer) {
        const count = Math.min(buffer.length, input.length - offset);
        buffer.set(input.subarray(offset, offset + count));
        offset += count;
        return count;
      },
    });
    pyodide.setStdout(sink(out));
    pyodide.setStderr(sink(err));
    const deadline = Date.now() + Math.max(1000, request.timeoutMs || 30000);
    let quiet = false;
    let stopped = false;
    let polled = 0;
    let signalled = 0;
    const interrupted = () => {
      if (quiet) return false;
      const now = Date.now();
      if (!stopped && now - polled > 250) {
        polled = now;
        stopped = cancelled(request.id);
      }
      if (!(stopped || now > deadline) || now - signalled < 50) return false;
      signalled = now;
      return true;
    };
    pyodide.setInterruptBuffer({ get 0() { return interrupted() ? 2 : 0; }, set 0(_value) {} });
    const stop = () => {
      quiet = true;
      try {
        python.cancel();
      } catch {}
      quiet = false;
    };
    const timer = setTimeout(stop, Math.max(0, deadline - Date.now()));
    running = { id: request.id, stop: () => { stopped = true; stop(); } };
    const env = { ...request.env, PWD: request.cwd, HOME: request.home, MPLBACKEND: "Agg", PYTHONDONTWRITEBYTECODE: "1" };
    const path0 = request.kind === "file" ? parent(request.filename) : request.kind === "module" ? request.cwd : "";
    let status;
    const fetched = wheels = request.kind === "pip" ? [] : null;
    try {
      status = Number(await python.start(JSON.stringify({ kind: request.kind, target, argv: request.argv, filename: request.filename, cwd: request.cwd, env, path0 })));
    } finally {
      running = null;
      wheels = null;
      clearTimeout(timer);
      pyodide.setInterruptBuffer(undefined);
      flushAll();
    }
    if (request.kind === "pip" && status === 0 && (request.argv[0] === "install" || request.argv[0] === "uninstall")) {
      const added = fetched.map((url) => ({ name: wheelName(url), url }));
      const removed = new Set([...added.map((wheel) => wheel.name), ...(request.argv[0] === "uninstall" ? request.argv.slice(1).filter((arg) => !arg.startsWith("-")).map(canonical) : [])]);
      await remember([...(await installs()).filter((wheel) => !removed.has(wheel.name)), ...added]);
    }
    return { status, stdout: text(out), stderr: text(err) };
  };

  const described = (error) => error?.name === "ErrnoError" ? "file system error " + (Object.keys(errors).find((name) => errors[name] === error.errno) ?? error.errno) : error?.message ?? String(error);

  window.nanocodePython = (request) => {
    const parsed = JSON.parse(request);
    const next = queue
      .then(() => execute(parsed))
      .catch((error) => ({ status: 1, stdout: "", stderr: parsed.name + ": " + described(error) + "\n" }))
      .then((reply) => JSON.stringify(reply));
    queue = next.catch(() => {});
    return next;
  };

  window.nanocodePreload = async (packages) => {
    const python = await boot();
    await python.pyodide.loadPackage(packages, quietly);
    const modules = packages.filter((name) => name !== "micropip").map((name) => name === "matplotlib" ? "matplotlib.pyplot" : name);
    await python.pyodide.runPythonAsync("import os\nos.environ['MPLBACKEND'] = 'Agg'\n" + modules.map((name) => "import " + name).join("\n")).catch(() => {});
    return String(python.pyodide.runPython("import sys; sys.version.split()[0]"));
  };
})();
