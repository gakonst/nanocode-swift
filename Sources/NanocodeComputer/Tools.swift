#if os(macOS)
import AppKit
import ApplicationServices

struct ToolResult {
    var text: String
    var png: Data?
}

enum Tools {
    static var instructions: String { """
    \(ComputerHost.current.name) operates macOS apps through their accessibility (AX) tree, with window screenshots as a fallback.
    - Call get_app_state(app) before acting. It returns the app's AX tree, one element per line as [index] Role "title" ..., and a screenshot of its window.
    - Element indexes belong to the latest state of that app and change when the UI changes; every action returns the updated state.
    - Prefer element_index. Use x/y (pixels in the latest screenshot of that app's window) only when no element fits.
    - Prefer set_value for text fields and perform_secondary_action for menus and steppers; use type_text and press_key for apps that need real typing.
    - Apps are operated in the background where possible; some apps ignore background mouse input, in which case element actions or keyboard input usually still work.
    - Terminals, password managers and system authentication dialogs are blocked.
    """ }

    static func schema(_ props: JSON, _ required: [String]) -> JSON {
        ["type": "object", "properties": props, "required": required, "additionalProperties": false]
    }
    static let appProp: JSON = ["type": "string", "description": "App display name, bundle identifier or .app path."]
    static let indexProp: JSON = ["type": "integer", "description": "Element index from the latest get_app_state of this app."]

    static var schemas: [JSON] {
        [
            ["name": "list_apps", "description": "List running and installed apps.", "inputSchema": schema([:], [])],
            ["name": "get_app_state", "description": "Get an app's accessibility tree and a screenshot of its window, launching it in the background if needed. By default the tree is diffed against the previous state of the app.",
             "inputSchema": schema(["app": appProp, "disableDiff": ["type": "boolean", "description": "Return the full tree instead of a diff."]], ["app"])],
            ["name": "click", "description": "Click an element (preferred) or a point in the latest screenshot.",
             "inputSchema": schema([
                "app": appProp, "element_index": indexProp,
                "x": ["type": "number", "description": "X in screenshot pixels."], "y": ["type": "number", "description": "Y in screenshot pixels."],
                "mouse_button": ["type": "string", "enum": ["left", "right", "middle", "l", "r", "m"]],
                "click_count": ["type": "integer", "description": "2 for double click."],
             ], ["app"])],
            ["name": "drag", "description": "Drag between two points in the latest screenshot.",
             "inputSchema": schema(["app": appProp, "from_x": ["type": "number"], "from_y": ["type": "number"], "to_x": ["type": "number"], "to_y": ["type": "number"]], ["app", "from_x", "from_y", "to_x", "to_y"])],
            ["name": "perform_secondary_action", "description": "Perform a named accessibility action listed for the element, such as ShowMenu, Increment, Decrement, Raise, Confirm or Cancel.",
             "inputSchema": schema(["app": appProp, "element_index": indexProp, "action": ["type": "string"]], ["app", "element_index", "action"])],
            ["name": "press_key", "description": "Press a key or chord, such as Return, Escape, Tab, Down, cmd+a, cmd+shift+z, ctrl+Page_Down, in the app's focused element. Refused when the focused window or element changed since get_app_state.",
             "inputSchema": schema(["app": appProp, "key": ["type": "string"]], ["app", "key"])],
            ["name": "scroll", "description": "Scroll an element by pages.",
             "inputSchema": schema(["app": appProp, "element_index": indexProp,
                                    "direction": ["type": "string", "enum": ["up", "down", "left", "right", "u", "d", "l", "r"]],
                                    "pages": ["type": "number", "description": "Pages to scroll, default 1."]], ["app", "element_index", "direction"])],
            ["name": "select_text", "description": "Select text inside a text element, or place the cursor before or after it. Use prefix/suffix to disambiguate repeated text.",
             "inputSchema": schema(["app": appProp, "element_index": indexProp, "text": ["type": "string"],
                                    "prefix": ["type": "string"], "suffix": ["type": "string"],
                                    "selection_type": ["type": "string", "enum": ["text", "cursor_before", "cursor_after"]]], ["app", "element_index", "text"])],
            ["name": "set_value", "description": "Set the value of an element such as a text field, checkbox, slider or popup.",
             "inputSchema": schema(["app": appProp, "element_index": indexProp, "value": ["type": "string"]], ["app", "element_index", "value"])],
            ["name": "type_text", "description": "Type text into the app's focused element. Newlines are typed as Shift+Return, a line break that doesn't send a chat message; use press_key Return to submit. Refused when the focused window or element changed since get_app_state. Where Shift+Return means something else (it runs a notebook cell, or is a soft break in a word processor), type each line separately and press_key Return between them.",
             "inputSchema": schema(["app": appProp, "text": ["type": "string"]], ["app", "text"])],
        ]
    }

