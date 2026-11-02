#if os(iOS) || os(macOS)
import CoreLocation
import Foundation
import MapKit
import Nanocode
import UserNotifications

extension DeviceKit {
  static let locationActions = ["current", "search", "geocode", "reverse", "directions"]
  static let geofenceActions = ["add", "list", "remove", "events"]

  static let locationProperties: [String: JSON] = [
    "query": prop("string", "For search: what to look for (coffee, a pharmacy, a business). For geocode: an address or place. For directions: where to go."),
    "latitude": prop("number"), "longitude": prop("number"),
    "near_latitude": prop("number", "For search: search around here instead of the \(DeviceTools.here)."),
    "near_longitude": prop("number"),
    "radius_km": prop("number", "For search: how far around, 5 by default."),
    "transport": choice(["automobile", "walking", "transit", "cycling"], "For directions: automobile by default."),
    "limit": prop("integer", "For search and geocode: how many places."),
  ]

  static let location = HostTool(
    name: "location",
    description: "Where this \(DeviceTools.here) is and places around it, from Apple Maps. current: coordinates, accuracy, altitude, speed and the address. search: places matching a query near the \(DeviceTools.here) or a point. geocode: an address or place to coordinates. reverse: coordinates to an address. directions: distance and travel time from the \(DeviceTools.here) to a place or coordinates (latitude/longitude), with the steps.",
    parameters: schema(locationActions, locationProperties)
  ) { call in try await whereabouts(call.input) }

  static let geofenceProperties: [String: JSON] = [
    "name": prop("string", "For add: what the place is, shown in the notification."),
    "query": prop("string", "For add: an address or place to look up instead of latitude/longitude."),
    "latitude": prop("number"), "longitude": prop("number"),
    "radius_m": prop("number", "For add: 150 by default."),
    "notify": choice(["arrive", "leave", "both"], "For add: when to notify; arrive by default."),
    "message": prop("string", "For add: the notification's text, such as a reminder to buy milk."),
    "repeats": prop("boolean", "For add: keep notifying every time (default), or remove the geofence after the first notification."),
    "id": prop("string", "For remove: the geofence id."),
    "limit": prop("integer", "For events: how many, newest first."),
  ]

  static let geofence = HostTool(
    name: "geofence",
    description: "Geofences that notify the owner on this \(DeviceTools.here) when they arrive at or leave a place, even when \(DeviceTools.settings.app) is closed (iOS relaunches it). add, list, remove, and events (what happened, newest first). iOS allows 20 geofences per app; it needs location access always (capability location_always).",
    parameters: schema(geofenceActions, geofenceProperties)
  ) { call in try await fences(call.input) }

  static func whereabouts(_ input: JSON) async throws -> ToolResult {
    try await DeviceTools.gate("location")
    switch input["action"]?.string {
    case "current":
      let here = try await DeviceTools.position()
      var object = point(here)
      object["accuracy_m"] = .number(here.horizontalAccuracy.rounded())
      object["altitude_m"] = .number(here.altitude.rounded())
      object["time"] = DeviceTools.stamp(here.timestamp)
      if here.speed >= 0 { object["speed_m_s"] = .number(here.speed) }
      if here.course >= 0 { object["course_degrees"] = .number(here.course.rounded()) }
      if let address = await address(here) { object["address"] = .string(address) }
      return .json(.object(object))
    case "search":
      let query = try need(input, "query", for: "search")
      let center: CLLocation
      if let latitude = input["near_latitude"]?.number, let longitude = input["near_longitude"]?.number {
        center = CLLocation(latitude: latitude, longitude: longitude)
      } else {
        center = try await DeviceTools.position()
      }
      let radius = (input["radius_km"]?.number ?? 5) * 1000
      let items = try await places(query, near: center, radius: radius)
      return .json(.array(items.prefix(try count(input, 10, most: 100)).map { place($0, from: center) }))
    case "geocode":
      let query = try need(input, "query", for: "geocode")
      let items = try await places(query, near: nil, radius: nil)
      guard !items.isEmpty else { throw NanocodeError("Apple Maps found nothing for \(query)") }
      return .json(.array(items.prefix(try count(input, 5, most: 100)).map { place($0, from: nil) }))
    case "reverse":
      guard let latitude = input["latitude"]?.number, let longitude = input["longitude"]?.number else {
        throw NanocodeError("reverse takes latitude and longitude")
      }
      let spot = CLLocation(latitude: latitude, longitude: longitude)
      var object = point(spot)
      object["address"] = string(await address(spot))
      return .json(.object(object))
    case "directions":
      return .json(try await directions(input))
    default:
      throw unknown("location", locationActions)
    }
  }

  static func point(_ location: CLLocation) -> [String: JSON] {
    ["latitude": .number(location.coordinate.latitude), "longitude": .number(location.coordinate.longitude)]
  }

