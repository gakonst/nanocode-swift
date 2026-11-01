#if os(iOS)
import EventKit
import Foundation
import Nanocode

extension DeviceKit {
  static let calendarActions = ["list", "get", "calendars", "create", "update", "delete", "calendar_create", "calendar_delete"]
  static let reminderActions = ["list", "get", "lists", "add", "update", "complete", "uncomplete", "delete", "list_create", "list_delete"]
  static let maxSpan: TimeInterval = 4 * 366 * 86_400

  static var events: EKEventStore { DeviceTools.events }

  static let recurrenceProperty: JSON = .object([
    "type": "object",
    "description": "Repeat: frequency daily, weekly, monthly or yearly; interval; days (monday…sunday, for weekly); count or until. The string none removes it.",
    "properties": .object(["frequency": choice(["daily", "weekly", "monthly", "yearly"]), "interval": prop("integer"), "count": prop("integer"),
                           "until": prop("string"), "days": list(prop("string"))]),
  ])

  static let calendarProperties: [String: JSON] = [
    "from": when, "to": when,
    "query": prop("string", "For list: only events whose title, location or notes contain it."),
    "calendars": list(prop("string"), "For list: calendar titles or ids; every calendar otherwise."),
    "id": prop("string", "An event id from list (get, update, delete), or a calendar id (calendar_delete)."),
    "occurrence": when,
    "span": choice(["this", "future"], "For update and delete of a repeating event: this occurrence (default) or this and the future ones."),
    "title": prop("string"), "start": when, "end": when, "all_day": prop("boolean"), "location": prop("string"), "notes": prop("string"),
    "url": prop("string"), "time_zone": prop("string", "An IANA time zone such as Europe/Athens; floating for all-day events."),
    "availability": choice(["busy", "free", "tentative", "unavailable"]),
    "alarms": list(prop("number"), "Minutes before the start for each alert; an empty list removes them."),
    "recurrence": recurrenceProperty,
    "calendar": prop("string", "For create: a calendar title or id; the default calendar otherwise."),
    "source": prop("string", "For calendar_create: the account (source) title, such as iCloud; the default calendar's otherwise."),
    "color": prop("string", "For calendar_create: a hex color such as #34C759."),
  ]

  static let reminderProperties: [String: JSON] = [
    "lists": list(prop("string"), "For list: list titles or ids; every list otherwise."),
    "completed": prop("boolean", "For list: completed reminders instead of open ones."),
    "from": when, "to": when,
    "query": prop("string", "For list: only reminders whose title or notes contain it."),
    "id": prop("string", "A reminder id (get, update, complete, uncomplete, delete) or a list id (list_delete)."),
    "title": prop("string"), "notes": prop("string"), "url": prop("string"),
    "due": prop("string", "ISO 8601 date (no time) or date-time; an empty string clears it."),
    "priority": choice(["none", "high", "medium", "low"]),
    "alarms": list(prop("number"), "Minutes before the due time for each alert; an empty list removes them."),
    "recurrence": recurrenceProperty,
    "list": prop("string", "For add: a list title or id; the default list otherwise."),
    "color": prop("string", "For list_create: a hex color."),
  ]

  static let calendar = HostTool(
    name: "calendar",
    description: "Every calendar on this iPhone (all accounts added to iOS). list: events between two dates (the next 7 days by default; at most 4 years at once, EventKit's limit). get, create, update (only the fields given), delete. calendars lists calendars; calendar_create and calendar_delete manage them. EventKit can't invite attendees; it reads them.",
    parameters: schema(calendarActions, paged(calendarProperties))
  ) { call in try await schedule(call.input) }

  static let reminders = HostTool(
    name: "reminders",
    description: "The owner's reminders on this iPhone. list: open reminders (or completed ones), filtered by list, due window and text. get, add, update (only the fields given), complete, uncomplete, delete. lists lists the reminder lists; list_create and list_delete manage them.",
    parameters: schema(reminderActions, paged(reminderProperties))
  ) { call in try await todo(call.input) }

