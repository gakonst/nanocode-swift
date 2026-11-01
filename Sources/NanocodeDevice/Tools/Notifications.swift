#if os(iOS) || os(macOS)
import Foundation
import Intents
import Nanocode
import UserNotifications

extension DeviceKit {
  static let notificationActions = ["schedule", "pending", "delivered", "cancel", "cancel_all", "clear", "clear_all", "badge", "settings"]

  static let notificationProperties: [String: JSON] = [
    "title": prop("string"), "subtitle": prop("string"), "body": prop("string"),
    "seconds": prop("number", "For schedule: show it after this many seconds (1 by default)."),
    "at": when,
    "repeat": choice(["none", "hourly", "daily", "weekly", "monthly", "yearly"],
                     "For schedule with at: repeat at the same minute every hour, the same time every day, week, month or year."),
    "every_seconds": prop("number", "For schedule: repeat every this many seconds (at least 60, iOS's minimum)."),
    "time_sensitive": prop("boolean", "For schedule: break through Focus (needs the time-sensitive entitlement)."),
    "sound": prop("boolean", "For schedule: play the default sound (true by default)."),
    "badge": prop("integer", "For schedule: the app badge to set when it shows; for badge: the number (0 clears it)."),
    "thread": prop("string", "For schedule: group notifications with the same thread together."),
    "url": prop("string", "For schedule: a personal:// or https link kept with the notification."),
    "id": prop("string", "For schedule: an id to replace an earlier one. For cancel and clear: one id."),
    "ids": list(prop("string"), "For cancel and clear: several ids."),
  ]

  static let notification = HostTool(
    name: "notification",
    description: "Local notifications on this \(DeviceTools.here). schedule: now, after seconds, at a date, or repeating. pending: scheduled ones not shown yet. delivered: ones in Notification Center. cancel, cancel_all (pending), clear, clear_all (delivered), badge (the app icon number), settings (what the owner allowed).",
    parameters: schema(notificationActions, notificationProperties)
  ) { call in try await remind(call.input) }

  static func remind(_ input: JSON) async throws -> ToolResult {
    let center = UNUserNotificationCenter.current()
    let action = input["action"]?.string
    if action != "settings" { try await DeviceTools.gate("notifications") }
    switch action {
    case "schedule":
      let content = UNMutableNotificationContent()
      content.title = input["title"]?.string ?? DeviceTools.settings.app
      content.subtitle = input["subtitle"]?.string ?? ""
      content.body = input["body"]?.string ?? ""
      if input["sound"]?.bool ?? true { content.sound = .default }
      if let badge = input["badge"]?.int { content.badge = NSNumber(value: badge) }
      if let thread = text(input, "thread") { content.threadIdentifier = thread }
      if let url = text(input, "url") { content.userInfo = ["url": url] }
      if input["time_sensitive"]?.bool == true {
        guard Entitlements.timeSensitive else {
          throw NanocodeError("this app is missing the signed time-sensitive notifications entitlement; rebuild with a supporting provisioning profile, or schedule without time_sensitive")
        }
        content.interruptionLevel = .timeSensitive
      }
      let trigger = try trigger(input)
      let id = text(input, "id") ?? UUID().uuidString
      try await center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
      var result: [String: JSON] = ["id": .string(id), "title": .string(content.title)]
      if let next = (trigger as? UNCalendarNotificationTrigger)?.nextTriggerDate() ?? (trigger as? UNTimeIntervalNotificationTrigger)?.nextTriggerDate() {
        result["next"] = DeviceTools.stamp(next)
      }
      return .json(.object(result))
    case "pending":
      let requests = await center.pendingNotificationRequests()
      return .json(.array(requests.map { request in
        var object = describe(request.content, id: request.identifier)
        if let next = (request.trigger as? UNCalendarNotificationTrigger)?.nextTriggerDate()
          ?? (request.trigger as? UNTimeIntervalNotificationTrigger)?.nextTriggerDate() {
          object["next"] = DeviceTools.stamp(next)
        }
        object["repeats"] = .bool(request.trigger?.repeats ?? false)
        return .object(object)
      }))
    case "delivered":
      let delivered = await center.deliveredNotifications()
      return .json(.array(delivered.map { item in
        var object = describe(item.request.content, id: item.request.identifier)
        object["shown"] = DeviceTools.stamp(item.date)
        return .object(object)
      }))
    case "cancel":
      let ids = texts(input, "ids") + texts(input, "id")
      guard !ids.isEmpty else { throw NanocodeError("cancel takes an id or ids") }
      center.removePendingNotificationRequests(withIdentifiers: ids)
      return .json(["cancelled": .array(ids.map(JSON.string))])
    case "cancel_all":
      let count = await center.pendingNotificationRequests().count
      center.removeAllPendingNotificationRequests()
      return .json(["cancelled": .number(Double(count))])
    case "clear":
      let ids = texts(input, "ids") + texts(input, "id")
      guard !ids.isEmpty else { throw NanocodeError("clear takes an id or ids") }
      center.removeDeliveredNotifications(withIdentifiers: ids)
      return .json(["cleared": .array(ids.map(JSON.string))])
    case "clear_all":
      let count = await center.deliveredNotifications().count
      center.removeAllDeliveredNotifications()
      return .json(["cleared": .number(Double(count))])
    case "badge":
      guard let badge = input["badge"]?.int, badge >= 0 else { throw NanocodeError("badge takes a number, 0 to clear it") }
      try await center.setBadgeCount(badge)
      return .json(["badge": .number(Double(badge))])
    case "settings":
      let settings = await center.notificationSettings()
      func state(_ value: UNNotificationSetting) -> JSON { .string(value == .enabled ? "on" : value == .disabled ? "off" : "not_supported") }
      let authorization = switch settings.authorizationStatus {
      case .authorized: "authorized"
      case .denied: "denied"
      case .provisional: "provisional"
      case .ephemeral: "ephemeral"
      default: "not_asked"
      }
      return .json(["authorization": .string(authorization), "alerts": state(settings.alertSetting), "sounds": state(settings.soundSetting),
                    "badges": state(settings.badgeSetting), "lock_screen": state(settings.lockScreenSetting),
                    "time_sensitive": state(settings.timeSensitiveSetting), "scheduled_summary": state(settings.scheduledDeliverySetting),
                    "time_sensitive_entitlement": .bool(Entitlements.timeSensitive)])
    default:
      throw unknown("notification", notificationActions)
    }
  }