    static var settleMs: Int { Int(setting("SETTLE_MS") ?? "") ?? 500 }

    static func requireTrust() throws {
        guard AXIsProcessTrusted() else {
            let app = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "This app"
            throw CUAError("\(app) does not have Accessibility permission, so nothing ran. The user can turn on \(app) in System Settings > Privacy & Security > Accessibility.")
        }
    }

    static func target(_ a: JSON, reading: Bool = false) throws -> NSRunningApplication {
        guard let q = argString(a, "app") else { throw CUAError("app is required") }
        try requireTrust()
        let app = try Apps.resolve(q)
        try Policy.check(app)
        let s = Sessions.get(app.processIdentifier)
        let scope = argString(a, "_scope")
        if scope != s.scope {
            s.scope = scope
            s.lastText = nil
        }
        if !reading {
            let now = Focus.of(app.processIdentifier)
            s.focus.begin((now.window, now.element))
        }
        return app
    }

    static func element(_ app: NSRunningApplication, _ a: JSON) throws -> AXUIElement {
        guard let idx = argInt(a, "element_index") else { throw CUAError("element_index is required") }
        let s = Sessions.get(app.processIdentifier)
        if s.elements.isEmpty { throw CUAError("No state for \(app.localizedName ?? "app"). Call get_app_state first.") }
        guard idx >= 0 && idx < s.elements.count else {
            throw CUAError("element_index \(idx) is out of range (0..<\(s.elements.count)). Call get_app_state for fresh indexes.")
        }
        return s.elements[idx]
    }

    static func screenPoint(_ app: NSRunningApplication, x: Double, y: Double) throws -> CGPoint {
        guard let f = Sessions.get(app.processIdentifier).windowFrame else {
            throw CUAError("No screenshot for this app yet. Call get_app_state first.")
        }
        return CGPoint(x: f.minX + x, y: f.minY + y)
    }

    static func point(at el: AXUIElement, _ app: NSRunningApplication) {
        if let f = axFrame(el), f.width > 0 || f.height > 0 {
            AgentCursor.glide(to: CGPoint(x: f.midX, y: f.midY), pid: app.processIdentifier)
        }
        recheck(app)
    }

    static func recheck(_ app: NSRunningApplication) {
        let now = Focus.of(app.processIdentifier)
        Sessions.get(app.processIdentifier).focus.begin((now.window, now.element))
    }

    static func pointAtFocus(_ app: NSRunningApplication) {
        let appEl = AXUIElementCreateApplication(app.processIdentifier)
        if let focused = axElement(appEl, kAXFocusedUIElementAttribute) { point(at: focused, app) }
    }

    static func center(_ el: AXUIElement) throws -> CGPoint {
        guard let f = axFrame(el), f.width > 0 || f.height > 0 else { throw CUAError("element has no on-screen frame; use x/y instead") }
        return CGPoint(x: f.midX, y: f.midY)
    }

    static func state(_ app: NSRunningApplication, diff: Bool, note: String? = nil, fresh: Bool = false, on el: AXUIElement? = nil) -> ToolResult {
        let s = Sessions.get(app.processIdentifier)
        let now = Focus.of(app.processIdentifier)
        s.focus.record((now.window, now.element), fresh: fresh, ours: { focused in el.map { contains($0, focused) } ?? false })
        let snap = AXTree.snapshot(app)
        s.elements = snap.elements
        var text = note.map { $0 + "\n" } ?? ""
        text += (diff ? s.lastText : nil).map { Diff.render(old: $0, new: snap.text) } ?? snap.text
        s.lastText = snap.text
        var png: Data?
        do {
            let shot = try Screenshot.capture(pid: app.processIdentifier, near: snap.windowFrame)
            s.windowFrame = shot.frame
            s.windowID = shot.windowID
            png = shot.png
            text += "\nScreenshot: \(Int(shot.frame.width))x\(Int(shot.frame.height)) window pixels, file://\(shot.path)"
        } catch {
            s.windowFrame = snap.windowFrame
            s.windowID = nil
            text += "\n" + ScreenshotFailure.message(error, app: ScreenshotFailure.windows(of: app), preflight: CGPreflightScreenCaptureAccess)
        }
        return ToolResult(text: text, png: png)
    }