  static func schedule(_ input: JSON) async throws -> ToolResult {
    try await DeviceTools.gate("calendar")
    switch input["action"]?.string {
    case "list":
      let start = DeviceTools.date(input["from"]) ?? Date()
      let end = DeviceTools.date(input["to"]) ?? start.addingTimeInterval(7 * 86_400)
      guard end > start else { throw NanocodeError("to must be after from") }
      guard end.timeIntervalSince(start) <= maxSpan else { throw NanocodeError("EventKit lists at most 4 years at once; split the window") }
      let wanted = texts(input, "calendars")
      let calendars = wanted.isEmpty ? nil : try wanted.map { try findCalendar($0, .event) }
      let query = text(input, "query")?.lowercased()
      let found = events.events(matching: events.predicateForEvents(withStart: start, end: end, calendars: calendars))
        .filter { event in
          guard let query else { return true }
          return [event.title, event.location, event.notes].compactMap { $0?.lowercased() }.contains { $0.contains(query) }
        }
        .sorted { $0.startDate < $1.startDate }
      return .json(try page(found.map(describe), input, 100, most: 5000))
    case "get":
      return .json(describe(try event(input)))
    case "calendars":
      return .json(.array(events.calendars(for: .event).map(describe)))
    case "create":
      guard let title = text(input, "title"), let start = DeviceTools.date(input["start"]) else { throw NanocodeError("create takes a title and a start") }
      let created = EKEvent(eventStore: events)
      created.title = title
      created.startDate = start
      created.isAllDay = input["all_day"]?.bool ?? false
      created.endDate = DeviceTools.date(input["end"]) ?? start.addingTimeInterval(created.isAllDay ? 86_400 : 3_600)
      if let name = text(input, "calendar") {
        created.calendar = try findCalendar(name, .event)
      } else {
        guard let fallback = events.defaultCalendarForNewEvents else { throw NanocodeError("this iPhone has no calendar to add events to") }
        created.calendar = fallback
      }
      try apply(input, to: created)
      guard created.endDate >= created.startDate else { throw NanocodeError("end must not be before start") }
      try events.save(created, span: .thisEvent, commit: true)
      return .json(describe(created))
    case "update":
      let found = try event(input)
      if let title = input["title"]?.string { found.title = title }
      if let start = DeviceTools.date(input["start"]) {
        let length = found.endDate.timeIntervalSince(found.startDate)
        found.startDate = start
        if input["end"] == nil { found.endDate = start.addingTimeInterval(length) }
      }
      if let end = DeviceTools.date(input["end"]) { found.endDate = end }
      if let allDay = input["all_day"]?.bool { found.isAllDay = allDay }
      if let name = text(input, "calendar") { found.calendar = try findCalendar(name, .event) }
      try apply(input, to: found)
      guard found.endDate >= found.startDate else { throw NanocodeError("end must not be before start") }
      try events.save(found, span: span(input), commit: true)
      return .json(describe(found))
    case "delete":
      let found = try event(input)
      let title = found.title ?? ""
      try events.remove(found, span: span(input), commit: true)
      return .json(["deleted": .string(input["id"]?.string ?? ""), "title": .string(title)])
    case "calendar_create":
      let made = EKCalendar(for: .event, eventStore: events)
      made.title = try need(input, "title", for: "calendar_create")
      made.source = try source(input, .event)
      if let color = text(input, "color") { made.cgColor = try cgColor(color) }
      try events.saveCalendar(made, commit: true)
      return .json(describe(made))
    case "calendar_delete":
      let made = try findCalendar(try need(input, "id", for: "calendar_delete"), .event)
      try events.removeCalendar(made, commit: true)
      return .json(["deleted": .string(made.calendarIdentifier), "title": .string(made.title)])
    default:
      throw unknown("calendar", calendarActions)
    }
  }

  static func event(_ input: JSON) throws -> EKEvent {
    let id = try need(input, "id", for: input["action"]?.string ?? "calendar")
    guard let first = events.event(withIdentifier: id) else { throw NanocodeError("no event has the id \(id)") }
    guard let occurrence = DeviceTools.date(input["occurrence"]) else { return first }
    let day = Calendar.current.startOfDay(for: occurrence)
    let matches = events.events(matching: events.predicateForEvents(withStart: day.addingTimeInterval(-86_400), end: day.addingTimeInterval(2 * 86_400),
                                                                     calendars: [first.calendar]))
      .filter { $0.eventIdentifier == id }
    guard let nearest = matches.min(by: { abs($0.startDate.timeIntervalSince(occurrence)) < abs($1.startDate.timeIntervalSince(occurrence)) }) else {
      throw NanocodeError("that event has no occurrence near \(DeviceTools.stamp(occurrence).string ?? "")")
    }
    return nearest
  }

  static func span(_ input: JSON) -> EKSpan { input["span"]?.string == "future" ? .futureEvents : .thisEvent }

