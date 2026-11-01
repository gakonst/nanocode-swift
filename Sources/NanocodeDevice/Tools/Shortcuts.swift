#if os(iOS) || os(macOS)
import Foundation
import Nanocode
#if os(iOS)
import UIKit
#else
import AppKit
#endif

@MainActor public enum ShortcutCallbacks {
  static var waiting: [String: CheckedContinuation<(status: String, result: String?), Never>] = [:]

  public static func handle(_ url: URL) -> Bool {
    guard url.scheme == DeviceTools.settings.scheme, url.host == "shortcut-result" else { return false }
    let parts = url.pathComponents.filter { $0 != "/" }
    guard let id = parts.first else { return true }
    let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
    let result = items.first { $0.name == "result" }?.value ?? items.first { $0.name == "errorMessage" }?.value
    waiting.removeValue(forKey: id)?.resume(returning: (parts.count > 1 ? parts[1] : "success", result))
    return true
  }

  static func wait(_ id: String, seconds: Double) async -> (status: String, result: String?) {
    await withCheckedContinuation { continuation in
      waiting[id] = continuation
      Task { @MainActor in
        try? await Task.sleep(for: .seconds(seconds))
        waiting.removeValue(forKey: id)?.resume(returning: ("timeout", nil))
      }
    }
  }
}

extension DeviceKit {
  static let shortcutActions = ["run", "open"]

  static let shortcut = HostTool(
    name: "shortcut",
    description: "Runs one of the owner's Shortcuts by name on this \(DeviceTools.here), with optional text input, and waits for its result: Shortcuts runs it and comes back to \(DeviceTools.settings.app) with the shortcut's output (x-callback-url). With wait false it only starts it. open opens the Shortcuts app (to a shortcut's editor when named). It needs \(DeviceTools.settings.app) open, since iOS opens the Shortcuts app to run it.",
    parameters: DeviceTools.schema([
      "action": DeviceTools.actions(shortcutActions),
      "name": prop("string", "The shortcut's name, exactly as in Shortcuts."),
      "input": prop("string", "Text passed to the shortcut as its input."),
      "wait": prop("boolean", "Wait for the result (true by default)."),
      "seconds": prop("number", "How long to wait for the result, 120 by default."),
    ], required: ["name"])
  ) { call in try await runShortcut(call.input) }

  static func runShortcut(_ input: JSON) async throws -> ToolResult {
    let name = try need(input, "name", for: "shortcut")
    try await foreground("Running a shortcut")
    if input["action"]?.string == "open" {
      guard let url = URL(string: "shortcuts://open-shortcut?name=" + escape(name)) else { throw NanocodeError("that name does not make a URL") }
      await DeviceTools.open(url)
      return .text("Opened Shortcuts.")
    }
    let id = UUID().uuidString.lowercased()
    var query = "name=" + escape(name)
    if let text = input["input"]?.string { query += "&input=text&text=" + escape(text) }
    let wait = input["wait"]?.bool ?? true
    if wait {
      for status in ["success", "error", "cancel"] {
        query += "&x-\(status)=" + escape(DeviceTools.settings.scheme + "://shortcut-result/\(id)/\(status)")
      }
    }
    guard let url = URL(string: (wait ? "shortcuts://x-callback-url/run-shortcut?" : "shortcuts://run-shortcut?") + query) else {
      throw NanocodeError("that shortcut name does not make a URL")
    }
    let seconds = input["seconds"]?.number ?? 120
    guard seconds > 0 else { throw NanocodeError("seconds must be positive") }
    #if os(iOS)
    let opened = await MainActor.run { UIApplication.shared.canOpenURL(url) }
    #else
    let opened = NSWorkspace.shared.urlForApplication(toOpen: url) != nil
    #endif
    guard opened else { throw NanocodeError("the Shortcuts app is not installed") }
    guard wait else {
      await DeviceTools.open(url)
      return .text("Started \(name) in Shortcuts.")
    }
    async let answer = ShortcutCallbacks.wait(id, seconds: seconds)
    await DeviceTools.open(url)
    let (status, result) = await answer
    switch status {
    case "success": return .json(["status": "success", "result": string(result)])
    case "error": throw NanocodeError("\(name) failed in Shortcuts\(result.map { ": \($0)" } ?? "")")
    case "cancel": return .json(["status": "cancelled"])
    default: throw NanocodeError("\(name) didn't come back from Shortcuts within \(Int(seconds)) seconds; it may still be running")
    }
  }

  static func escape(_ text: String) -> String {
    var allowed = CharacterSet.alphanumerics
    allowed.insert(charactersIn: "-._~")
    return text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text
  }
}
#endif
