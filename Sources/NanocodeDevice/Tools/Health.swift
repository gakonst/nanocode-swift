#if os(iOS)
import Foundation
import HealthKit
import Nanocode

extension DeviceKit {
  static let healthActions = ["types", "authorize", "read", "statistics", "write", "delete", "characteristics", "workouts", "write_workout"]

  static let healthStore = HKHealthStore()

  static let quantityNames = [
    "stepCount", "distanceWalkingRunning", "distanceCycling", "distanceSwimming", "distanceWheelchair", "distanceDownhillSnowSports",
    "distanceCrossCountrySkiing", "distanceRowing", "distancePaddleSports", "distanceSkatingSports", "pushCount", "swimmingStrokeCount", "flightsClimbed",
    "nikeFuel", "appleExerciseTime", "appleMoveTime", "appleStandTime", "activeEnergyBurned", "basalEnergyBurned", "heartRate", "restingHeartRate",
    "walkingHeartRateAverage", "heartRateVariabilitySDNN", "heartRateRecoveryOneMinute", "atrialFibrillationBurden", "oxygenSaturation",
    "bodyTemperature", "basalBodyTemperature", "bloodPressureSystolic", "bloodPressureDiastolic", "respiratoryRate", "vo2Max",
    "peripheralPerfusionIndex", "bloodGlucose", "bloodAlcoholContent", "electrodermalActivity", "forcedVitalCapacity", "forcedExpiratoryVolume1",
    "peakExpiratoryFlowRate", "inhalerUsage", "insulinDelivery", "numberOfTimesFallen", "numberOfAlcoholicBeverages", "uvExposure",
    "environmentalAudioExposure", "headphoneAudioExposure", "environmentalSoundReduction", "timeInDaylight", "waterTemperature", "underwaterDepth",
    "bodyMass", "bodyMassIndex", "bodyFatPercentage", "leanBodyMass", "height", "waistCircumference", "appleSleepingWristTemperature",
    "appleSleepingBreathingDisturbances", "sixMinuteWalkTestDistance", "walkingSpeed", "walkingStepLength", "walkingAsymmetryPercentage",
    "walkingDoubleSupportPercentage", "stairAscentSpeed", "stairDescentSpeed", "appleWalkingSteadiness", "runningSpeed", "runningPower",
    "runningStrideLength", "runningVerticalOscillation", "runningGroundContactTime", "cyclingSpeed", "cyclingPower", "cyclingCadence",
    "cyclingFunctionalThresholdPower", "physicalEffort", "estimatedWorkoutEffortScore", "workoutEffortScore", "crossCountrySkiingSpeed",
    "paddleSportsSpeed", "rowingSpeed", "dietaryEnergyConsumed", "dietaryProtein", "dietaryCarbohydrates", "dietaryFatTotal", "dietaryFatSaturated",
    "dietaryFatMonounsaturated", "dietaryFatPolyunsaturated", "dietaryCholesterol", "dietarySodium", "dietarySugar", "dietaryFiber", "dietaryWater",
    "dietaryCaffeine", "dietaryCalcium", "dietaryIron", "dietaryPotassium", "dietaryVitaminA", "dietaryVitaminB6", "dietaryVitaminB12",
    "dietaryVitaminC", "dietaryVitaminD", "dietaryVitaminE", "dietaryVitaminK", "dietaryThiamin", "dietaryRiboflavin", "dietaryNiacin",
    "dietaryFolate", "dietaryBiotin", "dietaryPantothenicAcid", "dietaryPhosphorus", "dietaryIodine", "dietaryMagnesium", "dietaryZinc",
    "dietarySelenium", "dietaryCopper", "dietaryManganese", "dietaryChromium", "dietaryMolybdenum", "dietaryChloride",
  ]

