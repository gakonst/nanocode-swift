#if os(macOS)
import AppKit
import CoreGraphics

enum Input {
    static let source = CGEventSource(stateID: .privateState)
    static var useHID: Bool { setting("INPUT") == "hid" }
    static var mouseMode: String { setting("MOUSE") ?? "nsevent" }
    static var focusFirst: Bool { setting("FOCUS") == "1" }

    static var window: (id: CGWindowID, frame: CGRect)?

    static let skyLight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW)
    static func private_<T>(_ name: String, _: T.Type) -> T? {
        guard let h = skyLight, let sym = dlsym(h, name) ?? dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) else { return nil }
        return unsafeBitCast(sym, to: T.self)
    }
    typealias PostToPid = @convention(c) (pid_t, CGEvent) -> Void
    typealias SetWindowLocation = @convention(c) (CGEvent, CGPoint) -> Void
    typealias PostEventRecordTo = @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, UnsafeMutablePointer<UInt8>) -> Int32
    typealias PSNForPID = @convention(c) (pid_t, UnsafeMutablePointer<ProcessSerialNumber>) -> Int32
    static let slPostToPid = private_("SLEventPostToPid", PostToPid.self)
    static let setWindowLocation = private_("CGEventSetWindowLocation", SetWindowLocation.self)
    static let postEventRecord = private_("SLPSPostEventRecordTo", PostEventRecordTo.self)
    static let psnForPid = private_("GetProcessForPID", PSNForPID.self)

    static func post(_ e: CGEvent, _ pid: pid_t) {
        if useHID { e.post(tap: .cghidEventTap); return }
        if mouseMode == "skylight", let f = slPostToPid { f(pid, e) } else { e.postToPid(pid) }
    }

    static func tagWindow(_ e: CGEvent, _ p: CGPoint) {
        guard let w = window, mouseMode != "cg" else { return }
        for raw: UInt32 in [91, 92] {
            let field: CGEventField? = CGEventField(rawValue: raw)
            if let field { e.setIntegerValueField(field, value: Int64(w.id)) }
        }
        setWindowLocation?(e, CGPoint(x: p.x - w.frame.minX, y: p.y - w.frame.minY))
    }

    static func makeKey(_ pid: pid_t) {
        guard focusFirst, !useHID, let w = window, let post = postEventRecord, let getPSN = psnForPid else { return }
        var psn = ProcessSerialNumber()
        guard getPSN(pid, &psn) == 0 else { return }
        for kind: UInt8 in [1, 2] {
            var bytes = [UInt8](repeating: 0, count: 0xf8)
            bytes[0x04] = 0xf8
            bytes[0x08] = kind
            bytes[0x3a] = 0x10
            var wid = UInt32(w.id)
            withUnsafeBytes(of: &wid) { for (i, b) in $0.enumerated() { bytes[0x3c + i] = b } }
            for i in 0x20..<0x30 { bytes[i] = 0xff }
            _ = bytes.withUnsafeMutableBufferPointer { post(&psn, $0.baseAddress!) }
        }
        usleep(30_000)
    }

    static func mouseEvent(_ t: CGEventType, at p: CGPoint, button: CGMouseButton, clicks: Int) -> CGEvent? {
        if mouseMode == "nsevent" || mouseMode == "skylight", let w = window,
           let nsType = NSEvent.EventType(rawValue: UInt(t.rawValue)) {
            let loc = NSPoint(x: p.x - w.frame.minX, y: w.frame.height - (p.y - w.frame.minY))
            let down = [CGEventType.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(t)
            if let e = NSEvent.mouseEvent(with: nsType, location: loc, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                          windowNumber: Int(w.id), context: nil, eventNumber: 0, clickCount: clicks,
                                          pressure: down ? 1 : 0)?.cgEvent {
                e.location = p
                if button == .center { e.setIntegerValueField(.mouseEventButtonNumber, value: 2) }
                tagWindow(e, p)
                return e
            }
        }
        guard let e = CGEvent(mouseEventSource: source, mouseType: t, mouseCursorPosition: p, mouseButton: button) else { return nil }
        e.setIntegerValueField(.mouseEventClickState, value: Int64(clicks))
        tagWindow(e, p)
        return e
    }

    static func mouseTypes(_ button: Int) -> (CGEventType, CGEventType, CGEventType, CGMouseButton) {
        switch button {
        case 1: return (.rightMouseDown, .rightMouseUp, .rightMouseDragged, .right)
        case 2: return (.otherMouseDown, .otherMouseUp, .otherMouseDragged, .center)
        default: return (.leftMouseDown, .leftMouseUp, .leftMouseDragged, .left)
        }
    }

    static func click(at p: CGPoint, pid: pid_t, button: Int, count: Int) {
        let (down, up, _, btn) = mouseTypes(button)
        makeKey(pid)
        if let move = mouseEvent(.mouseMoved, at: p, button: btn, clicks: 0) { post(move, pid) }
        usleep(20_000)
        for n in 1...max(1, count) {
            for t in [down, up] {
                guard let e = mouseEvent(t, at: p, button: btn, clicks: n) else { continue }
                post(e, pid)
                usleep(15_000)
            }
            usleep(30_000)
        }
    }

    static func drag(from a: CGPoint, to b: CGPoint, pid: pid_t) {
        let (down, up, dragged, btn) = mouseTypes(0)
        makeKey(pid)
        func send(_ t: CGEventType, _ p: CGPoint) { if let e = mouseEvent(t, at: p, button: btn, clicks: 1) { post(e, pid) } }
        send(down, a)
        usleep(50_000)
        let steps = 20
        for i in 1...steps {
            let f = CGFloat(i) / CGFloat(steps)
            send(dragged, CGPoint(x: a.x + (b.x - a.x) * f, y: a.y + (b.y - a.y) * f))
            usleep(12_000)
        }
        usleep(50_000)
        send(up, b)
    }

    static func scroll(at p: CGPoint, pid: pid_t, dx: Int, dy: Int) {
        let steps = max(1, max(abs(dx), abs(dy)) / 40)
        for _ in 0..<steps {
            guard let e = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2,
                                  wheel1: Int32(dy / steps), wheel2: Int32(dx / steps), wheel3: 0) else { return }
            e.location = p
            tagWindow(e, p)
            post(e, pid)
            usleep(8_000)
        }
    }

    static let keyCodes: [String: CGKeyCode] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12,
        "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23,
        "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34,
        "p": 35, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46,
        ".": 47, "`": 50,
        "return": 36, "enter": 36, "tab": 48, "space": 49, "delete": 51, "backspace": 51, "escape": 53, "esc": 53,
        "forwarddelete": 117, "home": 115, "end": 119, "pageup": 116, "pagedown": 121,
        "left": 123, "right": 124, "down": 125, "up": 126, "kpenter": 76, "help": 114,
        "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97, "f7": 98, "f8": 100,
        "f9": 101, "f10": 109, "f11": 103, "f12": 111,
    ]
    static let aliases: [String: String] = [
        "plus": "=", "minus": "-", "equal": "=", "comma": ",", "period": ".", "slash": "/", "backslash": "\\",
        "semicolon": ";", "apostrophe": "'", "quote": "'", "grave": "`", "bracketleft": "[", "bracketright": "]",
        "pgup": "pageup", "pgdn": "pagedown", "pagedn": "pagedown", "del": "forwarddelete", "ret": "return", "spacebar": "space",
    ]

    static func normalize(_ k: String) -> String {
        var s = k.lowercased().replacingOccurrences(of: "_", with: "")
        if s.hasPrefix("arrow") && s.count > 5 { s = String(s.dropFirst(5)) }
        if s.hasPrefix("kp") && s != "kpenter" { s = String(s.dropFirst(2)) }
        return aliases[s] ?? s
    }

    static func parseKey(_ spec: String) throws -> (CGKeyCode?, String?, CGEventFlags) {
        var parts = spec.split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        if spec.hasSuffix("++") || spec == "+" { parts = parts.filter { !$0.isEmpty } + ["+"] }
        parts = parts.filter { !$0.isEmpty }
        guard let keyPart = parts.popLast() else { throw CUAError("empty key") }
        var flags: CGEventFlags = []
        for m in parts {
            switch m.lowercased() {
            case "cmd", "command", "super", "meta", "win": flags.insert(.maskCommand)
            case "shift": flags.insert(.maskShift)
            case "alt", "option", "opt": flags.insert(.maskAlternate)
            case "ctrl", "control": flags.insert(.maskControl)
            case "fn": flags.insert(.maskSecondaryFn)
            default: throw CUAError("unknown modifier \"\(m)\" in \"\(spec)\"")
            }
        }
        let name = normalize(keyPart)
        if let code = keyCodes[name] {
            if ["left", "right", "up", "down"].contains(name) { flags.formUnion([.maskNumericPad, .maskSecondaryFn]) }
            if ["home", "end", "pageup", "pagedown", "forwarddelete", "help"].contains(name) || name.hasPrefix("f") && name.count > 1 {
                flags.insert(.maskSecondaryFn)
            }
            return (code, nil, flags)
        }
        if keyPart.count == 1 {
            if keyPart.lowercased() != keyPart, let code = keyCodes[keyPart.lowercased()] {
                return (code, nil, flags.union(.maskShift))
            }
            return (nil, keyPart, flags)
        }
        throw CUAError("unknown key \"\(keyPart)\"")
    }

    static let keyChars: [CGKeyCode: String] = {
        var m: [CGKeyCode: String] = [36: "\r", 48: "\t", 49: " ", 51: "\u{7f}", 53: "\u{1b}"]
        for (name, code) in keyCodes where name.count == 1 { m[code] = name }
        return m
    }()

    static func nsFlags(_ f: CGEventFlags) -> NSEvent.ModifierFlags {
        var m: NSEvent.ModifierFlags = []
        if f.contains(.maskCommand) { m.insert(.command) }
        if f.contains(.maskShift) { m.insert(.shift) }
        if f.contains(.maskAlternate) { m.insert(.option) }
        if f.contains(.maskControl) { m.insert(.control) }
        if f.contains(.maskSecondaryFn) { m.insert(.function) }
        if f.contains(.maskNumericPad) { m.insert(.numericPad) }
        return m
    }

    static func keyEvent(code: CGKeyCode, char: String?, flags: CGEventFlags, down: Bool) -> CGEvent? {
        if mouseMode != "cg", let w = window {
            let base = char ?? keyChars[code] ?? ""
            let chars = flags.contains(.maskShift) ? base.uppercased() : base
            if let e = NSEvent.keyEvent(with: down ? .keyDown : .keyUp, location: .zero, modifierFlags: nsFlags(flags),
                                        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: Int(w.id), context: nil,
                                        characters: chars, charactersIgnoringModifiers: base, isARepeat: false, keyCode: code)?.cgEvent {
                e.flags = flags
                return e
            }
        }
        guard let e = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down) else { return nil }
        if let char {
            let u = Array(char.utf16)
            e.keyboardSetUnicodeString(stringLength: u.count, unicodeString: u)
        }
        e.flags = flags
        return e
    }

    static func pressKey(_ spec: String, pid: pid_t) throws {
        let (code, char, flags) = try parseKey(spec)
        for down in [true, false] {
            guard let e = keyEvent(code: code ?? 0, char: char, flags: flags, down: down) else { continue }
            post(e, pid)
            usleep(12_000)
        }
    }

    enum Keystroke: Equatable {
        case key(String)
        case character(String)
    }

    static func keystrokes(_ text: String) -> [Keystroke] {
        text.map { ch in
            if ch == "\n" || ch == "\r\n" || ch == "\r" { return .key("shift+return") }
            if ch == "\t" { return .key("tab") }
            return .character(String(ch))
        }
    }

    static func typeText(_ text: String, pid: pid_t) throws {
        for stroke in keystrokes(text) {
            let ch: String
            switch stroke {
            case .key(let spec): try pressKey(spec, pid: pid); continue
            case .character(let c): ch = c
            }
            let u = Array(ch.utf16)
            for down in [true, false] {
                guard let e = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down) else { continue }
                e.keyboardSetUnicodeString(stringLength: u.count, unicodeString: u)
                e.flags = []
                post(e, pid)
            }
            usleep(4_000)
        }
    }
}
#endif
