#if os(macOS)
import AppKit
#else
import UIKit
#endif

public final class MarkdownNode: Stack {
  let skin: Skin
  var color: KitColor
  var size: CGFloat
  let nested: Bool
  let depth: Int
  private var blocks: [MarkdownBlock] = []
  private var source: String?
  private var live = false

  public init(skin: Skin, color: KitColor? = nil, size: CGFloat? = nil, nested: Bool = false, depth: Int = 0) {
    self.skin = skin
    self.color = color ?? skin.text
    self.size = size ?? skin.proseSize
    self.nested = nested
    self.depth = depth
    super.init(frame: .zero)
    axis = .vertical
    align = .fill
  }


  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("created in code") }

  public func update(_ text: String, live: Bool) {
    guard text != source || live != self.live else { return }
    source = text
    self.live = live
    render(Markdown.streaming(text, live: live))
  }

  func render(_ next: [MarkdownBlock]) {
    var nodes: [Node] = []
    for (index, block) in next.enumerated() {
      if index < blocks.count, index < items.count, blocks[index] == block {
        nodes.append(items[index])
      } else if index < blocks.count, index < items.count, case .paragraph(let text) = block, case .paragraph = blocks[index],
                let node = items[index] as? TextNode {
        node.text = paragraph(text)
        nodes.append(node)
      } else {
        nodes.append(build(block))
      }
    }
    blocks = next
    for (index, node) in nodes.enumerated() { node.spaceBefore = index == 0 ? 0 : gap(next[index - 1], next[index]) }
    set(nodes)
  }

  func margins(_ block: MarkdownBlock) -> (CGFloat, CGFloat) {
    let bottom = nested ? 4 : skin.blockGap
    switch block {
    case .heading: return (skin.claude ? 22 : 24, 10)
    case .rule: return (skin.claude ? 22 : 24, skin.claude ? 22 : 24)
    case .code: return (4, bottom)
    default: return (0, bottom)
    }
  }

  func gap(_ previous: MarkdownBlock, _ next: MarkdownBlock) -> CGFloat {
    max(margins(previous).1, margins(next).0)
  }

  var lineHeight: CGFloat { (size * skin.proseLine).rounded() }

  func paragraph(_ text: String) -> NSAttributedString {
    Rich.inline(text, skin: skin, font: skin.prose(size), color: color, lineHeight: lineHeight)
  }

  func build(_ block: MarkdownBlock) -> Node {
    switch block {
    case .paragraph(let text):
      return TextNode(paragraph(text))
    case .task(let checked, let text):
      let box = Label(styled(checked ? "☑" : "☐", skin.prose(size), skin.muted, lineHeight: lineHeight))
      return Stack(.horizontal, spacing: 6, align: .start, [box, grown(TextNode(paragraph(text)))])
    case .heading(let level, let text):
      let heading = skin.headings[min(level, skin.headings.count) - 1]
      let font = skin.claude ? KitFont.serif(heading, bold: true) : KitFont.sans(heading, .semibold)
      return TextNode(Rich.inline(text, skin: skin, font: font, color: color, lineHeight: (heading * 1.3).rounded()))
    case .list(let ordered, let start, let items):
      let list = Stack(.vertical, spacing: skin.claude ? 6 : 4, align: .fill)
      let markers = ["•", "◦", "▪"]
      list.set(items.enumerated().map { index, blocks in
        let marker = Label(styled(ordered ? "\(start + index)." : markers[min(depth, 2)], skin.prose(size), color, lineHeight: lineHeight, alignment: .right))
        marker.fixedWidth = 26
        marker.padding = Insets(right: ordered ? 6 : 9)
        let body = MarkdownNode(skin: skin, color: color, size: size, nested: true, depth: depth + 1)
        body.render(blocks)
        return Stack(.horizontal, spacing: 0, align: .start, [marker, grown(body)])
      })
      return list
    case .code(let language, let text):
      return CodeBlockNode(skin: skin, language: language, text: text)
    case .table(let header, let rows):
      return ScrollNode(TableNode(skin: skin, header: header, rows: rows, lineHeight: (14 * skin.proseLine).rounded()), axis: .horizontal)
    case .quote(let inner):
      let body = MarkdownNode(skin: skin, color: skin.muted, size: size, nested: nested, depth: depth)
      body.render(inner)
      let quote = Stack(.vertical, spacing: 0, align: .fill, [body])
      quote.padding = Insets(left: 14)
      quote.rules = [(.left, skin.border, 3)]
      return quote
    case .rule:
      return Rule(skin.border)
    }
  }

  func grown(_ node: Node) -> Node {
    node.grow = 1
    return node
  }
}