    static func after(_ app: NSRunningApplication, _ note: String, on el: AXUIElement? = nil) -> ToolResult {
        let now = Focus.of(app.processIdentifier)
        Sessions.get(app.processIdentifier).focus.acted((now.window, now.element))
        sleepMs(settleMs)
        return state(app, diff: true, note: note, on: el)
    }

    static func aim(_ s: AppSession) {
        if let id = s.windowID, let f = s.windowFrame { Input.window = (id, f) } else { Input.window = nil }
    }

    static func contains(_ el: AXUIElement, _ inner: AXUIElement) -> Bool {
        var node: AXUIElement? = inner
        for _ in 0..<6 {
            guard let n = node else { return false }
            if CFEqual(n, el) { return true }
            node = axElement(n, kAXParentAttribute)
        }
        return false
    }

    static func requireSameFocus(_ app: NSRunningApplication) throws {
        let now = Focus.of(app.processIdentifier)
        guard let what = Sessions.get(app.processIdentifier).focus.refusal((now.window, now.element)) else { return }
        let name = app.localizedName ?? "the app"
        if what == "unknown" {
            throw CUAError("No state for \(name), so nothing was sent: call get_app_state first to see where keys would land.")
        }
        let moved = what == "focus" ? "window or element" : what
        throw CUAError("\(name)'s focused \(moved) changed since get_app_state (someone may have switched windows or clicked elsewhere), so nothing was sent. Call get_app_state to see where keys would land now.")
    }

    static func ok(_ e: AXError) -> Bool { e == .success || e == .cannotComplete }

