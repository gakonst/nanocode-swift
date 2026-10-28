import Foundation
import Security

public enum Identifier {
  public static func uuidv7() -> String {
    var bytes = [UInt8](repeating: 0, count: 16)
    _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
    let millis = UInt64(Date().timeIntervalSince1970 * 1000)
    for index in 0..<6 { bytes[index] = UInt8((millis >> (8 * (5 - UInt64(index)))) & 0xff) }
    bytes[6] = (bytes[6] & 0x0f) | 0x70
    bytes[8] = (bytes[8] & 0x3f) | 0x80
    let hex = bytes.map { String(format: "%02x", $0) }.joined()
    let parts = [hex.prefix(8), hex.dropFirst(8).prefix(4), hex.dropFirst(12).prefix(4), hex.dropFirst(16).prefix(4), hex.dropFirst(20)]
    return parts.map(String.init).joined(separator: "-")
  }
}

public enum Provider: String, Codable, Sendable, CaseIterable, Identifiable {
  case claude
  case codex
  public var id: String { rawValue }
}

public enum Authentication: Sendable, Hashable {
  case tempo
  case apiKey(String)
  case headers([String: String])

  var json: JSON {
    switch self {
    case .tempo: "tempo"
    case .apiKey(let key): ["api_key": .string(key)]
    case .headers(let headers): ["headers": .object(headers.mapValues(JSON.string))]
    }
  }
}

public enum WorkspaceTools: String, Sendable {
  case all, files, none
}

public struct SessionEnvironment: Sendable {
  public var cwd: String?
  public var shell: String?
  public var timezone: String?
  public var date: String?
  public var projectInstructions: String?

  public init(cwd: String? = nil, shell: String? = nil, timezone: String? = TimeZone.current.identifier,
              date: String? = SessionEnvironment.today(), projectInstructions: String? = nil) {
    self.cwd = cwd
    self.shell = shell
    self.timezone = timezone
    self.date = date
    self.projectInstructions = projectInstructions
  }

  public static func today() -> String {
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .iso8601)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter.string(from: Date())
  }

  var json: JSON {
    var object: [String: JSON] = [:]
    if let cwd { object["cwd"] = .string(cwd) }
    if let shell { object["shell"] = .string(shell) }
    if let timezone { object["timezone"] = .string(timezone) }
    if let date { object["date"] = .string(date) }
    if let projectInstructions { object["project_instructions"] = .string(projectInstructions) }
    return .object(object)
  }
}

public struct HandLink: Sendable, Hashable {
  public enum Mode: String, Sendable { case alongside, replace }
  public var url: String
  public var token: String
  public var name: String?
  public var mode: Mode

  public init(url: String, token: String, name: String? = nil, mode: Mode = .alongside) {
    self.url = url
    self.token = token
    self.name = name
    self.mode = mode
  }

  var json: JSON {
    var object: [String: JSON] = ["url": .string(url), "token": .string(token), "mode": .string(mode.rawValue)]
    if let name { object["name"] = .string(name) }
    return .object(object)
  }
}

public struct HandRelay: Sendable, Hashable {
  public static let nanocode = URL(string: "https://nanocode.xyz/cloudflare/relay")!
  public static let install = "https://nanocode.xyz/install"
  public let base: URL
  public let token: String

  public init(base: URL = HandRelay.nanocode, token: String = HandRelay.newToken()) {
    self.base = base
    self.token = token
  }

  public static func newToken() -> String {
    var bytes = [UInt8](repeating: 0, count: 16)
    _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
    return bytes.map { String(format: "%02x", $0) }.joined()
  }

  public var socket: String {
    var components = URLComponents(url: base, resolvingAgainstBaseURL: false)!
    components.scheme = components.scheme == "http" ? "ws" : "wss"
    return components.url!.absoluteString
  }

  public func brain(mode: HandLink.Mode = .replace) -> HandLink {
    HandLink(url: socket + (socket.contains("?") ? "&" : "?") + "role=brain&wait", token: token, mode: mode)
  }

