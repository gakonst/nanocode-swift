import Foundation
import Observation
import UniformTypeIdentifiers

public protocol ChatBackend: AnyObject, Sendable {
  var events: AsyncStream<SessionEvent> { get }
  func replay() async throws -> [SessionEvent]
  func openRequests() async throws -> [String]
  func start(_ prompt: String, images: [String], files: [PromptFile], requestID: String) async throws -> Submitted
  func steerRunning(_ prompt: String, images: [String], files: [PromptFile], requestID: String) async throws -> Bool
  func stopTurn(_ requestID: String) async throws
  func resume() async
}

extension Session: ChatBackend {
  public func replay() async throws -> [SessionEvent] { [.logged(try await history())] }

  public func openRequests() async throws -> [String] { try await pending().map(\.requestID) }

  public func start(_ prompt: String, images: [String], files: [PromptFile], requestID: String) async throws -> Submitted {
    try await submit(prompt, images: images, files: files, requestID: requestID)
  }

  public func steerRunning(_ prompt: String, images: [String], files: [PromptFile], requestID: String) async throws -> Bool {
    try await steer(prompt, images: images, files: files, requestID: requestID)
  }

  public func stopTurn(_ requestID: String) async throws { try await cancel(requestID) }

  public func resume() async {}
}

@MainActor
@Observable
public final class Chat {
  public private(set) var entries: [Entry] = []
  public private(set) var live: [Entry] = []
  public private(set) var driving = false
  public private(set) var error: String?
  public private(set) var backend: (any ChatBackend)?
  public private(set) var loading = false
  public private(set) var waiting: String?
  public var workspace: URL?
  @ObservationIgnored private var requests: [String] = []
  @ObservationIgnored private var local = Set<String>()
  @ObservationIgnored private let transcript: Transcript
  @ObservationIgnored private var listener: Task<Void, Never>?
  @ObservationIgnored private let revealMs: Double

  public init(revealMs: Double = 30) {
    self.revealMs = revealMs
    transcript = Transcript(revealMs: revealMs)
    transcript.add = { [weak self] entry in self?.entries.append(entry) }
    transcript.live = { [weak self] entries in self?.live = entries }
    transcript.hidesPrompt = { [weak self] request in self?.local.contains(request) ?? false }
    transcript.apply = { [weak self] event in self?.applied(event) }
  }

  public var session: Session? { backend as? Session }

  public var pending: Bool { driving || !requests.isEmpty }

  public var turns: [Turn] { Turn.group(entries, live: live, pending: pending) }

  public var activity: Activity { Activity.of(live, pending: pending) }

  public func attach(_ backend: any ChatBackend, history: Bool = true) async {
    detach()
    self.backend = backend
    entries = []
    live = []
    error = nil
    transcript.reset()
    let events = backend.events
    listener = Task { @MainActor [weak self] in
      for await event in events {
        self?.handle(event)
      }
    }
    guard history else { return }
    loading = true
    defer { loading = false }
    do {
      let replayed = try await backend.replay()
      transcript.revealMs = 0
      for event in replayed { push(event) }
      transcript.run { [weak self] in self.map { $0.transcript.revealMs = $0.revealMs } }
      requests = try await backend.openRequests()
    } catch {
      self.error = error.localizedDescription
    }
    Task { await backend.resume() }
  }

  public func detach() {
    listener?.cancel()
    listener = nil
    backend = nil
    requests = []
    driving = false
  }

  public func attach(_ files: [URL]) throws -> [String] {
    guard let workspace else { throw NanocodeError("this chat has no workspace to attach files to") }
    let uploads = workspace.appendingPathComponent("uploads", isDirectory: true)
    try FileManager.default.createDirectory(at: uploads, withIntermediateDirectories: true)
    return try files.map { file in
      let scoped = file.startAccessingSecurityScopedResource()
      defer { if scoped { file.stopAccessingSecurityScopedResource() } }
      var target = uploads.appendingPathComponent(file.lastPathComponent)
      var index = 2
      while FileManager.default.fileExists(atPath: target.path) {
        let stem = file.deletingPathExtension().lastPathComponent
        let suffix = file.pathExtension.isEmpty ? "" : ".\(file.pathExtension)"
        target = uploads.appendingPathComponent("\(stem)-\(index)\(suffix)")
        index += 1
      }
      try FileManager.default.copyItem(at: file, to: target)
      let size = (try? FileManager.default.attributesOfItem(atPath: target.path)[.size] as? Int) ?? 0
      let kind = target.pathExtension.isEmpty ? "file" : target.pathExtension
      return "Attached: \(target.path) (\(kind), \(Format.bytes(size)))"
    }
  }

  public static func promptFiles(_ files: [URL]) throws -> [PromptFile] {
    try files.map { file in
      let scoped = file.startAccessingSecurityScopedResource()
      defer { if scoped { file.stopAccessingSecurityScopedResource() } }
      let type = UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
      return PromptFile(filename: file.lastPathComponent, mediaType: type, data: try Data(contentsOf: file))
    }
  }

  public func send(_ text: String, images: [String] = [], files: [URL] = []) async {
    guard let backend else {
      error = "No session is open."
      return
    }
    var text = text
    var documents: [PromptFile] = []
    if !files.isEmpty {
      do {
        if workspace != nil {
          let lines = try attach(files)
          text = text.isEmpty ? lines.joined(separator: "\n") : text + "\n\n" + lines.joined(separator: "\n")
        } else {
          documents = try Self.promptFiles(files)
        }
      } catch {
        self.error = error.localizedDescription
        return
      }
    }
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty || !images.isEmpty || !documents.isEmpty else { return }
    error = nil
    let request = Identifier.uuidv7()
    local.insert(request)
    let steering = pending
    transcript.aside(Entry(id: "user-\(request)", kind: .user, text: trimmed, startedAt: Date().timeIntervalSince1970 * 1000,
                           steer: steering, images: images, requestID: request))
    do {
      if steering, try await backend.steerRunning(trimmed, images: images, files: documents, requestID: request) {
        return
      }
      requests.append(request)
      let submitted = try await backend.start(trimmed, images: images, files: documents, requestID: request)
      if submitted.status == "too_large" {
        requests.removeAll { $0 == request }
        error = "The message is too large to send."
      }
    } catch {
      requests.removeAll { $0 == request }
      self.error = error.localizedDescription
    }
  }

  public func stop() async {
    guard let backend, let request = requests.first else { return }
    do {
      try await backend.stopTurn(request)
    } catch {
      self.error = error.localizedDescription
    }
  }

  private func push(_ event: SessionEvent) {
    switch event {
    case .logged(let events), .live(let events): transcript.push(events)
    case .events(let events): for event in events { transcript.push(event) }
    default: handle(event)
    }
  }

  private func handle(_ event: SessionEvent) {
    switch event {
    case .logged(let events), .live(let events):
      transcript.push(events)
    case .events(let events):
      for event in events { transcript.push(event) }
    case .driving(let driving):
      self.driving = driving
      if !driving { waiting = nil }
    case .turn(let turn):
      let report = TurnReport(turn)
      requests.removeAll { $0 == report.requestID }
      waiting = nil
    case .waiting(let request, let retry):
      waiting = "Waiting to retry \(request.prefix(8)) in \(Int(retry / 1000)) s"
    case .resumed:
      break
    case .failure(let message):
      error = message
    }
  }

  private func applied(_ event: LiveEvent) {
    if event.type == "turn", let request = event.requestID {
      requests.removeAll { $0 == request }
    }
  }
}
