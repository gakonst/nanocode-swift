import Foundation
import os
import UniformTypeIdentifiers

public enum RemoteKind: String, Codable, Sendable, CaseIterable, Identifiable {
  case cloudflare
  case vercel
  public var id: String { rawValue }
}

public struct RemoteServer: Sendable, Hashable {
  public var kind: RemoteKind
  public var url: URL
  public var token: String?

  public init(kind: RemoteKind, url: URL, token: String? = nil) {
    self.kind = kind
    self.url = url
    self.token = token
  }

  public static func cloudflare(_ url: URL = URL(string: "https://nanocode.xyz/cloudflare/")!, token: String? = nil) -> RemoteServer {
    RemoteServer(kind: .cloudflare, url: url, token: token)
  }

  public static func vercel(_ url: URL = URL(string: "https://nanocode.xyz/vercel/api/chat")!, token: String? = nil) -> RemoteServer {
    RemoteServer(kind: .vercel, url: url, token: token)
  }
}

public struct RemoteConversation: Codable, Sendable, Hashable, Identifiable {
  public var id: String
  public var kind: RemoteKind
  public var url: URL
  public var provider: Provider
  public var model: String
  public var thinking: String?
  public var title: String?
  public var createdAt: Date
  public var updatedAt: Date
  public var session: String?
  public var cursor: String?
  public var open: String?
  public var hand: String?

  public init(id: String, kind: RemoteKind, url: URL, provider: Provider, model: String, thinking: String? = nil,
              title: String? = nil, createdAt: Date = Date(), updatedAt: Date = Date(), session: String? = nil,
              cursor: String? = nil, open: String? = nil, hand: String? = nil) {
    self.id = id
    self.kind = kind
    self.url = url
    self.provider = provider
    self.model = model
    self.thinking = thinking
    self.title = title
    self.createdAt = createdAt
    self.updatedAt = updatedAt
    self.session = session
    self.cursor = cursor
    self.open = open
    self.hand = hand
  }
}

public final class RemoteStore: Sendable {
  public let directory: URL
  private let lock = OSAllocatedUnfairLock()

  public init(directory: URL) throws {
    self.directory = directory
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  }

  private var index: URL { directory.appendingPathComponent("conversations.json") }

  private func journal(_ id: String) -> URL { directory.appendingPathComponent("\(id).jsonl") }

  public var visitor: String {
    lock.withLock {
      let file = directory.appendingPathComponent("visitor")
      if let saved = try? String(contentsOf: file, encoding: .utf8), saved.count == 64 { return saved }
      var bytes = [UInt8](repeating: 0, count: 32)
      _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
      let created = bytes.map { String(format: "%02x", $0) }.joined()
      try? created.write(to: file, atomically: true, encoding: .utf8)
      return created
    }
  }

  private func load() -> [RemoteConversation] {
    guard let data = try? Data(contentsOf: index) else { return [] }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .millisecondsSince1970
    return (try? decoder.decode([RemoteConversation].self, from: data)) ?? []
  }

  private func write(_ conversations: [RemoteConversation]) {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .millisecondsSince1970
    if let data = try? encoder.encode(conversations) { try? data.write(to: index, options: .atomic) }
  }

  public func conversations() -> [RemoteConversation] {
    lock.withLock { load() }.sorted { $0.updatedAt > $1.updatedAt }
  }

  public func save(_ conversation: RemoteConversation) {
    lock.withLock {
      var all = load()
      if let index = all.firstIndex(where: { $0.id == conversation.id }) { all[index] = conversation } else { all.append(conversation) }
      write(all)
    }
  }

  public func remove(_ id: String) {
    lock.withLock {
      write(load().filter { $0.id != id })
      try? FileManager.default.removeItem(at: journal(id))
    }
  }

  func append(_ id: String, _ lines: [JSON]) {
    guard !lines.isEmpty else { return }
    var buffer = Data()
    for line in lines {
      buffer.append(line.data())
      buffer.append(0x0a)
    }
    let data = buffer
    lock.withLock {
      let file = journal(id)
      if let handle = try? FileHandle(forWritingTo: file) {
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
        try? handle.close()
      } else {
        try? data.write(to: file)
      }
    }
  }

