#if os(macOS)
import AppKit
import ScreenCaptureKit

struct Shot {
    let png: Data
    let frame: CGRect
    let windowID: CGWindowID
    let path: String
}

enum Screenshot {
    static func distance(_ a: CGRect, _ b: CGRect) -> CGFloat {
        abs(a.minX - b.minX) + abs(a.minY - b.minY) + abs(a.width - b.width) + abs(a.height - b.height)
    }

    private static var latest: [pid_t: String] = [:]

    static func capture(pid: pid_t, near: CGRect?) throws -> Shot {
        let shot = try captureWindow(pid: pid, near: near)
        if let old = latest[pid], old != shot.path { try? FileManager.default.removeItem(atPath: old) }
        latest[pid] = shot.path
        return shot
    }

    private static func captureWindow(pid: pid_t, near: CGRect?) throws -> Shot {
        try runSync {
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            let wins = content.windows.filter {
                $0.owningApplication?.processID == pid && $0.windowLayer == 0 && $0.frame.width > 40 && $0.frame.height > 40
            }
            guard var win = wins.first else {
                throw CaptureError.noWindow
            }
            if let near, let best = wins.min(by: { distance($0.frame, near) < distance($1.frame, near) }) { win = best }
            let filter = SCContentFilter(desktopIndependentWindow: win)
            let cfg = SCStreamConfiguration()
            cfg.width = max(1, Int(win.frame.width.rounded()))
            cfg.height = max(1, Int(win.frame.height.rounded()))
            cfg.showsCursor = false
            cfg.ignoreShadowsSingleWindow = true
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
            do {
                let png = try encodeImage(image)
                let dir = FileManager.default.temporaryDirectory.appendingPathComponent(ComputerHost.current.server, isDirectory: true)
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let url = dir.appendingPathComponent("app-\(pid)-\(Int(Date().timeIntervalSince1970 * 1000)).\(imageExtension)")
                try png.write(to: url)
                return Shot(png: png, frame: win.frame, windowID: win.windowID, path: url.path)
            } catch {
                throw CaptureError.afterCapture(error)
            }
        }
    }
}

enum CaptureError: Error {
    case noWindow
    case afterCapture(Error)
}

enum ScreenshotFailure {
    struct AppWindows {
        var exited = false
        var hidden = false
        var minimized = 0
    }

    static let permission = "Screenshot unavailable: this app does not have Screen Recording permission (System Settings > Privacy & Security > Screen & System Audio Recording)."

    static func message(_ error: Error, app: AppWindows, preflight: () -> Bool) -> String {
        if app.exited { return "Screenshot unavailable: the app quit, so it has no window to capture." }
        if case CaptureError.noWindow = error {
            if app.minimized > 0 {
                return "Screenshot unavailable: the app's window\(app.minimized == 1 ? " is" : "s are") minimized, so none is on screen to capture."
            }
            if app.hidden { return "Screenshot unavailable: the app is hidden, so none of its windows is on screen to capture." }
            return "Screenshot unavailable: the app has no on-screen window to capture (it may be windowless, or its windows are on another Space)."
        }
        if case CaptureError.afterCapture(let underlying) = error { return "Screenshot unavailable: \(underlying)" }
        let ns = error as NSError
        if ns.domain == SCStreamErrorDomain && ns.code == SCStreamError.userDeclined.rawValue { return permission }
        return preflight() ? "Screenshot unavailable: \(error)" : permission
    }

    static func windows(of app: NSRunningApplication) -> AppWindows {
        if app.isTerminated { return AppWindows(exited: true) }
        let appEl = AXUIElementCreateApplication(app.processIdentifier)
        let minimized = axElements(axAttr(appEl, kAXWindowsAttribute)).filter { axBool(axAttr($0, kAXMinimizedAttribute)) == true }.count
        return AppWindows(hidden: app.isHidden, minimized: minimized)
    }
}

extension Screenshot {
    static func captureDisplay() throws -> (png: Data, width: Int, height: Int) {
        try runSync {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let d = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) ?? content.displays.first else {
                throw CUAError("no display to capture")
            }
            let own = content.windows.filter {
                $0.owningApplication?.processID == getpid()
                    || !Policy.allows(bundleID: $0.owningApplication?.bundleIdentifier ?? "")
            }
            let filter = SCContentFilter(display: d, excludingWindows: own)
            let cfg = SCStreamConfiguration()
            cfg.width = d.width
            cfg.height = d.height
            cfg.showsCursor = true
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
            return (try encodeImage(image), d.width, d.height)
        }
    }
}

var jpegImages: Bool { setting("IMAGE_FORMAT")?.lowercased() == "jpeg" }
var imageExtension: String { jpegImages ? "jpg" : "png" }
var imageMime: String { jpegImages ? "image/jpeg" : "image/png" }

func encodeImage(_ image: CGImage) throws -> Data {
    let rep = NSBitmapImageRep(cgImage: image)
    guard jpegImages else {
        guard let png = rep.representation(using: .png, properties: [:]) else { throw CUAError("image encoding failed") }
        return png
    }
    let limit = Int(setting("MAX_IMAGE_BYTES") ?? "") ?? 400_000
    var data: Data?
    for quality in [0.8, 0.6, 0.45, 0.3, 0.2] {
        data = rep.representation(using: .jpeg, properties: [.compressionFactor: quality])
        if let data, data.count <= limit { return data }
    }
    guard let data else { throw CUAError("image encoding failed") }
    return data
}
#endif
