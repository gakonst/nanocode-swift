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

  public init(id: String = "default", url: String, token: String, name: String? = nil, workspace: URL? = nil,
              shell: Bool? = nil, tools: [HostTool] = [], headers: [String: String] = [:]) {
    self.id = id
    self.url = url
    self.token = token
    self.name = name
    self.workspace = workspace
    self.shell = shell
    self.tools = tools
    self.headers = headers
  }

  var json: JSON {
    var object: [String: JSON] = [
      "id": .string(id), "url": .string(url), "token": .string(token),
      "tools": .array(tools.map(\.definition)), "headers": .object(headers.mapValues(JSON.string)),
    ]
    if let name { object["name"] = .string(name) }
    if let workspace { object["workspace"] = .string(workspace.path) }
    if let shell { object["shell"] = .bool(shell) }
    return .object(object)
  }

  public static func parse(command: String) -> (url: String, token: String)? {
    let words = command.split(whereSeparator: \.isWhitespace).map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "'\"")) }
    guard let url = words.first(where: { $0.hasPrefix("ws://") || $0.hasPrefix("wss://") }) else { return nil }
    guard let flag = words.firstIndex(of: "--token"), words.indices.contains(flag + 1) else { return nil }
    return (url, words[flag + 1])
  }
}

public extension NanocodeRuntime {
  func startHand(_ configuration: HandConfiguration) async throws -> HandStatus? {
    register(configuration.tools)
    return HandStatus(try await command("hand_start", configuration.json))
  }

  func stopHand(_ id: String = "default") async throws {
    try await command("hand_stop", ["id": .string(id)])
  }

  func hands() async throws -> [HandStatus] {
    (try await command("hand_status")).array?.compactMap(HandStatus.init) ?? []
  }
}