  func lines(_ id: String) -> [JSON] {
    let data = lock.withLock { try? Data(contentsOf: journal(id)) } ?? Data()
    return data.split(separator: 0x0a).compactMap { try? JSON.parse(Data($0)) }
  }
}

struct ServerEvent {
  var id: String?
  var event: String?
  var data: String
}

struct ServerEvents: AsyncSequence {
  typealias Element = ServerEvent
  let bytes: URLSession.AsyncBytes

  struct AsyncIterator: AsyncIteratorProtocol {
    var bytes: URLSession.AsyncBytes.AsyncIterator
    var line: [UInt8] = []

    mutating func next() async throws -> ServerEvent? {
      var current = ServerEvent(id: nil, event: nil, data: "")
      var hasData = false
      while true {
        guard let byte = try await bytes.next() else {
          return hasData || current.id != nil ? current : nil
        }
        if byte == 0x0d { continue }
        if byte != 0x0a {
          line.append(byte)
          continue
        }
        let text = String(decoding: line, as: UTF8.self)
        line.removeAll(keepingCapacity: true)
        if text.isEmpty {
          if hasData || current.id != nil || current.event != nil { return current }
          continue
        }
        if text.hasPrefix(":") { continue }
        let field: Substring
        var value: Substring = ""
        if let colon = text.firstIndex(of: ":") {
          field = text[..<colon]
          value = text[text.index(after: colon)...]
          if value.first == " " { value = value.dropFirst() }
        } else {
          field = Substring(text)
        }
        switch field {
        case "id": current.id = String(value)
        case "event": current.event = String(value)
        case "data":
          current.data += hasData ? "\n" + value : String(value)
          hasData = true
        default: break
        }
      }
    }
  }

  func makeAsyncIterator() -> AsyncIterator { AsyncIterator(bytes: bytes.makeAsyncIterator()) }
}

public final class RemoteSession: ChatBackend, @unchecked Sendable {
  public let server: RemoteServer
  public let store: RemoteStore

  private struct Queued {
    var prompt: String
    var images: [String]
    var files: [PromptFile]
    var requestID: String
  }

  private struct State {
    var record: RemoteConversation
    var listeners: [UUID: AsyncStream<SessionEvent>.Continuation] = [:]
    var queue: [Queued] = []
    var running = false
    var stopped: Set<String> = []
    var saved = Date.distantPast
    var streams: [String: Task<JSON?, Error>] = [:]
    var settled: [String: JSON] = [:]
    var unadmitted: Set<String> = []
    var posting: String?
  }

  private let state: OSAllocatedUnfairLock<State>
  private var http: URLSession { Self.http }

  private static let http: URLSession = {
    let configuration = URLSessionConfiguration.default
    configuration.timeoutIntervalForRequest = 300
    configuration.timeoutIntervalForResource = 24 * 60 * 60
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    return URLSession(configuration: configuration)
  }()

  private static let handTokens = OSAllocatedUnfairLock<[String: String]>(initialState: [:])

  public init(server: RemoteServer, store: RemoteStore, conversation: RemoteConversation) {
    self.server = server
    self.store = store
    state = OSAllocatedUnfairLock(uncheckedState: State(record: conversation))
  }

  public static func create(server: RemoteServer, store: RemoteStore, provider: Provider, model: String,
                            thinking: String?) -> RemoteSession {
    var bytes = [UInt8](repeating: 0, count: 12)
    _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
    let id = "app-" + bytes.map { String(format: "%02x", $0) }.joined()
    let now = Date()
    let record = RemoteConversation(id: id, kind: server.kind, url: server.url, provider: provider, model: model,
                                    thinking: thinking, title: nil, createdAt: now, updatedAt: now)
    return RemoteSession(server: server, store: store, conversation: record)
  }

  public var id: String { record.id }

