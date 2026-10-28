import Foundation
import os

public enum MarkdownBlock: Hashable, Sendable {
  case paragraph(String)
  case task(checked: Bool, text: String)
  case heading(Int, String)
  case list(ordered: Bool, start: Int, items: [[MarkdownBlock]])
  case code(language: String, text: String)
  case table(header: [String], rows: [[String]])
  case quote([MarkdownBlock])
  case rule
}

public enum Markdown {
  public static func parse(_ text: String) -> [MarkdownBlock] {
    parse(lines: text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n"))
  }

  struct Parsed: @unchecked Sendable { var cache: [String: [MarkdownBlock]] = [:] }
  static let parsed = OSAllocatedUnfairLock(uncheckedState: Parsed())
  static let cacheLimit = 512

  public static func parse(blocks: [String]) -> [MarkdownBlock] {
    blocks.flatMap { block in
      if let cached = parsed.withLock({ $0.cache[block] }) { return cached }
      let result = parse(block)
      parsed.withLock { state in
        if state.cache.count > cacheLimit { state.cache.removeAll() }
        state.cache[block] = result
      }
      return result
    }
  }

  public static func streaming(_ text: String, live: Bool) -> [MarkdownBlock] {
    parse(blocks: MarkdownStream.blocks(live ? MarkdownStream.complete(text) : text))
  }

  static func parse(lines: [String]) -> [MarkdownBlock] {
    var blocks: [MarkdownBlock] = []
    var paragraph: [String] = []
    var i = 0
    func flush() {
      if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: "\n"))); paragraph = [] }
    }
    while i < lines.count {
      let line = lines[i]
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if trimmed.isEmpty { flush(); i += 1; continue }
      if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
        flush()
        let fence = String(trimmed.prefix(3))
        let language = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
        var code: [String] = []
        i += 1
        while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(fence) { code.append(lines[i]); i += 1 }
        blocks.append(.code(language: language, text: code.joined(separator: "\n")))
        i += 1
        continue
      }
      if let level = heading(trimmed) {
        flush()
        blocks.append(.heading(level, String(trimmed.drop(while: { $0 == "#" })).trimmingCharacters(in: .whitespaces)))
        i += 1; continue
      }
      if trimmed.range(of: #"^([-*_])( ?\1){2,}$"#, options: .regularExpression) != nil {
        flush(); blocks.append(.rule); i += 1; continue
      }
      if trimmed.hasPrefix(">") {
        flush()
        var quoted: [String] = []
        while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(">") {
          quoted.append(String(lines[i].trimmingCharacters(in: .whitespaces).dropFirst()).trimmingCharacters(in: .init(charactersIn: " ")))
          i += 1
        }
        blocks.append(.quote(parse(lines: quoted)))
        continue
      }
      if trimmed.hasPrefix("|"), i + 1 < lines.count, isDelimiterRow(lines[i + 1]) {
        flush()
        let header = cells(trimmed)
        var rows: [[String]] = []
        i += 2
        while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("|") { rows.append(cells(lines[i])); i += 1 }
        blocks.append(.table(header: header, rows: rows))
        continue
      }
      if let marker = listMarker(line) {
        flush()
        var items: [[String]] = []
        let ordered = marker.ordered
        while i < lines.count {
          let current = lines[i]
          if let m = listMarker(current), m.indent < marker.indent + 2, m.ordered == ordered {
            items.append([String(current.dropFirst(m.width))])
          } else if current.trimmingCharacters(in: .whitespaces).isEmpty {
            if i + 1 < lines.count, leadingSpaces(lines[i + 1]) > marker.indent, !items.isEmpty { items[items.count - 1].append(""); i += 1; continue }
            break
          } else if leadingSpaces(current) > marker.indent, !items.isEmpty {
            items[items.count - 1].append(String(current.dropFirst(min(leadingSpaces(current), marker.width))))
          } else if listMarker(current) == nil, !items.isEmpty, !paragraphBreaker(current) {
            items[items.count - 1][items[items.count - 1].count - 1] += "\n" + current.trimmingCharacters(in: .whitespaces)
          } else { break }
          i += 1
        }
        blocks.append(.list(ordered: ordered, start: marker.start, items: items.map { task(parse(lines: $0)) }))
        continue
      }
      paragraph.append(trimmed)
      i += 1
    }
    flush()
    return blocks
  }

  static func heading(_ line: String) -> Int? {
    let hashes = line.prefix { $0 == "#" }.count
    guard (1...6).contains(hashes), line.dropFirst(hashes).first == " " else { return nil }
    return hashes
  }

  static func paragraphBreaker(_ line: String) -> Bool {
    let t = line.trimmingCharacters(in: .whitespaces)
    return t.hasPrefix("```") || t.hasPrefix(">") || heading(t) != nil || t.hasPrefix("|")
  }

  static func leadingSpaces(_ line: String) -> Int { line.prefix { $0 == " " }.count }
  static func task(_ item: [MarkdownBlock]) -> [MarkdownBlock] {
    guard case .paragraph(let text)? = item.first, text.count > 3, text.dropFirst(3).first?.isWhitespace == true,
          let box = ["[ ]": false, "[x]": true, "[X]": true][String(text.prefix(3))] else { return item }
    return [.task(checked: box, text: String(text.dropFirst(4)))] + item.dropFirst()
  }

  struct Marker { let indent: Int; let width: Int; let ordered: Bool; let start: Int }

  static func listMarker(_ line: String) -> Marker? {
    let indent = leadingSpaces(line)
    let rest = line.dropFirst(indent)
    if let first = rest.first, "-*+".contains(first), rest.dropFirst().first == " " {
      return Marker(indent: indent, width: indent + 2, ordered: false, start: 1)
    }
    let digits = rest.prefix { $0.isNumber }
    if !digits.isEmpty, digits.count < 10 {
      let after = rest.dropFirst(digits.count)
      if let dot = after.first, dot == "." || dot == ")", after.dropFirst().first == " " {
        return Marker(indent: indent, width: indent + digits.count + 2, ordered: true, start: Int(digits) ?? 1)
      }
    }
    return nil
  }

  static func isDelimiterRow(_ line: String) -> Bool {
    let t = line.trimmingCharacters(in: .whitespaces)
    return t.hasPrefix("|") && t.range(of: #"^\|?(\s*:?-+:?\s*\|)+\s*:?-*:?\s*$"#, options: .regularExpression) != nil
  }

  static func cells(_ line: String) -> [String] {
    var t = line.trimmingCharacters(in: .whitespaces)
    if t.hasPrefix("|") { t.removeFirst() }
    if t.hasSuffix("|") { t.removeLast() }
    return t.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
  }
}