    static func call(_ name: String, _ a: JSON) throws -> ToolResult {
        switch name {
        case "list_apps":
            return ToolResult(text: Apps.list())

        case "get_app_state":
            let app = try target(a, reading: true)
            return state(app, diff: !argBool(a, "disableDiff"), fresh: true)

        case "click":
            let app = try target(a)
            let pid = app.processIdentifier
            let button: Int = switch (argString(a, "mouse_button") ?? "left").lowercased() {
                case "right", "r": 1
                case "middle", "m": 2
                default: 0
            }
            let count = max(1, argInt(a, "click_count") ?? 1)
            let s = Sessions.get(pid)
            if a["element_index"] != nil {
                let el = try element(app, a)
                point(at: el, app)
                let actions = axActions(el)
                if button == 0 && count == 1 && actions.contains(kAXPressAction) && ok(AXUIElementPerformAction(el, kAXPressAction as CFString)) {
                    AgentCursor.press()
                    return after(app, "Pressed element \(argInt(a, "element_index")!).", on: el)
                }
                if button == 1 && count == 1 && actions.contains(kAXShowMenuAction) && ok(AXUIElementPerformAction(el, kAXShowMenuAction as CFString)) {
                    AgentCursor.press()
                    return after(app, "Opened the context menu of element \(argInt(a, "element_index")!).", on: el)
                }
                AgentCursor.press()
                aim(s); Input.click(at: try center(el), pid: pid, button: button, count: count)
                return after(app, "Clicked element \(argInt(a, "element_index")!).", on: el)
            }
            guard let x = argDouble(a, "x"), let y = argDouble(a, "y") else { throw CUAError("click needs element_index or x and y") }
            let p = try screenPoint(app, x: x, y: y)
            AgentCursor.glide(to: p, pid: app.processIdentifier)
            recheck(app)
            AgentCursor.press()
            aim(s); Input.click(at: p, pid: pid, button: button, count: count)
            return after(app, "Clicked at (\(Int(x)), \(Int(y))).")

        case "drag":
            let app = try target(a)
            guard let fx = argDouble(a, "from_x"), let fy = argDouble(a, "from_y"),
                  let tx = argDouble(a, "to_x"), let ty = argDouble(a, "to_y") else { throw CUAError("drag needs from_x, from_y, to_x, to_y") }
            aim(Sessions.get(app.processIdentifier))
            let from = try screenPoint(app, x: fx, y: fy), to = try screenPoint(app, x: tx, y: ty)
            AgentCursor.glide(to: from, pid: app.processIdentifier)
            recheck(app)
            AgentCursor.press()
            AgentCursor.glide(to: to, pid: app.processIdentifier, wait: false)
            Input.drag(from: from, to: to, pid: app.processIdentifier)
            return after(app, "Dragged from (\(Int(fx)), \(Int(fy))) to (\(Int(tx)), \(Int(ty))).")

        case "perform_secondary_action":
            let app = try target(a)
            let el = try element(app, a)
            guard let raw = argString(a, "action"), !raw.isEmpty else { throw CUAError("action is required") }
            let available = axActions(el)
            let wanted = raw.hasPrefix("AX") ? raw : "AX" + raw
            guard let action = available.first(where: {
                $0.caseInsensitiveCompare(wanted) == .orderedSame || $0.caseInsensitiveCompare(raw) == .orderedSame
                    || shortName($0).caseInsensitiveCompare(raw) == .orderedSame
            }) else {
                throw CUAError("Element does not support \(raw). Available: \(available.map(shortName).joined(separator: ", "))")
            }
            point(at: el, app)
            let err = AXUIElementPerformAction(el, action as CFString)
            AgentCursor.press()
            guard ok(err) else { throw CUAError("\(shortName(action)) failed: AXError \(err.rawValue)") }
            return after(app, "Performed \(shortName(action)).", on: el)

        case "press_key":
            let app = try target(a)
            guard let key = argString(a, "key") else { throw CUAError("key is required") }
            aim(Sessions.get(app.processIdentifier))
            pointAtFocus(app)
            try requireSameFocus(app)
            try Input.pressKey(key, pid: app.processIdentifier)
            return after(app, "Pressed \(key).")

        case "type_text":
            let app = try target(a)
            guard let text = argString(a, "text") else { throw CUAError("text is required") }
            aim(Sessions.get(app.processIdentifier))
            pointAtFocus(app)
            try requireSameFocus(app)
            try Input.typeText(text, pid: app.processIdentifier)
            return after(app, "Typed \(text.count) characters.")

        case "scroll":
            let app = try target(a)
            let el = try element(app, a)
            point(at: el, app)
            let dir = (argString(a, "direction") ?? "").lowercased()
            let pages = argDouble(a, "pages") ?? 1
            guard let f = axFrame(el) else { throw CUAError("element has no frame") }
            let v = Int(f.height * 0.85 * pages), h = Int(f.width * 0.85 * pages)
            let (dx, dy): (Int, Int) = switch dir {
                case "up", "u": (0, v)
                case "down", "d": (0, -v)
                case "left", "l": (h, 0)
                case "right", "r": (-h, 0)
                default: (0, 0)
            }
            if dx == 0 && dy == 0 { throw CUAError("direction must be up, down, left or right") }
            let axAction = switch dir {
                case "up", "u": "AXScrollUpByPage"
                case "down", "d": "AXScrollDownByPage"
                case "left", "l": "AXScrollLeftByPage"
                default: "AXScrollRightByPage"
            }
            var node: AXUIElement? = el
            for _ in 0..<8 {
                guard let n = node else { break }
                if axActions(n).contains(axAction) {
                    let times = max(1, Int(pages.rounded()))
                    var okCount = 0
                    for _ in 0..<times where ok(AXUIElementPerformAction(n, axAction as CFString)) { okCount += 1 }
                    if okCount > 0 { return after(app, "Scrolled \(dir) \(okCount) page(s).") }
                }
                let vertical = dir.hasPrefix("u") || dir.hasPrefix("d")
                if let bar = axElement(n, vertical ? kAXVerticalScrollBarAttribute : kAXHorizontalScrollBarAttribute),
                   let current = axAttr(bar, kAXValueAttribute) as? NSNumber, let area = axFrame(n) {
                    var settable = DarwinBoolean(false)
                    AXUIElementIsAttributeSettable(bar, kAXValueAttribute as CFString, &settable)
                    let content = axElements(axAttr(n, kAXContentsAttribute)).compactMap(axFrame).first
                        ?? axElements(axAttr(n, kAXChildrenAttribute)).compactMap(axFrame).max { $0.height * $0.width < $1.height * $1.width }
                    let visible = vertical ? area.height : area.width
                    let total = content.map { vertical ? $0.height : $0.width } ?? 0
                    if settable.boolValue && total > visible {
                        let step = Double(visible * 0.9 / (total - visible)) * pages
                        let sign: Double = (dir.hasPrefix("u") || dir.hasPrefix("l")) ? -1 : 1
                        let target = min(1, max(0, current.doubleValue + sign * step))
                        if ok(AXUIElementSetAttributeValue(bar, kAXValueAttribute as CFString, NSNumber(value: target))) {
                            return after(app, "Scrolled \(dir) \(pages) page(s).")
                        }
                    }
                }
                if axText(axAttr(n, kAXRoleAttribute)) == "AXScrollArea" { break }
                node = axElement(n, kAXParentAttribute)
            }
            aim(Sessions.get(app.processIdentifier))
            Input.scroll(at: CGPoint(x: f.midX, y: f.midY), pid: app.processIdentifier, dx: dx, dy: dy)
            return after(app, "Scrolled \(dir) \(pages) page(s).")

        case "set_value":
            let app = try target(a)
            let el = try element(app, a)
            point(at: el, app)
            guard let value = argString(a, "value") else { throw CUAError("value is required") }
            var settable = DarwinBoolean(false)
            AXUIElementIsAttributeSettable(el, kAXValueAttribute as CFString, &settable)
            if settable.boolValue {
                let current = axAttr(el, kAXValueAttribute)
                let newValue: CFTypeRef
                if let current, CFGetTypeID(current) == CFNumberGetTypeID() || CFGetTypeID(current) == CFBooleanGetTypeID(), let d = Double(value) {
                    newValue = NSNumber(value: d)
                } else if let current, CFGetTypeID(current) == CFBooleanGetTypeID() || CFGetTypeID(current) == CFNumberGetTypeID() {
                    newValue = NSNumber(value: ["true", "yes", "on"].contains(value.lowercased()) ? 1 : 0)
                } else {
                    newValue = value as CFString
                }
                let err = AXUIElementSetAttributeValue(el, kAXValueAttribute as CFString, newValue)
                if ok(err) { return after(app, "Set value of element \(argInt(a, "element_index")!).", on: el) }
            }
            let appEl = AXUIElementCreateApplication(app.processIdentifier)
            let before = axElement(appEl, kAXFocusedUIElementAttribute)
            let focusing = AXUIElementSetAttributeValue(el, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            sleepMs(100)
            let focused = axElement(appEl, kAXFocusedUIElementAttribute)
            let landed = focused.map { f in
                CFEqual(f, el) || (contains(el, f) && !(before.map { CFEqual($0, f) } ?? false))
            } ?? false
            guard ok(focusing), landed else {
                throw CUAError("Element \(argInt(a, "element_index")!)'s value can't be set through accessibility and it didn't take focus, so nothing was typed. Click it first, then use type_text.")
            }
            aim(Sessions.get(app.processIdentifier))
            try Input.pressKey("cmd+a", pid: app.processIdentifier)
            try Input.typeText(value, pid: app.processIdentifier)
            return after(app, "Value is not settable through AX; focused the element, selected all and typed instead.", on: el)

        case "select_text":
            let app = try target(a)
            let el = try element(app, a)
            point(at: el, app)
            guard let text = argString(a, "text"), !text.isEmpty else { throw CUAError("text is required") }
            guard let full = axText(axAttr(el, kAXValueAttribute)) else { throw CUAError("element has no text value") }
            let prefix = argString(a, "prefix") ?? "", suffix = argString(a, "suffix") ?? ""
            let ns = full as NSString
            let needle = prefix + text + suffix
            let r = ns.range(of: needle)
            guard r.location != NSNotFound else { throw CUAError("text not found in element") }
            let rest = NSRange(location: r.location + 1, length: ns.length - r.location - 1)
            if rest.length > 0 && ns.range(of: needle, range: rest).location != NSNotFound {
                throw CUAError("text occurs more than once; add prefix or suffix")
            }
            let start = r.location + (prefix as NSString).length
            let len = (text as NSString).length
            var range: CFRange = switch argString(a, "selection_type") ?? "text" {
                case "cursor_before": CFRange(location: start, length: 0)
                case "cursor_after": CFRange(location: start + len, length: 0)
                default: CFRange(location: start, length: len)
            }
            AXUIElementSetAttributeValue(el, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            guard let axv = AXValueCreate(.cfRange, &range) else { throw CUAError("could not build range") }
            let err = AXUIElementSetAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, axv)
            guard ok(err) else { throw CUAError("selecting text failed: AXError \(err.rawValue)") }
            return after(app, "Selected text.", on: el)

        default:
            throw CUAError("unknown tool \(name)")
        }
    }
}
#endif