  static func apply(_ input: JSON, to event: EKEvent) throws {
    if let location = input["location"]?.string { event.location = location.isEmpty ? nil : location }
    if let notes = input["notes"]?.string { event.notes = notes.isEmpty ? nil : notes }
    if let url = input["url"]?.string { event.url = url.isEmpty ? nil : URL(string: url) }
    if let zone = text(input, "time_zone") {
      guard zone == "floating" || TimeZone(identifier: zone) != nil else { throw NanocodeError("\(zone) is not a time zone") }
      event.timeZone = zone == "floating" ? nil : TimeZone(identifier: zone)
    }
    switch input["availability"]?.string {
    case "busy": event.availability = .busy
    case "free": event.availability = .free
    case "tentative": event.availability = .tentative
    case "unavailable": event.availability = .unavailable
    default: break
    }
    if let alarms = input["alarms"]?.array {
      event.alarms = alarms.compactMap(\.number).map { EKAlarm(relativeOffset: -$0 * 60) }
    }
    if let rule = input["recurrence"] { event.recurrenceRules = try recurrence(rule).map { [$0] } }
  }

  static func recurrence(_ json: JSON) throws -> EKRecurrenceRule? {
    if json.string == "none" || json.isNull { return nil }
    guard let frequency = json["frequency"]?.string else { throw NanocodeError("recurrence takes a frequency, or the string none") }
    let kind: EKRecurrenceFrequency
    switch frequency {
    case "daily": kind = .daily
    case "weekly": kind = .weekly
    case "monthly": kind = .monthly
    case "yearly": kind = .yearly
    default: throw NanocodeError("recurrence frequency is daily, weekly, monthly or yearly")
    }
    let names = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]
    let days = try json["days"]?.array?.map { day -> EKRecurrenceDayOfWeek in
      guard let index = names.firstIndex(of: day.string?.lowercased() ?? ""), let weekday = EKWeekday(rawValue: index + 1) else {
        throw NanocodeError("recurrence days are monday … sunday")
      }
      return EKRecurrenceDayOfWeek(weekday)
    }
    let end: EKRecurrenceEnd? = if let count = json["count"]?.int { EKRecurrenceEnd(occurrenceCount: count) }
      else if let until = DeviceTools.date(json["until"]) { EKRecurrenceEnd(end: until) } else { nil }
    return EKRecurrenceRule(recurrenceWith: kind, interval: max(json["interval"]?.int ?? 1, 1), daysOfTheWeek: days, daysOfTheMonth: nil,
                            monthsOfTheYear: nil, weeksOfTheYear: nil, daysOfTheYear: nil, setPositions: nil, end: end)
  }

  static func describe(_ rule: EKRecurrenceRule) -> JSON {
    let frequency = switch rule.frequency {
    case .daily: "daily"
    case .weekly: "weekly"
    case .monthly: "monthly"
    case .yearly: "yearly"
    @unknown default: "other"
    }
    let names = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]
    var object: [String: JSON] = ["frequency": .string(frequency), "interval": .number(Double(rule.interval))]
    if let days = rule.daysOfTheWeek, !days.isEmpty {
      object["days"] = .array(days.map { .string(names[max(0, min(6, $0.dayOfTheWeek.rawValue - 1))]) })
    }
    if let end = rule.recurrenceEnd {
      if let date = end.endDate { object["until"] = DeviceTools.stamp(date) } else { object["count"] = .number(Double(end.occurrenceCount)) }
    }
    return .object(object)
  }

  static func findCalendar(_ key: String, _ type: EKEntityType) throws -> EKCalendar {
    let all = events.calendars(for: type)
    if let found = all.first(where: { $0.calendarIdentifier == key }) ?? all.first(where: { $0.title.localizedCaseInsensitiveCompare(key) == .orderedSame }) {
      return found
    }
    throw NanocodeError("no \(type == .event ? "calendar" : "reminder list") is called \(key)")
  }

  static func source(_ input: JSON, _ type: EKEntityType) throws -> EKSource {
    if let name = text(input, "source") {
      guard let found = events.sources.first(where: { $0.title.localizedCaseInsensitiveCompare(name) == .orderedSame || $0.sourceIdentifier == name }) else {
        throw NanocodeError("no account is called \(name); these exist: \(events.sources.map(\.title).joined(separator: ", "))")
      }
      return found
    }
    let fallback = type == .event ? events.defaultCalendarForNewEvents : events.defaultCalendarForNewReminders()
    guard let found = fallback?.source else { throw NanocodeError("this iPhone has no account to add it to") }
    return found
  }

  static func cgColor(_ hex: String) throws -> CGColor {
    let digits = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
    guard digits.count == 6, let value = UInt32(digits, radix: 16) else { throw NanocodeError("color takes a hex color such as #34C759") }
    return CGColor(srgbRed: CGFloat((value >> 16) & 0xff) / 255, green: CGFloat((value >> 8) & 0xff) / 255, blue: CGFloat(value & 0xff) / 255, alpha: 1)
  }

  static func describe(_ calendar: EKCalendar) -> JSON {
    ["id": .string(calendar.calendarIdentifier), "title": .string(calendar.title), "source": .string(calendar.source?.title ?? ""),
     "writable": .bool(calendar.allowsContentModifications), "subscribed": .bool(calendar.isSubscribed)]
  }

  static func describe(_ event: EKEvent) -> JSON {
    var object: [String: JSON] = [
      "id": .string(event.eventIdentifier ?? ""), "title": .string(event.title ?? ""), "start": DeviceTools.stamp(event.startDate),
      "end": DeviceTools.stamp(event.endDate), "all_day": .bool(event.isAllDay), "calendar": .string(event.calendar?.title ?? ""),
      "calendar_id": .string(event.calendar?.calendarIdentifier ?? ""),
    ]
    if let location = event.location, !location.isEmpty { object["location"] = .string(location) }
    if let notes = event.notes, !notes.isEmpty { object["notes"] = .string(notes) }
    if let url = event.url { object["url"] = .string(url.absoluteString) }
    if let zone = event.timeZone { object["time_zone"] = .string(zone.identifier) }
    if let rule = event.recurrenceRules?.first { object["recurrence"] = describe(rule) }
    if let alarms = event.alarms, !alarms.isEmpty { object["alarms"] = .array(alarms.map { .number(-$0.relativeOffset / 60) }) }
    if let organizer = event.organizer { object["organizer"] = participant(organizer) }
    if let attendees = event.attendees, !attendees.isEmpty { object["attendees"] = .array(attendees.map(participant)) }
    if let external = event.calendarItemExternalIdentifier { object["external_id"] = .string(external) }
    let availability = switch event.availability {
    case .busy: "busy"
    case .free: "free"
    case .tentative: "tentative"
    case .unavailable: "unavailable"
    default: "not_supported"
    }
    object["availability"] = .string(availability)
    return .object(object)
  }

  static func participant(_ person: EKParticipant) -> JSON {
    let status = switch person.participantStatus {
    case .accepted: "accepted"
    case .declined: "declined"
    case .tentative: "tentative"
    case .pending: "pending"
    case .delegated: "delegated"
    default: "unknown"
    }
    let address = person.url.absoluteString.replacingOccurrences(of: "mailto:", with: "")
    return ["name": .string(person.name ?? ""), "email": .string(address), "status": .string(status), "me": .bool(person.isCurrentUser)]
  }

  static func todo(_ input: JSON) async throws -> ToolResult {
    try await DeviceTools.gate("reminders")
    switch input["action"]?.string {
    case "list":
      let wanted = texts(input, "lists")
      let lists = wanted.isEmpty ? nil : try wanted.map { try findCalendar($0, .reminder) }
      let start = DeviceTools.date(input["from"])
      let end = DeviceTools.date(input["to"])
      let predicate = input["completed"]?.bool == true
        ? events.predicateForCompletedReminders(withCompletionDateStarting: start, ending: end, calendars: lists)
        : events.predicateForIncompleteReminders(withDueDateStarting: start, ending: end, calendars: lists)
      let query = text(input, "query")?.lowercased()
      let found = await fetch(predicate).filter { reminder in
        guard let query else { return true }
        return [reminder.title, reminder.notes].compactMap { $0?.lowercased() }.contains { $0.contains(query) }
      }
      return .json(try page(found.map(describe), input, 100, most: 10_000))
    case "get":
      return .json(describe(try reminder(input)))
    case "lists":
      return .json(.array(events.calendars(for: .reminder).map(describe)))
    case "add":
      guard let title = text(input, "title") else { throw NanocodeError("add takes a title") }
      let made = EKReminder(eventStore: events)
      made.title = title
      if let name = text(input, "list") {
        made.calendar = try findCalendar(name, .reminder)
      } else {
        guard let fallback = events.defaultCalendarForNewReminders() else { throw NanocodeError("this iPhone has no reminder list") }
        made.calendar = fallback
      }
      try apply(input, to: made)
      try events.save(made, commit: true)
      return .json(describe(made))
    case "update":
      let found = try reminder(input)
      if let title = input["title"]?.string { found.title = title }
      if let name = text(input, "list") { found.calendar = try findCalendar(name, .reminder) }
      try apply(input, to: found)
      try events.save(found, commit: true)
      return .json(describe(found))
    case "complete", "uncomplete":
      let found = try reminder(input)
      found.isCompleted = input["action"]?.string == "complete"
      try events.save(found, commit: true)
      return .json(describe(found))
    case "delete":
      let found = try reminder(input)
      let title = found.title ?? ""
      try events.remove(found, commit: true)
      return .json(["deleted": .string(found.calendarItemIdentifier), "title": .string(title)])
    case "list_create":
      let made = EKCalendar(for: .reminder, eventStore: events)
      made.title = try need(input, "title", for: "list_create")
      made.source = try source(input, .reminder)
      if let color = text(input, "color") { made.cgColor = try cgColor(color) }
      try events.saveCalendar(made, commit: true)
      return .json(describe(made))
    case "list_delete":
      let made = try findCalendar(try need(input, "id", for: "list_delete"), .reminder)
      try events.removeCalendar(made, commit: true)
      return .json(["deleted": .string(made.calendarIdentifier), "title": .string(made.title)])
    default:
      throw unknown("reminders", reminderActions)
    }
  }

  static func fetch(_ predicate: NSPredicate) async -> [EKReminder] {
    nonisolated(unsafe) let predicate = predicate
    return await withCheckedContinuation { (continuation: CheckedContinuation<[EKReminder], Never>) in
      _ = events.fetchReminders(matching: predicate) { found in
        nonisolated(unsafe) let found = found ?? []
        continuation.resume(returning: found)
      }
    }
  }

  static func reminder(_ input: JSON) throws -> EKReminder {
    let id = try need(input, "id", for: input["action"]?.string ?? "reminders")
    guard let found = events.calendarItem(withIdentifier: id) as? EKReminder else { throw NanocodeError("no reminder has the id \(id)") }
    return found
  }

  static func apply(_ input: JSON, to reminder: EKReminder) throws {
    if let notes = input["notes"]?.string { reminder.notes = notes.isEmpty ? nil : notes }
    if let url = input["url"]?.string { reminder.url = url.isEmpty ? nil : URL(string: url) }
    if let due = input["due"]?.string {
      if due.isEmpty {
        reminder.dueDateComponents = nil
      } else {
        guard let date = DeviceTools.date(input["due"]) else { throw NanocodeError("due takes an ISO 8601 date or date-time") }
        let dateOnly = due.count <= 10
        reminder.dueDateComponents = Calendar.current.dateComponents(dateOnly ? [.year, .month, .day] : [.year, .month, .day, .hour, .minute], from: date)
        if !dateOnly, input["alarms"] == nil, (reminder.alarms ?? []).isEmpty { reminder.addAlarm(EKAlarm(absoluteDate: date)) }
      }
    }
    switch input["priority"]?.string {
    case "none": reminder.priority = 0
    case "high": reminder.priority = 1
    case "medium": reminder.priority = 5
    case "low": reminder.priority = 9
    default: break
    }
    if let alarms = input["alarms"]?.array {
      let due = reminder.dueDateComponents.flatMap { Calendar.current.date(from: $0) }
      reminder.alarms = try alarms.compactMap(\.number).map { minutes in
        guard let due else { throw NanocodeError("alarms on a reminder need a due date") }
        return EKAlarm(absoluteDate: due.addingTimeInterval(-minutes * 60))
      }
    }
    if let rule = input["recurrence"] { reminder.recurrenceRules = try recurrence(rule).map { [$0] } }
  }

  static func describe(_ reminder: EKReminder) -> JSON {
    var object: [String: JSON] = [
      "id": .string(reminder.calendarItemIdentifier), "title": .string(reminder.title ?? ""),
      "completed": .bool(reminder.isCompleted), "list": .string(reminder.calendar?.title ?? ""),
      "priority": .string(reminder.priority == 0 ? "none" : reminder.priority < 5 ? "high" : reminder.priority == 5 ? "medium" : "low"),
    ]
    if let due = reminder.dueDateComponents.flatMap({ Calendar.current.date(from: $0) }) { object["due"] = DeviceTools.stamp(due) }
    if let done = reminder.completionDate { object["completed_at"] = DeviceTools.stamp(done) }
    if let notes = reminder.notes, !notes.isEmpty { object["notes"] = .string(notes) }
    if let url = reminder.url { object["url"] = .string(url.absoluteString) }
    if let rule = reminder.recurrenceRules?.first { object["recurrence"] = describe(rule) }
    if let alarms = reminder.alarms, !alarms.isEmpty { object["alarms"] = .array(alarms.map { DeviceTools.stamp($0.absoluteDate) }) }
    if let created = reminder.creationDate { object["created"] = DeviceTools.stamp(created) }
    return .object(object)
  }
}
#endif