  static func trigger(_ input: JSON) throws -> UNNotificationTrigger? {
    if let every = input["every_seconds"]?.number {
      guard every >= 60 else { throw NanocodeError("iOS repeats notifications at most once a minute; every_seconds must be at least 60") }
      return UNTimeIntervalNotificationTrigger(timeInterval: every, repeats: true)
    }
    if let at = DeviceTools.date(input["at"]) {
      let units: Set<Calendar.Component>
      switch input["repeat"]?.string ?? "none" {
      case "none": units = [.year, .month, .day, .hour, .minute, .second]
      case "hourly": units = [.minute]
      case "daily": units = [.hour, .minute]
      case "weekly": units = [.weekday, .hour, .minute]
      case "monthly": units = [.day, .hour, .minute]
      case "yearly": units = [.month, .day, .hour, .minute]
      default: throw NanocodeError("repeat is none, hourly, daily, weekly, monthly or yearly")
      }
      let repeats = (input["repeat"]?.string ?? "none") != "none"
      if !repeats, at <= Date() { throw NanocodeError("at is in the past; leave it out to show the notification now") }
      return UNCalendarNotificationTrigger(dateMatching: Calendar.current.dateComponents(units, from: at), repeats: repeats)
    }
    let seconds = input["seconds"]?.number ?? 1
    guard seconds > 0 else { throw NanocodeError("seconds must be positive") }
    return UNTimeIntervalNotificationTrigger(timeInterval: seconds, repeats: false)
  }

  static func describe(_ content: UNNotificationContent, id: String) -> [String: JSON] {
    var object: [String: JSON] = ["id": .string(id), "title": .string(content.title), "body": .string(content.body)]
    if !content.subtitle.isEmpty { object["subtitle"] = .string(content.subtitle) }
    if !content.threadIdentifier.isEmpty { object["thread"] = .string(content.threadIdentifier) }
    if let url = content.userInfo["url"] as? String { object["url"] = .string(url) }
    return object
  }

  static let focus = HostTool(
    name: "focus",
    description: "Whether the owner has a Focus on (Do Not Disturb, Sleep, Work…) on this \(DeviceTools.here) right now. iOS shares only on or off, not which Focus.",
    parameters: DeviceTools.schema([:])
  ) { _ in
    try await DeviceTools.gate("focus")
    let status = INFocusStatusCenter.default.focusStatus
    return .json(["focused": status.isFocused.map(JSON.bool) ?? .null, "known": .bool(status.isFocused != nil)])
  }
}
#endif