  public var record: RemoteConversation { state.withLock { $0.record } }

  public var hand: String? {
    get { record.hand }
    set { mutate(save: true) { $0.hand = newValue } }
  }

  public var events: AsyncStream<SessionEvent> {
    AsyncStream { continuation in
      let key = UUID()
      state.withLock { $0.listeners[key] = continuation }
      continuation.onTermination = { [weak self] _ in
        _ = self?.state.withLock { $0.listeners.removeValue(forKey: key) }
      }
    }
  }

  private func emit(_ event: SessionEvent) {
    for listener in state.withLock({ Array($0.listeners.values) }) { listener.yield(event) }
  }

  private func mutate(save force: Bool = false, _ change: (inout RemoteConversation) -> Void) {
    let (record, write) = state.withLockUnchecked { state -> (RemoteConversation, Bool) in
      change(&state.record)
      let now = Date()
      let write = force || now.timeIntervalSince(state.saved) > 0.3
      if write { state.saved = now }
      return (state.record, write)
    }
    if write { store.save(record) }
  }

  private func headers(_ request: inout URLRequest, json: Bool = false, stream: Bool = false) {
    if server.kind == .cloudflare { request.setValue(store.visitor, forHTTPHeaderField: "x-nanocode-visitor") }
    if let token = server.token, !token.isEmpty { request.setValue("Bearer \(token)", forHTTPHeaderField: "authorization") }
    if json { request.setValue("application/json", forHTTPHeaderField: "content-type") }
    if stream { request.setValue("text/event-stream", forHTTPHeaderField: "accept") }
  }

  private func cloudflareURL(_ suffix: String) -> URL {
    let session = record.session ?? record.id
    let encoded = session.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? session
    return URL(string: "sessions/\(encoded)/\(suffix)", relativeTo: server.url)!.absoluteURL
  }

  private func vercelURL(_ query: [URLQueryItem]) -> URL {
    var components = URLComponents(url: server.url, resolvingAgainstBaseURL: false)!
    components.queryItems = query
    return components.url!
  }

  private func post(_ url: URL, _ body: JSON, stream: Bool = false) -> URLRequest {
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.httpBody = body.data()
    headers(&request, json: true, stream: stream)
    return request
  }

  private func failure(_ data: Data, _ response: URLResponse) -> String {
    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
    let body = String(decoding: data, as: UTF8.self)
    let message = (try? JSON.parse(data))?["error"]?.string ?? body
    return "\(server.kind == .cloudflare ? "Cloudflare" : "Vercel") answered \(status): \(message.prefix(400))"
  }

  public func replay() async throws -> [SessionEvent] {
    var events: [SessionEvent] = []
    var logged: [LoggedEvent] = []
    var live: [LiveEvent] = []
    for line in store.lines(record.id) {
      if let event = line["logged"].flatMap(LoggedEvent.init) {
        if !live.isEmpty {
          events.append(.events(live))
          live = []
        }
        logged.append(event)
      } else if let event = line["live"].flatMap(LiveEvent.init(json:)) {
        if !logged.isEmpty {
          events.append(.logged(logged))
          logged = []
        }
        live.append(event)
      }
    }
    if !logged.isEmpty { events.append(.logged(logged)) }
    if !live.isEmpty { events.append(.events(live)) }
    return events
  }

  public func openRequests() async throws -> [String] { record.open.map { [$0] } ?? [] }

  public func start(_ prompt: String, images: [String], files: [PromptFile], requestID: String) async throws -> Submitted {
    mutate(save: true) { record in
      if record.title == nil, !prompt.isEmpty { record.title = String(prompt.prefix(80)) }
      record.updatedAt = Date()
    }
    if server.kind == .vercel { journalPrompt(prompt, images: images, requestID: requestID, kind: "prompt") }
    let begin = state.withLock { state -> Bool in
      state.queue.append(Queued(prompt: prompt, images: images, files: files, requestID: requestID))
      if state.running { return false }
      state.running = true
      return true
    }
    if begin { Task { await self.drain() } }
    return Submitted(status: "queued", turn: nil)
  }

