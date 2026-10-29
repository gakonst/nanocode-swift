import AVFoundation
import Contacts
@preconcurrency import CoreBluetooth
import CoreLocation
import EventKit
import Foundation
import ImageIO
import MapKit
import NanocodeKit
import Photos
import Speech
import UniformTypeIdentifiers
import UserNotifications
import Vision
#if os(macOS)
import AppKit
#else
import CoreMotion
import MediaPlayer
@preconcurrency import MessageUI
import UIKit
import VisionKit
#endif

extension DemoTools {
  static var workspace = FileManager.default.temporaryDirectory

  static var frameworks: [HostTool] {
    #if os(macOS)
    [photos, contacts, calendar, reminders, location, notify, listen, bluetooth, compose, shortcut]
    #else
    [photos, contacts, calendar, reminders, location, notify, listen, bluetooth, compose, shortcut, camera, motion, music]
    #endif
  }

  static func schema(_ properties: [String: JSON], required: [String] = []) -> JSON {
    ["type": "object", "properties": .object(properties), "required": .array(required.map(JSON.string)), "additionalProperties": false]
  }

  static func actions(_ names: [String]) -> JSON {
    ["type": "string", "enum": .array(names.map(JSON.string))]
  }

  nonisolated static func stamp(_ date: Date?) -> JSON {
    guard let date else { return .null }
    return .string(date.formatted(Date.ISO8601FormatStyle(timeZone: .current)))
  }

