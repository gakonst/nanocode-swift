#if os(macOS)
import AppKit
import QuartzCore

enum AgentCursor {
    static var enabled: Bool { setting("CURSOR") != "0" }
    private static var overlay: CursorOverlay?
    private static var shown = false

    static func glide(to point: CGPoint, pid: pid_t, wait: Bool = true) {
        guard enabled, !Thread.isMainThread else { return }
        shown = visible(point, pid: pid)
        var duration: TimeInterval = 0
        DispatchQueue.main.sync {
            if shown {
                if overlay == nil { overlay = CursorOverlay() }
                duration = overlay?.glide(to: point) ?? 0
            } else {
                overlay?.hideNow()
            }
        }
        if wait && duration > 0 { usleep(useconds_t(duration * 1_000_000)) }
    }

    static func press() {
        guard enabled, shown else { return }
        DispatchQueue.main.async { overlay?.press() }
    }

    static func visible(_ point: CGPoint, pid: pid_t) -> Bool {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] else { return false }
        for window in windows {
            let owner = window[kCGWindowOwnerPID as String] as? pid_t ?? 0
            if owner == getpid() || (window[kCGWindowAlpha as String] as? Double ?? 1) == 0 { continue }
            guard let bounds = window[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds), frame.contains(point) else { continue }
            return owner == pid
        }
        return false
    }
}

private final class CursorOverlay {
    private let window: NSPanel
    private let root = CALayer()
    private let pointer = CALayer()
    private var position: CGPoint?
    private var screen: NSScreen?
    private var hide: DispatchWorkItem?
    private let accent = NSColor(srgbRed: 0.33, green: 0.38, blue: 0.98, alpha: 1)

    init() {
        window = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.overlayWindow)))
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        let view = NSView()
        view.layer = root
        view.wantsLayer = true
        window.contentView = view
        buildPointer()
        root.addSublayer(pointer)
    }

    private func buildPointer() {
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let tip: [(CGFloat, CGFloat)] = [(0, 0), (0, 17), (4, 13), (7, 20), (9.5, 19), (6.5, 12), (12, 12)]
        let path = CGMutablePath()
        for (i, (x, y)) in tip.enumerated() {
            let p = CGPoint(x: x * 1.2, y: 24 - y * 1.2)
            if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
        }
        path.closeSubpath()
        pointer.bounds = CGRect(x: 0, y: 0, width: 24, height: 24)
        pointer.anchorPoint = CGPoint(x: 0, y: 1)
        pointer.opacity = 0
        let arrow = CAShapeLayer()
        arrow.frame = pointer.bounds
        arrow.path = path
        arrow.fillColor = accent.cgColor
        arrow.strokeColor = NSColor.white.cgColor
        arrow.lineWidth = 1.5
        arrow.lineJoin = .round
        arrow.contentsScale = scale
        arrow.shadowColor = NSColor.black.cgColor
        arrow.shadowOpacity = 0.35
        arrow.shadowRadius = 3
        arrow.shadowOffset = CGSize(width: 0, height: -1)
        pointer.addSublayer(arrow)

        let text = CATextLayer()
        let label = ComputerHost.current.name
        let font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        text.string = label
        text.font = font
        text.fontSize = 11
        text.foregroundColor = NSColor.white.cgColor
        text.alignmentMode = .center
        text.contentsScale = scale
        let width = ceil((label as NSString).size(withAttributes: [.font: font]).width) + 12
        let pill = CALayer()
        pill.frame = CGRect(x: 14, y: -12, width: width, height: 18)
        pill.backgroundColor = accent.cgColor
        pill.cornerRadius = 9
        pill.borderColor = NSColor.white.withAlphaComponent(0.9).cgColor
        pill.borderWidth = 1
        text.frame = CGRect(x: 0, y: 2, width: width, height: 15)
        pill.addSublayer(text)
        pointer.addSublayer(pill)
    }

    private var primaryHeight: CGFloat { NSScreen.screens.first?.frame.height ?? 0 }

    private func cocoa(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x, y: primaryHeight - p.y) }

    private func local(_ p: CGPoint) -> CGPoint {
        let c = cocoa(p)
        let frame = screen?.frame ?? .zero
        return CGPoint(x: c.x - frame.minX, y: c.y - frame.minY)
    }

    func glide(to target: CGPoint) -> TimeInterval {
        let target = CGPoint(x: target.x.rounded(), y: target.y.rounded())
        let on = NSScreen.screens.first { $0.frame.contains(cocoa(target)) } ?? NSScreen.main
        var start = position
        if on != screen {
            screen = on
            if let frame = on?.frame { window.setFrame(frame, display: false) }
            start = nil
        }
        if start == nil {
            let mouse = NSEvent.mouseLocation
            let user = CGPoint(x: mouse.x, y: primaryHeight - mouse.y)
            start = on?.frame.contains(mouse) == true ? user : CGPoint(x: target.x + 80, y: target.y + 80)
        }
        let from = local(start!), to = local(target)
        let distance = hypot(to.x - from.x, to.y - from.y)
        let duration = distance < 2 ? 0 : min(0.5, 0.14 + Double(distance) / 2400)
        hide?.cancel()
        window.orderFrontRegardless()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        pointer.position = to
        pointer.opacity = 1
        pointer.removeAnimation(forKey: "fade")
        CATransaction.commit()
        if duration > 0 {
            let glide = CABasicAnimation(keyPath: "position")
            glide.fromValue = NSValue(point: from)
            glide.toValue = NSValue(point: to)
            glide.duration = duration
            glide.timingFunction = CAMediaTimingFunction(controlPoints: 0.25, 0.85, 0.3, 1)
            pointer.add(glide, forKey: "glide")
        }
        position = target
        scheduleHide()
        return duration
    }

    func hideNow() {
        hide?.cancel()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        pointer.opacity = 0
        CATransaction.commit()
        window.orderOut(nil)
        position = nil
        screen = nil
    }

    func press() {
        guard let position else { return }
        let ring = CAShapeLayer()
        let r: CGFloat = 16
        ring.path = CGPath(ellipseIn: CGRect(x: -r, y: -r, width: 2 * r, height: 2 * r), transform: nil)
        ring.position = local(position)
        ring.fillColor = accent.withAlphaComponent(0.18).cgColor
        ring.strokeColor = accent.cgColor
        ring.lineWidth = 2
        ring.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        root.insertSublayer(ring, below: pointer)
        let grow = CABasicAnimation(keyPath: "transform.scale")
        grow.fromValue = 0.3
        grow.toValue = 1.3
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        let group = CAAnimationGroup()
        group.animations = [grow, fade]
        group.duration = 0.4
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        CATransaction.begin()
        CATransaction.setCompletionBlock { ring.removeFromSuperlayer() }
        ring.opacity = 0
        ring.add(group, forKey: "press")
        CATransaction.commit()
        let squeeze = CAKeyframeAnimation(keyPath: "transform.scale")
        squeeze.values = [1, 0.82, 1]
        squeeze.duration = 0.2
        pointer.add(squeeze, forKey: "press")
        scheduleHide()
    }

    private func scheduleHide() {
        hide?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            CATransaction.begin()
            CATransaction.setCompletionBlock { [weak self] in
                if self?.pointer.opacity == 0 { self?.window.orderOut(nil) }
            }
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 1
            fade.toValue = 0
            fade.duration = 0.4
            self.pointer.opacity = 0
            self.pointer.add(fade, forKey: "fade")
            CATransaction.commit()
        }
        hide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: work)
    }
}
#endif
