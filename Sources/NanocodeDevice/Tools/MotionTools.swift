#if os(iOS)
import CoreMotion
import Foundation
import Nanocode

extension DeviceKit {
  static let motionActions = ["summary", "activities", "sensors", "altitude"]

  static let motion = HostTool(
    name: "motion",
    description: "Motion on this \(DeviceTools.here). summary: steps, distance, floors, pace and cadence, and minutes walking, running, cycling, driving or still between two dates (today by default; iOS keeps 7 days). activities: each stretch of activity with its start, kind and confidence. sensors: average orientation, gravity, acceleration and heading over a few seconds. altitude: barometric pressure, relative and absolute altitude over a few seconds.",
    parameters: DeviceTools.schema([
      "action": DeviceTools.actions(motionActions),
      "from": when, "to": when,
      "seconds": prop("number", "For sensors and altitude: how long to sample, 3 by default."),
    ])
  ) { call in try await movement(call.input) }

  nonisolated(unsafe) static let sensorManager = CMMotionManager()
  nonisolated(unsafe) static let altimeter = CMAltimeter()

  static func movement(_ input: JSON) async throws -> ToolResult {
    let action = input["action"]?.string ?? "summary"
    let start = DeviceTools.date(input["from"]) ?? Calendar.current.startOfDay(for: Date())
    let end = DeviceTools.date(input["to"]) ?? Date()
    let seconds = input["seconds"]?.number ?? 3
    switch action {
    case "summary":
      try await DeviceTools.gate("motion")
      guard CMPedometer.isStepCountingAvailable() else { throw NanocodeError("this \(DeviceTools.here) does not count steps") }
      var object = try await DeviceTools.steps(start, end)
      let extra = try await pace(start, end)
      object.merge(extra) { first, _ in first }
      if CMMotionActivityManager.isActivityAvailable() { object["activity_minutes"] = await DeviceTools.moved(start, end) }
      object["from"] = DeviceTools.stamp(start)
      object["to"] = DeviceTools.stamp(end)
      return .json(.object(object))
    case "activities":
      try await DeviceTools.gate("motion")
      guard CMMotionActivityManager.isActivityAvailable() else { throw NanocodeError("this \(DeviceTools.here) does not record activity") }
      return .json(.array(await stretches(start, end)))
    case "sensors":
      guard sensorManager.isDeviceMotionAvailable else { throw NanocodeError("this \(DeviceTools.here) has no motion sensors available") }
      guard seconds > 0, seconds <= 60 else { throw NanocodeError("seconds is above 0 and at most 60") }
      return .json(try await sample(seconds))
    case "altitude":
      try await DeviceTools.gate("motion")
      guard CMAltimeter.isRelativeAltitudeAvailable() else { throw NanocodeError("this \(DeviceTools.here) has no barometer") }
      guard seconds > 0, seconds <= 60 else { throw NanocodeError("seconds is above 0 and at most 60") }
      return .json(await barometer(seconds))
    default:
      throw unknown("motion", motionActions)
    }
  }

  static func pace(_ start: Date, _ end: Date) async throws -> [String: JSON] {
    try await withCheckedThrowingContinuation { continuation in
      DeviceTools.pedometer.queryPedometerData(from: start, to: end) { data, error in
        guard let data else {
          continuation.resume(throwing: error ?? NanocodeError("motion data is not available"))
          return
        }
        var object: [String: JSON] = [:]
        if let pace = data.averageActivePace { object["average_pace_s_per_m"] = .number(pace.doubleValue) }
        if let pace = data.currentPace { object["current_pace_s_per_m"] = .number(pace.doubleValue) }
        if let cadence = data.currentCadence { object["cadence_steps_per_s"] = .number(cadence.doubleValue) }
        continuation.resume(returning: object)
      }
    }
  }

