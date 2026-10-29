import Foundation
@_exported import NanocodeCore
import NanocodeFFI
import os

public struct NanocodeError: LocalizedError, Sendable, Equatable {
  public let message: String
  public init(_ message: String) { self.message = message }
  public var errorDescription: String? { message }
}

public enum SessionEvent: Sendable {
  case logged([LoggedEvent])
  case live([LoggedEvent])
  case events([LiveEvent])
  case driving(Bool)
  case turn(JSON)
  case waiting(requestID: String, retryMs: Double)
  case resumed(String)
  case failure(String)
}

public struct DevicePrompt: Sendable, Hashable {
  public let userCode: String
  public let verificationURI: URL
  public let verificationURIComplete: URL?
  public let expiresIn: Int
}

public enum RuntimeEvent: Sendable {
  case hand(id: String, event: JSON)
  case handStopped(id: String, error: String?)
  case runner(id: String, event: JSON)
  case runnerStopped(id: String, error: String?)
  case walletPrompt(DevicePrompt)
  case payments(JSON)
  case notice(String)
  case log(String)
}

public struct ToolCall: Sendable {
  public let name: String
  public let input: JSON
  public let sessionID: String?
  public let callID: String?
  public let turnID: String?
  public let model: String?
}

public enum ToolContent: Sendable {
  case text(String)
  case image(dataURL: String, detail: String = "auto")

  var json: JSON {
    switch self {
    case .text(let text): ["type": "input_text", "text": .string(text)]
    case .image(let url, let detail): ["type": "input_image", "image_url": .string(url), "detail": .string(detail)]
    }
  }
}

public enum ToolResult: Sendable {
  case text(String)
  case json(JSON)
  case content([ToolContent], structured: JSON? = nil)

  var json: JSON {
    switch self {
    case .text(let text): .string(text)
    case .json(let value): value
    case .content(let items, let structured):
      if let structured {
        ["content": .array(items.map(\.json)), "structured_result": structured]
      } else {
        ["content": .array(items.map(\.json))]
      }
    }
  }
}

public enum PermissionMode: String, Sendable, CaseIterable {
  case plan
  case readOnly = "read_only"
  case auto
  case fullAccess = "full_access"
}

public struct ApprovalRequest: Sendable {
  public let id: String
  public let sessionID: String
  public let tool: String
  public let kind: String
  public let summary: String
  public let server: String
  public let arguments: String
  public let suggestedRule: String

  init(_ json: JSON) {
    id = json["id"]?.string ?? ""
    sessionID = json["session_id"]?.string ?? ""
    tool = json["tool"]?.string ?? ""
    kind = json["kind"]?.string ?? ""
    summary = json["summary"]?.string ?? ""
    server = json["server"]?.string ?? ""
    arguments = json["arguments"]?.string ?? ""
    suggestedRule = json["suggested_rule"]?.string ?? ""
  }
}

public enum ApprovalDecision: Sendable {
  case allow
  case allowAlways(rule: String)
  case deny(feedback: String? = nil)

  var json: JSON {
    switch self {
    case .allow: "allow"
    case .allowAlways(let rule): ["allow_always": .string(rule)]
    case .deny(let feedback): ["deny": feedback.map(JSON.string) ?? .null]
    }
  }
}

public struct HostTool: Sendable {
  public let name: String
  public let description: String
  public let parameters: JSON
  public let content: Bool
  public let run: @Sendable (ToolCall) async throws -> ToolResult

  public init(name: String, description: String, parameters: JSON, content: Bool = false,
              run: @escaping @Sendable (ToolCall) async throws -> ToolResult) {
    self.name = name
    self.description = description
    self.parameters = parameters
    self.content = content
    self.run = run
  }

  var definition: JSON {
    ["name": .string(name), "description": .string(description), "parameters": parameters, "content": .bool(content)]
  }
}

struct Pointer: @unchecked Sendable {
  let raw: OpaquePointer
}

final class Router: @unchecked Sendable {
  struct State {
    var handle: Pointer?
    var next: UInt64 = 1
    var pending: [UInt64: CheckedContinuation<JSON, Error>] = [:]
    var sessions: [String: [UUID: AsyncStream<SessionEvent>.Continuation]] = [:]
    var listeners: [UUID: AsyncStream<RuntimeEvent>.Continuation] = [:]
    var tools: [String: HostTool] = [:]
    var capabilities: [String: [HandCapability]] = [:]
    var approve: (@Sendable (ApprovalRequest) async -> ApprovalDecision)?
    var subscriptions: (any SubscriptionStore)?
    var willEdit: (@Sendable (_ sessionID: String, _ paths: [String]) async -> Void)?
    var python: (@Sendable (String) async throws -> String)?
    var stopped = false
  }

