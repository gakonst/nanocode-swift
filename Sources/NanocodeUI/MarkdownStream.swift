import Foundation
import os
public enum MarkdownStream {
  public static let incompleteLink = "nanocode:incomplete"

  struct Opener { var char: Character; var count: Int; var at: Int }

  static func space(_ c: Character?) -> Bool { c.map(\.isWhitespace) ?? true }
  static func punct(_ c: Character?) -> Bool {
    guard let c else { return false }
    return c.unicodeScalars.allSatisfy { CharacterSet.punctuationCharacters.contains($0) || CharacterSet.symbols.contains($0) }
  }
  static func word(_ c: Character?) -> Bool { c.map { $0.isLetter || $0.isNumber } ?? false }
  static func runLength(_ text: [Character], _ at: Int) -> Int {
    var end = at
    while end < text.count, text[end] == text[at] { end += 1 }
    return end - at
  }

  struct Expressions: @unchecked Sendable { var cache: [String: NSRegularExpression] = [:] }
  static let expressions = OSAllocatedUnfairLock(uncheckedState: Expressions())
  static func regex(_ pattern: String) -> NSRegularExpression {
    if let cached = expressions.withLock({ $0.cache[pattern] }) { return cached }
    let compiled = try! NSRegularExpression(pattern: pattern)
    expressions.withLock { $0.cache[pattern] = compiled }
    return compiled
  }
  static func match(_ pattern: String, _ text: String) -> [String?]? {
    let ns = text as NSString
    guard let m = regex(pattern).firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { return nil }
    return (0..<m.numberOfRanges).map { m.range(at: $0).location == NSNotFound ? nil : ns.substring(with: m.range(at: $0)) }
  }
  static func test(_ pattern: String, _ text: String?) -> Bool { text.map { match(pattern, $0) != nil } ?? false }

