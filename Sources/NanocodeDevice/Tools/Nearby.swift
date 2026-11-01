#if os(iOS)
@preconcurrency import CoreBluetooth
@preconcurrency import CoreNFC
import Foundation
import Nanocode
import Network

extension DeviceKit {
  static let bluetoothActions = ["scan", "inspect", "read", "write"]

  static let bluetooth = HostTool(
    name: "bluetooth",
    description: "Bluetooth Low Energy devices near this iPhone. scan: devices advertising nearby for some seconds, strongest first, with names, services and manufacturer data. inspect: connect to one (id from scan) and list its services and characteristics with every readable value. read: one characteristic's value. write: send bytes (hex) or text to a characteristic. Classic Bluetooth audio devices don't show; iOS only lets apps use BLE.",
    parameters: schema(bluetoothActions, [
      "seconds": prop("number", "For scan: how long, 5 by default and at most 60. For the others: how long to wait for the device, 10 by default."),
      "services": list(prop("string"), "For scan: only devices advertising these service UUIDs."),
      "id": prop("string", "The device id from scan."),
      "service": prop("string", "For read and write: the service UUID."),
      "characteristic": prop("string", "For read and write: the characteristic UUID."),
      "hex": prop("string", "For write: bytes as hex."),
      "text": prop("string", "For write: UTF-8 text."),
      "with_response": prop("boolean", "For write: wait for the device to confirm (true by default when it supports it)."),
    ])
  ) { call in try await radio(call.input) }

  @MainActor static func radio(_ input: JSON) async throws -> ToolResult {
    try await DeviceTools.gate("bluetooth")
    let action = input["action"]?.string ?? "scan"
    let seconds = input["seconds"]?.number
    switch action {
    case "scan":
      let wait = seconds ?? 5
      guard wait > 0, wait <= 60 else { throw NanocodeError("seconds is above 0 and at most 60") }
      let services = try texts(input, "services").map(uuid)
      return .json(.array(try await BLE().scan(seconds: wait, services: services)))
    case "inspect", "read", "write":
      let wait = seconds ?? 10
      guard wait > 0, wait <= 60 else { throw NanocodeError("seconds is above 0 and at most 60") }
      guard let id = text(input, "id").flatMap(UUID.init(uuidString:)) else { throw NanocodeError("\(action) takes a device id from scan") }
      let session = BLE()
      if action == "inspect" { return .json(try await session.inspect(id, seconds: wait)) }
      let service = try uuid(try need(input, "service", for: action))
      let characteristic = try uuid(try need(input, "characteristic", for: action))
      if action == "read" { return .json(try await session.read(id, service, characteristic, seconds: wait)) }
      let bytes: Data
      if let hex = text(input, "hex") {
        guard let decoded = Data(hex: hex) else { throw NanocodeError("hex takes pairs of hex digits") }
        bytes = decoded
      } else if let value = input["text"]?.string {
        bytes = Data(value.utf8)
      } else {
        throw NanocodeError("write takes hex or text")
      }
      return .json(try await session.write(id, service, characteristic, bytes, response: input["with_response"]?.bool, seconds: wait))
    default:
      throw unknown("bluetooth", bluetoothActions)
    }
  }

  static func uuid(_ text: String) throws -> CBUUID {
    let clean = text.trimmingCharacters(in: .whitespaces)
    let hex = clean.replacingOccurrences(of: "-", with: "")
    guard [4, 8, 32].contains(hex.count), hex.allSatisfy(\.isHexDigit) else { throw NanocodeError("\(text) is not a Bluetooth UUID") }
    return CBUUID(string: clean)
  }

  @MainActor final class BLE: NSObject, @preconcurrency CBCentralManagerDelegate, @preconcurrency CBPeripheralDelegate {
    var manager: CBCentralManager?
    var ready: CheckedContinuation<CBManagerState, Never>?
    var found: [UUID: [String: JSON]] = [:]
    var order: [UUID: Int] = [:]
    var step: CheckedContinuation<String?, Never>?
    var token = 0
    var peripheral: CBPeripheral?