  public func steerRunning(_ prompt: String, images: [String], files: [PromptFile], requestID: String) async throws -> Bool {
    guard state.withLock({ $0.running }), let session = record.session ?? (server.kind == .cloudflare ? record.id : nil) else {
      return false
    }
    switch server.kind {
    case .cloudflare:
      var body: [String: JSON] = ["request_id": .string(requestID), "prompt": .string(prompt), "steer": true,
                                  "provider": .string(record.provider.rawValue), "model": .string(record.model)]
      if let hand = record.hand { body["hand"] = .string(hand) }
      let request = post(cloudflareURL("turns"), .object(body))
      let (data, response) = try await retrying { try await self.http.data(for: request) }
      let status = (response as? HTTPURLResponse)?.statusCode ?? 0
      if status == 409 { return false }
      guard (200..<300).contains(status) else { throw NanocodeError(failure(data, response)) }
      return true
    case .vercel:
      let (data, response) = try await http.data(for: post(server.url, ["kind": "steer", "sessionId": .string(session), "text": .string(prompt)]))
      guard ((response as? HTTPURLResponse)?.statusCode ?? 0) < 300 else { throw NanocodeError(failure(data, response)) }
      journalPrompt(prompt, images: images, requestID: requestID, kind: "steer")
      return true
    }
  }

  public func stopTurn(_ requestID: String) async throws {
    let open = record.open ?? requestID
    let dropped = state.withLock { state -> [String] in
      let dropped = state.queue.map(\.requestID).filter { $0 != open }
      state.queue.removeAll()
      state.stopped.insert(open)
      return dropped
    }
    for request in dropped { emit(.turn(["report": ["request_id": .string(request), "status": "cancelled"]])) }
    switch server.kind {
    case .cloudflare:
      let (data, response) = try await cancel(open)
      switch (response as? HTTPURLResponse)?.statusCode ?? 0 {
      case 202:
        return
      case 200..<300:
        settle(open, (try? JSON.parse(data)).flatMap { $0["status"] == nil ? nil : $0 } ?? ["status": "cancelled"])
      case 404:
        if state.withLock({ $0.posting == open }) {
          _ = state.withLock { $0.unadmitted.insert(open) }
        } else {
          settle(open, ["status": "cancelled", "error": .string("the deployment has no turn \(open)")])
        }
      default:
        throw NanocodeError(failure(data, response))
      }
    case .vercel:
      guard let session = record.session else { return }
      let request = post(server.url, ["kind": "cancel", "sessionId": .string(session)])
      let (data, response) = try await retrying { try await self.http.data(for: request) }
      guard ((response as? HTTPURLResponse)?.statusCode ?? 0) < 300 else { throw NanocodeError(failure(data, response)) }
    }
  }

  private func cancel(_ requestID: String) async throws -> (Data, URLResponse) {
    let encoded = requestID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? requestID
    let request = post(cloudflareURL("turns/\(encoded)/cancel"), [:])
    return try await retrying { try await self.http.data(for: request) }
  }

  private func settle(_ requestID: String, _ report: JSON) {
    let (active, task) = state.withLock { state -> (Bool, Task<JSON?, Error>?) in
      guard state.running, state.record.open == requestID else { return (false, nil) }
      state.settled[requestID] = report
      return (true, state.streams[requestID])
    }
    if active {
      task?.cancel()
    } else {
      var object = report.object ?? [:]
      object["request_id"] = .string(requestID)
      emit(.turn(["report": .object(object)]))
    }
  }

  private func settled(_ requestID: String) -> JSON? {
    state.withLock { $0.settled.removeValue(forKey: requestID) }
  }

  private static let controlRetries = 2

