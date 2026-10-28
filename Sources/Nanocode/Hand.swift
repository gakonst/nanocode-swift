import Foundation

public struct HandItem: Sendable, Hashable, Identifiable {
  public let kind: String
  public let id: String
  public let label: String
  public let sessionID: String?
  public let silentMs: Double
}

public struct HandStatus: Sendable, Hashable, Identifiable {
  public let id: String
  public let name: String?
  public let url: String
  public let directory: String
  public let busy: Bool
  public let items: [HandItem]

  init?(_ json: JSON) {
    guard let id = json["id"]?.string else { return nil }
    self.id = id
    name = json["name"]?.string
    url = json["url"]?.string ?? ""
    directory = json["directory"]?.string ?? ""
    busy = json["busy"]?.bool ?? false
    items = (json["items"]?.array ?? []).map { item in
      HandItem(kind: item["kind"]?.string ?? "", id: item["id"]?.string ?? "", label: item["label"]?.string ?? "",
               sessionID: item["session_id"]?.string, silentMs: item["silent_ms"]?.number ?? 0)
    }
  }
}

public enum HandState: Sendable, Hashable {
  case idle
  case connecting
  case connected(endpoint: String)
  case disconnected(reason: String)
  case retrying(delayMs: Double)
  case stopped(error: String?)

  init(_ event: JSON) {
    switch event["state"]?.string {
    case "connecting": self = .connecting
    case "connected": self = .connected(endpoint: event["endpoint"]?.string ?? "")
    case "disconnected": self = .disconnected(reason: event["reason"]?.string ?? "")
    case "retrying": self = .retrying(delayMs: event["delay_ms"]?.number ?? 0)
    case "revoked": self = .stopped(error: "The brain revoked this hand.")
    case "replaced": self = .stopped(error: "Another process took this hand's place.")
    case "rejected": self = .stopped(error: "The brain refused the hand (HTTP \(event["status"]?.int ?? 0)).")
    case "fenced": self = .stopped(error: "The brain fenced this runner: \(event["reason"]?.string ?? "")")
    case "catalog", "call_started", "call_completed": self = .connected(endpoint: "")
    default: self = .idle
    }
  }

  public var label: String {
    switch self {
    case .idle: "Off"
    case .connecting: "Connecting…"
    case .connected: "Connected"
    case .disconnected(let reason): "Disconnected: \(reason)"
    case .retrying(let delay): "Reconnecting in \(Int(delay / 1000)) s"
    case .stopped(let error): error ?? "Stopped"
    }
  }

  public var online: Bool {
    if case .connected = self { return true }
    return false
  }
}

public struct HandConfiguration: Sendable {
  public var id: String
  public var url: String
  public var token: String
  public var name: String?
  public var workspace: URL?
  public var shell: Bool?
  public var tools: [HostTool]
  public var headers: [String: String]
  public var capabilities: [HandCapability]
  public var toolsOnly: Bool
  public var environment: HandEnvironment?

  public init(id: String = "default", url: String, token: String, name: String? = nil, workspace: URL? = nil,
              shell: Bool? = nil, tools: [HostTool] = [], headers: [String: String] = [:],
              capabilities: [HandCapability] = [], toolsOnly: Bool = false, environment: HandEnvironment? = nil) {
    self.id = id
    self.url = url
    self.token = token
    self.name = name
    self.workspace = workspace
    self.shell = shell
    self.tools = tools
    self.headers = headers
    self.capabilities = capabilities
    self.toolsOnly = toolsOnly
    self.environment = environment
  }

  var json: JSON {
    var object: [String: JSON] = [
      "id": .string(id), "url": .string(url), "token": .string(token),
      "tools": .array(tools.map(\.definition)), "headers": .object(headers.mapValues(JSON.string)),
    ]
    if let name { object["name"] = .string(name) }
    if let workspace { object["workspace"] = .string(workspace.path) }
    if let shell { object["shell"] = .bool(shell) }
    if !capabilities.isEmpty { object["capabilities"] = .array(capabilities.map(\.spec)) }
    if toolsOnly { object["tools_only"] = .bool(true) }
    if let environment { object["environment"] = environment.json }
    return .object(object)
  }

  public static func parse(command: String) -> (url: String, token: String)? {
    let words = command.split(whereSeparator: \.isWhitespace).map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "'\"")) }
    guard let url = words.first(where: { $0.hasPrefix("ws://") || $0.hasPrefix("wss://") }) else { return nil }
    guard let flag = words.firstIndex(of: "--token"), words.indices.contains(flag + 1) else { return nil }
    return (url, words[flag + 1])
  }
}

public struct RunnerMachine: Sendable {
  public var id: String
  public var name: String
  public var workspace: String?
  public var capabilities: [String]

  public init(id: String, name: String, workspace: String? = nil, capabilities: [String] = ["shell"]) {
    self.id = id
    self.name = name
    self.workspace = workspace
    self.capabilities = capabilities
  }

  var json: JSON {
    var object: [String: JSON] = ["id": .string(id), "name": .string(name), "capabilities": .array(capabilities.map(JSON.string))]
    if let workspace { object["workspace"] = .string(workspace) }
    return .object(object)
  }
}

public struct RunnerConfiguration: Sendable {
  public var id: String
  public var url: String
  public var token: String
  public var machine: RunnerMachine?
  public var workspace: URL?
  public var shell: Bool?
  public var tools: [HostTool]

  public init(id: String = "default", url: String, token: String, machine: RunnerMachine? = nil, workspace: URL? = nil,
              shell: Bool? = nil, tools: [HostTool] = []) {
    self.id = id
    self.url = url
    self.token = token
    self.machine = machine
    self.workspace = workspace
    self.shell = shell
    self.tools = tools
  }

  var json: JSON {
    var object: [String: JSON] = [
      "id": .string(id), "url": .string(url), "token": .string(token), "tools": .array(tools.map(\.definition)),
    ]
    if let machine { object["machine"] = machine.json }
    if let workspace { object["workspace"] = .string(workspace.path) }
    if let shell { object["shell"] = .bool(shell) }
    return .object(object)
  }
}

public extension NanocodeRuntime {
  func startRunner(_ configuration: RunnerConfiguration) async throws -> JSON {
    register(configuration.tools)
    return try await command("runner_start", configuration.json)
  }

  func stopRunner(_ id: String = "default") async throws {
    try await command("runner_stop", ["id": .string(id)])
  }

  func runners() async throws -> [JSON] {
    (try await command("runner_status")).array ?? []
  }

  func startHand(_ configuration: HandConfiguration) async throws -> HandStatus? {
    register(configuration.tools)
    router.state.withLock { $0.capabilities[configuration.id] = configuration.capabilities }
    return HandStatus(try await command("hand_start", configuration.json))
  }

  func stopHand(_ id: String = "default") async throws {
    try await command("hand_stop", ["id": .string(id)])
    router.state.withLock { $0.capabilities[id] = nil }
  }

  func hands() async throws -> [HandStatus] {
    (try await command("hand_status")).array?.compactMap(HandStatus.init) ?? []
  }
}
