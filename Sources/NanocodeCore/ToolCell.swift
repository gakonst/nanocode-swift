import Foundation

public enum EntryKind: String, Sendable, Hashable {
  case assistant, error, reasoning, tool, user
}

public enum ToolStatus: String, Sendable, Hashable {
  case running, completed, failed, cancelled, yielded
}

public enum ToolBody: String, Sendable, Hashable {
  case text, code, diff
}

public struct ToolCell: Sendable, Hashable, Identifiable {
  public var callID: String
  public var tool: String
  public var name: String
  public var title: String
  public var input: String
  public var body: ToolBody
  public var language: String
  public var output: String
  public var outputLanguage: String
  public var status: ToolStatus
  public var startedAt: Double
  public var durationMs: Double?
  public var exitCode: Int?
  public var images: [String]
  public var details: [String]
  public var children: [ToolCell]
  public var id: String { callID }

  public var summary: String {
    let head = [name, title].filter { !$0.isEmpty }.joined(separator: " ")
    var meta: [String] = []
    if status != .completed { meta.append(status.rawValue) }
    if let durationMs { meta.append(Format.duration(durationMs)) }
    meta.append(contentsOf: details)
    let tail = meta.filter { !$0.isEmpty }.joined(separator: " · ")
    return tail.isEmpty ? head : "\(head) · \(tail)"
  }
}

public enum Format {
  public static func duration(_ milliseconds: Double) -> String {
    if milliseconds < 1000 { return "\(max(0, Int(milliseconds.rounded()))) ms" }
    if milliseconds < 60_000 { return String(format: milliseconds < 10_000 ? "%.1f s" : "%.0f s", milliseconds / 1000) }
    let minutes = Int(milliseconds / 60_000)
    return "\(minutes)m \(Int(((milliseconds - Double(minutes) * 60_000) / 1000).rounded()))s"
  }

  public static func bytes(_ size: Int) -> String {
    if size < 1024 { return "\(size) B" }
    if size < 1024 * 1024 { return "\(Int((Double(size) / 1024).rounded())) KB" }
    return String(format: "%.1f MB", Double(size) / 1024 / 1024)
  }

  public static func clip(_ text: String, _ limit: Int) -> String {
    text.count > limit ? "\(text.prefix(limit))…" : text
  }
}

final class ToolNode {
  var callID: String
  var tool: String
  var name: String
  var title = ""
  var input = ""
  var body: ToolBody = .text
  var language = ""
  var output = ""
  var outputLanguage = ""
  var status: ToolStatus = .running
  var startedAt: Double
  var durationMs: Double?
  var exitCode: Int?
  var images: [String] = []
  var details: [String] = []
  var children: [ToolNode] = []

  init(callID: String, tool: String, startedAt: Double) {
    self.callID = callID
    self.tool = tool
    self.name = tool
    self.startedAt = startedAt
  }

  init(_ cell: ToolCell) {
    callID = cell.callID
    tool = cell.tool
    name = cell.name
    title = cell.title
    input = cell.input
    body = cell.body
    language = cell.language
    output = cell.output
    outputLanguage = cell.outputLanguage
    status = cell.status
    startedAt = cell.startedAt
    durationMs = cell.durationMs
    exitCode = cell.exitCode
    images = cell.images
    details = cell.details
    children = cell.children.map(ToolNode.init)
  }

  var snapshot: ToolCell {
    ToolCell(callID: callID, tool: tool, name: name, title: title, input: input, body: body, language: language,
             output: output, outputLanguage: outputLanguage, status: status, startedAt: startedAt,
             durationMs: durationMs, exitCode: exitCode, images: images, details: details,
             children: children.map(\.snapshot))
  }

  func finish(_ status: ToolStatus) {
    if self.status == .running {
      self.status = status
      if durationMs == nil { durationMs = Date().timeIntervalSince1970 * 1000 - startedAt }
    }
    for child in children {
      child.finish(status == .yielded ? .running : self.status == .yielded ? .completed : self.status)
    }
  }
}

enum Describe {
  static let codeTools: Set<String> = ["exec", "code_mode", "js"]