  static func stretches(_ start: Date, _ end: Date) async -> [JSON] {
    await withCheckedContinuation { continuation in
      DeviceTools.activities.queryActivityStarting(from: start, to: end, to: OperationQueue()) { found, _ in
        let found = found ?? []
        let list: [JSON] = found.enumerated().map { index, activity in
          let until = index + 1 < found.count ? found[index + 1].startDate : end
          let kind = activity.walking ? "walking" : activity.running ? "running" : activity.cycling ? "cycling"
            : activity.automotive ? "vehicle" : activity.stationary ? "stationary" : "unknown"
          let confidence = switch activity.confidence {
          case .high: "high"
          case .medium: "medium"
          default: "low"
          }
          return ["start": DeviceTools.stamp(activity.startDate), "end": DeviceTools.stamp(until), "kind": .string(kind), "confidence": .string(confidence),
                  "minutes": .number((until.timeIntervalSince(activity.startDate) / 60).rounded())]
        }
        continuation.resume(returning: list)
      }
    }
  }

  final class Samples: @unchecked Sendable {
    let lock = NSLock()
    var values: [[Double]] = []
    func add(_ value: [Double]) { lock.withLock { values.append(value) } }
    func average() -> [Double] {
      lock.withLock {
        guard let first = values.first else { return [] }
        return (0..<first.count).map { index in values.map { $0[index] }.reduce(0, +) / Double(values.count) }
      }
    }
    var count: Int { lock.withLock { values.count } }
  }

  static func sample(_ seconds: Double) async throws -> JSON {
    let samples = Samples()
    let queue = OperationQueue()
    sensorManager.deviceMotionUpdateInterval = 0.05
    let frame: CMAttitudeReferenceFrame = CMMotionManager.availableAttitudeReferenceFrames().contains(.xMagneticNorthZVertical)
      ? .xMagneticNorthZVertical : .xArbitraryZVertical
    sensorManager.startDeviceMotionUpdates(using: frame, to: queue) { motion, _ in
      guard let motion else { return }
      samples.add([motion.attitude.pitch, motion.attitude.roll, motion.attitude.yaw, motion.gravity.x, motion.gravity.y, motion.gravity.z,
                   motion.userAcceleration.x, motion.userAcceleration.y, motion.userAcceleration.z, motion.heading])
    }
    try? await Task.sleep(for: .seconds(seconds))
    sensorManager.stopDeviceMotionUpdates()
    let mean = samples.average()
    guard mean.count == 10 else { throw NanocodeError("the motion sensors gave no readings") }
    let degrees = { (radians: Double) in JSON.number((radians * 180 / .pi).rounded()) }
    let rounded = { (value: Double) in JSON.number((value * 1000).rounded() / 1000) }
    return ["samples": .number(Double(samples.count)),
            "attitude_degrees": ["pitch": degrees(mean[0]), "roll": degrees(mean[1]), "yaw": degrees(mean[2])],
            "gravity_g": ["x": rounded(mean[3]), "y": rounded(mean[4]), "z": rounded(mean[5])],
            "user_acceleration_g": ["x": rounded(mean[6]), "y": rounded(mean[7]), "z": rounded(mean[8])],
            "heading_degrees": frame == .xMagneticNorthZVertical && mean[9] >= 0 ? .number(mean[9].rounded()) : .null,
            "face": .string(mean[5] < -0.8 ? "up" : mean[5] > 0.8 ? "down" : "tilted")]
  }

  static func barometer(_ seconds: Double) async -> JSON {
    let relative = Samples()
    let absolute = Samples()
    let queue = OperationQueue()
    altimeter.startRelativeAltitudeUpdates(to: queue) { data, _ in
      if let data { relative.add([data.relativeAltitude.doubleValue, data.pressure.doubleValue]) }
    }
    if CMAltimeter.isAbsoluteAltitudeAvailable() {
      altimeter.startAbsoluteAltitudeUpdates(to: queue) { data, _ in
        if let data { absolute.add([data.altitude, data.accuracy]) }
      }
    }
    try? await Task.sleep(for: .seconds(seconds))
    altimeter.stopRelativeAltitudeUpdates()
    altimeter.stopAbsoluteAltitudeUpdates()
    let pressure = relative.average()
    let height = absolute.average()
    return ["pressure_kpa": pressure.count == 2 ? .number((pressure[1] * 100).rounded() / 100) : .null,
            "relative_altitude_m": pressure.count == 2 ? .number((pressure[0] * 100).rounded() / 100) : .null,
            "altitude_m": height.count == 2 ? .number(height[0].rounded()) : .null,
            "altitude_accuracy_m": height.count == 2 ? .number(height[1].rounded()) : .null]
  }
}
#endif
