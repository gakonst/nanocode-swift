#if os(iOS)
import Foundation
import HomeKit
import Nanocode

extension DeviceKit {
  static let homeActions = ["homes", "accessories", "read", "set", "scenes", "run_scene"]

  static let characteristicKinds: [String: String] = [
    "power": HMCharacteristicTypePowerState, "brightness": HMCharacteristicTypeBrightness, "hue": HMCharacteristicTypeHue,
    "saturation": HMCharacteristicTypeSaturation, "color_temperature": HMCharacteristicTypeColorTemperature,
    "current_temperature": HMCharacteristicTypeCurrentTemperature, "target_temperature": HMCharacteristicTypeTargetTemperature,
    "heating_cooling": HMCharacteristicTypeTargetHeatingCooling, "current_heating_cooling": HMCharacteristicTypeCurrentHeatingCooling,
    "lock": HMCharacteristicTypeTargetLockMechanismState, "lock_state": HMCharacteristicTypeCurrentLockMechanismState,
    "position": HMCharacteristicTypeTargetPosition, "current_position": HMCharacteristicTypeCurrentPosition, "active": HMCharacteristicTypeActive,
    "humidity": HMCharacteristicTypeCurrentRelativeHumidity, "target_humidity": HMCharacteristicTypeTargetRelativeHumidity,
    "door": HMCharacteristicTypeTargetDoorState, "door_state": HMCharacteristicTypeCurrentDoorState, "motion": HMCharacteristicTypeMotionDetected,
    "contact": HMCharacteristicTypeContactState, "battery": HMCharacteristicTypeBatteryLevel, "low_battery": HMCharacteristicTypeStatusLowBattery,
    "outlet_in_use": HMCharacteristicTypeOutletInUse, "speed": HMCharacteristicTypeRotationSpeed, "air_quality": HMCharacteristicTypeAirQuality,
    "volume": HMCharacteristicTypeVolume, "mute": HMCharacteristicTypeMute, "light_level": HMCharacteristicTypeCurrentLightLevel,
    "smoke": HMCharacteristicTypeSmokeDetected, "leak": HMCharacteristicTypeLeakDetected, "occupancy": HMCharacteristicTypeOccupancyDetected,
    "security": HMCharacteristicTypeTargetSecuritySystemState, "security_state": HMCharacteristicTypeCurrentSecuritySystemState,
    "name": HMCharacteristicTypeName,
  ]

  static let home = HostTool(
    name: "home",
    description: "Apple Home (HomeKit) on this iPhone. homes: homes with their rooms and zones. accessories: every accessory (filter by home or room) with its services, characteristics and current values. read: refresh one accessory's values. set: change a characteristic, by id or by kind (power, brightness, hue, saturation, color_temperature, target_temperature, heating_cooling, lock, position, active, door, speed, volume, mute, security…). scenes: the home's scenes; run_scene runs one.",
    parameters: schema(homeActions, [
      "home": prop("string", "A home name or id; the primary home by default."),
      "room": prop("string", "For accessories: only this room."),
      "accessory": prop("string", "An accessory name or id (read, set)."),
      "characteristic": prop("string", "For set: a characteristic id from accessories."),
      "kind": prop("string", "For set: what to change on the accessory, such as power or brightness."),
      "value": .object(["type": .array([.string("boolean"), .string("number"), .string("string")]), "description": "For set: the new value."]),
      "scene": prop("string", "For run_scene: a scene name or id."),
    ])
  ) { call in try await homeKit(call.input) }