  static func date(_ value: JSON?) -> Date? {
    guard let text = value?.string?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
    for options: ISO8601DateFormatter.Options in [[.withInternetDateTime, .withFractionalSeconds], [.withInternetDateTime]] {
      let formatter = ISO8601DateFormatter()
      formatter.formatOptions = options
      if let date = formatter.date(from: text) { return date }
    }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = .current
    for format in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm", "yyyy-MM-dd"] {
      formatter.dateFormat = format
      if let date = formatter.date(from: text) { return date }
    }
    return nil
  }

  static func limit(_ input: JSON, _ fallback: Int, most: Int) -> Int {
    min(max(input["limit"]?.int ?? fallback, 1), most)
  }

  static func folder(_ name: String) throws -> URL {
    let url = workspace.appendingPathComponent(name, isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  static func file(_ path: String) -> URL {
    path.hasPrefix("/") ? URL(fileURLWithPath: path) : workspace.appendingPathComponent(path)
  }

  static func name(_ date: Date?, _ index: Int, _ suffix: String) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyyMMdd-HHmmss"
    return formatter.string(from: date ?? Date()) + (index > 0 ? "-\(index)" : "") + "." + suffix
  }

  static func answer(_ value: JSON) -> ToolResult {
    .json(value)
  }

  nonisolated static func jpeg(_ data: Data, longest: Int?) throws -> (data: Data, width: Int, height: Int) {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { throw NanocodeError("the image could not be read") }
    let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
    let width = properties?[kCGImagePropertyPixelWidth] as? Int ?? 0
    let height = properties?[kCGImagePropertyPixelHeight] as? Int ?? 0
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceThumbnailMaxPixelSize: longest.map { min($0, max(width, height, 1)) } ?? max(width, height, 1),
    ]
    guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { throw NanocodeError("the image could not be decoded") }
    let output = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else {
      throw NanocodeError("the image could not be encoded")
    }
    CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
    guard CGImageDestinationFinalize(destination) else { throw NanocodeError("the image could not be encoded") }
    return (output as Data, image.width, image.height)
  }

  nonisolated static func recognize(_ data: Data) -> String {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return "" }
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = true
    try? VNImageRequestHandler(cgImage: image).perform([request])
    return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
  }

  static func image(_ data: Data, description: JSON) throws -> ToolResult {
    let preview = try jpeg(data, longest: 1568)
    return .content([.text(description.text(pretty: true)), .image(dataURL: "data:image/jpeg;base64," + preview.data.base64EncodedString())],
                    structured: description)
  }

  static let photos = HostTool(
    name: "photos",
    description: "The photo library on this device. list: recent photos and videos, newest first. view: look at one photo. save: write photos into the workspace as JPEG files under photos/. text: read the text in a photo or an image file. add: save an image file from the workspace to the library.",
    parameters: schema([
      "action": actions(["list", "view", "save", "text", "add"]),
      "limit": ["type": "integer", "description": "For list: how many, 20 by default and at most 200."],
      "since": ["type": "string", "description": "For list: an ISO 8601 date; only items taken after it."],
      "until": ["type": "string", "description": "For list: an ISO 8601 date; only items taken before it."],
      "media": ["type": "string", "enum": ["image", "video", "any"]],
      "favorites": ["type": "boolean", "description": "For list: only favorites."],
      "ids": ["type": "array", "items": ["type": "string"], "description": "Ids from list, for view, save and text."],
      "path": ["type": "string", "description": "For add and text: an image file, absolute or relative to the workspace."],
    ], required: ["action"]),
    content: true
  ) { call in try await DemoTools.photoLibrary(call.input) }

  static func photoLibrary(_ input: JSON) async throws -> ToolResult {
    let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
    guard status == .authorized || status == .limited else { throw NanocodeError("photo library access is off for this app; turn it on in Settings") }
    let ids = input["ids"]?.array?.compactMap(\.string) ?? []
    switch input["action"]?.string {
    case "list":
      let options = PHFetchOptions()
      options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
      options.fetchLimit = limit(input, 20, most: 200)
      var predicates: [NSPredicate] = []
      switch input["media"]?.string {
      case "image": predicates.append(NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue))
      case "video": predicates.append(NSPredicate(format: "mediaType == %d", PHAssetMediaType.video.rawValue))
      default: break
      }
      if let since = date(input["since"]) { predicates.append(NSPredicate(format: "creationDate > %@", since as NSDate)) }
      if let until = date(input["until"]) { predicates.append(NSPredicate(format: "creationDate < %@", until as NSDate)) }
      if input["favorites"]?.bool == true { predicates.append(NSPredicate(format: "favorite == YES")) }
      if !predicates.isEmpty { options.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: predicates) }
      let assets = PHAsset.fetchAssets(with: options)
      return answer(.array((0..<assets.count).map { describe(assets.object(at: $0)) }))
    case "view":
      guard let id = ids.first, let asset = asset(id) else { throw NanocodeError("view takes the id of a photo from list") }
      return try image(try await photoData(asset), description: describe(asset))
    case "save":
      let directory = try folder("photos")
      var saved: [JSON] = []
      for (index, id) in ids.enumerated() {
        guard let asset = asset(id), asset.mediaType == .image else { continue }
        let photo = try jpeg(try await photoData(asset), longest: nil)
        let url = directory.appendingPathComponent(name(asset.creationDate, ids.count > 1 ? index + 1 : 0, "jpg"))
        try photo.data.write(to: url)
        saved.append(["id": .string(id), "path": .string(url.path), "width": .number(Double(photo.width)), "height": .number(Double(photo.height))])
      }
      guard !saved.isEmpty else { throw NanocodeError("save takes the ids of photos from list") }
      return answer(.array(saved))
    case "text":
      let data: Data
      if let path = input["path"]?.string {
        data = try Data(contentsOf: file(path))
      } else if let id = ids.first, let asset = asset(id) {
        data = try await photoData(asset)
      } else {
        throw NanocodeError("text takes a photo id or an image path")
      }
      let text = await Task.detached { recognize(data) }.value
      return answer(["text": .string(text)])
    case "add":
      guard let path = input["path"]?.string else { throw NanocodeError("add takes the path of an image file") }
      let url = file(path)
      guard FileManager.default.fileExists(atPath: url.path) else { throw NanocodeError("\(url.path) does not exist") }
      try await keep(url)
      return answer(["added": .string(url.path)])
    default:
      throw NanocodeError("photos takes the action list, view, save, text or add")
    }
  }

  nonisolated static func keep(_ url: URL) async throws {
    try await PHPhotoLibrary.shared().performChanges { _ = PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: url) }
  }

  static func asset(_ id: String) -> PHAsset? {
    PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject
  }

  static func describe(_ asset: PHAsset) -> JSON {
    var object: [String: JSON] = [
      "id": .string(asset.localIdentifier),
      "date": stamp(asset.creationDate),
      "media": .string(asset.mediaType == .video ? "video" : asset.mediaType == .image ? "image" : "other"),
      "width": .number(Double(asset.pixelWidth)),
      "height": .number(Double(asset.pixelHeight)),
      "favorite": .bool(asset.isFavorite),
    ]
    if asset.mediaType == .video { object["seconds"] = .number(asset.duration.rounded()) }
    if let location = asset.location {
      object["latitude"] = .number(location.coordinate.latitude)
      object["longitude"] = .number(location.coordinate.longitude)
    }
    return .object(object)
  }

  static func photoData(_ asset: PHAsset) async throws -> Data {
    try await withCheckedThrowingContinuation { continuation in request(asset, continuation) }
  }

  nonisolated static func request(_ asset: PHAsset, _ continuation: CheckedContinuation<Data, Error>) {
    let options = PHImageRequestOptions()
    options.isNetworkAccessAllowed = true
    options.deliveryMode = .highQualityFormat
    options.version = .current
    PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) { data, _, _, info in
      if let data {
        continuation.resume(returning: data)
      } else {
        let error = info?[PHImageErrorKey] as? Error
        continuation.resume(throwing: NanocodeError("the photo could not be loaded\(error.map { ": \($0.localizedDescription)" } ?? "")"))
      }
    }
  }

  static let contactKeys: [CNKeyDescriptor] = [
    CNContactGivenNameKey, CNContactFamilyNameKey, CNContactOrganizationNameKey, CNContactJobTitleKey, CNContactPhoneNumbersKey,
    CNContactEmailAddressesKey, CNContactPostalAddressesKey, CNContactBirthdayKey,
  ] as [CNKeyDescriptor] + [CNContactFormatter.descriptorForRequiredKeys(for: .fullName), CNContactVCardSerialization.descriptorForRequiredKeys()]

  static let contacts = HostTool(
    name: "contacts",
    description: "The user's contacts on this device. search: people whose name matches a query. list: contacts in the user's order. create: add a contact. export: write the matching contacts into the workspace as a .vcf file under contacts/.",
    parameters: schema([
      "action": actions(["search", "list", "create", "export"]),
      "query": ["type": "string", "description": "For search and export: part of a name."],
      "limit": ["type": "integer", "description": "For search and list: 20 by default, at most 500."],
      "given_name": ["type": "string"],
      "family_name": ["type": "string"],
      "organization": ["type": "string"],
      "phones": ["type": "array", "items": ["type": "string"]],
      "emails": ["type": "array", "items": ["type": "string"]],
    ], required: ["action"])
  ) { call in try await DemoTools.addressBook(call.input) }

  static func addressBook(_ input: JSON) async throws -> ToolResult {
    let store = CNContactStore()
    guard try await store.requestAccess(for: .contacts) else { throw NanocodeError("contacts access is off for this app; turn it on in Settings") }
    let count = limit(input, 20, most: 500)
    switch input["action"]?.string {
    case "search", "export":
      guard let query = input["query"]?.string, !query.isEmpty else { throw NanocodeError("\(input["action"]?.string ?? "search") takes a query") }
      let found = try store.unifiedContacts(matching: CNContact.predicateForContacts(matchingName: query), keysToFetch: contactKeys)
      if input["action"]?.string == "search" { return answer(.array(found.prefix(count).map(describe))) }
      guard !found.isEmpty else { throw NanocodeError("no contact matches \(query)") }
      let url = try folder("contacts").appendingPathComponent(query.replacingOccurrences(of: "/", with: "-") + ".vcf")
      try CNContactVCardSerialization.data(with: found).write(to: url)
      return answer(["path": .string(url.path), "contacts": .number(Double(found.count))])
    case "list":
      let request = CNContactFetchRequest(keysToFetch: contactKeys)
      request.sortOrder = .userDefault
      var found: [JSON] = []
      try store.enumerateContacts(with: request) { contact, stop in
        found.append(describe(contact))
        if found.count >= count { stop.pointee = true }
      }
      return answer(.array(found))
    case "create":
      let contact = CNMutableContact()
      contact.givenName = input["given_name"]?.string ?? ""
      contact.familyName = input["family_name"]?.string ?? ""
      contact.organizationName = input["organization"]?.string ?? ""
      contact.phoneNumbers = (input["phones"]?.array ?? []).compactMap(\.string).map {
        CNLabeledValue(label: CNLabelPhoneNumberMobile, value: CNPhoneNumber(stringValue: $0))
      }
      contact.emailAddresses = (input["emails"]?.array ?? []).compactMap(\.string).map { CNLabeledValue(label: CNLabelHome, value: $0 as NSString) }
      guard !(contact.givenName + contact.familyName + contact.organizationName).isEmpty else { throw NanocodeError("create takes a name or an organization") }
      let request = CNSaveRequest()
      request.add(contact, toContainerWithIdentifier: nil)
      try store.execute(request)
      return answer(describe(contact))
    default:
      throw NanocodeError("contacts takes the action search, list, create or export")
    }
  }

  static func describe(_ contact: CNContact) -> JSON {
    var object: [String: JSON] = [
      "id": .string(contact.identifier),
      "name": .string(CNContactFormatter.string(from: contact, style: .fullName) ?? ""),
      "phones": .array(contact.phoneNumbers.map {
        ["label": .string(CNLabeledValue<CNPhoneNumber>.localizedString(forLabel: $0.label ?? "")), "number": .string($0.value.stringValue)]
      }),
      "emails": .array(contact.emailAddresses.map {
        ["label": .string(CNLabeledValue<NSString>.localizedString(forLabel: $0.label ?? "")), "address": .string($0.value as String)]
      }),
    ]
    if !contact.organizationName.isEmpty { object["organization"] = .string(contact.organizationName) }
    if !contact.jobTitle.isEmpty { object["job_title"] = .string(contact.jobTitle) }
    if let address = contact.postalAddresses.first {
      object["address"] = .string(CNPostalAddressFormatter.string(from: address.value, style: .mailingAddress).replacingOccurrences(of: "\n", with: ", "))
    }
    if let birthday = contact.birthday, let month = birthday.month, let day = birthday.day {
      object["birthday"] = .string(birthday.year.map { String(format: "%04d-%02d-%02d", $0, month, day) } ?? String(format: "--%02d-%02d", month, day))
    }
    return .object(object)
  }

  static let events = EKEventStore()

  static let calendar = HostTool(
    name: "calendar",
    description: "The user's calendars on this device. list: events between two dates, the next 7 days by default. calendars: the calendars. create: add an event.",
    parameters: schema([
      "action": actions(["list", "calendars", "create"]),
      "from": ["type": "string", "description": "ISO 8601 date or date-time; now by default."],
      "to": ["type": "string", "description": "ISO 8601 date or date-time; 7 days after from by default."],
      "query": ["type": "string", "description": "For list: only events whose title contains it."],
      "limit": ["type": "integer", "description": "For list: 50 by default, at most 500."],
      "title": ["type": "string"],
      "start": ["type": "string", "description": "For create: ISO 8601 date-time, or a date with all_day."],
      "end": ["type": "string", "description": "For create: ISO 8601 date-time; an hour after start by default."],
      "all_day": ["type": "boolean"],
      "location": ["type": "string"],
      "notes": ["type": "string"],
      "calendar": ["type": "string", "description": "For create: a calendar's title; the default calendar otherwise."],
    ], required: ["action"])
  ) { call in try await DemoTools.schedule(call.input) }

  static func schedule(_ input: JSON) async throws -> ToolResult {
    guard try await events.requestFullAccessToEvents() else { throw NanocodeError("calendar access is off for this app; turn it on in Settings") }
    switch input["action"]?.string {
    case "list":
      let start = date(input["from"]) ?? Date()
      let end = date(input["to"]) ?? start.addingTimeInterval(7 * 86_400)
      let query = input["query"]?.string?.lowercased()
      let found = events.events(matching: events.predicateForEvents(withStart: start, end: end, calendars: nil))
        .filter { query == nil || ($0.title ?? "").lowercased().contains(query ?? "") }
        .sorted { $0.startDate < $1.startDate }
      return answer(.array(found.prefix(limit(input, 50, most: 500)).map(describe)))
    case "calendars":
      return answer(.array(events.calendars(for: .event).map {
        ["id": .string($0.calendarIdentifier), "title": .string($0.title), "source": .string($0.source?.title ?? ""), "writable": .bool($0.allowsContentModifications)]
      }))
    case "create":
      guard let title = input["title"]?.string, let start = date(input["start"]) else { throw NanocodeError("create takes a title and a start") }
      let event = EKEvent(eventStore: events)
      event.title = title
      event.startDate = start
      event.isAllDay = input["all_day"]?.bool ?? false
      event.endDate = date(input["end"]) ?? start.addingTimeInterval(event.isAllDay ? 86_400 : 3_600)
      event.location = input["location"]?.string
      event.notes = input["notes"]?.string
      let named = input["calendar"]?.string.flatMap { name in events.calendars(for: .event).first { $0.title == name } }
      guard let target = named ?? events.defaultCalendarForNewEvents else { throw NanocodeError("this device has no calendar to add events to") }
      event.calendar = target
      try events.save(event, span: .thisEvent)
      return answer(describe(event))
    default:
      throw NanocodeError("calendar takes the action list, calendars or create")
    }
  }

  static func describe(_ event: EKEvent) -> JSON {
    var object: [String: JSON] = [
      "id": .string(event.eventIdentifier ?? ""),
      "title": .string(event.title ?? ""),
      "start": stamp(event.startDate),
      "end": stamp(event.endDate),
      "all_day": .bool(event.isAllDay),
      "calendar": .string(event.calendar?.title ?? ""),
    ]
    if let location = event.location, !location.isEmpty { object["location"] = .string(location) }
    if let notes = event.notes, !notes.isEmpty { object["notes"] = .string(String(notes.prefix(500))) }
    return .object(object)
  }

  static let reminders = HostTool(
    name: "reminders",
    description: "The user's reminders on this device. list: open reminders, or all with completed. lists: the reminder lists. add: create a reminder. complete: mark one done.",
    parameters: schema([
      "action": actions(["list", "lists", "add", "complete"]),
      "completed": ["type": "boolean", "description": "For list: include completed reminders."],
      "limit": ["type": "integer", "description": "For list: 50 by default, at most 500."],
      "title": ["type": "string"],
      "due": ["type": "string", "description": "For add: ISO 8601 date or date-time."],
      "notes": ["type": "string"],
      "list": ["type": "string", "description": "For add: a list's title; the default list otherwise."],
      "id": ["type": "string", "description": "For complete: the reminder's id from list."],
    ], required: ["action"])
  ) { call in try await DemoTools.todo(call.input) }

  static func todo(_ input: JSON) async throws -> ToolResult {
    guard try await events.requestFullAccessToReminders() else { throw NanocodeError("reminders access is off for this app; turn it on in Settings") }
    switch input["action"]?.string {
    case "list":
      let predicate = input["completed"]?.bool == true
        ? events.predicateForReminders(in: nil)
        : events.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: nil)
      let count = limit(input, 50, most: 500)
      let found = await withCheckedContinuation { continuation in fetch(events, predicate, count, continuation) }
      return answer(.array(found))
    case "lists":
      return answer(.array(events.calendars(for: .reminder).map { ["id": .string($0.calendarIdentifier), "title": .string($0.title)] }))
    case "add":
      guard let title = input["title"]?.string else { throw NanocodeError("add takes a title") }
      let reminder = EKReminder(eventStore: events)
      reminder.title = title
      reminder.notes = input["notes"]?.string
      if let due = date(input["due"]) {
        let dateOnly = (input["due"]?.string?.count ?? 0) <= 10
        reminder.dueDateComponents = Calendar.current.dateComponents(dateOnly ? [.year, .month, .day] : [.year, .month, .day, .hour, .minute], from: due)
        if !dateOnly { reminder.addAlarm(EKAlarm(absoluteDate: due)) }
      }
      let named = input["list"]?.string.flatMap { name in events.calendars(for: .reminder).first { $0.title == name } }
      guard let target = named ?? events.defaultCalendarForNewReminders() else { throw NanocodeError("this device has no reminder list") }
      reminder.calendar = target
      try events.save(reminder, commit: true)
      return answer(describe(reminder))
    case "complete":
      guard let id = input["id"]?.string, let reminder = events.calendarItem(withIdentifier: id) as? EKReminder else {
        throw NanocodeError("complete takes the id of a reminder from list")
      }
      reminder.isCompleted = true
      try events.save(reminder, commit: true)
      return answer(describe(reminder))
    default:
      throw NanocodeError("reminders takes the action list, lists, add or complete")
    }
  }

  nonisolated static func fetch(_ store: EKEventStore, _ predicate: NSPredicate, _ count: Int, _ continuation: CheckedContinuation<[JSON], Never>) {
    _ = store.fetchReminders(matching: predicate) { found in
      continuation.resume(returning: (found ?? []).prefix(count).map(describe))
    }
  }

  nonisolated static func describe(_ reminder: EKReminder) -> JSON {
    var object: [String: JSON] = [
      "id": .string(reminder.calendarItemIdentifier),
      "title": .string(reminder.title ?? ""),
      "completed": .bool(reminder.isCompleted),
      "list": .string(reminder.calendar?.title ?? ""),
    ]
    if let due = reminder.dueDateComponents.flatMap({ Calendar.current.date(from: $0) }) { object["due"] = stamp(due) }
    if let notes = reminder.notes, !notes.isEmpty { object["notes"] = .string(String(notes.prefix(500))) }
    return .object(object)
  }

  static let locator = CLLocationManager()

  static let location = HostTool(
    name: "location",
    description: "Where this device is. current: coordinates, accuracy and the address there. search: places that match a query near the device, such as coffee or a pharmacy, from Apple Maps.",
    parameters: schema([
      "action": actions(["current", "search"]),
      "query": ["type": "string", "description": "For search: what to look for."],
      "radius_km": ["type": "number", "description": "For search: how far around the device, 5 by default."],
      "limit": ["type": "integer", "description": "For search: 10 by default, at most 25."],
    ], required: ["action"])
  ) { call in try await DemoTools.whereabouts(call.input) }

  static func whereabouts(_ input: JSON) async throws -> ToolResult {
    let here = try await position()
    switch input["action"]?.string {
    case "current":
      var object: [String: JSON] = [
        "latitude": .number(here.coordinate.latitude), "longitude": .number(here.coordinate.longitude),
        "accuracy_m": .number(here.horizontalAccuracy.rounded()), "altitude_m": .number(here.altitude.rounded()), "time": stamp(here.timestamp),
      ]
      if let place = try? await CLGeocoder().reverseGeocodeLocation(here).first {
        object["address"] = .string([place.name, place.locality, place.administrativeArea, place.postalCode, place.country].compactMap { $0 }.joined(separator: ", "))
      }
      return answer(.object(object))
    case "search":
      guard let query = input["query"]?.string, !query.isEmpty else { throw NanocodeError("search takes a query") }
      let radius = (input["radius_km"]?.number ?? 5) * 1000
      let request = MKLocalSearch.Request()
      request.naturalLanguageQuery = query
      request.region = MKCoordinateRegion(center: here.coordinate, latitudinalMeters: radius * 2, longitudinalMeters: radius * 2)
      let response = try await MKLocalSearch(request: request).start()
      let places: [JSON] = response.mapItems.prefix(limit(input, 10, most: 25)).map { item in
        let spot = CLLocation(latitude: item.placemark.coordinate.latitude, longitude: item.placemark.coordinate.longitude)
        var object: [String: JSON] = [
          "name": .string(item.name ?? ""), "address": .string(item.placemark.title ?? ""),
          "latitude": .number(item.placemark.coordinate.latitude), "longitude": .number(item.placemark.coordinate.longitude),
          "distance_m": .number(spot.distance(from: here).rounded()),
        ]
        if let phone = item.phoneNumber { object["phone"] = .string(phone) }
        if let url = item.url { object["url"] = .string(url.absoluteString) }
        return .object(object)
      }
      return answer(.array(places))
    default:
      throw NanocodeError("location takes the action current or search")
    }
  }

  static func position() async throws -> CLLocation {
    if locator.authorizationStatus == .notDetermined {
      locator.requestWhenInUseAuthorization()
      for _ in 0..<600 where locator.authorizationStatus == .notDetermined { try await Task.sleep(nanoseconds: 100_000_000) }
    }
    guard ![.notDetermined, .denied, .restricted].contains(locator.authorizationStatus) else {
      throw NanocodeError("location access is off for this app; turn it on in Settings")
    }
    let fix = try await withThrowingTaskGroup(of: CLLocation?.self) { group in
      group.addTask {
        for try await update in CLLocationUpdate.liveUpdates() {
          if let location = update.location, location.horizontalAccuracy >= 0, location.horizontalAccuracy < 1000 { return location }
        }
        return nil
      }
      group.addTask {
        try await Task.sleep(nanoseconds: 20_000_000_000)
        return nil
      }
      let first = try await group.next() ?? nil
      group.cancelAll()
      return first
    }
    guard let fix else { throw NanocodeError("this device did not find its location within 20 seconds") }
    return fix
  }

  final class Presenter: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
      [.banner, .list, .sound]
    }
  }

  static let presenter = Presenter()

  static func allowNotifications() async throws -> Bool {
    let center = UNUserNotificationCenter.current()
    center.delegate = presenter
    return try await center.requestAuthorization(options: [.alert, .sound, .badge])
  }

  static let notify = HostTool(
    name: "notify",
    description: "Local notifications on this device. schedule: show one now, after some seconds or at a date. pending: the ones not shown yet. cancel: remove one by id.",
    parameters: schema([
      "action": actions(["schedule", "pending", "cancel"]),
      "title": ["type": "string"],
      "body": ["type": "string"],
      "seconds": ["type": "number", "description": "For schedule: delay in seconds, 1 by default."],
      "at": ["type": "string", "description": "For schedule: an ISO 8601 date-time instead of seconds."],
      "id": ["type": "string", "description": "For cancel: the id that schedule returned."],
    ], required: ["action"])
  ) { call in try await DemoTools.notification(call.input) }

  static func notification(_ input: JSON) async throws -> ToolResult {
    guard try await allowNotifications() else { throw NanocodeError("notifications are off for this app; turn them on in Settings") }
    let center = UNUserNotificationCenter.current()
    switch input["action"]?.string {
    case "schedule":
      let content = UNMutableNotificationContent()
      content.title = input["title"]?.string ?? "Nanocode"
      content.body = input["body"]?.string ?? ""
      content.sound = .default
      let trigger: UNNotificationTrigger
      if let at = date(input["at"]) {
        trigger = UNCalendarNotificationTrigger(dateMatching: Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: at), repeats: false)
      } else {
        trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(input["seconds"]?.number ?? 1, 1), repeats: false)
      }
      let id = UUID().uuidString
      try await center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
      return answer(["id": .string(id), "title": .string(content.title)])
    case "pending":
      let requests = await center.pendingNotificationRequests()
      return answer(.array(requests.map { ["id": .string($0.identifier), "title": .string($0.content.title), "body": .string($0.content.body)] }))
    case "cancel":
      guard let id = input["id"]?.string else { throw NanocodeError("cancel takes an id") }
      center.removePendingNotificationRequests(withIdentifiers: [id])
      return answer(["cancelled": .string(id)])
    default:
      throw NanocodeError("notify takes the action schedule, pending or cancel")
    }
  }

  static func turnFinished(_ text: String) async {
    let center = UNUserNotificationCenter.current()
    guard await center.notificationSettings().authorizationStatus == .authorized else { return }
    let content = UNMutableNotificationContent()
    content.title = "Nanocode"
    content.body = text.isEmpty ? "Your answer is ready." : String(text.prefix(180))
    try? await center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
  }

  static let listen = HostTool(
    name: "listen",
    description: "Records the microphone on this device for some seconds, saves the recording in the workspace under audio/, and returns what was said.",
    parameters: schema([
      "seconds": ["type": "number", "description": "How long to record, 5 by default and at most 60."],
      "language": ["type": "string", "description": "A BCP 47 language such as en-US; the device's by default."],
    ])
  ) { call in try await DemoTools.hear(call.input) }

  static func hear(_ input: JSON) async throws -> ToolResult {
    guard await speechAccess() else { throw NanocodeError("speech recognition is off for this app; turn it on in Settings") }
    guard await AVCaptureDevice.requestAccess(for: .audio) else { throw NanocodeError("microphone access is off for this app; turn it on in Settings") }
    let url = try folder("audio").appendingPathComponent(name(Date(), 0, "caf"))
    let recorder = try Recorder(language: input["language"]?.string)
    let text = try await recorder.run(seconds: min(max(input["seconds"]?.number ?? 5, 1), 60), url: url)
    return answer(["text": .string(text), "path": .string(url.path)])
  }

  nonisolated static func speechAccess() async -> Bool {
    await withCheckedContinuation { continuation in
      SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) }
    }
  }

  final class Recorder: @unchecked Sendable {
    let engine = AVAudioEngine()
    let request = SFSpeechAudioBufferRecognitionRequest()
    let recognizer: SFSpeechRecognizer
    let lock = NSLock()
    var file: AVAudioFile?
    var task: SFSpeechRecognitionTask?
    var heard = ""
    var outcome: Result<String, Error>?
    var waiter: CheckedContinuation<String, Error>?

    init(language: String?) throws {
      guard let recognizer = language.map({ SFSpeechRecognizer(locale: Locale(identifier: $0)) }) ?? SFSpeechRecognizer(), recognizer.isAvailable else {
        throw NanocodeError("speech recognition is not available for this language right now")
      }
      self.recognizer = recognizer
    }

    func run(seconds: Double, url: URL) async throws -> String {
      #if os(iOS)
      let session = AVAudioSession.sharedInstance()
      try session.setCategory(.record, mode: .measurement, options: .duckOthers)
      try session.setActive(true, options: .notifyOthersOnDeactivation)
      defer { try? session.setActive(false, options: .notifyOthersOnDeactivation) }
      #endif
      let input = engine.inputNode
      let format = input.outputFormat(forBus: 0)
      file = try AVAudioFile(forWriting: url, settings: format.settings)
      request.shouldReportPartialResults = true
      request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
      task = recognizer.recognitionTask(with: request) { [self] result, error in
        if let result {
          lock.withLock { heard = result.bestTranscription.formattedString }
          if result.isFinal { finish(.success(result.bestTranscription.formattedString)) }
        } else if let error {
          finish(lock.withLock { heard.isEmpty } ? .failure(error) : .success(lock.withLock { heard }))
        }
      }
      input.installTap(onBus: 0, bufferSize: 4096, format: format) { [self] buffer, _ in
        request.append(buffer)
        try? file?.write(from: buffer)
      }
      engine.prepare()
      try engine.start()
      try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
      engine.stop()
      input.removeTap(onBus: 0)
      request.endAudio()
      Task { [self] in
        try? await Task.sleep(nanoseconds: 5_000_000_000)
        finish(.success(lock.withLock { heard }))
      }
      let text = try await withCheckedThrowingContinuation { continuation in
        lock.lock()
        if let outcome {
          lock.unlock()
          continuation.resume(with: outcome)
        } else {
          waiter = continuation
          lock.unlock()
        }
      }
      task?.cancel()
      file = nil
      return text
    }

    func finish(_ result: Result<String, Error>) {
      lock.lock()
      guard outcome == nil else {
        lock.unlock()
        return
      }
      outcome = result
      let waiter = self.waiter
      self.waiter = nil
      lock.unlock()
      waiter?.resume(with: result)
    }
  }

  @MainActor final class Scanner: NSObject, @preconcurrency CBCentralManagerDelegate {
    var manager: CBCentralManager?
    var ready: CheckedContinuation<CBManagerState, Never>?
    var found: [UUID: (name: String, rssi: Int, connectable: Bool)] = [:]

    func scan(seconds: Double) async throws -> [JSON] {
      let state = await withCheckedContinuation { continuation in
        ready = continuation
        manager = CBCentralManager(delegate: self, queue: .main)
      }
      guard let manager, state == .poweredOn else {
        throw NanocodeError(state == .unauthorized ? "Bluetooth access is off for this app; turn it on in Settings" : "Bluetooth is off or unavailable")
      }
      manager.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
      try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
      manager.stopScan()
      return found.sorted { $0.value.rssi > $1.value.rssi }.map {
        ["id": .string($0.key.uuidString), "name": .string($0.value.name), "rssi": .number(Double($0.value.rssi)), "connectable": .bool($0.value.connectable)]
      }
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
      guard central.state != .unknown, central.state != .resetting else { return }
      ready?.resume(returning: central.state)
      ready = nil
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
      let name = peripheral.name ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? ""
      found[peripheral.identifier] = (name, RSSI.intValue, advertisementData[CBAdvertisementDataIsConnectable] as? Bool ?? false)
    }
  }

  static let bluetooth = HostTool(
    name: "bluetooth",
    description: "Scans for Bluetooth Low Energy devices near this device for some seconds and lists them with their signal strength.",
    parameters: schema(["seconds": ["type": "number", "description": "How long to scan, 5 by default and at most 30."]])
  ) { call in try await DemoTools.nearby(call.input) }

  static func nearby(_ input: JSON) async throws -> ToolResult {
    answer(.array(try await Scanner().scan(seconds: min(max(input["seconds"]?.number ?? 5, 1), 30))))
  }

  static let compose = HostTool(
    name: "compose",
    description: "Opens a prefilled text message or email on this device for the user to review and send; it does not send anything itself. Email can attach files from the workspace.",
    parameters: schema([
      "kind": ["type": "string", "enum": ["message", "email"]],
      "to": ["type": "array", "items": ["type": "string"], "description": "Phone numbers or email addresses."],
      "subject": ["type": "string"],
      "body": ["type": "string"],
      "attachments": ["type": "array", "items": ["type": "string"], "description": "For email: files, absolute or relative to the workspace."],
    ], required: ["kind"])
  ) { call in try await DemoTools.draft(call.input) }

  static let shortcut = HostTool(
    name: "shortcut",
    description: "Runs one of the user's Shortcuts by name, with optional text input, by opening the Shortcuts app.",
    parameters: schema(["name": ["type": "string"], "input": ["type": "string"]], required: ["name"])
  ) { call in
    guard let name = call.input["name"]?.string else { throw NanocodeError("shortcut takes a name") }
    var parts = URLComponents(string: "shortcuts://run-shortcut")
    parts?.queryItems = [URLQueryItem(name: "name", value: name)]
    if let input = call.input["input"]?.string { parts?.queryItems? += [URLQueryItem(name: "input", value: "text"), URLQueryItem(name: "text", value: input)] }
    guard let url = parts?.url else { throw NanocodeError("that shortcut name does not make a URL") }
    await MainActor.run { NanocodeKit.open(url) }
    return .text("Opened Shortcuts to run \(name).")
  }

  #if os(macOS)
  static func draft(_ input: JSON) async throws -> ToolResult {
    let recipients = input["to"]?.array?.compactMap(\.string) ?? []
    let email = input["kind"]?.string == "email"
    guard let service = NSSharingService(named: email ? .composeEmail : .composeMessage) else { throw NanocodeError("this Mac cannot compose that") }
    service.recipients = recipients
    if let subject = input["subject"]?.string { service.subject = subject }
    var items: [Any] = [input["body"]?.string ?? ""]
    if email { items += (input["attachments"]?.array ?? []).compactMap(\.string).map(file) }
    guard service.canPerform(withItems: items) else { throw NanocodeError("this Mac has no account set up for that") }
    service.perform(withItems: items)
    return .text("Opened a draft for the user to send.")
  }
  #else
  static func top() throws -> UIViewController {
    let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    guard var controller = scenes.flatMap(\.windows).first(where: \.isKeyWindow)?.rootViewController ?? scenes.first?.windows.first?.rootViewController else {
      throw NanocodeError("the app is not on screen")
    }
    while let presented = controller.presentedViewController { controller = presented }
    return controller
  }

  @MainActor final class Composer: NSObject, @preconcurrency MFMessageComposeViewControllerDelegate, @preconcurrency MFMailComposeViewControllerDelegate {
    var done: CheckedContinuation<String, Never>?

    func messageComposeViewController(_ controller: MFMessageComposeViewController, didFinishWith result: MessageComposeResult) {
      controller.dismiss(animated: true)
      done?.resume(returning: result == .sent ? "sent" : result == .cancelled ? "cancelled" : "failed")
      done = nil
    }

    func mailComposeController(_ controller: MFMailComposeViewController, didFinishWith result: MFMailComposeResult, error: Error?) {
      controller.dismiss(animated: true)
      done?.resume(returning: result == .sent ? "sent" : result == .saved ? "saved as a draft" : result == .cancelled ? "cancelled" : "failed")
      done = nil
    }
  }

  static func draft(_ input: JSON) async throws -> ToolResult {
    let recipients = input["to"]?.array?.compactMap(\.string) ?? []
    let presenter = try top()
    let composer = Composer()
    if input["kind"]?.string == "email" {
      guard MFMailComposeViewController.canSendMail() else { throw NanocodeError("this device has no Mail account set up") }
      let controller = MFMailComposeViewController()
      controller.mailComposeDelegate = composer
      controller.setToRecipients(recipients)
      controller.setSubject(input["subject"]?.string ?? "")
      controller.setMessageBody(input["body"]?.string ?? "", isHTML: false)
      for path in (input["attachments"]?.array ?? []).compactMap(\.string) {
        let url = file(path)
        let type = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        controller.addAttachmentData(try Data(contentsOf: url), mimeType: type, fileName: url.lastPathComponent)
      }
      let result = await withCheckedContinuation { continuation in
        composer.done = continuation
        presenter.present(controller, animated: true)
      }
      withExtendedLifetime(composer) {}
      return .text("The email was \(result).")
    }
    guard MFMessageComposeViewController.canSendText() else { throw NanocodeError("this device cannot send text messages") }
    let controller = MFMessageComposeViewController()
    controller.messageComposeDelegate = composer
    controller.recipients = recipients
    controller.body = input["body"]?.string
    let result = await withCheckedContinuation { continuation in
      composer.done = continuation
      presenter.present(controller, animated: true)
    }
    withExtendedLifetime(composer) {}
    return .text("The message was \(result).")
  }

  @MainActor final class Capture: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate, @preconcurrency VNDocumentCameraViewControllerDelegate {
    var photo: CheckedContinuation<UIImage?, Never>?
    var scan: CheckedContinuation<[UIImage], Never>?

    func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
      picker.dismiss(animated: true)
      photo?.resume(returning: info[.originalImage] as? UIImage)
      photo = nil
    }

    func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
      picker.dismiss(animated: true)
      photo?.resume(returning: nil)
      photo = nil
    }

    func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFinishWith result: VNDocumentCameraScan) {
      controller.dismiss(animated: true)
      scan?.resume(returning: (0..<result.pageCount).map { result.imageOfPage(at: $0) })
      scan = nil
    }

    func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
      controller.dismiss(animated: true)
      scan?.resume(returning: [])
      scan = nil
    }

    func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFailWithError error: Error) {
      controller.dismiss(animated: true)
      scan?.resume(returning: [])
      scan = nil
    }
  }

  static let camera = HostTool(
    name: "camera",
    description: "Opens the camera on this device for the user: photo takes one picture, scan scans document pages and reads their text. Saves JPEG files in the workspace under camera/ and returns the picture.",
    parameters: schema(["mode": ["type": "string", "enum": ["photo", "scan"]]]),
    content: true
  ) { call in try await DemoTools.shoot(call.input) }

  static func shoot(_ input: JSON) async throws -> ToolResult {
    guard await AVCaptureDevice.requestAccess(for: .video) else { throw NanocodeError("camera access is off for this app; turn it on in Settings") }
    let presenter = try top()
    let capture = Capture()
    let directory = try folder("camera")
    if input["mode"]?.string == "scan" {
      guard VNDocumentCameraViewController.isSupported else { throw NanocodeError("this device cannot scan documents") }
      let controller = VNDocumentCameraViewController()
      controller.delegate = capture
      let pages = await withCheckedContinuation { continuation in
        capture.scan = continuation
        presenter.present(controller, animated: true)
      }
      withExtendedLifetime(capture) {}
      guard !pages.isEmpty else { return .text("The user cancelled the scan.") }
      var saved: [JSON] = []
      for (index, page) in pages.enumerated() {
        guard let data = page.jpegData(compressionQuality: 0.85) else { continue }
        let url = directory.appendingPathComponent(name(Date(), index + 1, "jpg"))
        try data.write(to: url)
        let text = await Task.detached { recognize(data) }.value
        saved.append(["path": .string(url.path), "text": .string(text)])
      }
      return answer(.array(saved))
    }
    guard UIImagePickerController.isSourceTypeAvailable(.camera) else { throw NanocodeError("this device has no camera") }
    let controller = UIImagePickerController()
    controller.sourceType = .camera
    controller.delegate = capture
    let shot = await withCheckedContinuation { continuation in
      capture.photo = continuation
      presenter.present(controller, animated: true)
    }
    withExtendedLifetime(capture) {}
    guard let shot, let data = shot.jpegData(compressionQuality: 0.85) else { return .text("The user cancelled the photo.") }
    let url = directory.appendingPathComponent(name(Date(), 0, "jpg"))
    try data.write(to: url)
    return try image(data, description: ["path": .string(url.path), "width": .number(Double(shot.size.width * shot.scale)), "height": .number(Double(shot.size.height * shot.scale))])
  }

  nonisolated(unsafe) static let pedometer = CMPedometer()
  nonisolated(unsafe) static let activities = CMMotionActivityManager()

  static let motion = HostTool(
    name: "motion",
    description: "Steps, distance, floors and time spent walking, running, cycling or in a vehicle on this device between two dates, today by default.",
    parameters: schema([
      "from": ["type": "string", "description": "ISO 8601 date or date-time; the start of today by default."],
      "to": ["type": "string", "description": "ISO 8601 date or date-time; now by default."],
    ])
  ) { call in try await DemoTools.movement(call.input) }

  static func movement(_ input: JSON) async throws -> ToolResult {
    let start = date(input["from"]) ?? Calendar.current.startOfDay(for: Date())
    let end = date(input["to"]) ?? Date()
    guard CMPedometer.isStepCountingAvailable() else { throw NanocodeError("this device does not count steps") }
    var object = try await steps(start, end)
    if CMMotionActivityManager.isActivityAvailable() { object["activity_minutes"] = await moved(start, end) }
    object["from"] = stamp(start)
    object["to"] = stamp(end)
    return answer(.object(object))
  }

  nonisolated static func steps(_ start: Date, _ end: Date) async throws -> [String: JSON] {
    try await withCheckedThrowingContinuation { continuation in
      pedometer.queryPedometerData(from: start, to: end) { data, error in
        guard let data else {
          continuation.resume(throwing: error ?? NanocodeError("motion data is not available"))
          return
        }
        var object: [String: JSON] = ["steps": .number(data.numberOfSteps.doubleValue)]
        if let distance = data.distance { object["distance_m"] = .number(distance.doubleValue.rounded()) }
        if let floors = data.floorsAscended { object["floors_up"] = .number(floors.doubleValue) }
        if let floors = data.floorsDescended { object["floors_down"] = .number(floors.doubleValue) }
        continuation.resume(returning: object)
      }
    }
  }

  nonisolated static func moved(_ start: Date, _ end: Date) async -> JSON {
    await withCheckedContinuation { continuation in
      activities.queryActivityStarting(from: start, to: end, to: OperationQueue()) { found, _ in
        let found = found ?? []
        var minutes: [String: Double] = [:]
        for (index, activity) in found.enumerated() {
          let until = index + 1 < found.count ? found[index + 1].startDate : end
          let kind = activity.walking ? "walking" : activity.running ? "running" : activity.cycling ? "cycling"
            : activity.automotive ? "vehicle" : activity.stationary ? "stationary" : "unknown"
          minutes[kind, default: 0] += until.timeIntervalSince(activity.startDate) / 60
        }
        continuation.resume(returning: .object(minutes.mapValues { .number($0.rounded()) }))
      }
    }
  }

  static let music = HostTool(
    name: "music",
    description: "The music library on this device. search: songs whose title, artist or album matches. playlists: the playlists. play: play the songs that match a query, or a playlist by name. pause, resume and now_playing control the player.",
    parameters: schema([
      "action": actions(["search", "playlists", "play", "pause", "resume", "now_playing"]),
      "query": ["type": "string"],
      "playlist": ["type": "string", "description": "For play: a playlist's name."],
      "limit": ["type": "integer", "description": "For search: 25 by default, at most 200."],
    ], required: ["action"])
  ) { call in try await DemoTools.library(call.input) }

  static func library(_ input: JSON) async throws -> ToolResult {
    guard await MPMediaLibrary.requestAuthorization() == .authorized else { throw NanocodeError("music library access is off for this app; turn it on in Settings") }
    let player = MPMusicPlayerController.systemMusicPlayer
    switch input["action"]?.string {
    case "search":
      guard let query = input["query"]?.string else { throw NanocodeError("search takes a query") }
      return answer(.array(songs(query).prefix(limit(input, 25, most: 200)).map(describe)))
    case "playlists":
      return answer(.array((MPMediaQuery.playlists().collections ?? []).map {
        ["name": .string($0.value(forProperty: MPMediaPlaylistPropertyName) as? String ?? ""), "songs": .number(Double($0.count))]
      }))
    case "play":
      if let name = input["playlist"]?.string {
        let query = MPMediaQuery.playlists()
        query.addFilterPredicate(MPMediaPropertyPredicate(value: name, forProperty: MPMediaPlaylistPropertyName, comparisonType: .contains))
        guard let playlist = query.collections?.first else { throw NanocodeError("no playlist is called \(name)") }
        player.setQueue(with: playlist)
      } else {
        let found = songs(input["query"]?.string ?? "")
        guard !found.isEmpty else { throw NanocodeError("no song matches that") }
        player.setQueue(with: MPMediaItemCollection(items: found))
      }
      player.play()
      return answer(player.nowPlayingItem.map(describe) ?? ["playing": true])
    case "pause":
      player.pause()
      return .text("Paused.")
    case "resume":
      player.play()
      return .text("Playing.")
    case "now_playing":
      return answer(player.nowPlayingItem.map(describe) ?? ["playing": false])
    default:
      throw NanocodeError("music takes the action search, playlists, play, pause, resume or now_playing")
    }
  }

  static func songs(_ text: String) -> [MPMediaItem] {
    var seen = Set<MPMediaEntityPersistentID>()
    return [MPMediaItemPropertyTitle, MPMediaItemPropertyArtist, MPMediaItemPropertyAlbumTitle].flatMap { property in
      let query = MPMediaQuery.songs()
      if !text.isEmpty { query.addFilterPredicate(MPMediaPropertyPredicate(value: text, forProperty: property, comparisonType: .contains)) }
      return query.items ?? []
    }.filter { seen.insert($0.persistentID).inserted }
  }

  static func describe(_ item: MPMediaItem) -> JSON {
    ["title": .string(item.title ?? ""), "artist": .string(item.artist ?? ""), "album": .string(item.albumTitle ?? ""), "seconds": .number(item.playbackDuration.rounded())]
  }
  #endif
}