  static func trimEnd(_ text: String) -> String {
    var t = Substring(text)
    while let last = t.last, last.isWhitespace { t.removeLast() }
    return String(t)
  }
  static func lines(_ text: String) -> [String] { text.components(separatedBy: "\n") }
  static func fences(_ lines: [String]) -> (code: [Bool], open: Bool) {
    var code: [Bool] = []
    var fence: String?
    for line in lines {
      let marker = match(#"^[\s>]*(?:(?:[-*+]|\d+[.)])\s+)?(`{3,}|~{3,})(.*)$"#, line)
      if let open = fence {
        code.append(true)
        if let marker, let run = marker[1], run.first == open.first, run.count >= open.count,
           (marker[2] ?? "").trimmingCharacters(in: .whitespaces).isEmpty { fence = nil }
      } else if let marker, let run = marker[1], !(run.first == "`" && (marker[2] ?? "").contains("`")) {
        code.append(true)
        fence = run
      } else {
        code.append(false)
      }
    }
    return (code, fence != nil)
  }
  static let blockStart = #"^\s*(?:[-*+](?:\s|$)|\d+[.)](?:\s|$)|#{1,6}(?:\s|$)|>|\|)"#
  static let rule = #"^ {0,3}([-*_])(?:[ \t]*\1){2,}[ \t]*$"#
  static func closedLine(_ line: String) -> Bool { test(#"^\s*(?:#{1,6}(?:\s|$)|\|)"#, line) || test(rule, line) }
  static func cells(_ line: String) -> [String] {
    var t = Array(line.trimmingCharacters(in: .whitespacesAndNewlines))
    if t.first == "|" { t.removeFirst() }
    if t.last == "|", !(t.count >= 2 && t[t.count - 2] == "\\") { t.removeLast() }
    var cells: [String] = [], current = ""
    for (i, c) in t.enumerated() {
      if c == "|", !(i > 0 && t[i - 1] == "\\") { cells.append(current); current = "" } else { current.append(c) }
    }
    cells.append(current)
    return cells
  }
  public static func complete(_ text: String) -> String {
    let rows = lines(trimEnd(text))
    if fences(rows).open || test(#"\n[ \t]*\n\s*$"#, text) { return closeInline(text) }
    let row = { (line: String?) in test(#"^\s*\|"#, line) }
    let valid = { (cell: String) in test(#"^\s*:?-+:?\s*$"#, cell) }
    let delimiter = { (header: String, typed: String) -> String in
      let done = typed.isEmpty ? [] : cells(typed)
      return "|" + cells(header).indices.map { i in " \(i < done.count && valid(done[i]) ? done[i].trimmingCharacters(in: .whitespaces) : "---") |" }.joined()
    }
    let at = { (offset: Int) -> String? in rows.count >= offset ? rows[rows.count - offset] : nil }
    let header = rows.count >= 2 ? rows[rows.count - 2] : rows[0]
    let last = rows.count >= 2 ? rows[rows.count - 1] : nil
    if rows.count > 1, row(header), !row(at(3)), let last, test(#"^\s*\|[\s|:-]*$"#, last) {
      let complete = cells(last).count == cells(header).count && cells(last).allSatisfy(valid)
      return complete ? text : (rows.dropLast() + [delimiter(header, last)]).joined(separator: "\n")
    }
    let final = rows.last!
    if row(final), !row(at(2)) {
      let joined = rows.joined(separator: "\n")
      if !text.dropFirst(joined.count).contains("\n") { return closeInline(rows.dropLast().joined(separator: "\n")) }
      return trimEnd(closeInline(text)) + "\n" + delimiter(final, "")
    }
    return closeInline(text)
  }

  static func closeInline(_ input: String) -> String {
    var text = input
    var rows = lines(text)
    if fences(rows).open { return text }
    let last = rows.count - 1
    if last > 0, test(#"^ {0,3}(?:-{1,2}|={1,2})[ \t]*$"#, rows[last]), !rows[last - 1].trimmingCharacters(in: .whitespaces).isEmpty,
       !fences(Array(rows[..<last])).code[last - 1] {
      rows = Array(rows[..<last])
      text = rows.joined(separator: "\n") + "\n"
    }
    let bodyText = trimEnd(text)
    let tail = String(text.dropFirst(bodyText.count))
    if tail.filter({ $0 == "\n" }).count > 1 { return text }
    rows = lines(bodyText)
    let code = fences(rows).code
    var first = rows.count - 1
    if code[first] || test(rule, rows[first]) { return text }
    while first > 0, !test(blockStart, rows[first]), !rows[first - 1].trimmingCharacters(in: .whitespaces).isEmpty, !code[first - 1], !closedLine(rows[first - 1]) {
      first -= 1
    }
    let body = Array(bodyText)
    var from = rows[..<first].reduce(0) { $0 + $1.count + 1 }
    from += (match(#"^(?:\s*(?:>|[-*+](?=\s)|\d+[.)](?=\s)|#{1,6}(?=\s|$)))*\s*"#, rows[first])?[0] ?? "").count
    if test(#"^\s*\|"#, rows[first]) { from = (body.lastIndex(of: "|") ?? -1) + 1 }

    var openers: [Opener] = []
    var brackets: [Int] = []
    var codeAt = -1, destination = -1, destinationBracket = -1
    var i = from
    scan: while i < body.count {
      let ch = body[i]
      if ch == "\\" { i += 2; continue }
      if ch == "`" {
        let n = runLength(body, i)
        var close = i + n
        while close < body.count, body[close] != "`" || runLength(body, close) != n { close += body[close] == "`" ? runLength(body, close) : 1 }
        if close < body.count { i = close + n; continue }
        if i + n < body.count { codeAt = i }
        break
      }
      if ch == "<", let autolink = match(#"^<[a-zA-Z][\w+.-]*:[^\s<>]*>"#, String(body[i...])) {
        i += autolink[0]!.count
        continue
      }
      if ch == "h" || ch == "w", test(#"^(?:https?://|www\.)"#, String(body[i..<min(i + 8, body.count)])), !word(i > 0 ? body[i - 1] : nil) {
        while i < body.count, !space(body[i]) { i += 1 }
        continue
      }
      if ch == "[" { brackets.append(i); i += 1; continue }
      if ch == "]" {
        let open = brackets.popLast()
        if let open, i + 1 == body.count { destination = i; destinationBracket = open; break }
        guard let open, i + 1 < body.count, body[i + 1] == "(" else { i += 1; continue }
        var end = i + 2, depth = 0
        while end < body.count, body[end] != ")" || depth > 0 {
          if body[end] == "\\" { end += 1 } else if body[end] == "(" { depth += 1 } else if body[end] == ")" { depth -= 1 }
          end += 1
        }
        if end >= body.count { destination = i; destinationBracket = open; break scan }
        while let top = openers.last, top.at > open { openers.removeLast() }
        i = end + 1
        continue
      }
      if ch == "*" || ch == "_" || ch == "~" {
        let n = runLength(body, i)
        let before: Character = i > from ? body[i - 1] : " "
        let after: Character? = i + n < body.count ? body[i + n] : nil
        let left = !space(after) && (!punct(after) || space(before) || punct(before))
        let right = !space(before) && (!punct(before) || space(after) || punct(after))
        let canOpen = ch == "_" ? left && (!right || punct(before)) : left
        let canClose = ch == "_" ? right && (!left || punct(after)) : right
        var rest = ch == "~" && n > 2 ? 0 : n
        var k = openers.count - 1
        while canClose, k >= 0, rest > 0 {
          defer { k -= 1 }
          let opener = openers[k]
          if opener.char != ch || ch == "~" && opener.count != rest && !(rest == 1 && i + n == body.count) { continue }
          let used = min(rest, opener.count)
          openers[k].count -= used
          rest -= used
          openers.removeLast(openers.count - (openers[k].count > 0 ? k + 1 : k))
        }
        if rest > 0, canOpen, ch == "~" ? rest == 2 : ch == "_" || !(word(before) && word(after)) {
          openers.append(Opener(char: ch, count: rest, at: i + n - rest))
        }
        i += n
        continue
      }
      i += 1
    }
    if let marker = body.last, "*_~`".contains(marker), codeAt < 0, destination < 0 {
      var index = body.count
      while index > 0, body[index - 1] == marker { index -= 1 }
      if index >= from, index == from || " \t\n([{".contains(body[index - 1]) || body[index - 1].isWhitespace {
        return closeInline(String(body[..<index]))
      }
    }

    let close = { (list: [Opener]) in list.reversed().map { String(repeating: $0.char, count: $0.count) }.joined() }
    let split = { (bracket: Int) in (close(openers.filter { $0.at > bracket }), close(openers.filter { $0.at < bracket })) }
    if destination >= 0 {
      let (inner, outer) = split(destinationBracket)
      return String(body[..<destination]) + inner + "](\(incompleteLink))" + outer + tail
    }
    var codeClose = ""
    if codeAt >= 0 {
      let ticks = runLength(body, codeAt)
      var trailing = 0
      while trailing < body.count, body[body.count - 1 - trailing] == "`" { trailing += 1 }
      if trailing >= ticks { return text }
      codeClose = String(repeating: "`", count: ticks - trailing)
    }
    guard let bracket = brackets.last else { return bodyText + codeClose + close(openers) + tail }
    let (inner, outer) = split(bracket)
    return bodyText + codeClose + inner + "](\(incompleteLink))" + outer + tail
  }
  public static func blocks(_ text: String) -> [String] {
    let rows = lines(text)
    if rows.contains(where: { test(#"^ {0,3}\[[^\]]+\]:"#, $0) }) { return [text] }
    let code = fences(rows).code
    var blocks: [[String]] = []
    var list = false
    for (index, line) in rows.enumerated() {
      let item = test(#"^(?:[-*+]|\d+[.)])(?:\s|$)"#, line)
      if index == 0 || rows[index - 1].trimmingCharacters(in: .whitespaces).isEmpty && !code[index - 1] && test(#"^\S"#, line) && !(item && list) {
        blocks.append([])
        list = false
      }
      list = list || item
      blocks[blocks.count - 1].append(line)
    }
    return blocks.map { $0.joined(separator: "\n") }
  }
}