  static let categoryRanges: [String: ClosedRange<Int>] = [
    "sleepAnalysis": 0...5, "mindfulSession": 0...0, "toothbrushingEvent": 0...0, "handwashingEvent": 0...0, "sexualActivity": 0...0,
    "intermenstrualBleeding": 0...0, "pregnancy": 0...0, "lactation": 0...0, "menstrualFlow": 1...5, "ovulationTestResult": 1...4,
    "cervicalMucusQuality": 1...5, "contraceptive": 1...7, "pregnancyTestResult": 1...3, "progesteroneTestResult": 1...3,
    "appetiteChanges": 0...3, "moodChanges": 0...1, "sleepChanges": 0...1, "bleedingDuringPregnancy": 0...0, "bleedingAfterPregnancy": 0...0,
    "infrequentMenstrualCycles": 0...0, "irregularMenstrualCycles": 0...0, "persistentIntermenstrualBleeding": 0...0, "prolongedMenstrualPeriods": 0...0,
  ]

  static let symptomNames = [
    "abdominalCramps", "acne", "bladderIncontinence", "bloating", "breastPain", "chestTightnessOrPain", "chills", "constipation", "coughing",
    "diarrhea", "dizziness", "drySkin", "fainting", "fatigue", "fever", "generalizedBodyAche", "hairLoss", "headache", "heartburn", "hotFlashes",
    "lossOfSmell", "lossOfTaste", "lowerBackPain", "memoryLapse", "nausea", "nightSweats", "pelvicPain", "rapidPoundingOrFlutteringHeartbeat",
    "runnyNose", "shortnessOfBreath", "sinusCongestion", "skippedHeartbeat", "soreThroat", "vaginalDryness", "vomiting", "wheezing",
  ]

  static let readOnlyCategoryNames = [
    "appleStandHour", "highHeartRateEvent", "lowHeartRateEvent", "irregularHeartRhythmEvent", "lowCardioFitnessEvent", "appleWalkingSteadinessEvent",
    "environmentalAudioExposureEvent", "headphoneAudioExposureEvent", "audioExposureEvent", "sleepApneaEvent",
  ]

  static let readOnlyQuantityNames: Set<String> = [
    "nikeFuel", "appleExerciseTime", "appleMoveTime", "appleStandTime", "walkingHeartRateAverage", "heartRateRecoveryOneMinute",
    "atrialFibrillationBurden", "appleWalkingSteadiness", "appleSleepingWristTemperature", "appleSleepingBreathingDisturbances",
    "estimatedWorkoutEffortScore", "environmentalSoundReduction", "walkingSpeed", "walkingStepLength", "walkingAsymmetryPercentage",
    "walkingDoubleSupportPercentage", "sixMinuteWalkTestDistance", "stairAscentSpeed", "stairDescentSpeed", "timeInDaylight",
  ]

  static let coreRead = ["stepCount", "distanceWalkingRunning", "activeEnergyBurned", "basalEnergyBurned", "flightsClimbed", "appleExerciseTime",
                         "heartRate", "restingHeartRate", "heartRateVariabilitySDNN", "oxygenSaturation", "respiratoryRate", "vo2Max", "bodyMass",
                         "height", "bodyFatPercentage", "sleepAnalysis", "mindfulSession", "workout", "dietaryWater", "dietaryEnergyConsumed"]
  static let coreWrite = ["bodyMass", "dietaryWater", "dietaryEnergyConsumed", "dietaryCaffeine", "mindfulSession", "workout", "sleepAnalysis"]

  static let workoutKinds: [String: HKWorkoutActivityType] = [
    "running": .running, "walking": .walking, "cycling": .cycling, "swimming": .swimming, "hiking": .hiking, "yoga": .yoga, "elliptical": .elliptical,
    "rowing": .rowing, "functional_strength": .functionalStrengthTraining, "strength": .traditionalStrengthTraining, "hiit": .highIntensityIntervalTraining,
    "dance": .cardioDance, "pilates": .pilates, "core": .coreTraining, "stairs": .stairClimbing, "tennis": .tennis, "soccer": .soccer,
    "basketball": .basketball, "climbing": .climbing, "skiing": .downhillSkiing, "snowboarding": .snowboarding, "boxing": .boxing,
    "martial_arts": .martialArts, "mind_and_body": .mindAndBody, "cooldown": .cooldown, "golf": .golf, "surfing": .surfingSports,
    "paddling": .paddleSports, "cross_training": .crossTraining, "mixed_cardio": .mixedCardio, "pickleball": .pickleball, "other": .other,
  ]