  static func decoded(_ value: JSON?) -> JSON {
    guard let value, !value.isNull else { return [:] }
    guard let text = value.string else { return value }
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.hasPrefix("{"), let parsed = JSON.parse(trimmed) else { return value }
    return parsed
  }

  static func firstLine(_ text: String) -> (first: String, more: Bool) {
    let lines = text.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n")
    return (lines.first ?? "", lines.count > 1)
  }

  static func patchFiles(_ patch: String) -> [String] {
    patch.components(separatedBy: "\n").compactMap { line in
      for prefix in ["*** Add File: ", "*** Update File: ", "*** Delete File: ", "*** Move to: "] where line.hasPrefix(prefix) {
        return String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
      }
      return nil
    }
  }

  static func linesPatch(_ header: String, _ path: String, _ removed: String, _ added: String) -> String {
    var lines = ["*** \(header): \(path)"]
    if header == "Update File" { lines.append("@@") }
    if !removed.isEmpty { lines += removed.components(separatedBy: "\n").map { "-\($0)" } }
    if !added.isEmpty { lines += added.components(separatedBy: "\n").map { "+\($0)" } }
    return lines.joined(separator: "\n")
  }

  static func stripPragma(_ source: String) -> String {
    guard let range = source.range(of: #"^\s*// @exec:[^\n]*(?:\n|$)"#, options: .regularExpression) else { return source }
    return String(source[range.upperBound...])
  }

  static func apply(_ cell: ToolNode, _ args: JSON?) {
    let value = decoded(args)
    let object = value.object ?? [:]
    func field(_ key: String) -> String? { object[key]?.string }
    func number(_ key: String) -> String? {
      if let number = object[key]?.number { return number.rounded() == number ? String(Int(number)) : String(number) }
      return object[key]?.string
    }
    func command(_ text: String) {
      let (first, more) = firstLine(text)
      cell.name = "run"
      cell.title = first
      cell.input = more ? text : ""
      cell.body = more ? .code : .text
      cell.language = more ? "bash" : ""
    }
    cell.name = cell.tool
    cell.title = ""
    cell.input = ""
    cell.body = .text
    cell.language = ""
    cell.details = []
    if codeTools.contains(cell.tool) {
      var source = value.string ?? field("code") ?? field("source") ?? field("input") ?? (object.isEmpty ? "" : value.text())
      source = stripPragma(source)
      cell.name = "code"
      cell.input = source
      cell.body = .code
      cell.language = "js"
      return
    }
    switch cell.tool {
    case "wait":
      cell.name = "code"
      cell.title = "cell \(number("cell_id") ?? "")\(object["terminate"]?.bool == true ? " · terminate" : " · wait")"
    case "exec_command":
      command(field("cmd") ?? "")
      if object["tty"]?.bool == true { cell.details.append("tty") }
    case "Bash", "bash", "shell", "run_command":
      command(field("command") ?? field("cmd") ?? field("script") ?? value.string ?? "")
      if object["run_in_background"]?.bool == true { cell.details.append("background") }
    case "write_stdin":
      let chars = field("chars") ?? ""
      cell.name = chars.isEmpty ? "poll" : "stdin"
      cell.title = "session \(number("session_id") ?? "")"
      cell.input = chars
    case "apply_patch":
      let patch = value.string ?? field("input") ?? field("patch") ?? ""
      cell.name = "patch"
      cell.input = patch
      cell.title = patchFiles(patch).joined(separator: ", ")
      cell.body = .diff
    case "Edit", "edit_file":
      let path = field("file_path") ?? field("path") ?? ""
      cell.name = "edit"
      cell.title = path
      cell.input = linesPatch("Update File", path, field("old_string") ?? "", field("new_string") ?? "")
      cell.body = .diff
      if object["replace_all"]?.bool == true { cell.details.append("all occurrences") }
    case "Write", "write_file":
      let path = field("file_path") ?? field("path") ?? ""
      cell.name = "write"
      cell.title = path
      cell.input = linesPatch("Add File", path, "", field("content") ?? "")
      cell.body = .diff
    case "Read", "read_file":
      cell.name = "read"
      cell.title = field("file_path") ?? field("path") ?? ""
      let range = [number("offset").map { "from line \($0)" }, number("limit").map { "\($0) lines" }].compactMap { $0 }
      if !range.isEmpty { cell.details.append(range.joined(separator: ", ")) }
    case "Glob", "Grep":
      cell.name = cell.tool.lowercased()
      cell.title = [field("pattern"), field("path").map { "in \($0)" }].compactMap { $0 }.joined(separator: " ")
    case "WebSearch", "web_search", "web__run":
      cell.name = "search"
      cell.title = field("query") ?? ""
    case "WebFetch", "fetch":
      cell.name = "fetch"
      cell.title = field("url") ?? ""
    case "spawn_agent":
      cell.name = "spawn agent"
      cell.title = field("role") ?? ""
      cell.input = field("task") ?? ""
    default:
      let strings = object.filter { $0.value.string != nil }.sorted { $0.key < $1.key }.map { ($0.key, $0.value.string!) }
      let short = strings.first { $0.1.count <= 80 && !$0.1.contains("\n") }
      if let text = value.string {
        cell.input = text
      } else if object.count == 1, strings.count == 1 {
        if let short { cell.title = short.1 } else { cell.input = strings[0].1 }
      } else if !object.isEmpty {
        if let short { cell.title = short.1 }
        cell.input = value.text(pretty: true)
        cell.body = .code
        cell.language = "json"
      }
    }
  }

  static func textOf(_ result: JSON?) -> String {
    guard let result else { return "" }
    if let text = result.string { return text }
    if let array = result.array {
      return array.map(textOf).reduce("") { text, part in
        part.isEmpty ? text : text.isEmpty || text.hasSuffix("\n") ? text + part : "\(text)\n\(part)"
      }
    }
    if let object = result.object {
      if let text = object["text"]?.string { return text }
      for key in ["content_blocks", "content", "Content"] {
        if let nested = object[key], nested.array != nil { return textOf(nested) }
      }
      if let text = object["Text"]?.string { return text }
    }
    return ""
  }

  static func isImage(_ url: String) -> Bool {
    let trimmed = url.trimmingCharacters(in: .whitespaces).lowercased()
    if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") { return true }
    for kind in ["png", "jpeg", "jpg", "gif", "webp", "avif", "bmp"] where trimmed.hasPrefix("data:image/\(kind)") { return true }
    return false
  }

  static func images(_ result: JSON?, _ found: inout [String]) {
    guard let result else { return }
    if let array = result.array {
      for item in array { images(item, &found) }
      return
    }
    guard let object = result.object else { return }
    let type = object["type"]?.string
    var url: String?
    if type == "input_image" || type == "image_url" {
      url = object["image_url"]?.string ?? object["image_url"]?["url"]?.string
    } else if type == "image", let data = object["data"]?.string {
      url = "data:\(object["mimeType"]?.string ?? object["mime_type"]?.string ?? "image/png");base64,\(data)"
    } else if type == "image", let source = object["source"], source["type"]?.string == "base64", let data = source["data"]?.string {
      url = "data:\(source["media_type"]?.string ?? "image/png");base64,\(data)"
    } else if type == "image", let source = object["source"], source["type"]?.string == "url" {
      url = source["url"]?.string
    }
    if let url = url?.trimmingCharacters(in: .whitespaces), isImage(url), !found.contains(url) { found.append(url) }
    for key in ["content", "content_blocks", "Content", "output"] {
      if let nested = object[key], nested.array != nil { images(nested, &found) }
    }
  }

  static func plain(_ text: String) -> String {
    guard text.contains("\u{1b}") else { return text }
    return text.replacingOccurrences(of: "\u{1b}(?:\\[[0-?]*[ -/]*[@-~]|\\][^\u{07}\u{1b}]*(?:\u{07}|\u{1b}\\\\)|[@-Z\\\\^_])", with: "", options: .regularExpression)
  }

  static func humanize(_ text: String) -> String {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.hasPrefix("{"), let value = JSON.parse(trimmed), let object = value.object,
          object["stdout"] != nil || object["stderr"] != nil else { return text }
    var parts = ["stdout", "stderr", "output"].compactMap { object[$0]?.string }.filter { !$0.isEmpty }
      .map { $0.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression) }
    if let code = object["exit_code"]?.int, code != 0 { parts.append("exit code \(code)") }
    return parts.joined(separator: "\n")
  }

