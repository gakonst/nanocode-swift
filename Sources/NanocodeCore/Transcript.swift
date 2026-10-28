import Foundation

public struct Entry: Sendable, Hashable, Identifiable {
  public var id: String
  public var kind: EntryKind
  public var text: String
  public var tool: ToolCell?
  public var startedAt: Double?
  public var endedAt: Double?
  public var steer = false
  public var images: [String] = []
  public var requestID: String?

  public init(id: String, kind: EntryKind, text: String, tool: ToolCell? = nil, startedAt: Double? = nil,
              endedAt: Double? = nil, steer: Bool = false, images: [String] = [], requestID: String? = nil) {
    self.id = id
    self.kind = kind
    self.text = text
    self.tool = tool
    self.startedAt = startedAt
    self.endedAt = endedAt
    self.steer = steer
    self.images = images
    self.requestID = requestID
  }
}

@MainActor
public final class Transcript {
  public var add: (Entry) -> Void = { _ in }
  public var live: ([Entry]) -> Void = { _ in }
  public var apply: (LiveEvent) -> Void = { _ in }
  public var ended: (ToolStatus) -> Void = { _ in }
  public var hidesPrompt: (String) -> Bool = { _ in false }
  public var revealMs: Double
  public var frameMs: Double = 16
  public var limit = 160

  private struct Stream {
    var kind: EntryKind?
    var item: String?
    var posted = 0
    var shown = 0
    var text = ""
    var started: Double?
    var ended: Double?
  }

  private enum Queued {
    case event(LiveEvent)
    case run(() -> Void)
    case aside(Entry)
  }

  private static let toolEvents: Set<String> = ["tool_input", "tool_start", "tool_output", "tool_end"]
  private static let outputLimit = 65_536

  private var stream = Stream()
  private var streaming: Entry?
  private var queue: [Queued] = []
  private var frame: Task<Void, Never>?
  private var clock: Double = 0
  private var running: [ToolNode] = []
  private var calls: [String: ToolNode] = [:]
  private var inputs: [String: ToolInput] = [:]
  private var links: [String: (cell: String, latest: String)] = [:]
  private var held: [Entry] = []
  private var orphans: [String: [ToolNode]] = [:]
  private var finished = Set<String>()
  private var seen: [UInt64: String] = [:]
  private var received: [String: Int] = [:]
  private var counter = 0

  public init(revealMs: Double = 30) {
    self.revealMs = revealMs
  }

  private func nextID() -> String {
    counter += 1
    return "entry-\(counter)"
  }

  private static func fingerprint(_ event: LiveEvent) -> String {
    let size = event["delta"]?.string.map { "\($0.utf16.count)" } ?? event["text"]?.string.map { "\($0.utf16.count)" } ?? ""
    return [event.type, event.callID.isEmpty ? (event.item ?? "") : event.callID, size].joined(separator: "|")
  }

  public func push(_ event: LiveEvent) {
    var event = event
    if let seq = event.seq {
      let key = Self.fingerprint(event)
      if seen[seq] == key { return }
      seen[seq] = key
      if seen.count > 4096, let oldest = seen.keys.min() { seen[oldest] = nil }
    }
    if event.type == "text", let item = event.item {
      let delta = Array(event.delta.utf16)
      let have = received[item] ?? (stream.kind == .assistant && stream.item == item ? stream.text.utf16.count : 0)
      let offset = event["offset"]?.int ?? have
      received[item] = max(have, offset + delta.count)
      if offset + delta.count <= have { return }
      let kept = offset >= have ? delta : Array(delta[(have - offset)...])
      event["delta"] = .string(String(decoding: kept, as: UTF16.self))
    }
    enqueue(.event(event))
  }

  public func push(_ logged: [LoggedEvent]) {
    for event in logged {
      if let live = LiveEvent.from(event) { push(live) }
    }
  }

  public func run(_ callback: @escaping () -> Void) { enqueue(.run(callback)) }

  public func aside(_ entry: Entry) { enqueue(.aside(entry)) }

  public func reset() {
    frame?.cancel()
    frame = nil
    queue = []
    stream = Stream()
    streaming = nil
    running = []
    calls = [:]
    inputs = [:]
    links = [:]
    orphans = [:]
    finished = []
    seen = [:]
    received = [:]
    held = []
    clock = 0
    live([])
  }