    func start() async throws -> CBCentralManager {
      if let manager, manager.state == .poweredOn { return manager }
      let state = await withCheckedContinuation { continuation in
        ready = continuation
        manager = CBCentralManager(delegate: self, queue: .main)
      }
      guard let manager, state == .poweredOn else {
        throw NanocodeError(state == .unauthorized ? "Bluetooth access is off for this app; the owner can turn it on in iOS Settings › \(DeviceTools.settings.app)." : "Bluetooth is off or unavailable")
      }
      return manager
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
      guard central.state != .unknown, central.state != .resetting else { return }
      ready?.resume(returning: central.state)
      ready = nil
    }

    func scan(seconds: Double, services: [CBUUID]) async throws -> [JSON] {
      let manager = try await start()
      manager.scanForPeripherals(withServices: services.isEmpty ? nil : services, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
      try? await Task.sleep(for: .seconds(seconds))
      manager.stopScan()
      return found.values.sorted { ($0["rssi"]?.number ?? -200) > ($1["rssi"]?.number ?? -200) }.map(JSON.object)
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
      var object: [String: JSON] = [
        "id": .string(peripheral.identifier.uuidString),
        "name": .string(peripheral.name ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? ""),
        "rssi": .number(RSSI.doubleValue),
        "connectable": .bool(advertisementData[CBAdvertisementDataIsConnectable] as? Bool ?? false),
      ]
      if let services = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID], !services.isEmpty {
        object["services"] = .array(services.map { .string($0.uuidString) })
      }
      if let data = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data { object["manufacturer_data"] = .string(data.hex) }
      if let power = advertisementData[CBAdvertisementDataTxPowerLevelKey] as? NSNumber { object["tx_power"] = .number(power.doubleValue) }
      found[peripheral.identifier] = object
    }

    func wait(_ seconds: Double, _ begin: () -> Void) async -> String? {
      token += 1
      let mine = token
      return await withCheckedContinuation { continuation in
        step = continuation
        begin()
        Task { @MainActor [weak self] in
          try? await Task.sleep(for: .seconds(seconds))
          guard let self, self.token == mine, let step = self.step else { return }
          self.step = nil
          step.resume(returning: "the Bluetooth device didn't answer within \(Int(seconds)) seconds")
        }
      }
    }

    func finish(_ error: Error?) {
      let current = step
      step = nil
      current?.resume(returning: error?.localizedDescription)
    }

    func connect(_ id: UUID, seconds: Double) async throws -> CBPeripheral {
      let manager = try await start()
      guard let target = manager.retrievePeripherals(withIdentifiers: [id]).first else {
        throw NanocodeError("this iPhone doesn't know that device; scan first")
      }
      peripheral = target
      target.delegate = self
      if let failure = await wait(seconds, { manager.connect(target) }) {
        manager.cancelPeripheralConnection(target)
        throw NanocodeError("couldn't connect: \(failure)")
      }
      if let failure = await wait(seconds, { target.discoverServices(nil) }) { throw NanocodeError(failure) }
      for service in target.services ?? [] {
        if let failure = await wait(seconds, { target.discoverCharacteristics(nil, for: service) }) { throw NanocodeError(failure) }
      }
      return target
    }

    func done() {
      if let peripheral { manager?.cancelPeripheralConnection(peripheral) }
    }

    func characteristic(_ target: CBPeripheral, _ service: CBUUID, _ characteristic: CBUUID) throws -> CBCharacteristic {
      guard let found = target.services?.first(where: { $0.uuid == service })?.characteristics?.first(where: { $0.uuid == characteristic }) else {
        throw NanocodeError("the device has no characteristic \(characteristic.uuidString) in service \(service.uuidString)")
      }
      return found
    }