  let state = OSAllocatedUnfairLock(uncheckedState: State())

  func send(_ payload: JSON) {
    let data = payload.data()
    let handle = state.withLock { $0.stopped ? nil : $0.handle }
    guard let handle else { return }
    data.withUnsafeBytes { buffer in
      nanocode_send(handle.raw, buffer.bindMemory(to: UInt8.self).baseAddress, buffer.count)
    }
  }

  func request(_ command: JSON) async throws -> JSON {
    try await withCheckedThrowingContinuation { continuation in
      let id: UInt64? = state.withLock { state in
        guard !state.stopped else { return nil }
        let id = state.next
        state.next += 1
        state.pending[id] = continuation
        return id
      }
      guard let id else {
        continuation.resume(throwing: NanocodeError("the nanocode runtime stopped"))
        return
      }
      send(["id": .number(Double(id)), "command": command])
    }
  }

  func receive(_ data: Data) {
    guard let message = try? JSON.parse(data), let object = message.object else { return }
    if let id = object["reply"]?.uint64 {
      let continuation = state.withLock { $0.pending.removeValue(forKey: id) }
      if let error = object["error"]?.string {
        continuation?.resume(throwing: NanocodeError(error))
      } else {
        continuation?.resume(returning: object["ok"] ?? .null)
      }
    } else if let event = object["event"] {
      session(event)
    } else if let call = object["call"] {
      handle(call: call)
    } else if let hand = object["hand"], let id = hand["id"]?.string {
      if hand.object?.keys.contains("stopped") == true {
        broadcast(.handStopped(id: id, error: hand["stopped"]?.string))
      } else if let event = hand["event"] {
        broadcast(.hand(id: id, event: event))
      }
    } else if let runner = object["runner"], let id = runner["id"]?.string {
      if runner.object?.keys.contains("stopped") == true {
        broadcast(.runnerStopped(id: id, error: runner["stopped"]?.string))
      } else if let event = runner["event"] {
        broadcast(.runner(id: id, event: event))
      }
    } else if let wallet = object["wallet"], let prompt = wallet["prompt"],
              let code = prompt["user_code"]?.string, let uri = prompt["verification_uri"]?.string.flatMap(URL.init(string:)) {
      broadcast(.walletPrompt(DevicePrompt(
        userCode: code, verificationURI: uri,
        verificationURIComplete: prompt["verification_uri_complete"]?.string.flatMap(URL.init(string:)),
        expiresIn: prompt["expires_in"]?.int ?? 600)))
    } else if let payments = object["payments"] {
      if let notice = payments["notice"]?.string { broadcast(.notice(notice)) }
      if let status = payments["status"] { broadcast(.payments(status)) }
    } else if let log = object["log"]?.string ?? object["fatal"]?.string {
      broadcast(.log(log))
    }
  }

  private func session(_ event: JSON) {
    guard let id = event["session"]?.string else { return }
    var events: [SessionEvent] = []
    if let logged = event["logged"]?.array { events.append(.logged(logged.compactMap(LoggedEvent.init))) }
    if let live = event["live"]?.array { events.append(.live(live.compactMap(LoggedEvent.init))) }
    if let driving = event["driving"]?.bool { events.append(.driving(driving)) }
    if let turn = event["turn"] { events.append(.turn(turn)) }
    if let waiting = event["waiting"]?.string { events.append(.waiting(requestID: waiting, retryMs: event["retry_ms"]?.number ?? 0)) }
    if let resumed = event["resumed"]?.string { events.append(.resumed(resumed)) }
    if let error = event["error"]?.string { events.append(.failure(error)) }
    let listeners = state.withLock { Array(($0.sessions[id] ?? [:]).values) }
    for listener in listeners {
      for event in events { listener.yield(event) }
    }
  }

  private func broadcast(_ event: RuntimeEvent) {
    let listeners = state.withLock { Array($0.listeners.values) }
    for listener in listeners { listener.yield(event) }
  }

