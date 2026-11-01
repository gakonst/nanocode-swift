#if os(iOS) || os(macOS)
import Foundation
import Nanocode
#if os(iOS)
import UIKit
#else
import AppKit
#endif

enum DeviceKit {
  static var tools: [HostTool] {
    #if os(iOS)
    var list = [device, clipboard, screen, shortcut, files, speech, contacts, calendar, reminders, location, geofence, notification, motion, music,
                bluetooth, localNetwork, photoLibrary, wallet]
    if Entitlements.focus { list.append(focus) }
    if Entitlements.health { list.append(health) }
    if Entitlements.home { list.append(home) }
    if Entitlements.nfc { list.append(nfc) }
    return list
    #else
    var list = [device, clipboard, shortcut, files, speech, contacts, calendar, reminders, location, geofence, notification, bluetooth, localNetwork,
                photoLibrary]
    if Entitlements.focus { list.append(focus) }
    return list
    #endif
  }

  static func text(_ input: JSON, _ key: String) -> String? {
    guard let value = input[key]?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
    return value
  }

  static func texts(_ input: JSON, _ key: String) -> [String] {
    if let one = text(input, key) { return [one] }
    return (input[key]?.array ?? []).compactMap { $0.string?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
  }

  static func need(_ input: JSON, _ key: String, for action: String) throws -> String {
    guard let value = text(input, key) else { throw NanocodeError("\(action) takes \(key)") }
    return value
  }

  static func count(_ input: JSON, _ fallback: Int, most: Int, key: String = "limit") throws -> Int {
    guard let value = input[key]?.int else { return fallback }
    guard value >= 1, value <= most else { throw NanocodeError("\(key) must be between 1 and \(most)") }
    return value
  }

  static func unknown(_ tool: String, _ actions: [String]) -> NanocodeError {
    let list = actions.count > 1 ? actions.dropLast().joined(separator: ", ") + " or " + (actions.last ?? "") : actions.joined()
    return NanocodeError("\(tool) takes the action \(list)")
  }

  static func schema(_ actions: [String], _ properties: [String: JSON]) -> JSON {
    var all = properties
    all["action"] = DeviceTools.actions(actions)
    return DeviceTools.schema(all, required: ["action"])
  }

  static func page(_ items: [JSON], _ input: JSON, _ fallback: Int, most: Int) throws -> JSON {
    let limit = try count(input, fallback, most: most)
    let offset = max(input["offset"]?.int ?? 0, 0)
    let slice = offset < items.count ? Array(items[offset..<min(offset + limit, items.count)]) : []
    return ["total": .number(Double(items.count)), "offset": .number(Double(offset)), "items": .array(slice),
            "next_offset": offset + limit < items.count ? .number(Double(offset + limit)) : .null]
  }

  #if os(iOS)
  @MainActor static var active: Bool { UIApplication.shared.applicationState == .active }
  #else
  @MainActor static var active: Bool { NSApp.isActive || NSApp.windows.contains(where: \.isVisible) }
  #endif

  static func foreground(_ what: String) async throws {
    guard await MainActor.run(body: { active }) else {
      throw NanocodeError("\(what) needs \(DeviceTools.settings.app) open on the \(DeviceTools.here); ask the owner to open it, then try again")
    }
  }

  static func number(_ value: Double?) -> JSON { value.map(JSON.number) ?? .null }
  static func number(_ value: Int?) -> JSON { value.map { .number(Double($0)) } ?? .null }
  static func string(_ value: String?) -> JSON { value.map(JSON.string) ?? .null }

  static func prop(_ type: String, _ description: String? = nil) -> JSON {
    var object: [String: JSON] = ["type": .string(type)]
    if let description { object["description"] = .string(description) }
    return .object(object)
  }

  static func choice(_ values: [String], _ description: String? = nil) -> JSON {
    var object: [String: JSON] = ["type": "string", "enum": .array(values.map(JSON.string))]
    if let description { object["description"] = .string(description) }
    return .object(object)
  }

  static func list(_ items: JSON, _ description: String? = nil) -> JSON {
    var object: [String: JSON] = ["type": "array", "items": items]
    if let description { object["description"] = .string(description) }
    return .object(object)
  }

  static func entry(_ keys: [String], _ description: String? = nil) -> JSON {
    var properties: [String: JSON] = [:]
    for key in keys { properties[key] = prop("string") }
    var object: [String: JSON] = ["type": "object", "properties": .object(properties)]
    if let description { object["description"] = .string(description) }
    return .object(object)
  }

  static let when: JSON = .object(["type": .array([.string("string"), .string("number")]),
                                    "description": .string("ISO 8601 date or date-time (the \(DeviceTools.here)'s time zone unless it has an offset), or milliseconds since 1970.")])

  static let pageProperties: [String: JSON] = [
    "limit": prop("integer", "How many to return."),
    "offset": prop("integer", "Skip this many, to page through long answers (next_offset)."),
  ]

  static func paged(_ properties: [String: JSON]) -> [String: JSON] {
    properties.merging(pageProperties) { first, _ in first }
  }
}
#endif