  @MainActor static func homeKit(_ input: JSON) async throws -> ToolResult {
    try await DeviceTools.gate("home")
    let homes = await HomeHub.shared.homes()
    guard !homes.isEmpty else { throw NanocodeError("the owner has no home in the Home app, or hasn't allowed \(DeviceTools.settings.app) to see it") }
    switch input["action"]?.string {
    case "homes":
      return .json(.array(homes.map { home in
        ["id": .string(home.uniqueIdentifier.uuidString), "name": .string(home.name), "primary": .bool(home.isPrimary),
         "rooms": .array(home.rooms.map { .string($0.name) }), "zones": .array(home.zones.map { .string($0.name) }),
         "accessories": .number(Double(home.accessories.count)), "scenes": .number(Double(home.actionSets.count))]
      }))
    case "accessories":
      let home = try pickHome(homes, input)
      let room = text(input, "room")
      let found = home.accessories.filter { room == nil || $0.room?.name.localizedCaseInsensitiveCompare(room ?? "") == .orderedSame }
      return .json(.array(found.map(describe)))
    case "read":
      let accessory = try pickAccessory(try pickHome(homes, input), try need(input, "accessory", for: "read"))
      for service in accessory.services {
        for characteristic in service.characteristics where characteristic.properties.contains(HMCharacteristicPropertyReadable) {
          try? await characteristic.readValue()
        }
      }
      return .json(describe(accessory))
    case "set":
      let home = try pickHome(homes, input)
      guard let value = input["value"] else { throw NanocodeError("set takes a value") }
      let target: HMCharacteristic
      if let id = text(input, "characteristic") {
        guard let found = home.accessories.flatMap(\.services).flatMap(\.characteristics).first(where: { $0.uniqueIdentifier.uuidString == id }) else {
          throw NanocodeError("no characteristic has the id \(id)")
        }
        target = found
      } else {
        let accessory = try pickAccessory(home, try need(input, "accessory", for: "set"))
        let kind = try need(input, "kind", for: "set")
        guard let type = characteristicKinds[kind] else { throw NanocodeError("kind is one of \(characteristicKinds.keys.sorted().joined(separator: ", ")), or give a characteristic id") }
        guard let found = accessory.services.flatMap(\.characteristics).first(where: { $0.characteristicType == type && $0.properties.contains(HMCharacteristicPropertyWritable) }) else {
          throw NanocodeError("\(accessory.name) has no \(kind) it lets apps change")
        }
        target = found
      }
      guard target.properties.contains(HMCharacteristicPropertyWritable) else { throw NanocodeError("that characteristic can't be changed") }
      try await target.writeValue(try homeValue(value, for: target))
      return .json(.object(characteristic(target)))
    case "scenes":
      let home = try pickHome(homes, input)
      return .json(.array(home.actionSets.map { set in
        ["id": .string(set.uniqueIdentifier.uuidString), "name": .string(set.name), "type": .string(set.actionSetType), "actions": .number(Double(set.actions.count))]
      }))
    case "run_scene":
      let home = try pickHome(homes, input)
      let key = try need(input, "scene", for: "run_scene")
      guard let set = home.actionSets.first(where: { $0.uniqueIdentifier.uuidString == key || $0.name.localizedCaseInsensitiveCompare(key) == .orderedSame }) else {
        throw NanocodeError("no scene is called \(key)")
      }
      try await home.executeActionSet(set)
      return .json(["ran": .string(set.name)])
    default:
      throw unknown("home", homeActions)
    }
  }

  @MainActor static func pickHome(_ homes: [HMHome], _ input: JSON) throws -> HMHome {
    if let key = text(input, "home") {
      guard let found = homes.first(where: { $0.uniqueIdentifier.uuidString == key || $0.name.localizedCaseInsensitiveCompare(key) == .orderedSame }) else {
        throw NanocodeError("no home is called \(key)")
      }
      return found
    }
    return homes.first(where: \.isPrimary) ?? homes[0]
  }

  @MainActor static func pickAccessory(_ home: HMHome, _ key: String) throws -> HMAccessory {
    guard let found = home.accessories.first(where: { $0.uniqueIdentifier.uuidString == key })
      ?? home.accessories.first(where: { $0.name.localizedCaseInsensitiveCompare(key) == .orderedSame })
      ?? home.accessories.first(where: { $0.name.localizedCaseInsensitiveContains(key) }) else {
      throw NanocodeError("no accessory in \(home.name) is called \(key)")
    }
    return found
  }

  @MainActor static func describe(_ accessory: HMAccessory) -> JSON {
    ["id": .string(accessory.uniqueIdentifier.uuidString), "name": .string(accessory.name), "room": .string(accessory.room?.name ?? ""),
     "category": .string(accessory.category.localizedDescription), "reachable": .bool(accessory.isReachable),
     "manufacturer": string(accessory.manufacturer), "model": string(accessory.model),
     "services": .array(accessory.services.filter { $0.isUserInteractive }.map { service in
       ["id": .string(service.uniqueIdentifier.uuidString), "name": .string(service.name), "type": .string(service.localizedDescription),
        "characteristics": .array(service.characteristics.map { .object(characteristic($0)) })]
     })]
  }

