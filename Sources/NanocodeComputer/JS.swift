#if os(macOS)
import Foundation
import JavaScriptCore

final class JSRuntime {
    static let shared = JSRuntime()

    private var ctx: JSContext!
    private var output: [JSON] = []
    private var images: [Int: Data] = [:]
    private var nextImage = 1
    private var timers: [(id: Int, due: Date, fn: JSValue)] = []
    private var nextTimer = 1
    private var settled = false
    private var failure: String?

    private init() { reset() }

    func reset() {
        ctx = JSContext()
        ctx.name = ComputerHost.current.server
        timers = []
        images = [:]

        let call: @convention(block) (String, String) -> String = { [unowned self] name, argsJSON in
            self.native(name, argsJSON)
        }
        let emitText: @convention(block) (String) -> Void = { [unowned self] s in
            self.output.append(["type": "text", "text": s])
        }
        let emitImage: @convention(block) (Int) -> Void = { [unowned self] id in
            if let png = self.images[id] {
                self.output.append(["type": "image", "data": png.base64EncodedString(), "mimeType": imageMime])
            }
        }
        let setTimer: @convention(block) (JSValue, Double) -> Int = { [unowned self] fn, ms in
            let id = self.nextTimer
            self.nextTimer += 1
            self.timers.append((id, Date().addingTimeInterval(max(0, ms) / 1000), fn))
            return id
        }
        let clearTimer: @convention(block) (Int) -> Void = { [unowned self] id in
            self.timers.removeAll { $0.id == id }
        }
        let done: @convention(block) (JSValue) -> Void = { [unowned self] _ in self.settled = true }
        let fail: @convention(block) (String) -> Void = { [unowned self] msg in
            self.settled = true
            self.failure = msg
        }
        for (name, fn) in [("__call", call as Any), ("__emitText", emitText), ("__emitImage", emitImage),
                           ("__setTimer", setTimer), ("__clearTimer", clearTimer), ("__done", done), ("__fail", fail)] {
            ctx.setObject(fn, forKeyedSubscript: name as NSString)
        }
        ctx.evaluateScript(JSRuntime.prelude)
        if let e = ctx.exception { FileHandle.standardError.write(Data("computer use prelude error: \(e)\n".utf8)) }
    }

    private func native(_ name: String, _ argsJSON: String) -> String {
        var out: JSON
        do {
            let args = (try JSONSerialization.jsonObject(with: Data(argsJSON.utf8))) as? JSON ?? [:]
            switch name {
            case "resolve_app":
                guard let q = argString(args, "app") else { throw CUAError("app is required") }
                try Tools.requireTrust()
                let app = try Apps.resolve(q)
                try Policy.check(app)
                out = ["ok": true, "name": app.localizedName ?? q, "bundleId": app.bundleIdentifier ?? "",
                       "pid": Int(app.processIdentifier), "path": app.bundleURL?.path ?? ""]
            case "display_screenshot":
                let shot = try Screenshot.captureDisplay()
                out = ["ok": true, "text": "Main display, \(shot.width)x\(shot.height) points.", "image": store(shot.png)]
            default:
                let r = try Tools.call(name, args)
                out = ["ok": true, "text": r.text]
                if let png = r.png { out["image"] = store(png) }
            }
        } catch {
            out = ["ok": false, "error": "\(error)"]
        }
        let d = (try? JSONSerialization.data(withJSONObject: out)) ?? Data("{\"ok\":false,\"error\":\"encoding\"}".utf8)
        return String(data: d, encoding: .utf8)!
    }

    private func store(_ png: Data) -> Int {
        let id = nextImage
        nextImage += 1
        images[id] = png
        if images.count > 16, let oldest = images.keys.min() { images[oldest] = nil }
        return id
    }