  public var command: String { "curl -fsSL \(Self.install) | sh -s -- hand '\(socket)' --token \(token)" }

  public var short: String { "nc hand '\(socket)' --token \(token)" }

  public func hands() async -> [String] {
    var components = URLComponents(url: base, resolvingAgainstBaseURL: false)!
    components.queryItems = (components.queryItems ?? []) + [URLQueryItem(name: "token", value: token)]
    guard let url = components.url, let (data, response) = try? await URLSession.shared.data(from: url),
          (response as? HTTPURLResponse)?.statusCode == 200, let json = try? JSON.parse(data) else { return [] }
    return json["hands"]?.array?.compactMap(\.string) ?? []
  }
}

public struct McpServer: Sendable, Hashable {
  public var name: String
  public var url: String
  public var headers: [String: String]
  public var bearerToken: String?
  public var paid: Bool

  public init(name: String, url: String, headers: [String: String] = [:], bearerToken: String? = nil, paid: Bool = false) {
    self.name = name
    self.url = url
    self.headers = headers
    self.bearerToken = bearerToken
    self.paid = paid
  }

  var json: JSON {
    var object: [String: JSON] = [
      "name": .string(name), "url": .string(url), "headers": .object(headers.mapValues(JSON.string)), "paid": .bool(paid),
    ]
    if let bearerToken { object["bearer_token"] = .string(bearerToken) }
    return .object(object)
  }
}

public struct Fork: Sendable {
  public var session: String
  public var checkpoint: JSON?
  public var before: String?

  public init(session: String, checkpoint: JSON? = nil, before: String? = nil) {
    self.session = session
    self.checkpoint = checkpoint
    self.before = before
  }

  var json: JSON {
    var object: [String: JSON] = ["session": .string(session)]
    if let checkpoint { object["checkpoint"] = checkpoint }
    if let before { object["before"] = .string(before) }
    return .object(object)
  }
}

public struct SessionConfiguration: Sendable {
  public var hands: [HandLink] = []
  public var mcpServers: [McpServer] = []
  public var permissionMode: PermissionMode?
  public var allow: [String] = []
  public var fork: Fork?
  public var sessionID: String
  public var provider: Provider
  public var model: String?
  public var thinking: String?
  public var serviceTier: String?
  public var instructions: String?
  public var endpoint: String?
  public var authentication: Authentication
  public var maxTokens: Int?
  public var subagents: Bool?
  public var workspace: URL?
  public var workspaceTools: WorkspaceTools
  public var tools: [HostTool]
  public var webSearch: Bool
  public var paidTools: Bool
  public var streamToolInput: Bool
  public var liveDeltas: Bool
  public var eventCoalesceMs: Int
  public var environment: SessionEnvironment?

  public init(sessionID: String = Identifier.uuidv7(), provider: Provider = .claude, model: String? = nil,
              thinking: String? = nil, serviceTier: String? = nil, instructions: String? = nil, endpoint: String? = nil,
              authentication: Authentication = .tempo, maxTokens: Int? = nil, subagents: Bool? = nil,
              workspace: URL? = nil, workspaceTools: WorkspaceTools = .all, tools: [HostTool] = [],
              webSearch: Bool = true, paidTools: Bool = false, streamToolInput: Bool = true,
              liveDeltas: Bool = false, eventCoalesceMs: Int = 50, environment: SessionEnvironment? = SessionEnvironment()) {
    self.sessionID = sessionID
    self.provider = provider
    self.model = model
    self.thinking = thinking
    self.serviceTier = serviceTier
    self.instructions = instructions
    self.endpoint = endpoint
    self.authentication = authentication
    self.maxTokens = maxTokens
    self.subagents = subagents
    self.workspace = workspace
    self.workspaceTools = workspaceTools
    self.tools = tools
    self.webSearch = webSearch
    self.paidTools = paidTools
    self.streamToolInput = streamToolInput
    self.liveDeltas = liveDeltas
    self.eventCoalesceMs = eventCoalesceMs
    self.environment = environment
  }