  private func handle(call: JSON) {
    guard let id = call["id"]?.uint64 else { return }
    let body = call["body"] ?? .null
    if call["kind"]?.string == "capability" {
      answerCapability(id: id, body: body)
      return
    }
    if call["kind"]?.string == "approval" {
      guard let approve = state.withLock({ $0.approve }) else {
        send(["command": ["reply": ["id": .number(Double(id)), "error": "this app does not answer approvals"]]])
        return
      }
      Task.detached { [weak self] in
        let decision = await approve(ApprovalRequest(body))
        self?.send(["command": ["reply": ["id": .number(Double(id)), "ok": decision.json]]])
      }
      return
    }
    if call["kind"]?.string == "subscription_store" {
      guard let store = state.withLock({ $0.subscriptions }) else {
        send(["command": ["reply": ["id": .number(Double(id)), "error": "this app keeps no plan sign-ins"]]])
        return
      }
      Task.detached { [weak self] in
        let reply: JSON
        do {
          reply = ["id": .number(Double(id)), "ok": try await SubscriptionCalls.answer(body, store: store)]
        } catch {
          reply = ["id": .number(Double(id)), "error": .string(error.localizedDescription)]
        }
        self?.send(["command": ["reply": reply]])
      }
      return
    }
    if call["kind"]?.string == "will_edit" {
      let willEdit = state.withLock { $0.willEdit }
      Task.detached { [weak self] in
        await willEdit?(body["session_id"]?.string ?? "", body["paths"]?.array?.compactMap(\.string) ?? [])
        self?.send(["command": ["reply": ["id": .number(Double(id)), "ok": .null]]])
      }
      return
    }
    if call["kind"]?.string == "python" {
      let python = state.withLock { $0.python }
      Task.detached { [weak self] in
        let reply: JSON
        do {
          guard let python else { throw NanocodeError("this app runs no Python") }
          reply = ["id": .number(Double(id)), "ok": .string(try await python(body["request"]?.string ?? "{}"))]
        } catch {
          reply = ["id": .number(Double(id)), "error": .string(error.localizedDescription)]
        }
        self?.send(["command": ["reply": reply]])
      }
      return
    }
    if call["kind"]?.string == "mcp_credentials" {
      do {
        send(["command": ["reply": ["id": .number(Double(id)), "ok": try McpCredentials.answer(body)]]])
      } catch {
        send(["command": ["reply": ["id": .number(Double(id)), "error": .string(error.localizedDescription)]]])
      }
      return
    }
    guard call["kind"]?.string == "tool", let name = body["name"]?.string else {
      send(["command": ["reply": ["id": .number(Double(id)), "error": "this app does not answer that call"]]])
      return
    }
    let tool = state.withLock { $0.tools[name] }
    let context = body["context"]
    let invocation = ToolCall(
      name: name, input: body["input"] ?? .null, sessionID: context?["session_id"]?.string,
      callID: context?["call_id"]?.string, turnID: context?["turn_id"]?.string, model: context?["model"]?.string)
    Task.detached { [weak self] in
      let reply: JSON
      if let tool {
        do {
          reply = ["id": .number(Double(id)), "ok": try await tool.run(invocation).json]
        } catch {
          reply = ["id": .number(Double(id)), "error": .string(error.localizedDescription)]
        }
      } else {
        reply = ["id": .number(Double(id)), "error": .string("the app has no tool named \(name)")]
      }
      self?.send(["command": ["reply": reply]])
    }
  }

  func subscribe(session id: String) -> AsyncStream<SessionEvent> {
    AsyncStream { continuation in
      let key = UUID()
      state.withLock { $0.sessions[id, default: [:]][key] = continuation }
      continuation.onTermination = { [weak self] _ in
        self?.state.withLock { state in
          state.sessions[id]?[key] = nil
          if state.sessions[id]?.isEmpty == true { state.sessions[id] = nil }
        }
      }
    }
  }

  func subscribe() -> AsyncStream<RuntimeEvent> {
    AsyncStream { continuation in
      let key = UUID()
      state.withLock { $0.listeners[key] = continuation }
      continuation.onTermination = { [weak self] _ in
        self?.state.withLock { _ = $0.listeners.removeValue(forKey: key) }
      }
    }
  }

  func stop() -> Pointer? {
    let (handle, pending, sessions, listeners) = state.withLock { state in
      state.stopped = true
      let taken = (state.handle, state.pending, state.sessions, state.listeners)
      state.handle = nil
      state.pending = [:]
      state.sessions = [:]
      state.listeners = [:]
      return taken
    }
    for continuation in pending.values { continuation.resume(throwing: NanocodeError("the nanocode runtime stopped")) }
    for listeners in sessions.values { for listener in listeners.values { listener.finish() } }
    for listener in listeners.values { listener.finish() }
    return handle
  }
}