  @MainActor static func characteristic(_ item: HMCharacteristic) -> [String: JSON] {
    var object: [String: JSON] = ["id": .string(item.uniqueIdentifier.uuidString), "type": .string(item.localizedDescription),
                                  "readable": .bool(item.properties.contains(HMCharacteristicPropertyReadable)),
                                  "writable": .bool(item.properties.contains(HMCharacteristicPropertyWritable))]
    if let kind = characteristicKinds.first(where: { $0.value == item.characteristicType })?.key { object["kind"] = .string(kind) }
    if let metadata = item.metadata {
      if let unit = metadata.units { object["unit"] = .string(unit.replacingOccurrences(of: "HMCharacteristicMetadataUnits", with: "").lowercased()) }
      if let minimum = metadata.minimumValue { object["min"] = .number(minimum.doubleValue) }
      if let maximum = metadata.maximumValue { object["max"] = .number(maximum.doubleValue) }
      if let step = metadata.stepValue { object["step"] = .number(step.doubleValue) }
    }
    switch item.value {
    case let flag as Bool where item.metadata?.format == HMCharacteristicMetadataFormatBool: object["value"] = .bool(flag)
    case let number as NSNumber: object["value"] = item.metadata?.format == HMCharacteristicMetadataFormatBool ? .bool(number.boolValue) : .number(number.doubleValue)
    case let text as String: object["value"] = .string(text)
    default: break
    }
    return object
  }

  @MainActor static func homeValue(_ value: JSON, for item: HMCharacteristic) throws -> Any {
    let format = item.metadata?.format
    if format == HMCharacteristicMetadataFormatBool {
      if let flag = value.bool { return flag }
      if let number = value.number { return number != 0 }
      if let text = value.string?.lowercased(), ["on", "off", "true", "false"].contains(text) { return text == "on" || text == "true" }
      throw NanocodeError("this characteristic takes true or false")
    }
    if format == HMCharacteristicMetadataFormatString {
      guard let text = value.string else { throw NanocodeError("this characteristic takes text") }
      return text
    }
    let number: Double
    if let given = value.number { number = given } else if let flag = value.bool { number = flag ? 1 : 0 } else {
      throw NanocodeError("this characteristic takes a number")
    }
    if let minimum = item.metadata?.minimumValue?.doubleValue, number < minimum { throw NanocodeError("the lowest value is \(minimum)") }
    if let maximum = item.metadata?.maximumValue?.doubleValue, number > maximum { throw NanocodeError("the highest value is \(maximum)") }
    if format == HMCharacteristicMetadataFormatFloat { return NSNumber(value: number) }
    guard number.rounded() == number else { throw NanocodeError("this characteristic takes a whole number") }
    return NSNumber(value: Int(number))
  }
}

@MainActor final class HomeHub: NSObject, @preconcurrency HMHomeManagerDelegate {
  static let shared = HomeHub()
  static let askedKey = "PhoneHomeAsked"
  private var manager: HMHomeManager?
  private var loaded = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  func homes() async -> [HMHome] {
    let manager = open()
    if !loaded {
      await withCheckedContinuation { continuation in
        waiters.append(continuation)
        Task { @MainActor in
          try? await Task.sleep(for: .seconds(60))
          self.release()
        }
      }
    }
    return manager.homes
  }

  func open() -> HMHomeManager {
    if let manager { return manager }
    let made = HMHomeManager()
    made.delegate = self
    manager = made
    UserDefaults.standard.set(true, forKey: Self.askedKey)
    return made
  }

  func permission() -> HandPermission {
    guard Entitlements.home else { return .denied }
    guard UserDefaults.standard.bool(forKey: Self.askedKey) else { return .prompt }
    let status = open().authorizationStatus
    if status.contains(.authorized) { return .granted }
    return status.contains(.determined) ? .denied : .prompt
  }

  func ask() async -> HandPermission {
    _ = await homes()
    return permission()
  }

  private func release() {
    loaded = true
    let waiting = waiters
    waiters = []
    for waiter in waiting { waiter.resume() }
  }

  func homeManagerDidUpdateHomes(_ manager: HMHomeManager) { release() }

  func homeManager(_ manager: HMHomeManager, didUpdate status: HMHomeManagerAuthorizationStatus) {
    if status.contains(.determined) && !status.contains(.authorized) { release() }
  }
}
#endif
