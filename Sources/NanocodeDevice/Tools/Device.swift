#if os(iOS) || os(macOS)
import AVFoundation
import Foundation
import Nanocode
import Network
#if os(iOS)
import UIKit
#else
import AppKit
#endif
import UniformTypeIdentifiers

extension DeviceKit {
  static let device = HostTool(
    name: "device_info",
    description: "Describes this \(DeviceTools.here): model, OS, name, locale and languages, time zone, battery and charging, Low Power Mode, thermal state, storage, memory, network, screen, appearance and accessibility settings.",
    parameters: DeviceTools.schema([:])
  ) { _ in
    async let network = path()
    var object = await MainActor.run { screenFacts() }
    let info = ProcessInfo.processInfo
    var system = utsname()
    uname(&system)
    let machine = withUnsafeBytes(of: &system.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    object["model_identifier"] = .string(machine)
    object["os"] = .string(info.operatingSystemVersionString)
    object["locale"] = .string(Locale.current.identifier)
    object["languages"] = .array(Locale.preferredLanguages.map(JSON.string))
    object["time_zone"] = .string(TimeZone.current.identifier)
    object["now"] = DeviceTools.stamp(Date())
    object["low_power_mode"] = .bool(info.isLowPowerModeEnabled)
    let thermal = switch info.thermalState {
    case .nominal: "nominal"
    case .fair: "fair"
    case .serious: "serious"
    case .critical: "critical"
    @unknown default: "unknown"
    }
    object["thermal_state"] = .string(thermal)
    object["memory_bytes"] = .number(Double(info.physicalMemory))
    object["uptime_seconds"] = .number(info.systemUptime.rounded())
    let home = URL(fileURLWithPath: NSHomeDirectory())
    if let values = try? home.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey]) {
      object["storage_free_bytes"] = number(values.volumeAvailableCapacityForImportantUsage.map(Double.init))
      object["storage_total_bytes"] = number(values.volumeTotalCapacity.map(Double.init))
    }
    let bundle = Bundle.main.infoDictionary ?? [:]
    object["app_version"] = .string("\(bundle["CFBundleShortVersionString"] as? String ?? "") (\(bundle["CFBundleVersion"] as? String ?? ""))")
    object["app_build"] = string(DeviceTools.settings.buildKey.flatMap { bundle[$0] as? String })
    object["network"] = await network
    return .json(.object(object))
  }

  #if os(macOS)
  @MainActor static func screenFacts() -> [String: JSON] {
    let info = ProcessInfo.processInfo
    var object: [String: JSON] = [
      "platform": "macOS", "version": .string(info.operatingSystemVersionString), "name": .string(Host.current().localizedName ?? "Mac"),
      "appearance": .string(NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? "dark" : "light"),
      "voiceover": .bool(NSWorkspace.shared.isVoiceOverEnabled), "reduce_motion": .bool(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion),
      "app_state": .string(NSApp.isActive ? "active" : "inactive"),
    ]
    if let screen = NSScreen.main {
      object["screen"] = ["width_pt": .number(screen.frame.width), "height_pt": .number(screen.frame.height), "scale": .number(screen.backingScaleFactor)]
    }
    return object
  }
  #else
  @MainActor static func screenFacts() -> [String: JSON] {
    let device = UIDevice.current
    device.isBatteryMonitoringEnabled = true
    let battery = switch device.batteryState {
    case .charging: "charging"
    case .full: "full"
    case .unplugged: "unplugged"
    default: "unknown"
    }
    var object: [String: JSON] = [
      "platform": .string(device.systemName), "version": .string(device.systemVersion), "model": .string(device.model), "name": .string(device.name),
      "battery_level": device.batteryLevel < 0 ? .null : .number((Double(device.batteryLevel) * 100).rounded()), "battery_state": .string(battery),
      "appearance": .string(UITraitCollection.current.userInterfaceStyle == .dark ? "dark" : "light"),
      "voiceover": .bool(UIAccessibility.isVoiceOverRunning), "reduce_motion": .bool(UIAccessibility.isReduceMotionEnabled),
      "bold_text": .bool(UIAccessibility.isBoldTextEnabled), "text_size": .string(UIApplication.shared.preferredContentSizeCategory.rawValue),
      "app_state": .string(UIApplication.shared.applicationState == .active ? "active" : UIApplication.shared.applicationState == .background ? "background" : "inactive"),
    ]
    if let screen = window()?.screen {
      object["screen"] = ["width_pt": .number(screen.bounds.width), "height_pt": .number(screen.bounds.height), "scale": .number(screen.scale),
                          "brightness": .number((screen.brightness * 100).rounded() / 100)]
    }
    return object
  }

  @MainActor static func window() -> UIWindowScene? {
    let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    return scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
  }
  #endif

  static func path() async -> JSON {
    let monitor = NWPathMonitor()
    let found: NWPath? = await withCheckedContinuation { continuation in
      let once = Once()
      monitor.pathUpdateHandler = { path in
        if once.take() { continuation.resume(returning: path) }
      }
      monitor.start(queue: DispatchQueue(label: "xyz.gakonst.personal.path"))
      DispatchQueue.global().asyncAfter(deadline: .now() + 2) { if once.take() { continuation.resume(returning: nil) } }
    }
    monitor.cancel()
    guard let found else { return .null }
    let kinds: [(NWInterface.InterfaceType, String)] = [(.wifi, "wifi"), (.cellular, "cellular"), (.wiredEthernet, "ethernet"), (.loopback, "loopback"), (.other, "other")]
    return ["status": .string(found.status == .satisfied ? "online" : found.status == .requiresConnection ? "requires_connection" : "offline"),
            "interfaces": .array(kinds.filter { found.usesInterfaceType($0.0) }.map { .string($0.1) }),
            "expensive": .bool(found.isExpensive), "constrained": .bool(found.isConstrained),
            "ipv4": .bool(found.supportsIPv4), "ipv6": .bool(found.supportsIPv6)]
  }

  final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func take() -> Bool { lock.withLock { if done { return false }; done = true; return true } }
  }

  static let clipboardActions = ["read", "write", "types", "clear"]

  static let clipboard = HostTool(
    name: "clipboard",
    description: "The clipboard on this \(DeviceTools.here). types: what it holds (text, URL, image) without reading it. read: its text, URL and, with image true, its image (iOS may ask the owner to allow pasting). write: copy text, a URL or an image (a file from the files tool, or base64). clear empties it. Without an action, text copies and no text reads, as before.",
    parameters: DeviceTools.schema([
      "action": DeviceTools.actions(clipboardActions),
      "text": prop("string", "For write: the text to copy."),
      "url": prop("string", "For write: a URL to copy."),
      "image": prop("boolean", "For read: also return the image."),
      "container": prop("string", "For write: the files container of an image to copy."),
      "path": prop("string", "For write: the path of an image file to copy."),
      "base64": prop("string", "For write: image bytes to copy."),
    ]),
    content: true
  ) { call in try await pasteboard(call.input) }

  static func pasteboard(_ input: JSON) async throws -> ToolResult {
    let action = input["action"]?.string ?? (input["text"] == nil ? "read" : "write")
    switch action {
    #if os(macOS)
    case "types":
      return .json(await MainActor.run {
        let board = NSPasteboard.general
        let types = board.types ?? []
        return ["text": .bool(types.contains(.string)), "url": .bool(types.contains(.URL)), "image": .bool(types.contains(.png) || types.contains(.tiff)),
                "items": .number(Double(board.pasteboardItems?.count ?? 0)), "change_count": .number(Double(board.changeCount))]
      })
    case "read":
      let (text, link, image) = await MainActor.run {
        let board = NSPasteboard.general
        let image = input["image"]?.bool == true ? board.data(forType: .png) ?? board.data(forType: .tiff) : nil
        return (board.string(forType: .string), board.string(forType: .URL), image)
      }
      let facts: JSON = ["text": string(text), "url": string(link)]
      if let image { return try DeviceTools.image(image, description: facts) }
      return .json(facts)
    case "write":
      var data: Data?
      if let base64 = text(input, "base64") {
        guard let decoded = Data(base64Encoded: base64) else { throw NanocodeError("base64 is not valid base64") }
        data = decoded
      } else if text(input, "path") != nil {
        data = try Data(contentsOf: try fileURL(input))
      }
      let value = input["text"]?.string
      let link = text(input, "url").flatMap(URL.init(string:))
      guard value != nil || link != nil || data != nil else { throw NanocodeError("write takes text, url, or an image (path or base64)") }
      let picture = try data.map { bytes in
        guard let image = NSImage(data: bytes) else { throw NanocodeError("that file is not an image") }
        return image
      }
      await MainActor.run {
        let board = NSPasteboard.general
        board.clearContents()
        if let picture { board.writeObjects([picture]) } else if let link { board.writeObjects([link as NSURL]) } else { board.setString(value ?? "", forType: .string) }
      }
      return .text(picture != nil ? "Copied the image." : link != nil ? "Copied the URL." : "Copied \(value?.count ?? 0) characters.")
    case "clear":
      await MainActor.run { _ = NSPasteboard.general.clearContents() }
      return .text("Cleared the clipboard.")
    #else
    case "types":
      return .json(await MainActor.run {
        let board = UIPasteboard.general
        return ["text": .bool(board.hasStrings), "url": .bool(board.hasURLs), "image": .bool(board.hasImages), "items": .number(Double(board.numberOfItems)),
                "change_count": .number(Double(board.changeCount))]
      })
    case "read":
      let (text, link, image) = await MainActor.run {
        let board = UIPasteboard.general
        return (board.string, board.url?.absoluteString, input["image"]?.bool == true ? board.image?.pngData() : nil)
      }
      let facts: JSON = ["text": string(text), "url": string(link)]
      if let image { return try DeviceTools.image(image, description: facts) }
      return .json(facts)
    case "write":
      var data: Data?
      if let base64 = text(input, "base64") {
        guard let decoded = Data(base64Encoded: base64) else { throw NanocodeError("base64 is not valid base64") }
        data = decoded
      } else if text(input, "path") != nil {
        data = try Data(contentsOf: try fileURL(input))
      }
      let value = input["text"]?.string
      let link = text(input, "url").flatMap(URL.init(string:))
      guard value != nil || link != nil || data != nil else { throw NanocodeError("write takes text, url, or an image (path or base64)") }
      let picture = try data.map { bytes in
        guard let image = UIImage(data: bytes) else { throw NanocodeError("that file is not an image") }
        return image
      }
      await MainActor.run {
        let board = UIPasteboard.general
        if let picture { board.image = picture } else if let link { board.url = link } else { board.string = value }
      }
      return .text(picture != nil ? "Copied the image." : link != nil ? "Copied the URL." : "Copied \(value?.count ?? 0) characters.")
    case "clear":
      await MainActor.run { UIPasteboard.general.items = [] }
      return .text("Cleared the clipboard.")
    #endif
    default:
      throw unknown("clipboard", clipboardActions)
    }
  }

  #if os(iOS)
  static let screenActions = ["get", "brightness", "haptic", "keep_awake", "torch"]

  static let screen = HostTool(
    name: "screen",
    description: "This iPhone's screen and feedback. get: brightness, whether it stays awake, the torch. brightness: set it (0 to 1; iOS restores the owner's setting when \(DeviceTools.settings.app) leaves the screen). haptic: play a haptic (light, medium, heavy, soft, rigid, success, warning, error, selection). keep_awake: stop the screen from locking while \(DeviceTools.settings.app) is open. torch: turn the flashlight on (level 0 to 1) or off.",
    parameters: schema(screenActions, [
      "value": prop("number", "For brightness: 0 to 1. For torch: the level, 0 to 1 (1 by default)."),
      "on": prop("boolean", "For keep_awake and torch."),
      "style": choice(["light", "medium", "heavy", "soft", "rigid", "success", "warning", "error", "selection"]),
    ])
  ) { call in try await display(call.input) }

  static func display(_ input: JSON) async throws -> ToolResult {
    switch input["action"]?.string {
    case "get":
      let torch = AVCaptureDevice.default(for: .video)
      let facts: [String: JSON] = await MainActor.run {
        ["brightness": window().map { .number(($0.screen.brightness * 100).rounded() / 100) } ?? .null,
         "keep_awake": .bool(UIApplication.shared.isIdleTimerDisabled)]
      }
      var object = facts
      object["torch"] = torch?.hasTorch == true ? .bool(torch?.isTorchActive == true) : .null
      return .json(.object(object))
    case "brightness":
      guard let value = input["value"]?.number, (0...1).contains(value) else { throw NanocodeError("brightness takes a value from 0 to 1") }
      try await foreground("Changing the brightness")
      await MainActor.run { window()?.screen.brightness = CGFloat(value) }
      return .json(["brightness": .number(value)])
    case "haptic":
      let style = input["style"]?.string ?? "medium"
      try await foreground("A haptic")
      try await MainActor.run {
        switch style {
        case "light": UIImpactFeedbackGenerator(style: .light).impactOccurred()
        case "medium": UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        case "heavy": UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
        case "soft": UIImpactFeedbackGenerator(style: .soft).impactOccurred()
        case "rigid": UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
        case "success": UINotificationFeedbackGenerator().notificationOccurred(.success)
        case "warning": UINotificationFeedbackGenerator().notificationOccurred(.warning)
        case "error": UINotificationFeedbackGenerator().notificationOccurred(.error)
        case "selection": UISelectionFeedbackGenerator().selectionChanged()
        default: throw NanocodeError("haptic style is light, medium, heavy, soft, rigid, success, warning, error or selection")
        }
      }
      return .text("Played the \(style) haptic.")
    case "keep_awake":
      let on = input["on"]?.bool ?? true
      await MainActor.run { UIApplication.shared.isIdleTimerDisabled = on }
      return .json(["keep_awake": .bool(on)])
    case "torch":
      guard let torch = AVCaptureDevice.default(for: .video), torch.hasTorch else { throw NanocodeError("this \(DeviceTools.here) has no torch") }
      let on = input["on"]?.bool ?? true
      let level = input["value"]?.number ?? 1
      guard level > 0, level <= 1 else { throw NanocodeError("the torch level is above 0 and at most 1") }
      try torch.lockForConfiguration()
      defer { torch.unlockForConfiguration() }
      if on { try torch.setTorchModeOn(level: Float(level)) } else { torch.torchMode = .off }
      return .json(["torch": .bool(on)])
    default:
      throw unknown("screen", screenActions)
    }
  }
  #endif
}
#endif