    func inspect(_ id: UUID, seconds: Double) async throws -> JSON {
      let target = try await connect(id, seconds: seconds)
      defer { done() }
      var services: [JSON] = []
      for service in target.services ?? [] {
        var characteristics: [JSON] = []
        for item in service.characteristics ?? [] {
          var object = describe(item)
          if item.properties.contains(.read) {
            if let failure = await wait(seconds, { target.readValue(for: item) }) { object["error"] = .string(failure) } else { object.merge(value(item.value)) { _, new in new } }
          }
          characteristics.append(.object(object))
        }
        services.append(["uuid": .string(service.uuid.uuidString), "name": .string(service.uuid.description), "primary": .bool(service.isPrimary),
                         "characteristics": .array(characteristics)])
      }
      return ["id": .string(id.uuidString), "name": .string(target.name ?? ""), "services": .array(services)]
    }

    func read(_ id: UUID, _ service: CBUUID, _ uuid: CBUUID, seconds: Double) async throws -> JSON {
      let target = try await connect(id, seconds: seconds)
      defer { done() }
      let item = try characteristic(target, service, uuid)
      guard item.properties.contains(.read) else { throw NanocodeError("that characteristic can't be read") }
      if let failure = await wait(seconds, { target.readValue(for: item) }) { throw NanocodeError(failure) }
      return .object(describe(item).merging(value(item.value)) { _, new in new })
    }

    func write(_ id: UUID, _ service: CBUUID, _ uuid: CBUUID, _ bytes: Data, response: Bool?, seconds: Double) async throws -> JSON {
      let target = try await connect(id, seconds: seconds)
      defer { done() }
      let item = try characteristic(target, service, uuid)
      let confirm = response ?? item.properties.contains(.write)
      if confirm {
        guard item.properties.contains(.write) else { throw NanocodeError("that characteristic can't be written with a response") }
        if let failure = await wait(seconds, { target.writeValue(bytes, for: item, type: .withResponse) }) { throw NanocodeError(failure) }
      } else {
        guard item.properties.contains(.writeWithoutResponse) else { throw NanocodeError("that characteristic can't be written") }
        target.writeValue(bytes, for: item, type: .withoutResponse)
      }
      return ["written": .number(Double(bytes.count)), "confirmed": .bool(confirm)]
    }

    func describe(_ item: CBCharacteristic) -> [String: JSON] {
      let names: [(CBCharacteristicProperties, String)] = [(.read, "read"), (.write, "write"), (.writeWithoutResponse, "write_without_response"),
                                                           (.notify, "notify"), (.indicate, "indicate"), (.broadcast, "broadcast")]
      return ["uuid": .string(item.uuid.uuidString), "name": .string(item.uuid.description),
              "properties": .array(names.filter { item.properties.contains($0.0) }.map { .string($0.1) })]
    }