  static func codeStatus(_ header: String) -> ToolStatus? {
    if header == "Script completed" { return .completed }
    if header == "Script failed" { return .failed }
    if header == "Script terminated" { return .cancelled }
    if header.hasPrefix("Script running with cell ID ") { return .yielded }
    return nil
  }

  static func stripCodeHeader(_ text: String) -> String {
    var lines = text.components(separatedBy: "\n")
    guard lines.first?.hasPrefix("Script ") == true else { return text }
    var index = 1
    while index < lines.count, ["Wall time", "Original token count", "Chunk ID"].contains(where: { lines[index].hasPrefix($0) }) { index += 1 }
    if index < lines.count, lines[index] == "Output:" { index += 1 }
    lines.removeFirst(min(index, lines.count))
    return lines.joined(separator: "\n")
  }

  static func trimEnd(_ text: String) -> String {
    var text = text
    while let last = text.last, last.isWhitespace { text.removeLast() }
    return text
  }

  static func finish(_ cell: ToolNode, _ event: LiveEvent) {
    let raw = textOf(event["result"])
    let structured = event["structured"]?.object ?? [:]
    var status: ToolStatus = event["status"]?.string == "completed" ? .completed : event["status"]?.string == "cancelled" ? .cancelled : .failed
    if let nanos = event["duration_ns"]?.number {
      if nanos > 0 { cell.durationMs = nanos / 1e6 }
    } else if cell.status == .running {
      cell.durationMs = event.at - cell.startedAt
    }
    if codeTools.contains(cell.tool) || cell.tool == "wait" {
      let header = raw.components(separatedBy: "\n").first ?? ""
      status = codeStatus(header) ?? status
      if cell.tool != "wait", header.hasPrefix("Script running with cell ID ") {
        let id = header.dropFirst("Script running with cell ID ".count).split(separator: " ").first.map(String.init) ?? ""
        cell.title = "cell \(id)"
      }
      let output = trimEnd(humanize(stripCodeHeader(raw)))
      cell.output = status == .cancelled && !cell.output.isEmpty && !output.contains(cell.output) ? trimEnd("\(cell.output)\n\(output)") : output
    } else if cell.tool == "exec_command" || cell.tool == "write_stdin" {
      var header = ""
      var output = raw
      if let range = raw.range(of: "Output:\n") {
        header = String(raw[..<range.lowerBound])
        output = String(raw[range.upperBound...])
      }
      cell.output = trimEnd(structured["output"]?.string ?? output)
      if let code = structured["exit_code"]?.int {
        cell.exitCode = code
      } else if let range = header.range(of: #"Process exited with code (-?\d+)"#, options: .regularExpression) {
        cell.exitCode = Int(header[range].split(separator: " ").last ?? "")
      }
      if let range = header.range(of: #"Process running with session ID (\d+)"#, options: .regularExpression),
         let session = header[range].split(separator: " ").last {
        cell.details.append("session \(session) running")
      }
    } else {
      cell.output = trimEnd(structured["output"]?.string ?? humanize(raw))
      let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
      if trimmed.hasPrefix("{"), let parsed = JSON.parse(trimmed), let code = parsed["exit_code"]?.int { cell.exitCode = code }
    }
    var found: [String] = []
    images(event["result"], &found)
    images(event["structured"], &found)
    if !found.isEmpty { cell.images = found }
    let output = cell.output.trimmingCharacters(in: .whitespacesAndNewlines)
    if !cell.output.isEmpty, output.hasPrefix("{") || output.hasPrefix("["), JSON.parse(output) != nil {
      cell.outputLanguage = "json"
    } else if cell.output.hasPrefix("diff --git") || cell.output.hasPrefix("--- ") {
      cell.outputLanguage = "diff"
    } else {
      cell.outputLanguage = ""
    }
    if status == .completed, let code = cell.exitCode, code != 0 { cell.details.append("exit \(code)") }
    cell.output = plain(cell.output)
    cell.status = status
  }
}
