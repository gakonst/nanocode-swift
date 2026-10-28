import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif
extension Markdown {
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

public enum Pasteboard {
  public static func copy(_ text: String) {
    #if os(macOS)
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
    #else
    UIPasteboard.general.string = text
    #endif
  }
}