    func run(_ code: String, timeoutMs: Int) -> (content: [JSON], isError: Bool) {
        output = []
        settled = false
        failure = nil
        ctx.exception = nil
        ctx.objectForKeyedSubscript("__run").call(withArguments: [code])
        if let e = ctx.exception {
            settled = true
            failure = e.toString()
            ctx.exception = nil
        }
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000)
        while !settled {
            timers.sort { $0.due < $1.due }
            guard let next = timers.first else {
                failure = "The cell's promise never settled: it awaits something that nothing will resolve."
                break
            }
            if next.due > deadline {
                failure = "Timed out after \(timeoutMs) ms."
                break
            }
            let wait = next.due.timeIntervalSinceNow
            if wait > 0 { usleep(useconds_t(wait * 1_000_000)) }
            timers.removeFirst()
            next.fn.call(withArguments: [])
            if let e = ctx.exception {
                output.append(["type": "text", "text": "Uncaught exception in timer: \(e)"])
                ctx.exception = nil
            }
        }
        if let failure { output.append(["type": "text", "text": "Error: \(failure)"]) }
        var merged: [JSON] = []
        for item in output {
            if item["type"] as? String == "text", let last = merged.last, last["type"] as? String == "text" {
                merged[merged.count - 1]["text"] = (last["text"] as! String) + "\n" + (item["text"] as! String)
            } else {
                merged.append(item)
            }
        }
        if merged.isEmpty { merged = [["type": "text", "text": "(no output)"]] }
        return (merged, failure != nil)
    }

    static let prelude = #"""
    (() => {
      const fmt = (v) => {
        if (typeof v === 'string') return v;
        if (v === undefined) return 'undefined';
        if (v instanceof Error) return v.stack ? v.message + '\n' + v.stack : String(v);
        try { const s = JSON.stringify(v, null, 2); return s === undefined ? String(v) : s; } catch { return String(v); }
      };
      const log = (...a) => __emitText(a.map(fmt).join(' '));
      globalThis.console = { log, info: log, warn: log, error: log, debug: log };
      globalThis.setTimeout = (fn, ms, ...args) => __setTimer(() => fn(...args), Number(ms) || 0);
      globalThis.clearTimeout = (id) => __clearTimer(id);
      globalThis.sleep = (ms) => new Promise((r) => setTimeout(r, ms));
      const call = (name, args) => {
        const r = JSON.parse(__call(name, JSON.stringify(args ?? {})));
        if (!r.ok) throw new Error(r.error);
        return r;
      };
      const show = (r, image) => {
        if (r.text) __emitText(r.text);
        if (image && r.image) __emitImage(r.image);
      };
      const target = (t) => (typeof t === 'number' ? { element_index: t } : { ...t });

      class App {
        constructor(info) { Object.assign(this, info); Object.freeze(this); }
        get key() { return this.path || this.bundleId || this.name; }
        _do(tool, args, image = false) { const r = call(tool, { app: this.key, ...args }); show(r, image); }
        async getState(opts = {}) {
          const r = call('get_app_state', { app: this.key, disableDiff: !!opts.full });
          show(r, opts.screenshot !== false);
        }
        async click(t, opts = {}) {
          const a = target(t);
          this._do('click', { ...a, mouse_button: opts.button ?? a.button, click_count: opts.count ?? a.count }, !!opts.screenshot);
        }
        async doubleClick(t, opts = {}) { return this.click(t, { ...opts, count: 2 }); }
        async rightClick(t, opts = {}) { return this.click(t, { ...opts, button: 'right' }); }
        async drag(from, to, opts = {}) {
          this._do('drag', { from_x: from.x, from_y: from.y, to_x: to.x, to_y: to.y }, !!opts.screenshot);
        }
        async scroll(index, direction = 'down', pages = 1) { this._do('scroll', { element_index: index, direction, pages }); }
        async type(text) { this._do('type_text', { text: String(text) }); }
        async press(key) { this._do('press_key', { key: String(key) }); }
        async setValue(index, value) { this._do('set_value', { element_index: index, value: String(value) }); }
        async selectText(index, text, opts = {}) {
          this._do('select_text', { element_index: index, text, prefix: opts.prefix, suffix: opts.suffix, selection_type: opts.mode });
        }
        async action(index, name) { this._do('perform_secondary_action', { element_index: index, action: name }); }
      }

      const cua = {
        async getState() { show(call('list_apps', {})); },
        async getApp(name, opts = {}) {
          const info = call('resolve_app', { app: String(name) });
          const app = new App({ name: info.name, bundleId: info.bundleId, pid: info.pid, path: info.path });
          if (opts.state !== false) await app.getState();
          return app;
        },
        async getScreenshot() { show(call('display_screenshot', {}), true); },
      };
      globalThis.cua = Object.freeze(cua);
      globalThis.display = (v) => __emitText(fmt(v));

      const AsyncFunction = (async () => {}).constructor;
      const stmt = /^\s*(let|const|var|if|for|while|do|switch|try|return|throw|function|class|import|export|break|continue)\b|^\s*(\{|\/\/|\/\*)/;
      const compile = (code) => {
        try { return new AsyncFunction('return (\n' + code + '\n)'); } catch {}
        const body = code.replace(/[\s;]+$/, '');
        for (let i = body.length - 1, tries = 0; i > 0 && tries < 40; i--) {
          if (body[i] !== ';' && body[i] !== '\n') continue;
          tries++;
          const tail = body.slice(i + 1);
          if (!tail.trim() || stmt.test(tail)) continue;
          try { return new AsyncFunction(body.slice(0, i + 1) + '\nreturn (\n' + tail + '\n)'); } catch {}
        }
        return new AsyncFunction(code);
      };
      globalThis.__run = (code) => {
        const fn = compile(code);
        fn().then((v) => { if (v !== undefined) __emitText(fmt(v)); __done(v); },
                  (e) => __fail(e instanceof Error ? (e.message || String(e)) : fmt(e)));
      };
    })();
    """#

    static var description: String { """
    Run JavaScript in a persistent \(ComputerHost.current.name) computer-use REPL to read and operate macOS apps in the background, \
    through their accessibility tree with window screenshots as a fallback.

    The cell body runs as an async function: use await, and return or end with an expression to print its value. \
    Local variables do not survive between calls; keep handles on globalThis (globalThis.notes = await cua.getApp("Notes")). \
    console.log prints. sleep(ms) waits.

    Start with one call:
      await cua.getState()                       // running and installed apps
      globalThis.app = await cua.getApp("Notes") // name, bundle id or .app path; launches in the background; prints its state
      await cua.getScreenshot()                  // whole main display, read-only

    App state is one element per line: [index] Role "title" desc=... value=... {focused,selected,disabled} actions=... \
    followed by a screenshot of the app's window. Indexes belong to the latest state of that app. Every action prints \
    what changed (lines not shown kept their index), so you rarely need to fetch the state again.

      await app.getState({ full: true })         // full tree instead of a diff; { screenshot: false } skips the image
      await app.click(12)                        // element index: presses it through accessibility when possible
      await app.click({ x: 120, y: 48 })         // pixels in the app's latest screenshot
      await app.click(12, { button: "right", count: 2, screenshot: true })
      await app.doubleClick(12); await app.rightClick(12)
      await app.drag({ x: 10, y: 10 }, { x: 200, y: 10 })
      await app.type("hello\\n")                 // types into the focused element; \\n is Shift+Return, a line break that never sends
      await app.press("Return")                  // submits; also a plain newline where Shift+Return runs or soft-breaks
      await app.press("cmd+shift+z")             // Return, Escape, Tab, Up, Page_Down, cmd+a, ...
      await app.setValue(7, "text")              // text fields, checkboxes, sliders, combo boxes
      await app.selectText(7, "word", { prefix: "a ", suffix: " b", mode: "text" | "cursor_before" | "cursor_after" })
      await app.scroll(3, "down", 2)             // up, down, left, right; pages
      await app.action(5, "ShowMenu")            // any action listed on the element

    Prefer element indexes, setValue and actions over coordinates and typing. The user keeps working while you act: \
    It does not activate apps or move the user's cursor. Terminals, password managers and system authentication \
    dialogs are blocked.
    """ }

    static let resetDescription = "Discard the REPL's JavaScript state (globals and handles). Apps, windows and their contents are not changed."
}
#endif