  public var pending: Bool { !queue.isEmpty }

  public func close() { enqueue(.run { [weak self] in self?.end(.cancelled) }) }

  private func end(_ status: ToolStatus) {
    settle(all: status)
    orphans = [:]
    links = [:]
    ended(status)
  }

  private func enqueue(_ item: Queued) {
    queue.append(item)
    schedule(after: 0)
  }

  private func schedule(after milliseconds: Double) {
    guard frame == nil else { return }
    frame = Task { @MainActor [weak self] in
      if milliseconds > 0 { try? await Task.sleep(nanoseconds: UInt64(milliseconds * 1_000_000)) } else { await Task.yield() }
      guard !Task.isCancelled else { return }
      self?.step()
    }
  }

  private func timing(_ entry: inout Entry) {
    entry.startedAt = stream.started
    entry.endedAt = stream.ended
  }

  private func post(_ kind: EntryKind, _ text: String) {
    var entry = Entry(id: nextID(), kind: kind, text: text)
    timing(&entry)
    add(entry)
  }

  private func release() {
    let entries = held
    held = []
    for entry in entries { add(entry) }
  }

  private func flush() {
    if stream.kind == .assistant {
      for chunk in Paragraphs.split(stream.text, from: stream.posted, final: true).chunks { post(.assistant, chunk) }
    } else if stream.kind == .reasoning {
      let text = stream.text.trimmingCharacters(in: .whitespacesAndNewlines)
      if !text.isEmpty { post(.reasoning, text) }
    }
    stream = Stream()
    streaming = nil
    release()
  }

  private func visible() -> String {
    let utf8 = Array(stream.text.utf8)
    return String(decoding: utf8[..<min(stream.shown, utf8.count)], as: UTF8.self)
  }

