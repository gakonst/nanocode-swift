import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif
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

  static func inline(_ source: String, size: CGFloat, theme: NanocodeTheme) -> AttributedString {
    let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace, failurePolicy: .returnPartiallyParsedIfPossible)
    var text = (try? AttributedString(markdown: source, options: options)) ?? AttributedString(source)
    for run in text.runs {
      let range = run.range
      let intent = run.inlinePresentationIntent ?? []
      if intent.contains(.code) {
        text[range].font = .mono(theme.codeSize)
        text[range].backgroundColor = theme.faint
      } else if intent.contains(.stronglyEmphasized) {
        text[range].font = .body(size, weight: .bold)
      }
      if intent.contains(.emphasized), !intent.contains(.code) {
        text[range].font = (text[range].font ?? .body(size)).italic()
      }
      if intent.contains(.strikethrough) { text[range].strikethroughStyle = .single }
      if let url = run.link {
        if url.absoluteString == MarkdownStream.incompleteLink {
          text[range].link = nil
          text[range].foregroundColor = theme.link
          text[range].underlineStyle = .single
        } else if ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") {
          text[range].foregroundColor = theme.link
          text[range].underlineStyle = .single
        } else {
          text[range].link = nil
        }
      }
    }
    var kept = AttributedString()
    var cursor = text.startIndex
    for run in text.runs where run.imageURL != nil {
      kept.append(text[cursor..<run.range.lowerBound])
      cursor = run.range.upperBound
    }
    kept.append(text[cursor...])
    return kept
  }
}

public struct MarkdownView: View {
  let blocks: [MarkdownBlock]
  var depth = 0
  var size: CGFloat?
  @Environment(\.nanocodeTheme) private var theme

  public init(_ text: String, live: Bool = false, size: CGFloat? = nil) {
    blocks = Markdown.streaming(text, live: live)
    self.size = size
  }

  init(blocks: [MarkdownBlock], depth: Int, size: CGFloat?) {
    self.blocks = blocks
    self.depth = depth
    self.size = size
  }

  public var body: some View {
    let size = self.size ?? theme.bodySize
    VStack(alignment: .leading, spacing: depth > 0 ? 2 : 10) {
      ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in view(for: block, size: size) }
    }
    .foregroundStyle(theme.foreground)
    .tint(theme.link)
  }

  @ViewBuilder func view(for block: MarkdownBlock, size: CGFloat) -> some View {
    switch block {
    case .paragraph(let text):
      Text(Markdown.inline(text, size: size, theme: theme)).font(.body(size)).lineHeight(theme.lineHeight, size: size)
        .fixedSize(horizontal: false, vertical: true)
        .textSelection(.enabled)
    case .task(let checked, let text):
      HStack(alignment: .top, spacing: 6) {
        Image(systemName: checked ? "checkmark.square.fill" : "square").foregroundStyle(theme.muted).padding(.top, 2)
        Text(Markdown.inline(text, size: size, theme: theme)).font(.body(size)).fixedSize(horizontal: false, vertical: true)
      }
    case .heading(let level, let text):
      let heading = level == 1 ? size + 5 : level == 2 ? size + 2 : size
      Text(Markdown.inline(text, size: heading, theme: theme)).font(.body(heading, weight: .semibold))
        .padding(.top, 6)
        .accessibilityAddTraits(.isHeader)
    case .list(let ordered, let start, let items):
      VStack(alignment: .leading, spacing: 4) {
        ForEach(Array(items.enumerated()), id: \.offset) { index, item in
          HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text(ordered ? "\(start + index)." : ["•", "◦", "▪"][min(depth, 2)]).font(.body(size))
              .frame(width: 22, alignment: ordered ? .trailing : .center).padding(.trailing, ordered ? 6 : 0)
            MarkdownView(blocks: item, depth: depth + 1, size: size)
          }
        }
      }
    case .code(let language, let text):
      CodeBlock(text: text, language: language)
    case .table(let header, let rows):
      TableCard(header: header, rows: rows)
    case .quote(let inner):
      MarkdownView(blocks: inner, depth: depth, size: size)
        .foregroundStyle(theme.muted)
        .padding(.leading, 12)
        .overlay(alignment: .leading) { Rectangle().fill(theme.border).frame(width: 2) }
    case .rule:
      Rectangle().fill(theme.border).frame(height: 1).padding(.vertical, 4)
    }
  }
}

public struct CodeBlock: View {
  let text: String
  let language: String
  var maxHeight: CGFloat?
  @Environment(\.nanocodeTheme) private var theme
  @State private var copied = false

  public init(text: String, language: String, maxHeight: CGFloat? = nil) {
    self.text = text
    self.language = language
    self.maxHeight = maxHeight
  }

  var code: some View {
    ScrollView(.horizontal) {
      Text(Highlight.attributed(text, language: language, theme: theme) ?? AttributedString(text))
        .font(.mono(theme.codeSize))
        .lineSpacing(3)
        .fixedSize()
        .textSelection(.enabled)
        .padding(.horizontal, 12).padding(.vertical, 10)
    }
    .scrollIndicators(.never)
    .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  public var body: some View {
    Group {
      if let maxHeight, text.split(separator: "\n", omittingEmptySubsequences: false).count > 14 {
        ScrollView(.vertical) { code }.frame(maxHeight: maxHeight)
      } else {
        code
      }
    }
    .background(theme.popover, in: RoundedRectangle(cornerRadius: 10))
    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(theme.border, lineWidth: 1))
    .overlay(alignment: .topTrailing) {
      Button {
        Pasteboard.copy(text)
        copied = true
      } label: {
        Image(systemName: copied ? "checkmark" : "doc.on.doc").font(.system(size: 11)).foregroundStyle(theme.muted).padding(8)
      }
      .buttonStyle(.plain)
    }
  }
}

struct TableCard: View {
  let header: [String]
  let rows: [[String]]
  @Environment(\.nanocodeTheme) private var theme

  var body: some View {
    ScrollView(.horizontal) {
      Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
        GridRow {
          ForEach(Array(header.enumerated()), id: \.offset) { _, cell in
            Text(Markdown.inline(cell, size: theme.bodySize - 2, theme: theme)).font(.body(theme.bodySize - 2, weight: .semibold))
              .foregroundStyle(theme.muted).padding(.horizontal, 12).padding(.vertical, 7)
          }
        }
        Divider().gridCellUnsizedAxes(.horizontal)
        ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
          if index > 0 { Divider().gridCellUnsizedAxes(.horizontal) }
          GridRow {
            ForEach(Array(header.indices), id: \.self) { column in
              Text(Markdown.inline(column < row.count ? row[column] : "", size: theme.bodySize - 1, theme: theme)).font(.body(theme.bodySize - 1))
                .padding(.horizontal, 12).padding(.vertical, 7)
            }
          }
        }
      }
    }
    .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
    .background(theme.popover, in: RoundedRectangle(cornerRadius: 10))
    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(theme.border, lineWidth: 1))
    .fixedSize(horizontal: true, vertical: false)
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

enum Pasteboard {
  static func copy(_ text: String) {
    #if os(macOS)
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
    #else
    UIPasteboard.general.string = text
    #endif
  }
}