  var json: JSON {
    var object: [String: JSON] = [
      "session_id": .string(sessionID),
      "provider": .string(provider.rawValue),
      "auth": authentication.json,
      "workspace_tools": .string(workspaceTools.rawValue),
      "tools": .array(tools.map(\.definition)),
      "web_search": .bool(webSearch),
      "paid_tools": .bool(paidTools),
      "stream_tool_input": .bool(streamToolInput),
      "live_deltas": .bool(liveDeltas),
      "event_coalesce_ms": .number(Double(eventCoalesceMs)),
    ]
    if let model { object["model"] = .string(model) }
    if let thinking { object["thinking"] = .string(thinking) }
    if let serviceTier { object["service_tier"] = .string(serviceTier) }
    if let instructions { object["instructions"] = .string(instructions) }
    if let endpoint { object["endpoint"] = .string(endpoint) }
    if let maxTokens { object["max_tokens"] = .number(Double(maxTokens)) }
    if let subagents { object["subagents"] = .bool(subagents) }
    if let workspace { object["workspace"] = .string(workspace.path) }
    if let environment { object["environment"] = environment.json }
    if !hands.isEmpty { object["hands"] = .array(hands.map(\.json)) }
    if !mcpServers.isEmpty { object["mcp_servers"] = .array(mcpServers.map(\.json)) }
    if let permissionMode { object["permission_mode"] = .string(permissionMode.rawValue) }
    if !allow.isEmpty { object["allow"] = .array(allow.map(JSON.string)) }
    if let fork { object["fork"] = fork.json }
    return .object(object)
  }
}

public struct SessionSummary: Sendable, Identifiable, Hashable {
  public let id: String
  public let model: String
  public let family: String
  public let title: String?
  public let preview: String?
  public let createdAt: Date
  public let updatedAt: Date
  public let open: Bool

  init?(_ json: JSON) {
    guard let id = json["session_id"]?.string else { return nil }
    self.id = id
    model = json["model"]?.string ?? ""
    family = json["family"]?.string ?? ""
    title = json["title"]?.string
    preview = json["preview"]?.string
    createdAt = Date(timeIntervalSince1970: (json["created_at_ms"]?.number ?? 0) / 1000)
    updatedAt = Date(timeIntervalSince1970: (json["updated_at_ms"]?.number ?? 0) / 1000)
    open = json["open"]?.bool ?? false
  }
}

public struct TurnReport: Sendable, Hashable {
  public let requestID: String
  public let status: String
  public let message: String?
  public let error: String?
  public let raw: JSON

  public init(_ json: JSON) {
    let report = json["report"] ?? json
    raw = json
    requestID = report["request_id"]?.string ?? ""
    status = report["status"]?.string ?? ""
    message = report["ok"]?["message"]?.string ?? report["message"]?.string
    error = report["error"]?.string ?? report["error"].flatMap { $0.isNull ? nil : $0.text() }
  }
}

public struct Submitted: Sendable {
  public let status: String
  public let turn: TurnReport?
}

public struct LogPage: Sendable {
  public let events: [LoggedEvent]
  public let nextCursor: UInt64
  public let hasMore: Bool
}

public final class Session: Sendable {
  public let id: String
  public let model: String
  let runtime: NanocodeRuntime

  init(id: String, model: String, runtime: NanocodeRuntime) {
    self.id = id
    self.model = model
    self.runtime = runtime
  }

  public var events: AsyncStream<SessionEvent> { runtime.events(session: id) }

  @discardableResult
  public func submit(_ prompt: String, images: [String] = [], requestID: String = Identifier.uuidv7(),
                     metadata: JSON = [:]) async throws -> Submitted {
    let result = try await runtime.command("submit", [
      "session": .string(id), "request_id": .string(requestID), "prompt": .string(prompt),
      "images": .array(images.map(JSON.string)), "metadata": metadata,
    ])
    return Submitted(status: result["submitted"]?.string ?? "", turn: result["turn"].map(TurnReport.init))
  }

