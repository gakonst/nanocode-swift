#if os(macOS)
import AppKit
import ApplicationServices

func axAttr(_ el: AXUIElement, _ name: String) -> CFTypeRef? {
    var v: CFTypeRef?
    return AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success ? v : nil
}

func axElement(_ el: AXUIElement, _ name: String) -> AXUIElement? {
    guard let v = axAttr(el, name), CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
    return (v as! AXUIElement)
}

func axElements(_ v: CFTypeRef?) -> [AXUIElement] {
    guard let v, CFGetTypeID(v) == CFArrayGetTypeID() else { return [] }
    return (v as! NSArray).compactMap { item -> AXUIElement? in
        let o = item as AnyObject
        return CFGetTypeID(o) == AXUIElementGetTypeID() ? (o as! AXUIElement) : nil
    }
}

func axText(_ v: CFTypeRef?) -> String? {
    guard let v else { return nil }
    let t = CFGetTypeID(v)
    if t == CFStringGetTypeID() { return v as? String }
    if t == CFBooleanGetTypeID() { return (v as! NSNumber).boolValue ? "true" : "false" }
    if t == CFNumberGetTypeID() { return (v as! NSNumber).stringValue }
    if t == CFAttributedStringGetTypeID() { return (v as! NSAttributedString).string }
    if t == CFURLGetTypeID() { return (v as! NSURL).absoluteString }
    return nil
}

func axBool(_ v: CFTypeRef?) -> Bool? {
    guard let v else { return nil }
    let t = CFGetTypeID(v)
    guard t == CFBooleanGetTypeID() || t == CFNumberGetTypeID() else { return nil }
    return (v as! NSNumber).boolValue
}

func axFrame(_ el: AXUIElement) -> CGRect? {
    guard let p = axAttr(el, kAXPositionAttribute), let s = axAttr(el, kAXSizeAttribute),
          CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
    var pt = CGPoint.zero
    var sz = CGSize.zero
    AXValueGetValue(p as! AXValue, .cgPoint, &pt)
    AXValueGetValue(s as! AXValue, .cgSize, &sz)
    return CGRect(origin: pt, size: sz)
}

func axActions(_ el: AXUIElement) -> [String] {
    var names: CFArray?
    guard AXUIElementCopyActionNames(el, &names) == .success, let names else { return [] }
    return (names as NSArray).compactMap { $0 as? String }
}

func axMulti(_ el: AXUIElement, _ names: [String]) -> [CFTypeRef?] {
    var out: CFArray?
    let err = AXUIElementCopyMultipleAttributeValues(el, names as CFArray, AXCopyMultipleAttributeOptions(rawValue: 0), &out)
    guard err == .success, let out else { return names.map { axAttr(el, $0) } }
    let arr = out as NSArray
    return (0..<names.count).map { i -> CFTypeRef? in
        guard i < arr.count else { return nil }
        let o = arr[i] as AnyObject
        if CFGetTypeID(o) == AXValueGetTypeID() && AXValueGetType(o as! AXValue) == .axError { return nil }
        if CFGetTypeID(o) == CFNullGetTypeID() { return nil }
        return o
    }
}

func shortName(_ s: String) -> String {
    if s.hasPrefix("Name:") {
        let name = s.dropFirst(5).split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
        return String(name)
    }
    return s.hasPrefix("AX") ? String(s.dropFirst(2)) : s
}

struct Snapshot {
    var text: String
    var elements: [AXUIElement]
    var windowFrame: CGRect?
}

enum AXTree {
    static let maxNodes = Int(setting("MAX_NODES") ?? "") ?? 1500
    static let maxDepth = 64
    static let attrs: [String] = [
        kAXRoleAttribute, kAXSubroleAttribute, kAXTitleAttribute, kAXDescriptionAttribute,
        kAXValueAttribute, kAXPlaceholderValueAttribute, kAXEnabledAttribute, kAXFocusedAttribute,
        kAXSelectedAttribute, kAXChildrenAttribute, kAXHelpAttribute, kAXSelectedTextAttribute,
    ]
    static let quietRoles: Set<String> = [
        "AXGroup", "AXUnknown", "AXSplitGroup", "AXLayoutArea", "AXLayoutItem", "AXGenericElement", "AXStaticText",
    ]
    static let hiddenActions: Set<String> = ["AXScrollToVisible", "AXShowDefaultUI", "AXShowAlternateUI", "AXShowMenu"]

    struct Builder {
        var lines: [String] = []
        var elements: [AXUIElement] = []
        var focused: AXUIElement?
        var truncated = false