  static let health = HostTool(
    name: "health",
    description: "Apple Health on this iPhone, every data type. types: the type names (quantities like stepCount or heartRate, categories like sleepAnalysis or headache, workout, and characteristics). authorize: ask the owner for read and write access to a set of types (iOS shows its Health sheet; needs \(DeviceTools.settings.app) open). read: samples of a type between two dates. statistics: sums or averages of a quantity per hour, day, week or month. write: save a quantity (value and unit) or category sample. delete: remove samples \(DeviceTools.settings.app) wrote. characteristics: date of birth, sex, blood type, skin type, wheelchair use. workouts: recent workouts with energy and distance. write_workout: save a workout. iOS never says whether reading was refused: a refused type reads as empty.",
    parameters: schema(healthActions, [
      "type": prop("string", "A type name from types, such as stepCount, heartRate, sleepAnalysis or workout."),
      "read": list(prop("string"), "For authorize: types to read."),
      "write": list(prop("string"), "For authorize: types to write."),
      "from": when, "to": when,
      "limit": prop("integer", "For read and workouts: how many, newest first (100 by default)."),
      "ascending": prop("boolean", "For read: oldest first."),
      "interval": choice(["hour", "day", "week", "month"], "For statistics: day by default."),
      "aggregate": choice(["sum", "average", "min", "max", "latest"], "For statistics: cumulative types (steps, energy, distance…) only sum; the others average (default), min, max or latest."),
      "unit": prop("string", "A unit such as count, kg, lb, km, mi, kcal, bpm, %, degC, mg/dL; the owner's preferred unit by default."),
      "value": prop("number", "For write: the quantity, or a category value (sleepAnalysis: 0 in bed, 1 asleep, 2 awake, 3 core, 4 deep, 5 REM; symptoms: 0 present, 1 not present, 2 mild, 3 moderate, 4 severe)."),
      "start": when, "end": when,
      "uuid": prop("string", "For delete: the sample's uuid from read."),
      "activity": prop("string", "For write_workout: running, walking, cycling, swimming, hiking, yoga, strength, hiit, other and more."),
      "energy_kcal": prop("number", "For write_workout: active energy burned."),
      "distance_m": prop("number", "For write_workout: distance."),
      "metadata": .object(["type": "object", "description": "For write: extra HealthKit metadata as strings, numbers or booleans."]),
    ])
  ) { call in try await healthData(call.input) }

  static func objectType(_ name: String) throws -> HKObjectType {
    if name == "workout" { return HKObjectType.workoutType() }
    let capital = name.prefix(1).uppercased() + name.dropFirst()
    let fixed = capital.replacingOccurrences(of: "Vo2Max", with: "VO2Max").replacingOccurrences(of: "UvExposure", with: "UVExposure")
    if quantityNames.contains(name), let type = HKObjectType.quantityType(forIdentifier: HKQuantityTypeIdentifier(rawValue: "HKQuantityTypeIdentifier" + fixed)) {
      return type
    }
    if categoryRanges[name] != nil || symptomNames.contains(name) || readOnlyCategoryNames.contains(name),
       let type = HKObjectType.categoryType(forIdentifier: HKCategoryTypeIdentifier(rawValue: "HKCategoryTypeIdentifier" + fixed)) {
      return type
    }
    if let characteristic = characteristicNames[name], let type = HKObjectType.characteristicType(forIdentifier: characteristic) { return type }
    throw NanocodeError("\(name) is not a Health type this iPhone knows; types lists them")
  }

  static let characteristicNames: [String: HKCharacteristicTypeIdentifier] = [
    "dateOfBirth": .dateOfBirth, "biologicalSex": .biologicalSex, "bloodType": .bloodType, "fitzpatrickSkinType": .fitzpatrickSkinType,
    "wheelchairUse": .wheelchairUse, "activityMoveMode": .activityMoveMode,
  ]