  public func steer(_ prompt: String, images: [String] = [], requestID: String = Identifier.uuidv7(), into: String? = nil) async throws -> Bool {
    var body: [String: JSON] = [
      "session": .string(id), "request_id": .string(requestID), "prompt": .string(prompt),
      "images": .array(images.map(JSON.string)),
    ]
    if let into { body["into"] = .string(into) }
    return try await runtime.command("steer", .object(body)).bool ?? false
  }

  @discardableResult
  public func cancel(_ requestID: String) async throws -> JSON {
    try await runtime.command("cancel", ["session": .string(id), "request_id": .string(requestID)])
  }

  public func moveQueued(_ requestID: String, into: String? = nil) async throws -> String {
    var body: [String: JSON] = ["session": .string(id), "request_id": .string(requestID)]
    if let into { body["into"] = .string(into) }
    return try await runtime.command("move_queued", .object(body))["moved"]?.string ?? ""
  }

  public func replace(_ requestID: String, text: String, editID: String = Identifier.uuidv7()) async throws -> String {
    try await runtime.command("replace", [
      "session": .string(id), "request_id": .string(requestID), "edit_id": .string(editID), "text": .string(text),
    ])["replaced"]?.string ?? ""
  }

  public func page(after: UInt64 = 0, limit: Int = 500, requestID: String? = nil, maxBytes: Int? = nil) async throws -> LogPage {
    var body: [String: JSON] = ["session": .string(id), "after": .number(Double(after)), "limit": .number(Double(limit))]
    if let requestID { body["request_id"] = .string(requestID) }
    if let maxBytes { body["max_bytes"] = .number(Double(maxBytes)) }
    let page = try await runtime.command("page", .object(body))
    return LogPage(
      events: page["events"]?.array?.compactMap(LoggedEvent.init) ?? [],
      nextCursor: page["next_cursor"]?.uint64 ?? after,
      hasMore: page["has_more"]?.bool ?? false)
  }

  public func history(pageSize: Int = 500) async throws -> [LoggedEvent] {
    var events: [LoggedEvent] = []
    var cursor: UInt64 = 0
    while true {
      let page = try await page(after: cursor, limit: pageSize)
      events.append(contentsOf: page.events)
      cursor = page.nextCursor
      if !page.hasMore { return events }
    }
  }

  public func pending() async throws -> [TurnReport] {
    (try await runtime.command("pending", ["session": .string(id)]))["turns"]?.array?.map(TurnReport.init) ?? []
  }

  public func turn(_ requestID: String) async throws -> TurnReport? {
    (try await runtime.command("turn", ["session": .string(id), "request_id": .string(requestID)]))["turn"]
      .flatMap { $0.isNull ? nil : TurnReport($0) }
  }

  public func settings(thinking: String? = nil, serviceTier: String? = nil) async throws {
    var body: [String: JSON] = ["session": .string(id)]
    if let thinking { body["thinking"] = .string(thinking) }
    if let serviceTier { body["service_tier"] = .string(serviceTier) }
    try await runtime.command("settings", .object(body))
  }

  @discardableResult
  public func compact() async throws -> JSON {
    try await runtime.command("compact", ["session": .string(id)])
  }

  public func setPermissionMode(_ mode: PermissionMode) async throws {
    try await runtime.command("permission_mode", ["session": .string(id), "mode": .string(mode.rawValue)])
  }

  public func checkpoint() async throws -> JSON {
    try await runtime.command("checkpoint", ["session": .string(id)])
  }

  public func preconnect() async throws {
    try await runtime.command("preconnect", ["session": .string(id)])
  }

  public func settle() async throws -> Bool {
    try await runtime.command("settle", ["session": .string(id)]).bool ?? false
  }

  public func close() async throws {
    try await runtime.command("close", ["session": .string(id)])
  }
}
