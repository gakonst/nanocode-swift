#if os(macOS)
import AppKit

enum Apps {
    static var searchDirs: [String] {
        ["/Applications", "/Applications/Utilities", "/System/Applications",
         "/System/Applications/Utilities", NSHomeDirectory() + "/Applications"]
    }

    static func installed() -> [URL] {
        var out: [URL] = []
        for dir in searchDirs {
            guard let items = try? FileManager.default.contentsOfDirectory(atPath: dir) else { continue }
            for item in items.sorted() where item.hasSuffix(".app") {
                out.append(URL(fileURLWithPath: dir).appendingPathComponent(item))
            }
        }
        return out
    }

    static func displayName(_ url: URL) -> String {
        let b = Bundle(url: url)
        return (b?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (b?.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? url.deletingPathExtension().lastPathComponent
    }

    static func list() -> String {
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        var seen = Set<String>()
        var lines = ["Running:"]
        for a in NSWorkspace.shared.runningApplications where a.activationPolicy == .regular {
            let path = a.bundleURL?.path ?? ""
            seen.insert(path)
            var flags = ["pid \(a.processIdentifier)"]
            if a.processIdentifier == front { flags.append("frontmost") }
            if a.isHidden { flags.append("hidden") }
            lines.append("  \(a.localizedName ?? "?") | \(a.bundleIdentifier ?? "-") | \(path) [\(flags.joined(separator: ", "))]")
        }
        lines.append("Installed (not running):")
        for u in installed() where !seen.contains(u.path) {
            lines.append("  \(displayName(u)) | \(Bundle(url: u)?.bundleIdentifier ?? "-") | \(u.path)")
        }
        return lines.joined(separator: "\n")
    }

    static func findRunning(_ q: String) -> NSRunningApplication? {
        let apps = NSWorkspace.shared.runningApplications.filter { !$0.isTerminated }
        if q.hasPrefix("/") {
            let want = URL(fileURLWithPath: q).standardizedFileURL.path
            return apps.first { $0.bundleURL?.standardizedFileURL.path == want }
        }
        let lq = q.lowercased()
        return apps.first { $0.bundleIdentifier?.lowercased() == lq }
            ?? apps.first { $0.activationPolicy == .regular && $0.localizedName?.lowercased() == lq }
            ?? apps.first { $0.bundleURL?.deletingPathExtension().lastPathComponent.lowercased() == lq }
            ?? apps.first { $0.localizedName?.lowercased() == lq }
    }

    static func findURL(_ q: String) -> URL? {
        if q.hasPrefix("/") { return FileManager.default.fileExists(atPath: q) ? URL(fileURLWithPath: q) : nil }
        if q.contains("."), let u = NSWorkspace.shared.urlForApplication(withBundleIdentifier: q) { return u }
        let lq = q.lowercased()
        let all = installed()
        return all.first { $0.deletingPathExtension().lastPathComponent.lowercased() == lq }
            ?? all.first { displayName($0).lowercased() == lq }
    }

    static func resolve(_ query: String) throws -> NSRunningApplication {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { throw CUAError("app is required") }
        if let a = findRunning(q) { return a }
        guard let url = findURL(q) else { throw CUAError("No application matches \"\(q)\". Call list_apps.") }
        try Policy.check(bundleID: Bundle(url: url)?.bundleIdentifier ?? "", name: displayName(url))
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = false
        cfg.addsToRecentItems = false
        let box = Box<Result<NSRunningApplication, Error>>()
        let sem = DispatchSemaphore(value: 0)
        NSWorkspace.shared.openApplication(at: url, configuration: cfg) { app, err in
            if let app { box.value = .success(app) } else { box.value = .failure(err ?? CUAError("launch failed")) }
            sem.signal()
        }
        if sem.wait(timeout: .now() + 20) == .timedOut { throw CUAError("Timed out launching \(q)") }
        let app = try box.value!.get()
        let deadline = Date().addingTimeInterval(10)
        while !app.isFinishedLaunching && Date() < deadline { sleepMs(100) }
        let winDeadline = Date().addingTimeInterval(5)
        let el = AXUIElementCreateApplication(app.processIdentifier)
        while Date() < winDeadline && axElements(axAttr(el, kAXWindowsAttribute)).isEmpty { sleepMs(150) }
        return app
    }
}

enum Policy {
    static let blocked: Set<String> = [
        "com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty", "dev.warp.Warp-Stable",
        "net.kovidgoyal.kitty", "io.alacritty", "com.github.wez.wezterm",
        "com.apple.keychainaccess", "com.apple.Passwords", "com.1password.1password", "com.agilebits.onepassword7",
        "com.bitwarden.desktop", "com.lastpass.LastPass", "com.dashlane.dashlanephonefinal",
        "com.apple.SecurityAgent", "com.apple.LocalAuthentication.UIAgent", "com.apple.coreservices.uiagent",
    ]

    static func check(_ app: NSRunningApplication) throws {
        try check(bundleID: app.bundleIdentifier ?? "", name: app.localizedName)
    }

    static func check(bundleID id: String, name: String?) throws {
        guard !allows(bundleID: id) else { return }
        throw CUAError("\(name ?? id) (\(id)) is blocked by \(ComputerHost.current.name)'s computer-use policy. Set \(ComputerHost.current.environment)_ALLOW=\(id) to permit it.")
    }

    static func allows(bundleID id: String) -> Bool {
        if setting("ALLOW_ALL") == "1" { return true }
        var deny = blocked
        for s in (setting("DENY") ?? "").split(separator: ",") {
            deny.insert(s.trimmingCharacters(in: .whitespaces))
        }
        let allow = Set((setting("ALLOW") ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
        if allow.contains(id) { return true }
        return !(deny.contains(id) || [HelperBundle.appIdentifier, Bundle.main.bundleIdentifier].contains(id))
    }
}
#endif