  static func writable(_ name: String) -> Bool {
    if name == "workout" { return true }
    if quantityNames.contains(name) { return !readOnlyQuantityNames.contains(name) }
    return categoryRanges[name] != nil || symptomNames.contains(name)
  }

  static func sampleType(_ name: String) throws -> HKSampleType {
    guard let type = try objectType(name) as? HKSampleType else { throw NanocodeError("\(name) is a characteristic; read it with characteristics") }
    return type
  }

  static func healthData(_ input: JSON) async throws -> ToolResult {
    try await DeviceTools.gate("health")
    guard HKHealthStore.isHealthDataAvailable() else { throw NanocodeError("Health data is not available on this device") }
    switch input["action"]?.string {
    case "types":
      return .json(["quantities": .array(quantityNames.map { name in
                      ["name": .string(name), "writable": .bool(writable(name))]
                    }),
                    "categories": .array((categoryRanges.keys.sorted() + symptomNames + readOnlyCategoryNames).map { name in
                      ["name": .string(name), "writable": .bool(writable(name))]
                    }),
                    "workout": ["name": "workout", "writable": true],
                    "characteristics": .array(characteristicNames.keys.sorted().map(JSON.string))])
    case "authorize":
      try await foreground("Asking for Health access")
      let read = try texts(input, "read").map(objectType)
      let writeNames = texts(input, "write")
      if let refused = writeNames.first(where: { !writable($0) }) { throw NanocodeError("\(refused) is read-only in Health; ask to read it instead") }
      let write = try writeNames.map(sampleType)
      guard !read.isEmpty || !write.isEmpty else { throw NanocodeError("authorize takes read or write types") }
      try await healthStore.requestAuthorization(toShare: Set(write), read: Set(read))
      return .json(.object(Dictionary(uniqueKeysWithValues: writeNames.map { name in
        (name, JSON.string(status(try? sampleType(name))))
      }).merging(["asked": .bool(true)]) { first, _ in first }))
    case "read":
      let name = try need(input, "type", for: "read")
      let type = try sampleType(name)
      try await needAccess(read: [type])
      let samples = try await query(type, input, limit: try count(input, 100, most: 100_000))
      let unit = try await unit(for: type, input)
      return .json(.array(samples.map { sample(name, $0, unit: unit) }))
    case "statistics":
      let name = try need(input, "type", for: "statistics")
      guard let type = try objectType(name) as? HKQuantityType else { throw NanocodeError("statistics works on quantity types") }
      try await needAccess(read: [type])
      return .json(try await statistics(type, input))
    case "write":
      let name = try need(input, "type", for: "write")
      guard writable(name) else { throw NanocodeError("\(name) is read-only in Health") }
      let type = try sampleType(name)
      try await needAccess(write: [type])
      let start = DeviceTools.date(input["start"]) ?? Date()
      let end = DeviceTools.date(input["end"]) ?? start
      guard end >= start else { throw NanocodeError("end must not be before start") }
      guard let value = input["value"]?.number else { throw NanocodeError("write takes a value") }
      let metadata = input["metadata"]?.object?.compactMapValues { value -> Any? in value.string ?? value.number ?? value.bool }
      let saved: HKSample
      if let quantityType = type as? HKQuantityType {
        let unit = try await unit(for: quantityType, input)
        saved = HKQuantitySample(type: quantityType, quantity: HKQuantity(unit: unit, doubleValue: value), start: start, end: end, metadata: metadata)
      } else if let categoryType = type as? HKCategoryType {
        let range = categoryRanges[name] ?? 0...4
        let code = Int(value)
        guard Double(code) == value, range.contains(code) else {
          throw NanocodeError("\(name) takes a whole value from \(range.lowerBound) to \(range.upperBound)")
        }
        var extra = metadata ?? [:]
        if name == "menstrualFlow", extra[HKMetadataKeyMenstrualCycleStart] == nil { extra[HKMetadataKeyMenstrualCycleStart] = false }
        if name == "sexualActivity", extra[HKMetadataKeySexualActivityProtectionUsed] == nil { extra[HKMetadataKeySexualActivityProtectionUsed] = false }
        saved = HKCategorySample(type: categoryType, value: code, start: start, end: end, metadata: extra.isEmpty ? nil : extra)
      } else {
        throw NanocodeError("write saves quantities and categories; use write_workout for workouts")
      }
      try await healthStore.save(saved)
      return .json(["saved": .string(saved.uuid.uuidString), "type": .string(name)])
    case "delete":
      let name = try need(input, "type", for: "delete")
      let type = try sampleType(name)
      guard let uuid = text(input, "uuid").flatMap(UUID.init(uuidString:)) else { throw NanocodeError("delete takes a sample's uuid") }
      let removed = try await healthStore.deleteObjects(of: type, predicate: HKQuery.predicateForObject(with: uuid))
      return .json(["deleted": .number(Double(removed))])
    case "characteristics":
      try await needAccess(read: characteristicNames.values.compactMap { HKObjectType.characteristicType(forIdentifier: $0) })
      var object: [String: JSON] = [:]
      if let birth = try? healthStore.dateOfBirthComponents(), let year = birth.year, let month = birth.month, let day = birth.day {
        object["date_of_birth"] = .string(String(format: "%04d-%02d-%02d", year, month, day))
      }
      if let sex = try? healthStore.biologicalSex().biologicalSex {
        object["biological_sex"] = .string(sex == .female ? "female" : sex == .male ? "male" : sex == .other ? "other" : "not_set")
      }
      if let blood = try? healthStore.bloodType().bloodType {
        let names: [HKBloodType: String] = [.aPositive: "A+", .aNegative: "A-", .bPositive: "B+", .bNegative: "B-", .abPositive: "AB+",
                                            .abNegative: "AB-", .oPositive: "O+", .oNegative: "O-"]
        object["blood_type"] = .string(names[blood] ?? "not_set")
      }
      if let skin = try? healthStore.fitzpatrickSkinType().skinType, skin != .notSet { object["skin_type"] = .number(Double(skin.rawValue)) }
      if let wheelchair = try? healthStore.wheelchairUse().wheelchairUse, wheelchair != .notSet { object["wheelchair"] = .bool(wheelchair == .yes) }
      return .json(.object(object))
    case "workouts":
      let type = HKObjectType.workoutType()
      try await needAccess(read: [type])
      let found = try await query(type, input, limit: try count(input, 50, most: 100_000))
      return .json(.array(found.compactMap { $0 as? HKWorkout }.map(describe)))
    case "write_workout":
      let type = HKObjectType.workoutType()
      try await needAccess(write: [type])
      guard let start = DeviceTools.date(input["start"]), let end = DeviceTools.date(input["end"]), end > start else {
        throw NanocodeError("write_workout takes a start and a later end")
      }
      let activity = input["activity"]?.string ?? "other"
      guard let kind = workoutKinds[activity] else { throw NanocodeError("activity is one of \(workoutKinds.keys.sorted().joined(separator: ", "))") }
      let configuration = HKWorkoutConfiguration()
      configuration.activityType = kind
      let builder = HKWorkoutBuilder(healthStore: healthStore, configuration: configuration, device: .local())
      try await builder.beginCollection(at: start)
      var samples: [HKSample] = []
      if let energy = input["energy_kcal"]?.number, let energyType = HKObjectType.quantityType(forIdentifier: .activeEnergyBurned) {
        try await needAccess(write: [energyType])
        samples.append(HKQuantitySample(type: energyType, quantity: HKQuantity(unit: .kilocalorie(), doubleValue: energy), start: start, end: end))
      }
      if let distance = input["distance_m"]?.number, let distanceType = HKObjectType.quantityType(forIdentifier: kind == .cycling ? .distanceCycling : kind == .swimming ? .distanceSwimming : .distanceWalkingRunning) {
        try await needAccess(write: [distanceType])
        samples.append(HKQuantitySample(type: distanceType, quantity: HKQuantity(unit: .meter(), doubleValue: distance), start: start, end: end))
      }
      if !samples.isEmpty { try await builder.addSamples(samples) }
      try await builder.endCollection(at: end)
      guard let workout = try await builder.finishWorkout() else { throw NanocodeError("Health didn't save the workout") }
      return .json(describe(workout))
    default:
      throw unknown("health", healthActions)
    }
  }