  static func address(_ location: CLLocation) async -> String? {
    if #available(iOS 26.0, macOS 26.0, *) {
      guard let request = MKReverseGeocodingRequest(location: location), let item = try? await request.mapItems.first else { return nil }
      return item.address?.fullAddress ?? item.name
    }
    guard let mark = try? await CLGeocoder().reverseGeocodeLocation(location).first else { return nil }
    let parts = [mark.name, mark.locality, mark.administrativeArea, mark.country].compactMap { $0 }
    return parts.isEmpty ? nil : parts.joined(separator: ", ")
  }

  static func location(of item: MKMapItem) -> CLLocation {
    if #available(iOS 26.0, macOS 26.0, *) { return item.location }
    return item.placemark.location ?? CLLocation(latitude: item.placemark.coordinate.latitude, longitude: item.placemark.coordinate.longitude)
  }

  static func fullAddress(of item: MKMapItem) -> String? {
    if #available(iOS 26.0, macOS 26.0, *) { return item.address?.fullAddress }
    return item.placemark.title
  }

  static func item(at location: CLLocation) -> MKMapItem {
    if #available(iOS 26.0, macOS 26.0, *) { return MKMapItem(location: location, address: nil) }
    return MKMapItem(placemark: MKPlacemark(coordinate: location.coordinate))
  }

  static func places(_ query: String, near center: CLLocation?, radius: Double?) async throws -> [MKMapItem] {
    let request = MKLocalSearch.Request()
    request.naturalLanguageQuery = query
    if let center, let radius {
      request.region = MKCoordinateRegion(center: center.coordinate, latitudinalMeters: radius * 2, longitudinalMeters: radius * 2)
    }
    let response = try await MKLocalSearch(request: request).start()
    return response.mapItems
  }

  static func place(_ item: MKMapItem, from center: CLLocation?) -> JSON {
    let spot = location(of: item)
    var object = point(spot)
    object["name"] = .string(item.name ?? "")
    object["address"] = .string(fullAddress(of: item) ?? "")
    if let center { object["distance_m"] = .number(spot.distance(from: center).rounded()) }
    if let phone = item.phoneNumber { object["phone"] = .string(phone) }
    if let url = item.url { object["url"] = .string(url.absoluteString) }
    if let category = item.pointOfInterestCategory { object["category"] = .string(category.rawValue.replacingOccurrences(of: "MKPOICategory", with: "")) }
    return .object(object)
  }

  static func directions(_ input: JSON) async throws -> JSON {
    let here = try await DeviceTools.position()
    let destination: MKMapItem
    if let latitude = input["latitude"]?.number, let longitude = input["longitude"]?.number {
      destination = item(at: CLLocation(latitude: latitude, longitude: longitude))
    } else {
      let query = try need(input, "query", for: "directions")
      guard let found = try await places(query, near: here, radius: 50_000).first else { throw NanocodeError("Apple Maps found nothing for \(query)") }
      destination = found
    }
    let request = MKDirections.Request()
    request.source = MKMapItem.forCurrentLocation()
    request.destination = destination
    let transport = input["transport"]?.string ?? "automobile"
    switch transport {
    case "walking": request.transportType = .walking
    case "transit": request.transportType = .transit
    case "cycling": request.transportType = .cycling
    default: request.transportType = .automobile
    }
    var object: [String: JSON] = ["to": place(destination, from: here), "transport": .string(transport)]
    if transport == "transit" {
      let eta = try await MKDirections(request: request).calculateETA()
      object["seconds"] = .number(eta.expectedTravelTime.rounded())
      object["distance_m"] = .number(eta.distance.rounded())
      object["arrive"] = DeviceTools.stamp(eta.expectedArrivalDate)
      return .object(object)
    }
    let response = try await MKDirections(request: request).calculate()
    object["routes"] = .array(response.routes.map { route in
      ["name": .string(route.name), "seconds": .number(route.expectedTravelTime.rounded()), "distance_m": .number(route.distance.rounded()),
       "advisories": .array(route.advisoryNotices.map(JSON.string)),
       "steps": .array(route.steps.filter { !$0.instructions.isEmpty }.map { step in
         ["instructions": .string(step.instructions), "distance_m": .number(step.distance.rounded())]
       })]
    })
    return .object(object)
  }

  static func fences(_ input: JSON) async throws -> ToolResult {
    switch input["action"]?.string {
    case "add":
      try await DeviceTools.gate("location_always")
      let center: CLLocationCoordinate2D
      var label = text(input, "name")
      if let latitude = input["latitude"]?.number, let longitude = input["longitude"]?.number {
        center = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
      } else {
        let query = try need(input, "query", for: "add")
        guard let found = try await places(query, near: nil, radius: nil).first else { throw NanocodeError("Apple Maps found nothing for \(query)") }
        center = location(of: found).coordinate
        label = label ?? found.name ?? query
      }
      let radius = input["radius_m"]?.number ?? 150
      guard radius > 0 else { throw NanocodeError("radius_m must be positive") }
      let notify = input["notify"]?.string ?? "arrive"
      guard ["arrive", "leave", "both"].contains(notify) else { throw NanocodeError("notify is arrive, leave or both") }
      let fence = Geofences.Fence(id: "fence-" + UUID().uuidString.prefix(8).lowercased(), name: label ?? "a place", latitude: center.latitude,
                                  longitude: center.longitude, radius: radius, notify: notify, message: text(input, "message"),
                                  repeats: input["repeats"]?.bool ?? true, created: Date())
      try await Geofences.shared.add(fence)
      var result = fence.json
      if await DeviceCapability.permission("notifications") != .granted {
        result["warning"] = "notifications are not allowed yet, so arrivals are only recorded in events; ask for the notifications capability"
      }
      return .json(.object(result))
    case "list":
      return .json(.array(await Geofences.shared.list().map { .object($0.json) }))
    case "remove":
      let id = try need(input, "id", for: "remove")
      guard await Geofences.shared.remove(id) else { throw NanocodeError("no geofence has the id \(id)") }
      return .json(["removed": .string(id)])
    case "events":
      let all = await Geofences.shared.history()
      return .json(.array(all.prefix(try count(input, 50, most: Geofences.historyKept)).map { .object($0) }))
    default:
      throw unknown("geofence", geofenceActions)
    }
  }
}

