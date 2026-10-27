import Foundation
import Observation

@MainActor
@Observable
public final class Chat {
  public private(set) var entries: [Entry] = []
  public private(set) var live: [Entry] = []
  public private(set) var driving = false
  public private(set) var error: String?
  public private(set) var session: Session?
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

  public var pending: Bool { driving || !requests.isEmpty }

  public var turns: [Turn] { Turn.group(entries, live: live, pending: pending) }

  public var activity: Activity { Activity.of(live, pending: pending) }

  public func attach(_ session: Session, history: Bool = true) async {
    detach()
    self.session = session
    entries = []
    live = []
    error = nil
    transcript.reset()
    let events = session.events
    listener = Task { @MainActor [weak self] in
      for await event in events {
        self?.handle(event)
      }
    }
    guard history else { return }
    loading = true
    defer { loading = false }
    do {
      let events = try await session.history()
      transcript.revealMs = 0
      transcript.push(events)
      transcript.run { [weak self] in self.map { $0.transcript.revealMs = $0.revealMs } }
      let pending = try await session.pending()
      requests = pending.map(\.requestID)
    } catch {
      self.error = error.localizedDescription
    }
  }

  public func detach() {
    listener?.cancel()
    listener = nil
    session = nil
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

  public func send(_ text: String, images: [String] = [], files: [URL] = []) async {
    guard let session else {
      error = "No session is open."
      return
    }
    var text = text
    if !files.isEmpty {
      do {
        let lines = try attach(files)
        text = text.isEmpty ? lines.joined(separator: "\n") : text + "\n\n" + lines.joined(separator: "\n")
      } catch {
        self.error = error.localizedDescription
        return
      }
    }
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty || !images.isEmpty else { return }
    error = nil
    let request = Identifier.uuidv7()
    local.insert(request)
    let steering = pending
    transcript.aside(Entry(id: "user-\(request)", kind: .user, text: trimmed, startedAt: Date().timeIntervalSince1970 * 1000,
                           steer: steering, images: images, requestID: request))
    do {
      if steering, try await session.steer(trimmed, images: images, requestID: request) {
        return
      }
      requests.append(request)
      let submitted = try await session.submit(trimmed, images: images, requestID: request)
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
    guard let session, let request = requests.first else { return }
    do {
      try await session.cancel(request)
    } catch {
      self.error = error.localizedDescription
    }
  }

  private func handle(_ event: SessionEvent) {
    switch event {
    case .logged(let events), .live(let events):
      transcript.push(events)
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