public final class CodeBlockNode: Stack {
  let skin: Skin
  let language = Label()
  let copy = Pressable()
  let copyLabel = Label()
  let body = TextNode()
  var code = ""
  var copied = false

  public init(skin: Skin, language: String, text: String) {
    self.skin = skin
    super.init(frame: .zero)
    axis = .vertical
    align = .fill
    fill = skin.code
    stroke = skin.border
    strokeWidth = skin.hairline
    radius = skin.codeRadius
    clips = true
    copy.set([copyLabel])
    copy.padding = Insets(v: 2, h: skin.claude ? 8 : 6)
    copy.radius = 6
    copy.hoverFill = skin.hover
    if skin.claude {
      copy.stroke = skin.border
      copy.strokeWidth = skin.hairline
    }
    copy.onHover = { [weak self] hovering in self?.paint(hovering) }
    copy.action = { [weak self] in self?.copyCode() }
    let bar = Stack(.horizontal, spacing: 8, align: .center, [self.language, Spacer(), copy])
    bar.padding = Insets(v: 6, h: skin.claude ? 12 : 14)
    bar.fill = skin.codeBar
    body.padding = skin.claude ? Insets(v: 12, h: 14) : Insets(v: 14, h: 16)
    set([bar, ScrollNode(body, axis: .horizontal)])
    update(language: language, text: text)
  }


  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("created in code") }

  func update(language: String, text: String) {
    code = text.hasSuffix("\n") ? String(text.dropLast()) : text
    self.language.text = styled(language == "text" ? "" : language, skin.ui(12), skin.muted)
    body.text = Rich.code(code, language: language, skin: skin, font: .mono(13.5), color: skin.text, lineHeight: (13.5 * 1.55).rounded())
    paint(false)
  }

  func paint(_ hovering: Bool) {
    copyLabel.text = styled(copied ? "Copied" : "Copy", skin.ui(12), hovering ? skin.text : skin.muted)
  }

  func copyCode() {
    Pasteboard.copy(code)
    copied = true
    paint(copy.hovering)
    Task { @MainActor [weak self] in
      try? await Task.sleep(nanoseconds: 1_500_000_000)
      self?.copied = false
      self?.paint(self?.copy.hovering ?? false)
    }
  }
}

public final class TableNode: Node {
  let skin: Skin
  var cells: [[Label]] = []

  public init(skin: Skin, header: [String], rows: [[String]], lineHeight: CGFloat) {
    self.skin = skin
    super.init(frame: .zero)
    for (index, row) in ([header] + rows).enumerated() {
      let labels = header.indices.map { column in
        let font = skin.ui(14, index == 0 ? .bold : .regular)
        let label = Label(Rich.inline(column < row.count ? row[column] : "", skin: skin, font: font, color: skin.text, lineHeight: lineHeight, prose: false))
        label.padding = Insets(v: 8, h: 12)
        addSubview(label)
        return label
      }
      cells.append(labels)
    }
  }


  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("created in code") }

  func columns() -> [CGFloat] {
    guard let first = cells.first else { return [] }
    return first.indices.map { column in cells.map { $0[column].measure(unbounded).width }.max() ?? 0 }
  }

  func heights(_ columns: [CGFloat]) -> [CGFloat] {
    cells.map { row in zip(row, columns).map { $0.measure($1).height }.max() ?? 0 }
  }

  public override func contentSize(_ width: CGFloat) -> CGSize {
    let columns = columns()
    let heights = heights(columns)
    return CGSize(width: columns.reduce(0, +), height: heights.reduce(0, +) + CGFloat(heights.count))
  }

  public override func arrange(_ rect: CGRect) {
    let columns = columns()
    let heights = heights(columns)
    var y = rect.minY
    var lines: [(Edge, KitColor, CGFloat)] = []
    for (row, height) in zip(cells, heights) {
      var x = rect.minX
      for (label, width) in zip(row, columns) {
        label.place(CGRect(x: x, y: y, width: width, height: height))
        x += width
      }
      y += height + 1
      lines.append((.top, skin.border, y - 1))
    }
    rowLines = lines.map { $0.2 }
    redraw()
  }

  var rowLines: [CGFloat] = []

  public override func draw(_ dirtyRect: CGRect) {
    super.draw(dirtyRect)
    guard let context = context() else { return }
    context.setFillColor(skin.border.cgColor)
    for y in rowLines { context.fill(CGRect(x: 0, y: y, width: bounds.width, height: 1)) }
  }
}
