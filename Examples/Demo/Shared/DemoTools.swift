import AVFoundation
import Foundation
import NanocodeUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

@MainActor
enum DemoTools {
  static let speaker = AVSpeechSynthesizer()

  static var all: [HostTool] { [device, openURL, clipboard, speak] }

  static let device = HostTool(
    name: "device_info",
    description: "Describes the device this app runs on: platform, OS version, model, locale, time zone, battery and appearance.",
    parameters: ["type": "object", "properties": [:], "additionalProperties": false]
  ) { _ in
    await MainActor.run { .json(describe()) }
  }

  static func describe() -> JSON {
    let info = ProcessInfo.processInfo
    var object: [String: JSON] = [
      "os": .string(info.operatingSystemVersionString),
      "locale": .string(Locale.current.identifier),
      "time_zone": .string(TimeZone.current.identifier),
      "now": .string(Date().formatted(date: .complete, time: .complete)),
      "processors": .number(Double(info.activeProcessorCount)),
      "memory_gb": .number((Double(info.physicalMemory) / 1_073_741_824).rounded()),
    ]
    #if os(macOS)
    object["platform"] = "macOS"
    object["name"] = .string(Host.current().localizedName ?? "Mac")
    object["appearance"] = .string(NSApp.effectiveAppearance.name.rawValue)
    #else
    let device = UIDevice.current
    device.isBatteryMonitoringEnabled = true
    object["platform"] = .string(device.systemName)
    object["model"] = .string(device.model)
    object["name"] = .string(device.name)
    object["battery"] = .number(Double(device.batteryLevel))
    object["appearance"] = .string(UITraitCollection.current.userInterfaceStyle == .dark ? "dark" : "light")
    #endif
    return .object(object)
  }

  static let openURL = HostTool(
    name: "open_url",
    description: "Opens an http or https URL in the user's browser on this device.",
    parameters: [
      "type": "object",
      "properties": ["url": ["type": "string", "description": "The http(s) URL to open."]],
      "required": ["url"], "additionalProperties": false,
    ]
  ) { call in
    guard let text = call.input["url"]?.string, let url = URL(string: text), ["http", "https"].contains(url.scheme ?? "") else {
      throw NanocodeError("open_url takes an http or https URL")
    }
    await MainActor.run {
      #if os(macOS)
      NSWorkspace.shared.open(url)
      #else
      UIApplication.shared.open(url)
      #endif
    }
    return .text("Opened \(url.absoluteString).")
  }

  static let clipboard = HostTool(
    name: "clipboard",
    description: "Reads the clipboard's text, or copies text to it when text is given.",
    parameters: [
      "type": "object",
      "properties": ["text": ["type": "string", "description": "Text to copy. Leave it out to read the clipboard."]],
      "additionalProperties": false,
    ]
  ) { call in
    await MainActor.run {
      #if os(macOS)
      if let text = call.input["text"]?.string {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        return .text("Copied \(text.count) characters.")
      }
      return .text(NSPasteboard.general.string(forType: .string) ?? "")
      #else
      if let text = call.input["text"]?.string {
        UIPasteboard.general.string = text
        return .text("Copied \(text.count) characters.")
      }
      return .text(UIPasteboard.general.string ?? "")
      #endif
    }
  }

  static let speak = HostTool(
    name: "speak",
    description: "Speaks text aloud on this device.",
    parameters: [
      "type": "object",
      "properties": ["text": ["type": "string"], "language": ["type": "string", "description": "A BCP 47 language such as en-US."]],
      "required": ["text"], "additionalProperties": false,
    ]
  ) { call in
    guard let text = call.input["text"]?.string else { throw NanocodeError("speak takes text") }
    let language = call.input["language"]?.string
    await MainActor.run {
      let utterance = AVSpeechUtterance(string: text)
      if let language { utterance.voice = AVSpeechSynthesisVoice(language: language) }
      speaker.speak(utterance)
    }
    return .text("Speaking.")
  }
}