  static func status(_ type: HKObjectType?) -> String {
    guard let type else { return "unknown" }
    switch healthStore.authorizationStatus(for: type) {
    case .sharingAuthorized: return "allowed"
    case .sharingDenied: return "denied"
    default: return "not_asked"
    }
  }

  static func needAccess(read: [HKObjectType] = [], write: [HKSampleType] = []) async throws {
    let request = try await healthStore.statusForAuthorizationRequest(toShare: Set(write), read: Set(read))
    if request == .shouldRequest {
      let names = (read + write.map { $0 as HKObjectType }).map(\.identifier).map(shortName)
      throw NanocodeError("Health access for \(Set(names).sorted().joined(separator: ", ")) hasn't been asked for yet; call health with action authorize and these types (read and/or write) while the owner has \(DeviceTools.settings.app) open, saying why")
    }
    for type in write where healthStore.authorizationStatus(for: type) == .sharingDenied {
      throw NanocodeError("the owner didn't allow writing \(shortName(type.identifier)); they can allow it in the Health app › Sharing › Apps › \(DeviceTools.settings.app)")
    }
  }

  static func shortName(_ identifier: String) -> String {
    for prefix in ["HKQuantityTypeIdentifier", "HKCategoryTypeIdentifier", "HKCharacteristicTypeIdentifier"] where identifier.hasPrefix(prefix) {
      let rest = identifier.dropFirst(prefix.count)
      let lowered = rest.prefix(1).lowercased() + rest.dropFirst()
      return lowered.replacingOccurrences(of: "vO2Max", with: "vo2Max").replacingOccurrences(of: "uVExposure", with: "uvExposure")
    }
    return identifier == HKObjectType.workoutType().identifier ? "workout" : identifier
  }