  private func reveal() {
    let text = visible()
    if stream.kind == .assistant {
      let (chunks, next) = Paragraphs.split(text, from: stream.posted)
      stream.posted = next
      for chunk in chunks { post(.assistant, chunk) }
      if !chunks.isEmpty { release() }
    }
    let bytes = Array(text.utf8)
    let rest = String(decoding: bytes[min(stream.posted, bytes.count)...], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    if !rest.isEmpty, let kind = stream.kind {
      streaming = Entry(id: "live-stream", kind: kind, text: rest, startedAt: stream.started)
    } else {
      streaming = nil
    }
  }

  private func emit() {
    var entries = running.map { cell in
      Entry(id: "live-\(cell.callID)", kind: .tool, text: cell.snapshot.summary, tool: cell.snapshot, startedAt: cell.startedAt)
    }
    if let streaming { entries.append(streaming) }
    live(entries)
  }

  private func resolve(_ id: String) -> String { links[id]?.latest ?? id }

  private func tool(_ event: LiveEvent) {
    let id = resolve(event.callID)
    let parentID = event["parent"]?.string.map(resolve)
    var cell = calls[id]
    if cell == nil {
      if event.type == "tool_output" { return }
      if finished.contains(id) { return }
      if let parentID, let original = event["parent"]?.string, finished.contains(parentID), calls[parentID] == nil, links[original] == nil { return }
      let created = ToolNode(callID: id, tool: event["name"]?.string ?? "tool", startedAt: event.at)
      calls[id] = created
      if let parentID, let parent = calls[parentID] { parent.children.append(created) } else { running.append(created) }
      cell = created
    }
    guard let cell else { return }
    switch event.type {
    case "tool_input":
      let input = inputs[id] ?? ToolInput()
      inputs[id] = input
      let delta = Array(event.delta.utf16)
      let have = input.raw.utf16.count
      let offset = event["offset"]?.int ?? have
      if offset + delta.count > have {
        input.push(String(decoding: offset >= have ? delta : Array(delta[(have - offset)...]), as: UTF16.self))
      }
      Describe.apply(cell, input.arguments())
    case "tool_start":
      inputs[id] = nil
      Describe.apply(cell, event["args"])
      if cell.tool == "wait" {
        let args = Describe.decoded(event["args"])
        let target = args["cell_id"]?.string ?? args["cell_id"]?.number.map { String(Int($0)) }
        for (origin, link) in links where link.cell == target {
          links[origin] = (link.cell, id)
          if let carried = orphans.removeValue(forKey: origin) {
            cell.children.append(contentsOf: carried.filter { orphan in !cell.children.contains { $0 === orphan } })
          }
        }
      }
    case "tool_output":
      if cell.status == .running, let text = event["text"]?.string {
        let output = cell.output.isEmpty ? Describe.plain(text) : cell.output + "\n" + Describe.plain(text)
        cell.output = output.count > Self.outputLimit ? String(output.suffix(Self.outputLimit)) : output
      }
    default:
      inputs[id] = nil
      Describe.finish(cell, event)
      let origin = event.callID
      if cell.status == .yielded, cell.title.hasPrefix("cell ") {
        let yielded = String(cell.title.dropFirst(5).split(separator: " ").first ?? "")
        links[origin] = (yielded, origin)
      } else {
        for (key, link) in links where link.latest == id && key != id { links[key] = nil }
      }
    }
    settle()
  }

  private func settle(all: ToolStatus? = nil) {
    while let first = running.first, all != nil || first.status != .running {
      running.removeFirst()
      first.finish(all ?? first.status)
      var posted = first.snapshot
      if first.status == .yielded {
        let carried = first.children.filter { $0.status == .running }
        if !carried.isEmpty { orphans[first.callID] = carried }
        posted.children = posted.children.map { child in
          var child = child
          if child.status == .running { child.status = .yielded }
          return child
        }
      }
      forget(first)
      var entry = Entry(id: nextID(), kind: .tool, text: posted.summary, tool: posted, startedAt: first.startedAt)
      if let duration = first.durationMs { entry.endedAt = first.startedAt + duration }
      add(entry)
    }
  }

  private func forget(_ cell: ToolNode) {
    if cell.status == .running, orphans.values.contains(where: { $0.contains { $0 === cell } }) { return }
    calls[cell.callID] = nil
    inputs[cell.callID] = nil
    finished.insert(cell.callID)
    for child in cell.children { forget(child) }
  }

  private static func describe(_ event: LiveEvent, limit: Int) -> (EntryKind, String)? {
    switch event.type {
    case "retrying":
      let error = event["error"]?.string ?? event["error"]?.text() ?? event["message"]?.string ?? ""
      return (.tool, "Retrying: \(error)")
    case "turn":
      let status = event["status"]?.string ?? ""
      if status == "completed" { return nil }
      if status == "cancelled" { return (.error, "The turn was cancelled.") }
      return (.error, "The turn \(status): \(event["error"]?.string ?? event["error"]?.text() ?? "")")
    case "error":
      return (.error, event["message"]?.string ?? event.fields.description)
    default:
      return nil
    }
  }

  private func step() {
    frame = nil
    let now = ProcessInfo.processInfo.systemUptime * 1000
    let elapsed = clock > 0 ? now - clock : 0
    clock = now
    let instant = revealMs <= 0
    var revealed = false
    while true {
      let next = queue.first
      var nextEvent: LiveEvent?
      if case .event(let event) = next { nextEvent = event }
      let kind: EntryKind? = nextEvent?.type == "text" ? .assistant : nextEvent?.type == "reasoning" ? .reasoning : nil
      let item = nextEvent?.item
      if let event = nextEvent, let kind, stream.kind == nil || (stream.kind == kind && stream.item == item) {
        queue.removeFirst()
        stream.kind = kind
        stream.item = item
        stream.text += event.delta
        if stream.started == nil { stream.started = event.at }
        stream.ended = event.at
        continue
      }
      if case .aside(let entry) = next, stream.kind == .assistant,
         !String(decoding: Array(stream.text.utf8)[min(stream.posted, stream.text.utf8.count)...], as: UTF8.self)
           .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        queue.removeFirst()
        held.append(entry)
        continue
      }
      if let event = nextEvent, kind == nil, !Self.toolEvents.contains(event.type), event.type != "user", event.type != "turn",
         Self.describe(event, limit: limit) == nil {
        queue.removeFirst()
        apply(event)
        continue
      }
      let total = stream.text.utf8.count
      if stream.shown < total {
        if revealed { break }
        revealed = true
        let backlog = total - stream.shown
        stream.shown += instant ? backlog : max(1, Int((Double(backlog) * (1 - exp(-elapsed / revealMs))).rounded(.up)))
        while stream.shown < total, !Self.boundary(stream.text, stream.shown) { stream.shown += 1 }
        reveal()
        continue
      }
      guard let next else { break }
      queue.removeFirst()
      flush()
      switch next {
      case .run(let callback):
        callback()
        continue
      case .aside(let entry):
        add(entry)
        continue
      case .event(let event):
        if let kind {
          stream = Stream(kind: kind, item: item, posted: 0, shown: 0, text: event.delta, started: event.at, ended: event.at)
          continue
        }
        if Self.toolEvents.contains(event.type) {
          tool(event)
          continue
        }
        if event.type == "user" {
          let request = event.requestID ?? ""
          let kind = event["kind"]?.string ?? ""
          if !request.hasPrefix("subagent-completion:"), kind == "prompt" || kind == "steer" || kind.isEmpty, !hidesPrompt(request) {
            add(Entry(id: nextID(), kind: .user, text: event["text"]?.string ?? "", startedAt: event.at,
                      steer: kind == "steer", images: event["images"]?.array?.compactMap(\.string) ?? [], requestID: request))
          }
          apply(event)
          continue
        }
        if event.type == "turn" { end(event["status"]?.string == "completed" ? .completed : .cancelled) }
        if let (kind, text) = Self.describe(event, limit: limit) {
          add(Entry(id: nextID(), kind: kind, text: text, requestID: event.requestID))
        }
        apply(event)
      }
    }
    emit()
    if !queue.isEmpty || stream.shown < stream.text.utf8.count {
      schedule(after: frameMs)
    } else {
      clock = 0
    }
  }