extension DemoTools {
  static var capabilities: [HandCapability] {
    var list = [
      HandCapability(name: "photos", description: "The photo library: list, read and save photos", tools: ["photos"],
                     permission: { await photosPermission() }, request: { _ in await askPhotos() }),
      HandCapability(name: "contacts", description: "The address book: search and add contacts", tools: ["contacts"],
                     permission: { await contactsPermission() }, request: { _ in await askContacts() }),
      HandCapability(name: "calendar", description: "Calendar events: list and add them", tools: ["calendar"],
                     permission: { await eventsPermission(.event) }, request: { _ in await askEvents(.event) }),
      HandCapability(name: "reminders", description: "Reminders: list, add and complete them", tools: ["reminders"],
                     permission: { await eventsPermission(.reminder) }, request: { _ in await askEvents(.reminder) }),
      HandCapability(name: "location", description: "Where this device is, and places near it", tools: ["location"],
                     permission: { await locationPermission() }, request: { _ in await askLocation() }),
      HandCapability(name: "notifications", description: "Notifications from this app", tools: ["notify"],
                     permission: { await notificationsPermission() }, request: { _ in await askNotifications() }),
      HandCapability(name: "microphone", description: "Listening through the microphone and transcribing speech", tools: ["listen"],
                     permission: { await listeningPermission() }, request: { _ in await askListening() }),
      HandCapability(name: "bluetooth", description: "Bluetooth Low Energy devices nearby", tools: ["bluetooth"],
                     permission: { await bluetoothPermission() }, request: { _ in await askBluetooth() }),
    ]
    #if !os(macOS)
    list += [
      HandCapability(name: "camera", description: "Taking photos with the camera", tools: ["camera"],
                     permission: { await cameraPermission() }, request: { _ in await askCamera() }),
      HandCapability(name: "motion", description: "Steps and activity from the motion sensors", tools: ["motion"],
                     permission: { await motionPermission() }),
      HandCapability(name: "music", description: "The music library and playback", tools: ["music"],
                     permission: { await musicPermission() }, request: { _ in await askMusic() }),
    ]
    #endif
    return list
  }