  static func query(_ type: HKSampleType, _ input: JSON, limit: Int) async throws -> [HKSample] {
    let start = DeviceTools.date(input["from"]) ?? Date().addingTimeInterval(-7 * 86_400)
    let end = DeviceTools.date(input["to"]) ?? Date()
    let predicate = HKQuery.predicateForSamples(withStart: start, end: end)
    let descriptor = HKSampleQueryDescriptor(predicates: [.sample(type: type, predicate: predicate)],
                                             sortDescriptors: [SortDescriptor(\.startDate, order: input["ascending"]?.bool == true ? .forward : .reverse)],
                                             limit: limit)
    return try await descriptor.result(for: healthStore)
  }

  static let unitNames: [String: HKUnit] = {
    var names = baseUnitNames
    if #available(iOS 18.0, *) { names["appleeffortscore"] = .appleEffortScore() }
    return names
  }()

  static let baseUnitNames: [String: HKUnit] = [
    "count": .count(), "%": .percent(), "kg": .gramUnit(with: .kilo), "g": .gram(), "mg": .gramUnit(with: .milli), "mcg": .gramUnit(with: .micro),
    "lb": .pound(), "oz": .ounce(), "st": .stone(), "m": .meter(), "km": .meterUnit(with: .kilo), "cm": .meterUnit(with: .centi), "mm": .meterUnit(with: .milli),
    "mi": .mile(), "ft": .foot(), "in": .inch(), "yd": .yard(), "kcal": .kilocalorie(), "kj": .jouleUnit(with: .kilo), "s": .second(), "min": .minute(),
    "hr": .hour(), "ms": .secondUnit(with: .milli), "degc": .degreeCelsius(), "degf": .degreeFahrenheit(), "mmhg": .millimeterOfMercury(),
    "l": .liter(), "ml": .literUnit(with: .milli), "fl_oz_us": .fluidOunceUS(), "bpm": .count().unitDivided(by: .minute()),
    "count/min": .count().unitDivided(by: .minute()), "mg/dl": .gramUnit(with: .milli).unitDivided(by: .literUnit(with: .deci)),
    "mmol/l": .moleUnit(with: .milli, molarMass: HKUnitMolarMassBloodGlucose).unitDivided(by: .liter()), "db": .decibelAWeightedSoundPressureLevel(),
    "w": .watt(), "m/s": .meter().unitDivided(by: .second()), "km/hr": .meterUnit(with: .kilo).unitDivided(by: .hour()),
    "mi/hr": .mile().unitDivided(by: .hour()), "iu": .internationalUnit(), "ml/(kg*min)": .literUnit(with: .milli).unitDivided(by: .gramUnit(with: .kilo).unitMultiplied(by: .minute())),
    "s/m": .second().unitDivided(by: .meter()), "kcal/hr*kg": .kilocalorie().unitDivided(by: .hour().unitMultiplied(by: .gramUnit(with: .kilo))),
    "lux": .lux(), "us": .siemenUnit(with: .micro),
  ]