  private static func boundary(_ text: String, _ offset: Int) -> Bool {
    let utf8 = text.utf8
    guard offset < utf8.count else { return true }
    let byte = utf8[utf8.index(utf8.startIndex, offsetBy: offset)]
    return byte & 0xC0 != 0x80
  }
}

public struct Turn: Sendable, Hashable, Identifiable {
  public struct Block: Sendable, Hashable, Identifiable {
    public var entry: Entry
    public var live: Bool
    public var id: String { entry.id }
  }

  public var id: String
  public var prompt: Entry?
  public var blocks: [Block]
  public var live: Bool
  public var startedAt: Double?
  public var endedAt: Double?

  public static func group(_ entries: [Entry], live: [Entry] = [], pending: Bool = false) -> [Turn] {
    var result: [Turn] = []
    let all = entries.map { ($0, false) } + live.map { ($0, true) }
    for (entry, isLive) in all {
      if entry.kind == .user || result.isEmpty {
        result.append(Turn(id: entry.id, prompt: entry.kind == .user ? entry : nil, blocks: [], live: false, startedAt: entry.startedAt))
      }
      var turn = result.removeLast()
      turn.live = turn.live || isLive
      if let ended = entry.endedAt ?? entry.startedAt, !isLive { turn.endedAt = ended }
      if entry.kind != .user {
        if var last = turn.blocks.last, last.entry.kind == entry.kind, entry.kind == .assistant || entry.kind == .reasoning {
          last.entry.text += "\n\n" + entry.text
          last.live = last.live || isLive
          last.entry.endedAt = isLive ? nil : entry.endedAt
          turn.blocks[turn.blocks.count - 1] = last
        } else {
          turn.blocks.append(Block(entry: entry, live: isLive))
        }
      }
      result.append(turn)
    }
    if pending, !result.isEmpty { result[result.count - 1].live = true }
    for index in result.indices where result[index].live { result[index].endedAt = nil }
    return result
  }
}

public enum ActivityPhase: String, Sendable {
  case idle, waiting, thinking, writing, running
}

public struct Activity: Sendable, Hashable {
  public var busy: Bool
  public var phase: ActivityPhase
  public var tool: String?

  public static func of(_ live: [Entry], pending: Bool) -> Activity {
    guard pending else { return Activity(busy: false, phase: .idle) }
    let last = live.last
    if last?.kind == .reasoning { return Activity(busy: true, phase: .thinking) }
    if last?.kind == .assistant { return Activity(busy: true, phase: .writing) }
    if let tool = last?.tool, tool.status == .running { return Activity(busy: true, phase: .running, tool: tool.name) }
    return Activity(busy: true, phase: .waiting)
  }
}