  static func askPhotos() async -> HandPermission {
    _ = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
    return photosPermission()
  }

  static func askContacts() async -> HandPermission {
    _ = try? await CNContactStore().requestAccess(for: .contacts)
    return contactsPermission()
  }

  static func askEvents(_ type: EKEntityType) async -> HandPermission {
    _ = try? await (type == .event ? events.requestFullAccessToEvents() : events.requestFullAccessToReminders())
    return eventsPermission(type)
  }

  static func askNotifications() async -> HandPermission {
    _ = try? await allowNotifications()
    return await notificationsPermission()
  }

  static func askListening() async -> HandPermission {
    _ = await speechAccess()
    _ = await AVCaptureDevice.requestAccess(for: .audio)
    return listeningPermission()
  }

  static func askBluetooth() async -> HandPermission {
    _ = try? await Scanner().scan(seconds: 1)
    return bluetoothPermission()
  }

  static var environment: HandEnvironment? {
    #if os(macOS)
    nil
    #else
    HandEnvironment(platform: "ios", osVersion: "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion), \(UIDevice.current.model)",
                    shell: "bash (nanocode-ts just-bash over this app's files)")
    #endif
  }

  static func photosPermission() -> HandPermission {
    switch PHPhotoLibrary.authorizationStatus(for: .readWrite) {
    case .authorized, .limited: .granted
    case .denied, .restricted: .denied
    case .notDetermined: .prompt
    @unknown default: .prompt
    }
  }