  static func unit(for type: HKSampleType, _ input: JSON) async throws -> HKUnit? {
    guard let quantity = type as? HKQuantityType else { return nil }
    return try await unit(for: quantity, input)
  }

  static func unit(for type: HKQuantityType, _ input: JSON) async throws -> HKUnit {
    if let name = text(input, "unit") {
      guard let unit = unitNames[name.lowercased()] else {
        throw NanocodeError("unit is one of \(unitNames.keys.sorted().joined(separator: ", ")); leave it out for the owner's preferred unit")
      }
      guard type.is(compatibleWith: unit) else { throw NanocodeError("\(name) is not a unit of \(shortName(type.identifier))") }
      return unit
    }
    if let preferred = try await healthStore.preferredUnits(for: [type])[type] { return preferred }
    if let fallback = unitNames.values.first(where: { type.is(compatibleWith: $0) }) { return fallback }
    throw NanocodeError("no unit fits \(shortName(type.identifier)); give one")
  }

  static func sample(_ name: String, _ sample: HKSample, unit: HKUnit?) -> JSON {
    var object: [String: JSON] = ["uuid": .string(sample.uuid.uuidString), "start": DeviceTools.stamp(sample.startDate), "end": DeviceTools.stamp(sample.endDate),
                                  "source": .string(sample.sourceRevision.source.name)]
    if let device = sample.device?.name { object["device"] = .string(device) }
    if let quantity = sample as? HKQuantitySample, let unit {
      object["value"] = .number(quantity.quantity.doubleValue(for: unit))
      object["unit"] = .string(unit.unitString)
    } else if let category = sample as? HKCategorySample {
      object["value"] = .number(Double(category.value))
      if name == "sleepAnalysis" {
        let stages = ["in_bed", "asleep", "awake", "core", "deep", "rem"]
        if stages.indices.contains(category.value) { object["stage"] = .string(stages[category.value]) }
      }
    } else if let workout = sample as? HKWorkout {
      return describe(workout)
    }
    if let metadata = sample.metadata, !metadata.isEmpty {
      object["metadata"] = .object(metadata.compactMapValues { value -> JSON? in
        switch value {
        case let text as String: .string(text)
        case let number as NSNumber: .number(number.doubleValue)
        case let date as Date: DeviceTools.stamp(date)
        case let quantity as HKQuantity: .string(quantity.description)
        default: nil
        }
      })
    }
    return .object(object)
  }

  static func describe(_ workout: HKWorkout) -> JSON {
    let kind = workoutKinds.first { $0.value == workout.workoutActivityType }?.key ?? "type_\(workout.workoutActivityType.rawValue)"
    var object: [String: JSON] = ["uuid": .string(workout.uuid.uuidString), "activity": .string(kind), "start": DeviceTools.stamp(workout.startDate),
                                  "end": DeviceTools.stamp(workout.endDate), "minutes": .number((workout.duration / 60).rounded()),
                                  "source": .string(workout.sourceRevision.source.name)]
    if let type = HKObjectType.quantityType(forIdentifier: .activeEnergyBurned), let energy = workout.statistics(for: type)?.sumQuantity() {
      object["energy_kcal"] = .number(energy.doubleValue(for: .kilocalorie()).rounded())
    }
    for identifier in [HKQuantityTypeIdentifier.distanceWalkingRunning, .distanceCycling, .distanceSwimming] {
      if let type = HKObjectType.quantityType(forIdentifier: identifier), let distance = workout.statistics(for: type)?.sumQuantity() {
        object["distance_m"] = .number(distance.doubleValue(for: .meter()).rounded())
      }
    }
    if let type = HKObjectType.quantityType(forIdentifier: .heartRate), let rate = workout.statistics(for: type)?.averageQuantity() {
      object["average_heart_rate"] = .number(rate.doubleValue(for: .count().unitDivided(by: .minute())).rounded())
    }
    return .object(object)
  }