public actor Geofences {
  public static let shared = Geofences()
  static let name = "NanocodeGeofences"
  static let fencesKey = "PhoneGeofences"
  static let historyKey = "PhoneGeofenceEvents"
  static let historyKept = 500
  static let most = 20

  struct Fence: Codable, Sendable {
    let id: String
    let name: String
    let latitude: Double
    let longitude: Double
    let radius: Double
    let notify: String
    let message: String?
    let repeats: Bool
    let created: Date

    var json: [String: JSON] {
      ["id": .string(id), "name": .string(name), "latitude": .number(latitude), "longitude": .number(longitude), "radius_m": .number(radius),
       "notify": .string(notify), "message": message.map(JSON.string) ?? .null, "repeats": .bool(repeats), "created": DeviceTools.stamp(created)]
    }
  }

  private var monitor: CLMonitor?
  private var listening = false

  func list() -> [Fence] {
    guard let data = UserDefaults.standard.data(forKey: Self.fencesKey) else { return [] }
    return (try? JSONDecoder().decode([Fence].self, from: data)) ?? []
  }

  private func save(_ fences: [Fence]) {
    UserDefaults.standard.set(try? JSONEncoder().encode(fences), forKey: Self.fencesKey)
  }

  func history() -> [[String: JSON]] {
    guard let data = UserDefaults.standard.data(forKey: Self.historyKey), let json = try? JSON.parse(data) else { return [] }
    return (json.array ?? []).compactMap(\.object)
  }

  private func record(_ entry: [String: JSON]) {
    let kept = [entry] + history().prefix(Self.historyKept - 1)
    UserDefaults.standard.set(JSON.array(kept.map(JSON.object)).data(), forKey: Self.historyKey)
  }

  private func opened() async -> CLMonitor {
    if let monitor { return monitor }
    let made = await CLMonitor(Self.name)
    monitor = made
    return made
  }

  public func resume() async {
    guard !list().isEmpty else { return }
    _ = await opened()
    listen()
  }

  func add(_ fence: Fence) async throws {
    var fences = list()
    guard fences.count < Self.most else {
      throw NanocodeError("iOS allows \(Self.most) geofences per app and \(fences.count) are set; remove one first")
    }
    let monitor = await opened()
    let condition = CLMonitor.CircularGeographicCondition(center: CLLocationCoordinate2D(latitude: fence.latitude, longitude: fence.longitude),
                                                          radius: fence.radius)
    await monitor.add(condition, identifier: fence.id, assuming: .unknown)
    fences.append(fence)
    save(fences)
    listen()
  }

  func remove(_ id: String) async -> Bool {
    var fences = list()
    guard fences.contains(where: { $0.id == id }) else { return false }
    fences.removeAll { $0.id == id }
    save(fences)
    await opened().remove(id)
    return true
  }

  private func listen() {
    guard !listening else { return }
    listening = true
    Task {
      let monitor = await opened()
      do {
        for try await event in await monitor.events { await handle(event.identifier, event.state, event.date) }
      } catch {
        record(["at": DeviceTools.stamp(Date()), "error": .string(error.localizedDescription)])
      }
      listening = false
    }
  }

  private func handle(_ id: String, _ state: CLMonitor.Event.State, _ date: Date) async {
    guard let fence = list().first(where: { $0.id == id }) else { return }
    let arrived: Bool
    switch state {
    case .satisfied: arrived = true
    case .unsatisfied: arrived = false
    default: return
    }
    let wanted = fence.notify == "both" || (fence.notify == "arrive") == arrived
    record(["at": DeviceTools.stamp(date), "id": .string(id), "name": .string(fence.name), "event": .string(arrived ? "arrive" : "leave"),
            "notified": .bool(wanted)])
    guard wanted else { return }
    let content = UNMutableNotificationContent()
    content.title = arrived ? "Arrived at \(fence.name)" : "Left \(fence.name)"
    content.body = fence.message ?? ""
    content.sound = .default
    content.interruptionLevel = Entitlements.timeSensitive ? .timeSensitive : .active
    try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "\(id)-\(Int(date.timeIntervalSince1970))", content: content, trigger: nil))
    if !fence.repeats { _ = await remove(id) }
  }
}
#endif