  static func contactsPermission() -> HandPermission {
    let status = CNContactStore.authorizationStatus(for: .contacts)
    #if os(iOS)
    if #available(iOS 18, *), status == .limited { return .granted }
    #endif
    switch status {
    case .authorized: return .granted
    case .denied, .restricted: return .denied
    default: return .prompt
    }
  }

  static func eventsPermission(_ type: EKEntityType) -> HandPermission {
    switch EKEventStore.authorizationStatus(for: type) {
    case .fullAccess: .granted
    case .denied, .restricted: .denied
    default: .prompt
    }
  }

  static func locationPermission() -> HandPermission {
    switch locator.authorizationStatus {
    case .authorizedAlways, .authorizedWhenInUse: .granted
    case .denied, .restricted: .denied
    default: .prompt
    }
  }

  static func askLocation() async -> HandPermission {
    if locator.authorizationStatus == .notDetermined {
      locator.requestWhenInUseAuthorization()
      for _ in 0..<600 where locator.authorizationStatus == .notDetermined { try? await Task.sleep(nanoseconds: 100_000_000) }
    }
    return locationPermission()
  }

  static func notificationsPermission() async -> HandPermission {
    switch await UNUserNotificationCenter.current().notificationSettings().authorizationStatus {
    case .notDetermined: .prompt
    case .denied: .denied
    default: .granted
    }
  }