    func value(_ data: Data?) -> [String: JSON] {
      guard let data else { return [:] }
      var object: [String: JSON] = ["hex": .string(data.hex)]
      if let text = String(data: data, encoding: .utf8), !text.isEmpty, text.allSatisfy({ !$0.isASCII || $0.isLetter || $0.isNumber || $0.isPunctuation || $0.isWhitespace || $0.isSymbol }) {
        object["text"] = .string(text)
      }
      return object
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) { finish(nil) }
    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
      finish(error ?? NanocodeError("the connection failed"))
    }
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) { finish(error) }
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) { finish(error) }
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) { finish(error) }
    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) { finish(error) }
  }

  static let localNetworkActions = ["browse", "types"]

  static var bonjourTypes: [String] { Bundle.main.object(forInfoDictionaryKey: "NSBonjourServices") as? [String] ?? [] }

  static let localNetwork = HostTool(
    name: "local_network",
    description: "Devices and services on the Wi-Fi network around this iPhone, found with Bonjour: printers, speakers, TVs, smart-home hubs, computers. browse: services of one or more types for some seconds, with their host, port and TXT records. types: the service types \(DeviceTools.settings.app) may browse (iOS only allows the types the app declares).",
    parameters: schema(localNetworkActions, [
      "types": list(prop("string"), "For browse: service types such as _http._tcp or _airplay._tcp; every declared type by default."),
      "seconds": prop("number", "For browse: how long, 3 by default and at most 30."),
    ])
  ) { call in try await neighbours(call.input) }

  static func neighbours(_ input: JSON) async throws -> ToolResult {
    switch input["action"]?.string {
    case "types":
      return .json(.array(bonjourTypes.map(JSON.string)))
    case "browse":
      try await DeviceTools.gate("local_network")
      let declared = bonjourTypes
      let wanted = texts(input, "types")
      let undeclared = wanted.filter { !declared.contains($0) }
      guard undeclared.isEmpty else {
        throw NanocodeError("iOS only lets \(DeviceTools.settings.app) browse the service types it declares; \(undeclared.joined(separator: ", ")) is not one (types lists them)")
      }
      let seconds = input["seconds"]?.number ?? 3
      guard seconds > 0, seconds <= 30 else { throw NanocodeError("seconds is above 0 and at most 30") }
      let types = wanted.isEmpty ? declared : wanted
      let results = await withTaskGroup(of: [JSON].self) { group in
        for type in types { group.addTask { await browse(type, seconds: seconds) } }
        var all: [JSON] = []
        for await found in group { all += found }
        return all
      }
      return .json(.array(results))
    default:
      throw unknown("local_network", localNetworkActions)
    }
  }

  final class Found: @unchecked Sendable {
    let lock = NSLock()
    var results: Set<NWBrowser.Result> = []
    var denied = false
    var ready = false
  }

  static func browse(_ type: String, seconds: Double) async -> [JSON] {
    let found = Found()
    let browser = NWBrowser(for: .bonjourWithTXTRecord(type: type, domain: nil), using: .tcp)
    browser.browseResultsChangedHandler = { results, _ in found.lock.withLock { found.results.formUnion(results) } }
    browser.stateUpdateHandler = { state in
      found.lock.withLock {
        if case .ready = state { found.ready = true }
        if case .waiting(let error) = state, case .dns(let code) = error, code == -65570 { found.denied = true }
      }
    }
    browser.start(queue: DispatchQueue(label: "xyz.gakonst.personal.bonjour"))
    try? await Task.sleep(for: .seconds(seconds))
    browser.cancel()
    let results = found.lock.withLock { Array(found.results) }
    return await withTaskGroup(of: JSON?.self) { group in
      for result in results { group.addTask { await describe(result, type: type) } }
      var all: [JSON] = []
      for await item in group { if let item { all.append(item) } }
      return all
    }
  }

  static func describe(_ result: NWBrowser.Result, type: String) async -> JSON? {
    guard case let .service(name, serviceType, domain, _) = result.endpoint else { return nil }
    var object: [String: JSON] = ["name": .string(name), "type": .string(serviceType), "domain": .string(domain)]
    if case let .bonjour(record) = result.metadata {
      object["txt"] = .object(record.dictionary.mapValues(JSON.string))
    }
    if let (host, port) = await resolve(result.endpoint) {
      object["host"] = .string(host)
      object["port"] = .number(Double(port))
    }
    return .object(object)
  }

  static func resolve(_ endpoint: NWEndpoint) async -> (String, Int)? {
    let connection = NWConnection(to: endpoint, using: .tcp)
    let once = Once()
    let answer: (String, Int)? = await withCheckedContinuation { continuation in
      connection.stateUpdateHandler = { state in
        switch state {
        case .ready:
          if once.take() {
            if case let .hostPort(host, port) = connection.currentPath?.remoteEndpoint {
              continuation.resume(returning: ("\(host)".components(separatedBy: "%").first ?? "\(host)", Int(port.rawValue)))
            } else {
              continuation.resume(returning: nil)
            }
          }
        case .failed, .cancelled:
          if once.take() { continuation.resume(returning: nil) }
        default: break
        }
      }
      connection.start(queue: DispatchQueue(label: "xyz.gakonst.personal.resolve"))
      DispatchQueue.global().asyncAfter(deadline: .now() + 3) { if once.take() { continuation.resume(returning: nil) } }
    }
    connection.cancel()
    return answer
  }

  static let localNetworkStateKey = "PhoneLocalNetwork"

  static func localNetworkPermission() -> HandPermission {
    switch UserDefaults.standard.string(forKey: localNetworkStateKey) {
    case "granted": .granted
    case "denied": .denied
    default: .prompt
    }
  }

  static func askLocalNetwork() async -> HandPermission {
    let found = Found()
    let type = bonjourTypes.first ?? "_http._tcp"
    let browser = NWBrowser(for: .bonjour(type: type, domain: nil), using: .tcp)
    browser.browseResultsChangedHandler = { results, _ in found.lock.withLock { if !results.isEmpty { found.ready = true } } }
    browser.stateUpdateHandler = { state in
      found.lock.withLock {
        if case .ready = state { found.ready = true }
        if case .waiting(let error) = state, case .dns(let code) = error, code == -65570 { found.denied = true }
      }
    }
    browser.start(queue: DispatchQueue(label: "xyz.gakonst.personal.bonjour"))
    var answer = HandPermission.prompt
    for _ in 0..<600 {
      try? await Task.sleep(for: .milliseconds(100))
      let (ready, denied) = found.lock.withLock { (found.ready, found.denied) }
      if ready { answer = .granted; break }
      if denied { answer = .denied }
    }
    browser.cancel()
    if answer != .prompt { UserDefaults.standard.set(answer.rawValue, forKey: localNetworkStateKey) }
    return answer
  }

  static let nfcActions = ["read", "write"]

  static let nfc = HostTool(
    name: "nfc",
    description: "NFC tags with this iPhone: read shows the iOS scan sheet and returns the tag's NDEF records (text, links, anything else as hex); write writes text or a link to a tag. The owner holds the top of the iPhone to the tag. Needs \(DeviceTools.settings.app) open.",
    parameters: schema(nfcActions, [
      "text": prop("string", "For write: text to write."),
      "url": prop("string", "For write: a link to write."),
      "message": prop("string", "What the scan sheet tells the owner."),
    ])
  ) { call in try await tag(call.input) }

  static func tag(_ input: JSON) async throws -> ToolResult {
    try await DeviceTools.gate("nfc")
    try await foreground("Scanning an NFC tag")
    switch input["action"]?.string {
    case "read":
      return .json(try await Tags.run(nil, message: text(input, "message") ?? "Hold your iPhone near the tag."))
    case "write":
      let payload: NFCNDEFPayload
      if let link = text(input, "url") {
        guard let url = URL(string: link), let made = NFCNDEFPayload.wellKnownTypeURIPayload(url: url) else { throw NanocodeError("that url can't be written") }
        payload = made
      } else if let value = input["text"]?.string {
        guard let made = NFCNDEFPayload.wellKnownTypeTextPayload(string: value, locale: Locale.current) else { throw NanocodeError("that text can't be written") }
        payload = made
      } else {
        throw NanocodeError("write takes text or url")
      }
      return .json(try await Tags.run(NFCNDEFMessage(records: [payload]), message: text(input, "message") ?? "Hold your iPhone near the tag to write it."))
    default:
      throw unknown("nfc", nfcActions)
    }
  }

  @MainActor final class Tags: NSObject, @preconcurrency NFCNDEFReaderSessionDelegate {
    var writing: NFCNDEFMessage?
    var done: CheckedContinuation<Result<JSON, Error>, Never>?

    static func run(_ writing: NFCNDEFMessage?, message: String) async throws -> JSON {
      guard NFCNDEFReaderSession.readingAvailable else { throw NanocodeError("this iPhone can't read NFC tags") }
      let tags = Tags()
      tags.writing = writing
      let session = NFCNDEFReaderSession(delegate: tags, queue: .main, invalidateAfterFirstRead: false)
      session.alertMessage = message
      let result = await withCheckedContinuation { continuation in
        tags.done = continuation
        session.begin()
      }
      withExtendedLifetime(tags) {}
      return try result.get()
    }

    func end(_ result: Result<JSON, Error>) {
      done?.resume(returning: result)
      done = nil
    }

    func readerSession(_ session: NFCNDEFReaderSession, didInvalidateWithError error: Error) {
      let code = (error as? NFCReaderError)?.code
      if code == .readerSessionInvalidationErrorUserCanceled { end(.failure(NanocodeError("the owner cancelled the scan"))) }
      else { end(.failure(error)) }
    }

    func readerSession(_ session: NFCNDEFReaderSession, didDetectNDEFs messages: [NFCNDEFMessage]) {}

    func readerSession(_ session: NFCNDEFReaderSession, didDetect tags: [any NFCNDEFTag]) {
      guard let first = tags.first else { return }
      nonisolated(unsafe) let session = session
      nonisolated(unsafe) let tag = first
      session.connect(to: tag) { error in
        MainActor.assumeIsolated {
          if let error {
            session.invalidate(errorMessage: "Couldn't connect to the tag.")
            self.end(.failure(error))
            return
          }
          tag.queryNDEFStatus { status, capacity, error in
            MainActor.assumeIsolated { self.queried(session, tag, status, capacity, error) }
          }
        }
      }
    }

    func queried(_ session: NFCNDEFReaderSession, _ tag: any NFCNDEFTag, _ status: NFCNDEFStatus, _ capacity: Int, _ error: Error?) {
      nonisolated(unsafe) let session = session
      if let error {
        session.invalidate(errorMessage: "Couldn't read the tag.")
        end(.failure(error))
        return
      }
      let state = status == .readWrite ? "read_write" : status == .readOnly ? "read_only" : "not_supported"
      if let writing {
        guard status == .readWrite else {
          session.invalidate(errorMessage: "This tag can't be written.")
          end(.failure(NanocodeError("the tag is \(state.replacingOccurrences(of: "_", with: " "))")))
          return
        }
        tag.writeNDEF(writing) { error in
          MainActor.assumeIsolated {
            if let error {
              session.invalidate(errorMessage: "Writing failed.")
              self.end(.failure(error))
            } else {
              session.alertMessage = "Written."
              session.invalidate()
              self.end(.success(["written": .bool(true), "capacity_bytes": .number(Double(capacity))]))
            }
          }
        }
        return
      }
      tag.readNDEF { message, error in
        nonisolated(unsafe) let message = message
        MainActor.assumeIsolated {
          session.alertMessage = "Read."
          session.invalidate()
          if let error, message == nil, (error as? NFCReaderError)?.code != .ndefReaderSessionErrorZeroLengthMessage {
            self.end(.failure(error))
            return
          }
          self.end(.success(["status": .string(state), "capacity_bytes": .number(Double(capacity)),
                             "records": .array((message?.records ?? []).map(Tags.record))]))
        }
      }
    }

    nonisolated static func record(_ payload: NFCNDEFPayload) -> JSON {
      var object: [String: JSON] = ["type": .string(String(decoding: payload.type, as: UTF8.self)), "hex": .string(payload.payload.hex)]
      if let url = payload.wellKnownTypeURIPayload() { object["url"] = .string(url.absoluteString) }
      let (text, locale) = payload.wellKnownTypeTextPayload()
      if let text { object["text"] = .string(text) }
      if let locale { object["language"] = .string(locale.identifier) }
      return .object(object)
    }
  }
}

extension Data {
  var hex: String { map { String(format: "%02x", $0) }.joined() }

  init?(hex: String) {
    let digits = hex.filter { !$0.isWhitespace && $0 != ":" && $0 != "-" }
    guard digits.count % 2 == 0 else { return nil }
    var bytes: [UInt8] = []
    var index = digits.startIndex
    while index < digits.endIndex {
      let next = digits.index(index, offsetBy: 2)
      guard let byte = UInt8(digits[index..<next], radix: 16) else { return nil }
      bytes.append(byte)
      index = next
    }
    self.init(bytes)
  }
}
#endif