  private func retrying(_ send: () async throws -> (Data, URLResponse)) async throws -> (Data, URLResponse) {
    var delay = 1.0
    var attempt = 0
    while true {
      do {
        let (data, response) = try await send()
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard attempt < Self.controlRetries, status == 408 || status == 429 || status >= 500 else { return (data, response) }
        delay = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "retry-after").flatMap(Double.init) ?? delay
      } catch let error as URLError where error.code != .cancelled && attempt < Self.controlRetries {
      }
      attempt += 1
      try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
      delay *= 2
    }
  }

  public func resume() async {
    let open = record.open
    if open == nil, server.kind == .cloudflare { await catchUp() }
    guard let open else { return }
    let begin = state.withLock { state -> Bool in
      if state.running { return false }
      state.running = true
      return true
    }
    guard begin else { return }
    emit(.driving(true))
    emit(.resumed(open))
    let report = await reconnect(open)
    finish(open, report)
    await drain()
  }

  public func delete() {
    state.withLock { $0.queue.removeAll() }
    store.remove(record.id)
  }

  public func handAccess(name: String) async throws -> (url: URL, token: String) {
    guard server.kind == .cloudflare else {
      throw NanocodeError("only the Cloudflare deployment takes this device as a hand")
    }
    let key = cloudflareURL("hands").absoluteString
    var token = Self.handTokens.withLock { $0[key] }
    if token == nil {
      var request = URLRequest(url: cloudflareURL("hands"))
      request.httpMethod = "POST"
      headers(&request)
      let (data, response) = try await http.data(for: request)
      guard ((response as? HTTPURLResponse)?.statusCode ?? 0) < 300, let minted = (try JSON.parse(data))["token"]?.string else {
        throw NanocodeError(failure(data, response))
      }
      Self.handTokens.withLock { $0[key] = minted }
      token = minted
    }
    guard let token else { throw NanocodeError("the deployment issued no hand token") }
    var components = URLComponents(url: cloudflareURL("hands/\(name)"), resolvingAgainstBaseURL: false)!
    components.scheme = components.scheme == "http" ? "ws" : "wss"
    return (components.url!, token)
  }

  public static func forgetHandToken(_ token: String) {
    handTokens.withLock { tokens in tokens = tokens.filter { $0.value != token } }
  }

  public func attachedHands() async -> [String] {
    guard server.kind == .cloudflare else { return [] }
    var request = URLRequest(url: cloudflareURL("hands"))
    headers(&request)
    guard let (data, _) = try? await http.data(for: request) else { return [] }
    return (try? JSON.parse(data))?["hands"]?.array?.compactMap(\.string) ?? []
  }

  private func journalPrompt(_ prompt: String, images: [String], requestID: String, kind: String) {
    let event = LiveEvent(type: "user", fields: [
      "text": .string(prompt), "kind": .string(kind), "images": .array(images.map(JSON.string)),
      "request_id": .string(requestID), "at": .number(Date().timeIntervalSince1970 * 1000),
    ])
    store.append(record.id, [["live": event.json]])
  }

  private func drain() async {
    while true {
      let next = state.withLock { state -> Queued? in
        if state.queue.isEmpty {
          state.running = false
          return nil
        }
        return state.queue.removeFirst()
      }
      guard let next else { break }
      emit(.driving(true))
      mutate(save: true) { $0.open = next.requestID }
      let report: JSON
      do {
        report = try await turn(next)
      } catch {
        emit(.failure(error.localizedDescription))
        report = ["status": "failed", "error": .string(error.localizedDescription)]
      }
      finish(next.requestID, report)
    }
    emit(.driving(false))
  }

  private func finish(_ requestID: String, _ report: JSON) {
    state.withLock { state in
      state.stopped.remove(requestID)
      state.settled[requestID] = nil
      state.unadmitted.remove(requestID)
    }
    mutate(save: true) { record in
      if record.open == requestID { record.open = nil }
      record.updatedAt = Date()
    }
    var object = report.object ?? [:]
    object["request_id"] = .string(requestID)
    emit(.turn(["report": .object(object)]))
  }

  private func turn(_ next: Queued) async throws -> JSON {
    switch server.kind {
    case .cloudflare: return try await cloudflareTurn(next)
    case .vercel: return try await vercelTurn(next)
    }
  }

  private static func decode(_ dataURL: String) -> (type: String, data: Data)? {
    guard dataURL.hasPrefix("data:"), let comma = dataURL.firstIndex(of: ",") else { return nil }
    let header = dataURL[dataURL.index(dataURL.startIndex, offsetBy: 5)..<comma]
    let type = header.split(separator: ";").first.map(String.init) ?? "application/octet-stream"
    guard let data = Data(base64Encoded: String(dataURL[dataURL.index(after: comma)...]), options: .ignoreUnknownCharacters) else { return nil }
    return (type, data)
  }

  private static func uploads(_ next: Queued) -> [(name: String, type: String, data: Data)] {
    var files: [(String, String, Data)] = []
    for (index, image) in next.images.enumerated() {
      guard let (type, data) = decode(image) else { continue }
      let suffix = UTType(mimeType: type)?.preferredFilenameExtension ?? "png"
      files.append(("image-\(index + 1).\(suffix)", type, data))
    }
    for file in next.files {
      guard let (type, data) = decode(file.dataURL) else { continue }
      files.append((file.filename, type, data))
    }
    return files
  }

  private static func attached(_ prompt: String, _ items: [(path: String, type: String, size: Int)]) -> String {
    guard !items.isEmpty else { return prompt }
    let lines = items.map { "Attached: \($0.path) (\($0.type.isEmpty ? "file" : $0.type), \(Format.bytes($0.size)))" }
    return prompt.isEmpty ? lines.joined(separator: "\n") : prompt + "\n\n" + lines.joined(separator: "\n")
  }

  private func cloudflareTurn(_ next: Queued) async throws -> JSON {
    mutate(save: true) { $0.session = $0.session ?? $0.id }
    var attachments: [(path: String, type: String, size: Int)] = []
    for upload in Self.uploads(next) {
      let name = upload.name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? upload.name
      var request = URLRequest(url: URL(string: cloudflareURL("files").absoluteString + "?name=\(name)")!)
      request.httpMethod = "POST"
      request.httpBody = upload.data
      headers(&request)
      request.setValue("application/octet-stream", forHTTPHeaderField: "content-type")
      let (data, response) = try await http.data(for: request)
      guard ((response as? HTTPURLResponse)?.statusCode ?? 0) < 300 else { throw NanocodeError(failure(data, response)) }
      let file = try JSON.parse(data)
      attachments.append((file["path"]?.string ?? "", file["type"]?.string ?? upload.type, file["size"]?.int ?? upload.data.count))
    }
    var body: [String: JSON] = [
      "request_id": .string(next.requestID), "prompt": .string(Self.attached(next.prompt, attachments)),
      "provider": .string(record.provider.rawValue), "model": .string(record.model),
    ]
    let images = attachments.filter { $0.type.hasPrefix("image/") }.map { JSON.string($0.path) }
    if !images.isEmpty { body["images"] = .array(images) }
    if let thinking = record.thinking { body["thinking"] = .string(thinking) }
    if let hand = record.hand { body["hand"] = .string(hand) }
    var delay = 0.5
    state.withLock { $0.posting = next.requestID }
    defer { state.withLock { $0.posting = nil } }
    while !Task.isCancelled, !state.withLock({ $0.stopped.contains(next.requestID) }) {
      var request = post(URL(string: cloudflareURL("turns").absoluteString + "?live=1&after=\(record.cursor ?? "0")")!,
                         .object(body), stream: true)
      request.timeoutInterval = 300
      do {
        if let report = try await follow(request, next.requestID) { return report }
        if let report = settled(next.requestID) { return report }
        state.withLock { $0.posting = nil }
        return await reconnect(next.requestID)
      } catch let error as NanocodeError {
        throw error
      } catch let retry as Retry {
        delay = retry.after ?? min(delay * 2, 15)
      } catch {
        delay = min(delay * 2, 15)
      }
      if let report = settled(next.requestID) { return report }
      if state.withLock({ $0.stopped.contains(next.requestID) }) { break }
      emit(.waiting(requestID: next.requestID, retryMs: delay * 1000))
      try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
    }
    if state.withLock({ $0.unadmitted.remove(next.requestID) != nil }) { _ = try? await cancel(next.requestID) }
    return settled(next.requestID) ?? ["status": "cancelled"]
  }

  private func follow(_ request: URLRequest, _ requestID: String) async throws -> JSON? {
    let reading = Task { try await self.read(request, requestID) }
    let done = state.withLock { state -> Bool in
      state.streams[requestID] = reading
      return state.settled[requestID] != nil
    }
    defer { state.withLock { state in if state.streams[requestID] == reading { state.streams[requestID] = nil } } }
    if done { reading.cancel() }
    return try await withTaskCancellationHandler { try await reading.value } onCancel: { reading.cancel() }
  }

  private func read(_ request: URLRequest, _ requestID: String) async throws -> JSON? {
    let (bytes, response) = try await http.bytes(for: request)
    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
    guard (200..<300).contains(status) else {
      var data = Data()
      for try await byte in bytes { data.append(byte) }
      if status == 408 || status == 429 || status >= 500 { throw Retry(after: (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "retry-after").flatMap(Double.init)) }
      throw NanocodeError(failure(data, response))
    }
    switch server.kind {
    case .cloudflare: return try await followCloudflare(bytes, requestID)
    case .vercel: return try await followVercel(bytes)
    }
  }

  private func followCloudflare(_ bytes: URLSession.AsyncBytes, _ requestID: String) async throws -> JSON? {
    for try await message in ServerEvents(bytes: bytes) {
      if let id = message.id, UInt64(id) != nil { mutate { $0.cursor = id } }
      guard !message.data.isEmpty, let json = JSON.parse(message.data), let logged = LoggedEvent(json) else { continue }
      if logged.seq > 0 {
        store.append(record.id, [["logged": logged.json]])
        emit(.logged([logged]))
      } else {
        emit(.live([logged]))
      }
      if logged.requestID == requestID, state.withLock({ $0.unadmitted.remove(requestID) != nil }) {
        Task { [weak self] in _ = try? await self?.cancel(requestID) }
      }
      let body = logged.event
      guard body["source"] == nil || body["source"]?.isNull == true, logged.requestID == requestID else { continue }
      if body["type"]?.string == "result" {
        mutate(save: true) { _ in }
        var report: [String: JSON] = ["status": body["status"] ?? "completed"]
        if let message = body["ok"]?["message"] { report["message"] = message }
        if let error = body["error"], !error.isNull { report["error"] = error }
        return .object(report)
      }
    }
    return nil
  }

  private func followVercel(_ bytes: URLSession.AsyncBytes) async throws -> JSON? {
    var report: JSON = ["status": "completed"]
    for try await message in ServerEvents(bytes: bytes) {
      if let id = message.id { mutate { $0.cursor = id } }
      if message.event == "end" {
        mutate(save: true) { _ in }
        return report
      }
      guard !message.data.isEmpty, let json = JSON.parse(message.data), let event = LiveEvent(json: json),
            event.type != "idle" else { continue }
      store.append(record.id, [["live": event.json]])
      emit(.events([event]))
      if event.type == "turn" {
        var fields: [String: JSON] = ["status": event["status"] ?? "completed"]
        if let message = event["message"] { fields["message"] = message }
        if let error = event["error"], !error.isNull { fields["error"] = error }
        report = .object(fields)
      }
    }
    return nil
  }

  private struct Retry: Error {
    var after: Double?
  }

  private func reconnect(_ requestID: String) async -> JSON {
    var delay = 0.5
    while !Task.isCancelled {
      if let report = settled(requestID) { return report }
      let request: URLRequest
      var check: Task<Void, Never>?
      switch server.kind {
      case .cloudflare:
        var get = URLRequest(url: URL(string: cloudflareURL("events").absoluteString + "?live=1&after=\(record.cursor ?? "0")")!)
        headers(&get, stream: true)
        request = get
        check = Task { [weak self] in await self?.check(requestID) }
      case .vercel:
        let cursor = record.cursor ?? "0.0"
        guard let session = record.session, !cursor.hasSuffix(";end") else { return ["status": "completed"] }
        var get = URLRequest(url: vercelURL([URLQueryItem(name: "sessionId", value: session), URLQueryItem(name: "cursor", value: cursor)]))
        headers(&get)
        request = get
      }
      do {
        if let report = try await follow(request, requestID) {
          check?.cancel()
          return report
        }
        delay = 1
      } catch let retry as Retry {
        delay = retry.after ?? min(delay * 2, 15)
      } catch let error as NanocodeError {
        check?.cancel()
        emit(.failure(error.localizedDescription))
        return ["status": "failed", "error": .string(error.localizedDescription)]
      } catch {
        delay = min(delay * 2, 15)
      }
      check?.cancel()
      if let report = settled(requestID) {
        await catchUp(force: true)
        return report
      }
      emit(.waiting(requestID: requestID, retryMs: delay * 1000))
      try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
    }
    return ["status": "cancelled"]
  }

  private func check(_ requestID: String) async {
    let encoded = requestID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? requestID
    var request = URLRequest(url: cloudflareURL("turns/\(encoded)"))
    headers(&request)
    guard let (data, response) = try? await http.data(for: request), (response as? HTTPURLResponse)?.statusCode == 200,
          let report = try? JSON.parse(data), let status = report["status"]?.string,
          Self.finished.contains(status) else { return }
    settle(requestID, report)
  }

  private static let finished: Set<String> = ["completed", "failed", "cancelled"]

  private func catchUp(force: Bool = false) async {
    guard server.kind == .cloudflare, force || record.session != nil else { return }
    while true {
      var request = URLRequest(url: URL(string: cloudflareURL("events").absoluteString + "?after=\(record.cursor ?? "0")&limit=500")!)
      headers(&request)
      guard let (data, response) = try? await http.data(for: request), ((response as? HTTPURLResponse)?.statusCode ?? 0) < 300,
            let page = try? JSON.parse(data) else { return }
      let events = page["events"]?.array?.compactMap(LoggedEvent.init) ?? []
      if !events.isEmpty {
        store.append(record.id, events.map { ["logged": $0.json] })
        emit(.logged(events))
      }
      if let next = page["next_cursor"]?.uint64 { mutate(save: true) { $0.cursor = String(next) } }
      guard page["has_more"]?.bool == true, !events.isEmpty else { return }
    }
  }

  private func vercelTurn(_ next: Queued) async throws -> JSON {
    if record.session == nil {
      var body: [String: JSON] = ["harness": .string(record.provider.rawValue), "model": .string(record.model), "warm": true]
      if let thinking = record.thinking { body["effort"] = .string(thinking) }
      let (data, response) = try await http.data(for: post(server.url, .object(body)))
      guard ((response as? HTTPURLResponse)?.statusCode ?? 0) < 300, let session = (try JSON.parse(data))["sessionId"]?.string else {
        throw NanocodeError(failure(data, response))
      }
      mutate(save: true) { $0.session = session }
    }
    guard let session = record.session else { throw NanocodeError("the Vercel deployment started no session") }
    var items: [(path: String, type: String, size: Int)] = []
    var carried: [JSON] = []
    for upload in Self.uploads(next) {
      let path = "/workspace/uploads/\(upload.name)"
      items.append((path, upload.type, upload.data.count))
      carried.append(["path": .string(path), "data": .string(upload.data.base64EncodedString())])
    }
    var body: [String: JSON] = ["sessionId": .string(session), "text": .string(Self.attached(next.prompt, items))]
    if !carried.isEmpty { body["attachments"] = .array(carried) }
    var request = post(server.url, .object(body))
    request.timeoutInterval = 300
    if let report = try await follow(request, next.requestID) { return report }
    return await reconnect(next.requestID)
  }
}