  static func statistics(_ type: HKQuantityType, _ input: JSON) async throws -> JSON {
    let start = DeviceTools.date(input["from"]) ?? Calendar.current.startOfDay(for: Date()).addingTimeInterval(-6 * 86_400)
    let end = DeviceTools.date(input["to"]) ?? Date()
    guard end > start else { throw NanocodeError("to must be after from") }
    let cumulative = type.aggregationStyle == .cumulative
    let aggregate = input["aggregate"]?.string ?? (cumulative ? "sum" : "average")
    let options: HKStatisticsOptions
    switch aggregate {
    case "sum":
      guard cumulative else { throw NanocodeError("\(shortName(type.identifier)) can't be summed; use average, min, max or latest") }
      options = .cumulativeSum
    case "average", "min", "max", "latest":
      guard !cumulative else { throw NanocodeError("\(shortName(type.identifier)) is cumulative; use sum") }
      options = aggregate == "average" ? .discreteAverage : aggregate == "min" ? .discreteMin : aggregate == "max" ? .discreteMax : .mostRecent
    default: throw NanocodeError("aggregate is sum, average, min, max or latest")
    }
    var step = DateComponents()
    switch input["interval"]?.string ?? "day" {
    case "hour": step.hour = 1
    case "day": step.day = 1
    case "week": step.day = 7
    case "month": step.month = 1
    default: throw NanocodeError("interval is hour, day, week or month")
    }
    let unit = try await unit(for: type, input)
    let predicate = HKQuery.predicateForSamples(withStart: start, end: end)
    let descriptor = HKStatisticsCollectionQueryDescriptor(predicate: .quantitySample(type: type, predicate: predicate), options: options,
                                                           anchorDate: Calendar.current.startOfDay(for: start), intervalComponents: step)
    let collection = try await descriptor.result(for: healthStore)
    var rows: [JSON] = []
    collection.enumerateStatistics(from: start, to: end) { statistics, _ in
      let quantity: HKQuantity? = switch aggregate {
      case "sum": statistics.sumQuantity()
      case "average": statistics.averageQuantity()
      case "min": statistics.minimumQuantity()
      case "max": statistics.maximumQuantity()
      default: statistics.mostRecentQuantity()
      }
      guard let quantity else { return }
      rows.append(["start": DeviceTools.stamp(statistics.startDate), "end": DeviceTools.stamp(statistics.endDate),
                   "value": .number((quantity.doubleValue(for: unit) * 100).rounded() / 100)])
    }
    return ["type": .string(shortName(type.identifier)), "unit": .string(unit.unitString), "aggregate": .string(aggregate), "rows": .array(rows)]
  }

  static func healthPermission() async -> HandPermission {
    guard Entitlements.health, HKHealthStore.isHealthDataAvailable() else { return .denied }
    guard let read = try? coreRead.map(objectType), let write = try? coreWrite.map(sampleType),
          let status = try? await healthStore.statusForAuthorizationRequest(toShare: Set(write), read: Set(read)) else { return .prompt }
    return status == .unnecessary ? .granted : .prompt
  }

  static func askHealth() async -> HandPermission {
    guard let read = try? coreRead.map(objectType), let write = try? coreWrite.map(sampleType) else { return .denied }
    try? await healthStore.requestAuthorization(toShare: Set(write), read: Set(read))
    return await healthPermission()
  }
}
#endif