        mutating func walk(_ el: AXUIElement, depth: Int, indent: Int, recurse: Bool = true) {
            if elements.count >= AXTree.maxNodes { truncated = true; return }
            if depth > AXTree.maxDepth { return }
            let v = axMulti(el, AXTree.attrs)
            let role = axText(v[0]) ?? "AXUnknown"
            let subrole = axText(v[1])
            let title = clip(axText(v[2]))
            let desc = clip(axText(v[3]))
            let value = clip(axText(v[4]), role == "AXStaticText" ? 500 : 300)
            let placeholder = clip(axText(v[5]))
            let enabled = axBool(v[6]) ?? true
            var focusedFlag = axBool(v[7]) ?? false
            if let f = focused, CFEqual(f, el) { focusedFlag = true }
            let selected = axBool(v[8]) ?? false
            let children = axElements(v[9])
            let help = clip(axText(v[10]))
            let actions = axActions(el).filter { !AXTree.hiddenActions.contains($0) }
            let labelled = title != nil || desc != nil || value != nil
            let show = !(AXTree.quietRoles.contains(role) && !labelled && actions.isEmpty && !focusedFlag)
            var childIndent = indent
            if show {
                let idx = elements.count
                elements.append(el)
                var s = String(repeating: "  ", count: indent) + "[\(idx)] " + shortName(role)
                if let sr = subrole, sr != "AXUnknown" { s += "(\(shortName(sr)))" }
                if let t = title { s += " \"\(t)\"" }
                if let d = desc, d != title { s += " desc=\"\(d)\"" }
                if let val = value, val != title { s += " value=\"\(val)\"" }
                if value == nil, let p = placeholder { s += " placeholder=\"\(p)\"" }
                if title == nil && desc == nil, let h = help { s += " help=\"\(h)\"" }
                var flags: [String] = []
                if focusedFlag { flags.append("focused") }
                if selected { flags.append("selected") }
                if !enabled { flags.append("disabled") }
                if !flags.isEmpty { s += " {" + flags.joined(separator: ",") + "}" }
                if let sel = clip(axText(v[11]), 120) { s += " selection=\"\(sel)\"" }
                if !actions.isEmpty { s += " actions=" + actions.map(shortName).joined(separator: ",") }
                lines.append(s)
                childIndent += 1
            }
            guard recurse || (role == "AXMenuBarItem" && selected) else { return }
            if role == "AXMenuItem" && !selected && !children.isEmpty { return }
            for c in children { walk(c, depth: depth + 1, indent: childIndent) }
        }
    }

    static func snapshot(_ app: NSRunningApplication) -> Snapshot {
        let pid = app.processIdentifier
        let appEl = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appEl, 3)
        var b = Builder()
        var header = "App: \(app.localizedName ?? "?") (\(app.bundleIdentifier ?? "no bundle id"), pid \(pid))"
        if !app.isActive { header += " [background]" }
        if app.isHidden { header += " [hidden]" }
        b.lines.append(header)
        b.focused = axElement(appEl, kAXFocusedUIElementAttribute)
        var windows = axElements(axAttr(appEl, kAXWindowsAttribute))
        if let fw = axElement(appEl, kAXFocusedWindowAttribute) ?? axElement(appEl, kAXMainWindowAttribute) {
            windows.removeAll { CFEqual($0, fw) }
            windows.insert(fw, at: 0)
        }
        if windows.isEmpty { b.lines.append("(no windows)") }
        for w in windows { b.walk(w, depth: 0, indent: 0) }
        for c in axElements(axAttr(appEl, kAXChildrenAttribute)) where axText(axAttr(c, kAXRoleAttribute)) == "AXMenu" {
            b.walk(c, depth: 0, indent: 0)
        }
        if let mb = axElement(appEl, kAXMenuBarAttribute) {
            b.lines.append("Menu bar:")
            for item in axElements(axAttr(mb, kAXChildrenAttribute)) { b.walk(item, depth: 0, indent: 1, recurse: false) }
        }
        if b.truncated { b.lines.append("(tree truncated at \(maxNodes) elements; set \(ComputerHost.current.environment)_MAX_NODES to raise)") }
        return Snapshot(text: b.lines.joined(separator: "\n"), elements: b.elements, windowFrame: windows.first.flatMap(axFrame))
    }
}

final class AppSession {
    var elements: [AXUIElement] = []
    var lastText: String?
    var scope: String?
    var windowFrame: CGRect?
    var windowID: CGWindowID?
    var focus = FocusTrack<AXUIElement>(same: { CFEqual($0, $1) })
}

struct Focus {
    var window: AXUIElement?
    var element: AXUIElement?

    static func of(_ pid: pid_t) -> Focus {
        let appEl = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appEl, 1)
        return Focus(window: axElement(appEl, kAXFocusedWindowAttribute), element: axElement(appEl, kAXFocusedUIElementAttribute))
    }

    static func moved<T>(from old: (window: T?, element: T?), to new: (window: T?, element: T?), same: (T, T) -> Bool) -> String? {
        func eq(_ a: T?, _ b: T?) -> Bool {
            switch (a, b) {
            case (nil, nil): true
            case let (a?, b?): same(a, b)
            default: false
            }
        }
        if !eq(old.window, new.window) { return "window" }
        if !eq(old.element, new.element) { return "element" }
        return nil
    }
}

struct FocusTrack<T> {
    typealias Reading = (window: T?, element: T?)
    var seen: Reading?
    var drifted = false
    var after: Reading?
    let same: (T, T) -> Bool

    init(same: @escaping (T, T) -> Bool) { self.same = same }

    mutating func begin(_ now: Reading) {
        if let seen, Focus.moved(from: seen, to: now, same: same) != nil { drifted = true }
    }

    mutating func acted(_ now: Reading) { after = now }

    mutating func record(_ now: Reading, fresh: Bool, ours: (T) -> Bool = { _ in false }) {
        if fresh { drifted = false }
        if !fresh, let after, Focus.moved(from: after, to: now, same: same) == "window", !(now.element.map(ours) ?? false) {
            drifted = true
        }
        after = nil
        if !drifted { seen = now }
    }

    func refusal(_ now: Reading) -> String? {
        guard let seen else { return "unknown" }
        if drifted { return "focus" }
        return Focus.moved(from: seen, to: now, same: same)
    }
}

enum Sessions {
    static var byPid: [pid_t: AppSession] = [:]
    static func get(_ pid: pid_t) -> AppSession {
        byPid = byPid.filter { NSRunningApplication(processIdentifier: $0.key) != nil }
        if let s = byPid[pid] { return s }
        let s = AppSession()
        byPid[pid] = s
        return s
    }
}
#endif
