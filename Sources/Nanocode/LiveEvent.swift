import Foundation

public struct LiveEvent: Sendable, Hashable {
  public let type: String
  public var fields: [String: JSON]

  public init(type: String, fields: [String: JSON] = [:]) {
    self.type = type
    self.fields = fields
  }

  public subscript(key: String) -> JSON? {
    get { fields[key] }
    set { fields[key] = newValue }
  }

  public var seq: UInt64? { fields["seq"]?.uint64 }
  public var at: Double { fields["at"]?.number ?? Date().timeIntervalSince1970 * 1000 }
  public var delta: String { fields["delta"]?.string ?? "" }
  public var callID: String { fields["call_id"]?.string ?? fields["call_id"]?.number.map { String(Int($0)) } ?? "" }
  public var item: String? {
    guard let item = fields["item"], !item.isNull else { return nil }
    return item.string ?? item.text()
  }
  public var requestID: String? { fields["request_id"]?.string }

  public static func from(_ logged: LoggedEvent) -> LiveEvent? {
    let body = logged.event
    var base: [String: JSON] = [:]
    if logged.seq > 0 { base["seq"] = .number(Double(logged.seq)) }
    if let request = logged.requestID { base["request_id"] = .string(request) }
    base["at"] = .number(logged.createdAt)
    func event(_ type: String, _ fields: [String: JSON]) -> LiveEvent {
      LiveEvent(type: type, fields: base.merging(fields) { $1 })
    }
    if body["source"]?.string == "agent", let agent = body["event"], let type = agent["type"]?.string {
      let payload = agent["payload"] ?? [:]
      func offset() -> [String: JSON] { payload["offset"]?.number.map { ["offset": .number($0)] } ?? [:] }
      switch type {
      case "assistant.delta":
        return event("text", ["delta": payload["text"] ?? "", "item": payload["item_id"] ?? .null].merging(offset()) { $1 })
      case "assistant.message":
        guard let text = payload["text"]?.string, !text.isEmpty else { return nil }
        return event("text", ["delta": .string(text), "item": payload["item_id"] ?? .null, "offset": 0])
      case "reasoning.summary.delta":
        let index = payload["model_call_index"]?.int.map(String.init) ?? payload["model_call_index"]?.text() ?? ""
        return event("reasoning", ["delta": payload["text"] ?? "", "item": .string("reasoning:\(index)")])
      case "tool.input.delta":
        return event("tool_input", ["name": payload["tool"] ?? "", "delta": payload["text"] ?? "",
                                     "call_id": payload["call_id"] ?? ""].merging(offset()) { $1 })
      case "tool.call":
        return event("tool_start", ["name": payload["tool"] ?? "", "args": payload["arguments"] ?? .null,
                                     "call_id": payload["call_id"] ?? "", "parent": parent(payload).json])
      case "tool.notification":
        return event("tool_output", ["call_id": payload["call_id"] ?? "", "text": payload["text"] ?? ""])
      case "tool.result":
        return event("tool_end", ["name": payload["tool"] ?? "", "call_id": payload["call_id"] ?? "",
                                   "parent": parent(payload).json, "status": payload["status"] ?? "",
                                   "result": payload["result"] ?? .null, "structured": payload["structured_result"] ?? .null,
                                   "duration_ns": payload["duration_ns"] ?? .null])
      case "input.accepted":
        return event("user", ["text": .string(promptText(payload["input"])), "kind": payload["kind"] ?? "",
                               "images": .array(promptImages(payload["input"]).map(JSON.string))])
      default:
        return nil
      }
    }
    if body["source"] != nil, body["source"]?.isNull == false { return nil }
    switch body["type"]?.string {
    case "result":
      var fields: [String: JSON] = ["status": body["status"] ?? ""]
      if let message = body["ok"]?["message"] { fields["message"] = message }
      if let error = body["error"], !error.isNull { fields["error"] = error }
      return event("turn", fields)
    case "retrying":
      return event("retrying", body.object ?? [:])
    default:
      return nil
    }
  }

  static func parent(_ payload: JSON) -> String? {
    if let parent = payload["parent_call_id"]?.string, !parent.isEmpty { return parent }
    let id = payload["call_id"]?.string ?? ""
    guard let slash = id.lastIndex(of: "/"), slash > id.startIndex else { return nil }
    return String(id[..<slash])
  }

  static func promptText(_ input: JSON?) -> String {
    guard let input else { return "" }
    if let text = input.string { return text }
    if let text = input["text"]?.string { return text }
    if let items = input.array ?? input["content"]?.array ?? input["items"]?.array {
      return items.compactMap { $0["text"]?.string ?? $0.string }.joined(separator: "\n")
    }
    return ""
  }

  static func promptImages(_ input: JSON?) -> [String] {
    guard let items = input?.array ?? input?["content"]?.array ?? input?["items"]?.array else { return [] }
    return items.compactMap { $0["image_url"]?.string }
  }
}

public enum Paragraphs {
  public static func split(_ text: String, from: Int, final: Bool = false) -> (chunks: [String], next: Int) {
    let bytes = Array(text.utf8)
    var chunks: [String] = []
    var start = min(from, bytes.count)
    var fenced = false
    var line = 0
    while line < start {
      if bytes[line...].starts(with: [96, 96, 96]) { fenced.toggle() }
      guard let end = bytes[line..<start].firstIndex(of: 10) else { break }
      line = end + 1
    }
    var index = start
    func trimmed(_ lower: Int, _ upper: Int) -> String {
      String(decoding: bytes[lower..<upper], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    while index < bytes.count {
      guard let newline = bytes[index...].firstIndex(of: 10) else { break }
      if bytes[index...].starts(with: [96, 96, 96]) { fenced.toggle() }
      let after = newline + 1
      if !fenced, after < bytes.count, bytes[after] == 10 {
        let chunk = trimmed(start, newline)
        if !chunk.isEmpty { chunks.append(chunk) }
        start = after + 1
      }
      index = after
    }
    if !final { return (chunks, start) }
    let rest = trimmed(start, bytes.count)
    if !rest.isEmpty { chunks.append(rest) }
    return (chunks, bytes.count)
  }
}