private let callback: NanocodeCallback = { context, data, length in
  guard let context, let data else { return }
  let router = Unmanaged<Router>.fromOpaque(context).takeUnretainedValue()
  router.receive(Data(bytes: data, count: length))
}

public final class NanocodeRuntime: @unchecked Sendable {
  let router: Router
  private let context: UnsafeMutableRawPointer
  public let dataDirectory: URL

  public init(dataDirectory: URL, tempoHome: URL? = nil) throws {
    self.dataDirectory = dataDirectory
    try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
    router = Router()
    context = Unmanaged.passRetained(router).toOpaque()
    var config: [String: JSON] = ["data_dir": .string(dataDirectory.path)]
    if let tempoHome { config["tempo_home"] = .string(tempoHome.path) }
    let data = JSON.object(config).data()
    let handle = data.withUnsafeBytes { buffer in
      nanocode_start(buffer.bindMemory(to: UInt8.self).baseAddress, buffer.count, callback, context)
    }
    guard let handle else {
      Unmanaged<Router>.fromOpaque(context).release()
      throw NanocodeError("the nanocode runtime did not start")
    }
    let pointer = Pointer(raw: handle)
    router.state.withLock { $0.handle = pointer }
  }

  public static func standard(named name: String = "nanocode") throws -> NanocodeRuntime {
    let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
    return try NanocodeRuntime(dataDirectory: base.appendingPathComponent(name, isDirectory: true))
  }

  deinit {
    let handle = router.stop()
    let context = self.context
    if let handle {
      nanocode_stop(handle.raw)
    }
    Unmanaged<Router>.fromOpaque(context).release()
  }

  @discardableResult
  public func command(_ name: String, _ body: JSON = [:]) async throws -> JSON {
    try await router.request([name: body])
  }

  public func register(_ tools: [HostTool]) {
    router.state.withLock { state in
      for tool in tools { state.tools[tool.name] = tool }
    }
  }

  public func setApprovalHandler(_ approve: @escaping @Sendable (ApprovalRequest) async -> ApprovalDecision) {
    router.state.withLock { $0.approve = approve }
  }

  public func setSubscriptionStore(_ store: some SubscriptionStore) {
    router.state.withLock { $0.subscriptions = store }
  }

  public func setEditObserver(_ willEdit: @escaping @Sendable (_ sessionID: String, _ paths: [String]) async -> Void) {
    router.state.withLock { $0.willEdit = willEdit }
  }

  public func setPythonHost(_ run: @escaping @Sendable (_ request: String) async throws -> String) {
    router.state.withLock { $0.python = run }
  }

  public var events: AsyncStream<RuntimeEvent> { router.subscribe() }

  public func events(session id: String) -> AsyncStream<SessionEvent> { router.subscribe(session: id) }

  public func models() async throws -> ModelCatalog {
    try ModelCatalog(try await command("models"))
  }

  public func sessions() async throws -> [SessionSummary] {
    (try await command("sessions")).array?.compactMap(SessionSummary.init) ?? []
  }

  public func open(_ configuration: SessionConfiguration) async throws -> Session {
    register(configuration.tools)
    let summary = try await command("open", configuration.json)
    return Session(id: summary["session_id"]?.string ?? configuration.sessionID, model: summary["model"]?.string ?? "", runtime: self)
  }

  public func runShell(_ script: String, in directory: URL? = nil, stdin: String? = nil, timeout: TimeInterval? = nil) async throws -> ShellResult {
    var body: [String: JSON] = ["script": .string(script)]
    if let directory { body["cwd"] = .string(directory.path) }
    if let stdin { body["stdin"] = .string(stdin) }
    if let timeout { body["timeout_ms"] = .number((timeout * 1000).rounded()) }
    return ShellResult(try await command("shell_run", .object(body)))
  }
}

public struct ShellResult: Sendable, Hashable {
  public let stdout: String
  public let stderr: String
  public let exitCode: Int
  public let truncated: Bool

  init(_ json: JSON) {
    stdout = json["stdout"]?.string ?? ""
    stderr = json["stderr"]?.string ?? ""
    exitCode = json["exit_code"]?.int ?? 0
    truncated = json["truncated"]?.bool ?? false
  }
}