  static func listeningPermission() -> HandPermission {
    let speech = SFSpeechRecognizer.authorizationStatus()
    let microphone = AVCaptureDevice.authorizationStatus(for: .audio)
    if speech == .authorized && microphone == .authorized { return .granted }
    if [.denied, .restricted].contains(speech) || [.denied, .restricted].contains(microphone) { return .denied }
    return .prompt
  }

  static func bluetoothPermission() -> HandPermission {
    switch CBManager.authorization {
    case .allowedAlways: .granted
    case .denied, .restricted: .denied
    default: .prompt
    }
  }

  #if !os(macOS)
  static func askCamera() async -> HandPermission {
    _ = await AVCaptureDevice.requestAccess(for: .video)
    return cameraPermission()
  }

  static func askMusic() async -> HandPermission {
    _ = await MPMediaLibrary.requestAuthorization()
    return musicPermission()
  }

  static func cameraPermission() -> HandPermission {
    switch AVCaptureDevice.authorizationStatus(for: .video) {
    case .authorized: .granted
    case .denied, .restricted: .denied
    default: .prompt
    }
  }

  static func motionPermission() -> HandPermission {
    switch CMMotionActivityManager.authorizationStatus() {
    case .authorized: .granted
    case .denied, .restricted: .denied
    default: .prompt
    }
  }

  static func musicPermission() -> HandPermission {
    switch MPMediaLibrary.authorizationStatus() {
    case .authorized: .granted
    case .denied, .restricted: .denied
    default: .prompt
    }
  }
  #endif
}
