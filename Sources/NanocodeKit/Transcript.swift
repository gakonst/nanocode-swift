#if os(macOS)
import AppKit
#else
import UIKit
#endif

enum CloneBlock {
  case tools(id: String, cells: [ToolCell], live: Bool)
  case block(Turn.Block)

  var id: String {
    switch self {
    case .tools(let id, _, _): id
    case .block(let block): block.id
    }
  }

  var kind: String {
    switch self {
    case .tools: "tools"
    case .block(let block):
      switch block.entry.kind {
      case .assistant: "assistant"
      case .reasoning: "reasoning"
      default: "note"
      }
    }
  }

  static func grouped(_ blocks: [Turn.Block]) -> [CloneBlock] {
    var result: [CloneBlock] = []
    for block in blocks {
      if let tool = block.entry.tool {
        if case .tools(let id, let cells, let live) = result.last {
          result[result.count - 1] = .tools(id: id, cells: cells + [tool], live: live || block.live)
        } else {
          result.append(.tools(id: block.id, cells: [tool], live: block.live))
        }
      } else {
        result.append(.block(block))
      }
    }
    return result
  }
}

enum Clone {
  static func seconds(_ block: Turn.Block) -> Int? {
    guard !block.live, let started = block.entry.startedAt, let ended = block.entry.endedAt else { return nil }
    return max(1, Int(((ended - started) / 1000).rounded()))
  }

  static func thought(_ text: String) -> String {
    text.replacingOccurrences(of: #"\*\*(.+?)\*\*"#, with: "$1", options: .regularExpression)
  }

  static func greeting(_ date: Date = Date()) -> String {
    let hour = Calendar.current.component(.hour, from: date)
    return hour < 5 ? "Good evening" : hour < 12 ? "Good morning" : hour < 18 ? "Good afternoon" : "Good evening"
  }

  static func lineCount(_ text: String) -> String {
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false).count
    return lines == 1 ? "1 line" : lines.formatted() + " lines"
  }

  static func trimmed(_ text: String) -> String {
    var text = text
    while let last = text.last, last.isWhitespace { text.removeLast() }
    return text
  }
}

struct TurnState {
  var wide: Bool
  var last: Bool
  var pending: Bool
  var busy: Bool
  var phase: ActivityPhase
}

final class LogNode: Stack {
  let skin: Skin
  let column = Stack(.vertical)
  let waiting = Label()
  let failure = Label()
  var turns: [String: TurnNode] = [:]

  init(skin: Skin) {
    self.skin = skin
    super.init(frame: .zero)
    axis = .vertical
    align = .center
    column.maxWidth = skin.column
    set([column])
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("created in code") }

  func update(_ chat: Chat, wide: Bool) {
    column.padding = skin.claude
      ? Insets(top: wide ? 12 : 8, left: wide ? 24 : 16, bottom: wide ? 40 : 32, right: wide ? 24 : 16)
      : Insets(top: wide ? 16 : 8, left: wide ? 24 : 16, bottom: wide ? 40 : 32, right: wide ? 24 : 16)
    let list = chat.turns
    let activity = chat.activity
    var nodes: [Node] = []
    var kept: [String: TurnNode] = [:]
    for (index, turn) in list.enumerated() {
      let node = turns[turn.id] ?? TurnNode(skin: skin)
      node.update(turn, TurnState(wide: wide, last: index == list.count - 1, pending: chat.pending, busy: activity.busy || chat.pending, phase: activity.phase))
      kept[turn.id] = node
      nodes.append(node)
    }
    turns = kept
    waiting.text = styled(chat.waiting ?? "", skin.ui(13), skin.muted)
    waiting.gone = chat.waiting == nil
    failure.text = styled(chat.error ?? "", skin.ui(13), skin.danger)
    failure.gone = chat.error == nil
    column.set(nodes + [waiting, failure])
  }
}

final class BubbleRow: Node {
  let bubble: Node
  var ratio: CGFloat { didSet { if ratio != oldValue { invalidate() } } }
  let trailing: Bool

  init(_ bubble: Node, ratio: CGFloat, trailing: Bool) {
    self.bubble = bubble
    self.ratio = ratio
    self.trailing = trailing
    super.init(frame: .zero)
    addSubview(bubble)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("created in code") }

  override func contentSize(_ width: CGFloat) -> CGSize {
    CGSize(width: width, height: bubble.measure((width * ratio).rounded()).height)
  }

  override func arrange(_ rect: CGRect) {
    let size = bubble.measure((rect.width * ratio).rounded())
    bubble.place(CGRect(x: trailing ? rect.maxX - size.width : rect.minX, y: rect.minY, width: size.width, height: size.height))
  }
}

final class TurnNode: Stack {
  let skin: Skin
  let prompt = TextNode()
  let images = Flow()
  let bubble: Stack
  let row: BubbleRow
  let assistant = Stack(.vertical, spacing: 12, align: .fill)
  let dot: Node
  var blocks: [String: (String, Node)] = [:]
  var promptText: String?
  var promptImages: [String] = []

  init(skin: Skin) {
    self.skin = skin
    images.spacing = 8
    if skin.claude {
      let avatar = Label(styled("Y", skin.ui(12, .semibold), skin.bg, alignment: .center))
      avatar.fill = skin.text
      avatar.radius = 13
      avatar.fixedWidth = 26
      avatar.fixedHeight = 26
      avatar.padding = Insets(top: 5)
      let body = Stack(.vertical, spacing: 8, align: .start, [prompt, images])
      body.padding = Insets(top: 1)
      body.shrink = true
      bubble = Stack(.horizontal, spacing: 10, align: .start, [avatar, body])
      bubble.padding = Insets(top: 10, left: 10, bottom: 10, right: 16)
      bubble.radius = 14
      row = BubbleRow(bubble, ratio: 0.85, trailing: false)
      let spark = Spinner(.glyph("✻", 22), color: skin.spark, period: 2.4)
      spark.alphaValueCompat = 0.9
      dot = spark
    } else {
      bubble = Stack(.vertical, spacing: 8, align: .start, [prompt, images])
      bubble.padding = Insets(v: 10, h: 16)
      bubble.radius = 18
      row = BubbleRow(bubble, ratio: 0.7, trailing: true)
      dot = Pulse(color: skin.text)
    }
    bubble.fill = skin.bubble
    super.init(frame: .zero)
    axis = .vertical
    spacing = skin.claude ? 14 : 20
    padding = skin.claude ? Insets(top: 10, bottom: 14) : Insets(v: 12, h: 0)
    if skin.claude { assistant.padding = Insets(v: 0, h: 4) }
    set([row, assistant])
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("created in code") }

  func update(_ turn: Turn, _ state: TurnState) {
    row.ratio = skin.claude || !state.wide ? 0.85 : 0.7
    if let entry = turn.prompt {
      if entry.text != promptText {
        promptText = entry.text
        prompt.text = styled(entry.text, skin.ui(16), skin.text, lineHeight: 24)
        prompt.gone = entry.text.isEmpty
      }
      if entry.images != promptImages {
        promptImages = entry.images
        images.set(entry.images.map { ImageNode($0, cover: CGSize(width: 36, height: 36)).rounded(8) })
        images.gone = entry.images.isEmpty
      }
      row.gone = false
    } else {
      row.gone = true
    }
    var nodes: [Node] = []
    var kept: [String: (String, Node)] = [:]
    for block in CloneBlock.grouped(turn.blocks) {
      let node: Node
      if let existing = blocks[block.id], existing.0 == block.kind { node = existing.1 } else { node = make(block) }
      fill(node, block)
      kept[block.id] = (block.kind, node)
      nodes.append(node)
    }
    blocks = kept
    if skin.claude, let spark = dot as? Spinner {
      let streaming = state.phase == .writing || state.phase == .thinking
      spark.spinning = state.busy && !streaming
      spark.fading = state.busy && streaming ? 1.2 : nil
      dot.gone = !state.last
    } else {
      dot.gone = !(state.last && state.pending && (state.phase == .waiting || state.phase == .running))
    }
    assistant.set(nodes + [dot])
    assistant.gone = nodes.isEmpty && dot.gone
  }

  func make(_ block: CloneBlock) -> Node {
    switch block {
    case .tools: return skin.claude ? ClaudeTools(skin: skin) : GPTTools(skin: skin)
    case .block(let entry):
      switch entry.entry.kind {
      case .assistant: return MarkdownNode(skin: skin)
      case .reasoning: return skin.claude ? ClaudeThinking(skin: skin) : GPTThought(skin: skin)
      default: return Label()
      }
    }
  }

  func fill(_ node: Node, _ block: CloneBlock) {
    switch block {
    case .tools(_, let cells, let live):
      (node as? GPTTools)?.update(cells, live: live)
      (node as? ClaudeTools)?.update(cells, live: live)
    case .block(let entry):
      if let markdown = node as? MarkdownNode { markdown.update(entry.entry.text, live: entry.live) }
      else if let thought = node as? GPTThought { thought.update(entry) }
      else if let thought = node as? ClaudeThinking { thought.update(entry) }
      else if let label = node as? Label {
        label.text = styled(entry.entry.text, skin.ui(13), entry.entry.kind == .error ? skin.danger : skin.muted, lineHeight: 19)
      }
    }
  }
}

extension Node {
  func rounded(_ radius: CGFloat) -> Self {
    self.radius = radius
    return self
  }

  var alphaValueCompat: CGFloat {
    get {
      #if os(macOS)
      alphaValue
      #else
      alpha
      #endif
    }
    set {
      #if os(macOS)
      alphaValue = newValue
      #else
      alpha = newValue
      #endif
    }
  }
}

final class GPTThought: Stack {
  let skin: Skin
  let header = Pressable(.horizontal, spacing: 4, align: .center)
  let label = Label()
  let chevron: IconNode
  let text = TextNode()
  let body: ScrollNode
  var open: Bool?
  var block: Turn.Block?

  init(skin: Skin) {
    self.skin = skin
    chevron = IconNode(.chevron, color: skin.muted)
    text.padding = Insets(left: 14)
    text.rules = [(.left, skin.border, 2)]
    body = ScrollNode(text, axis: .vertical, maxHeight: 320)
    super.init(frame: .zero)
    axis = .vertical
    spacing = 8
    align = .start
    label.lines = 1
    header.set([label, chevron])
    header.action = { [weak self] in self?.toggle() }
    header.onHover = { [weak self] _ in self?.paint() }
    body.sticks = true
    set([header, body])
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("created in code") }

  override func arrange(_ rect: CGRect) {
    let size = header.measure(rect.width)
    header.place(CGRect(x: rect.minX, y: rect.minY, width: size.width, height: size.height))
    if !body.gone {
      let height = body.measure(rect.width).height
      body.place(CGRect(x: rect.minX, y: rect.minY + size.height + spacing, width: rect.width, height: height))
    }
  }

  override func contentSize(_ width: CGFloat) -> CGSize {
    let size = header.measure(width)
    let height = body.gone ? 0 : body.measure(width).height + spacing
    return CGSize(width: width, height: size.height + height)
  }

  func toggle() {
    guard let block else { return }
    open = !(open ?? block.live)
    update(block)
  }

  func update(_ block: Turn.Block) {
    self.block = block
    let shown = open ?? block.live
    let next = styled(Clone.thought(block.entry.text), skin.ui(14), skin.muted, lineHeight: 21)
    text.text = next
    body.gone = !shown
    chevron.gone = block.live
    chevron.rotation = shown ? 0 : -90
    label.shimmering = block.live
    paint()
  }

  func paint() {
    guard let block else { return }
    let title = block.live ? "Thinking" : Clone.seconds(block).map { "Thought for \($0)s" } ?? "Thought"
    let color = block.live || header.hovering ? skin.text : skin.muted
    label.text = styled(title, skin.ui(15), color, lineHeight: 22)
    chevron.color = header.hovering ? skin.text : skin.muted
  }
}

final class ClaudeThinking: Stack {
  let skin: Skin
  let header = Pressable(.horizontal, spacing: 6, align: .center)
  let label = Label()
  let chevron: IconNode
  let text = TextNode()
  let body: ScrollNode
  var open = false
  var block: Turn.Block?

  init(skin: Skin) {
    self.skin = skin
    chevron = IconNode(.chevron, color: skin.muted)
    text.padding = Insets(v: 10, h: 12)
    body = ScrollNode(text, axis: .vertical, maxHeight: 260)
    body.rules = [(.top, skin.border, skin.hairline)]
    super.init(frame: .zero)
    axis = .vertical
    stroke = skin.border
    strokeWidth = skin.hairline
    radius = 10
    clips = true
    label.lines = 1
    header.padding = Insets(v: 8, h: 12)
    header.set([label, Spacer(), chevron])
    header.action = { [weak self] in
      guard let self, let block = self.block else { return }
      self.open.toggle()
      self.update(block)
    }
    header.onHover = { [weak self] _ in self?.paint() }
    body.sticks = true
    set([header, body])
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("created in code") }

  func update(_ block: Turn.Block) {
    self.block = block
    text.text = styled(Clone.thought(block.entry.text), skin.ui(14), skin.muted, lineHeight: 21)
    body.gone = !(open || block.live)
    chevron.rotation = open ? 180 : 0
    label.fade(block.live ? 1.4 : nil)
    paint()
  }

  func paint() {
    guard let block else { return }
    let title = block.live ? "Thinking…" : Clone.seconds(block).map { "Thought for \($0)s" } ?? "Thought process"
    let color = header.hovering ? skin.text : skin.muted
    label.text = styled(title, skin.ui(14), color, lineHeight: 21)
    chevron.color = color
  }
}

final class GPTTools: Stack {
  let skin: Skin
  let header = Pressable(.horizontal, spacing: 4, align: .center)
  let label = Label()
  let names = Label()
  let chevron: IconNode
  let body = Stack(.vertical, spacing: 10, align: .fill)
  var cells: [String: CellNode] = [:]
  var open: Bool?
  var current: ([ToolCell], Bool) = ([], false)

  init(skin: Skin) {
    self.skin = skin
    chevron = IconNode(.chevron, color: skin.muted)
    super.init(frame: .zero)
    axis = .vertical
    stroke = skin.border
    radius = 14
    clips = true
    label.lines = 1
    names.lines = 1
    names.grow = 1
    names.padding = Insets(left: 6)
    header.padding = Insets(v: 10, h: 14)
    header.set([label, names, chevron])
    header.action = { [weak self] in
      guard let self else { return }
      self.open = !(self.open ?? self.running)
      self.update(self.current.0, live: self.current.1)
    }
    header.onHover = { [weak self] hovering in
      guard let self else { return }
      self.chevron.color = hovering ? skin.text : skin.muted
    }
    body.padding = Insets(top: 10, left: 14, bottom: 14, right: 14)
    body.rules = [(.top, skin.border, 1)]
    set([header, body])
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("created in code") }

  var running: Bool { current.0.contains { $0.status == .running } }

  func update(_ list: [ToolCell], live: Bool) {
    current = (list, live)
    let running = running
    let shown = open ?? running
    let code = list.allSatisfy { $0.name == "code" || $0.tool == "exec" }
    let count = list.count
    let title = running ? (code ? "Running code" : "Working") : (code ? "Ran code" : "Used \(count) \(count == 1 ? "tool" : "tools")")
    label.text = styled(title, skin.ui(15, .medium), skin.text, lineHeight: 22)
    label.shimmering = running
    var seen = Set<String>()
    let joined = list.map { ($0.title.isEmpty ? $0.name : $0.title).replacingOccurrences(of: #" · (?:wait|terminate)$"#, with: "", options: .regularExpression) }
      .filter { $0 != "code" && seen.insert($0).inserted }
      .joined(separator: ", ")
    names.text = styled(joined, skin.ui(13), skin.faint, lineHeight: 19)
    chevron.rotation = shown ? 0 : -90
    body.gone = !shown
    guard shown else { return }
    var kept: [String: CellNode] = [:]
    body.set(list.map { cell in
      let node = cells[cell.callID] ?? CellNode(skin: skin)
      node.update(cell, live: live)
      kept[cell.callID] = node
      return node
    })
    cells = kept
  }
}

final class ClaudeTools: Stack {
  let skin: Skin
  var cells: [String: CellNode] = [:]

  init(skin: Skin) {
    self.skin = skin
    super.init(frame: .zero)
    axis = .vertical
    stroke = skin.border
    strokeWidth = skin.hairline
    radius = 10
    clips = true
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("created in code") }

  func update(_ list: [ToolCell], live: Bool) {
    var kept: [String: CellNode] = [:]
    set(list.enumerated().map { index, cell in
      let node = cells[cell.callID] ?? CellNode(skin: skin, collapsed: true)
      node.update(cell, live: live)
      node.rules = index > 0 ? [(.top, skin.border, skin.hairline)] : []
      kept[cell.callID] = node
      return node
    })
    cells = kept
  }
}

final class CellIcon: Stack {
  let skin: Skin
  let glyph = Label()
  let spinner: Spinner

  init(skin: Skin) {
    self.skin = skin
    spinner = skin.claude ? Spinner(.glyph("✻", 12), color: skin.spark, period: 1.2) : Spinner(.ring, color: skin.text, track: skin.border, period: 0.8)
    super.init(frame: .zero)
    axis = .horizontal
    align = .center
    fixedWidth = 14
    justify = .center
    set([glyph, spinner])
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("created in code") }

  func update(_ status: ToolStatus) {
    spinner.gone = status != .running
    glyph.gone = status == .running
    let mark = switch status {
    case .running: ""
    case .completed: "✓"
    case .failed: skin.claude ? "!" : "✕"
    case .cancelled: "–"
    case .yielded: "↻"
    }
    glyph.text = styled(mark, skin.ui(12), status == .failed ? skin.danger : skin.icon, alignment: .center)
  }

  override func baseline(_ width: CGFloat) -> CGFloat { glyph.gone ? 9 : glyph.baseline(width) }
}

final class SectionNode: Stack {
  enum Part { case input, output, error }
  let skin: Skin
  let before = Pressable()
  let after = Pressable()
  let beforeLabel = Label()
  let afterLabel = Label()
  let text = TextNode()
  let body: ScrollNode
  var more: (() -> Void)?
  var rendered: (String, String, Part)?

  init(skin: Skin) {
    self.skin = skin
    text.padding = Insets(v: 10, h: 12)
    body = ScrollNode(text, axis: .vertical, maxHeight: 360)
    body.fill = skin.code
    if skin.claude {
      body.rules = [(.top, skin.border, skin.hairline)]
    } else {
      body.radius = 10
      body.clips = true
    }
    super.init(frame: .zero)
    axis = .vertical
    align = .fill
    for (button, label) in [(before, beforeLabel), (after, afterLabel)] {
      button.set([label])
      button.padding = skin.claude ? Insets(v: 4, h: 12) : Insets(v: 2, h: 0)
      button.action = { [weak self] in self?.more?() }
    }
    let beforeRow = Stack(.horizontal, spacing: 0, align: .start, [before, Spacer()])
    let afterRow = Stack(.horizontal, spacing: 0, align: .start, [after, Spacer()])
    set([beforeRow, body, afterRow])
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("created in code") }

  func update(_ source: String, language: String, part: Part, limit: Int?, tail: Bool) {
    let lines = source.split(separator: "\n", omittingEmptySubsequences: false)
    var shown = source
    var hidden = 0
    if let limit, lines.count > limit {
      hidden = lines.count - limit
      shown = (tail ? Array(lines.suffix(limit)) : Array(lines.prefix(limit))).joined(separator: "\n")
    }
    let color = part == .error ? skin.danger : part == .output && !skin.claude ? skin.muted : skin.text
    if rendered?.0 != shown || rendered?.1 != language || rendered.map({ $0.2 != part }) ?? true {
      rendered = (shown, language, part)
      text.text = Rich.code(shown, language: language, skin: skin, font: .mono(12.5), color: color, lineHeight: 18.75)
    }
    before.superview.flatMap { $0 as? Node }?.gone = hidden == 0 || !tail
    after.superview.flatMap { $0 as? Node }?.gone = hidden == 0 || tail
    let label = styled(tail ? "… \(hidden) earlier lines" : "… \(hidden) more lines", skin.ui(12), skin.faint)
    beforeLabel.text = label
    afterLabel.text = label
  }
}

final class CellNode: Stack {
  let skin: Skin
  let nested: Bool
  let collapsed: Bool
  let header: Pressable
  let icon: CellIcon
  let name = Label()
  let title = Label()
  let meta = Label()
  let input: SectionNode
  let output: SectionNode
  let children: Stack
  var rail: Node?
  let images = Flow()
  var childNodes: [String: CellNode] = [:]
  var cell: ToolCell?
  var live = false
  var open = false
  var timer: Timer?

  init(skin: Skin, nested: Bool = false, collapsed: Bool = false) {
    self.skin = skin
    self.nested = nested
    self.collapsed = collapsed
    header = Pressable(.horizontal, spacing: 8, align: skin.claude ? .center : .baseline)
    icon = CellIcon(skin: skin)
    input = SectionNode(skin: skin)
    output = SectionNode(skin: skin)
    children = Stack(.vertical, spacing: skin.claude ? 0 : 6, align: .fill)
    super.init(frame: .zero)
    axis = .vertical
    align = .fill
    spacing = skin.claude ? 0 : 6
    name.lines = 1
    title.lines = 1
    title.shrink = true
    meta.lines = 1
    if skin.claude {
      title.grow = 1
      header.set([icon, name, title, meta])
      header.padding = nested ? Insets(v: 4, h: 10) : Insets(v: 8, h: 12)
      header.hoverFill = skin.hover
      children.padding = Insets(left: 24)
      set([header, input, children, output, images])
    } else {
      header.set([icon, name, title, meta, Spacer()])
      let rail = Stack(.vertical, spacing: 0, align: .fill, [children])
      children.padding = Insets(left: 12)
      children.rules = [(.left, skin.border, 2)]
      rail.padding = Insets(left: 6)
      self.rail = rail
      set([header, input, rail, output, images])
    }
    images.spacing = 8
    if skin.claude { images.padding = Insets(12) }
    header.action = { [weak self] in
      guard let self, let cell = self.cell else { return }
      self.open.toggle()
      self.update(cell, live: self.live)
    }
    input.more = { [weak self] in self?.expand() }
    output.more = { [weak self] in self?.expand() }
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("created in code") }

  func expand() {
    guard let cell else { return }
    open = true
    update(cell, live: live)
  }

  var running: Bool { cell?.status == .running }

  func metaText(_ now: Date) -> String {
    guard let cell else { return "" }
    var text = ""
    if cell.status == .running { text += " · \(Format.duration(now.timeIntervalSince1970 * 1000 - cell.startedAt))" }
    else if let duration = cell.durationMs { text += " · \(Format.duration(duration))" }
    if cell.status == .cancelled || cell.status == .failed { text += " · \(cell.status.rawValue)" }
    text += cell.details.map { " · \($0)" }.joined()
    let output = Clone.trimmed(cell.output)
    if collapsed, nested, cell.status != .running, !output.isEmpty { text += " · \(Clone.lineCount(output))" }
    return text
  }

  func tick() {
    meta.text = styled(metaText(Date()), skin.ui(skin.claude ? 12 : 13), skin.faint)
  }

  func update(_ cell: ToolCell, live: Bool) {
    self.cell = cell
    self.live = live
    let running = cell.status == .running
    let unsuccessful = cell.status == .failed || (cell.exitCode.map { $0 != 0 } ?? false)
    let shown = open || !collapsed
    let tail = live && running
    icon.update(cell.status)
    name.text = styled(cell.name, skin.claude ? skin.ui(13.5, .medium) : .mono(13, .semibold), skin.text)
    title.text = styled(cell.title, skin.claude ? .mono(12.5) : skin.ui(13), skin.muted)
    title.gone = cell.title.isEmpty
    tick()
    if running, live {
      if timer == nil {
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.tick() } }
      }
    } else {
      timer?.invalidate()
      timer = nil
    }
    let inputText = Clone.trimmed(cell.input)
    let outputText = Clone.trimmed(cell.output)
    input.gone = !(shown && !inputText.isEmpty && (!nested || open || cell.body == .diff))
    if !input.gone {
      input.update(inputText, language: cell.body == .diff ? "diff" : cell.language, part: .input, limit: open ? nil : 12, tail: tail)
    }
    let showChildren = (shown || collapsed) && !cell.children.isEmpty
    rail?.gone = !showChildren
    children.gone = !showChildren
    if showChildren {
      var kept: [String: CellNode] = [:]
      children.set(cell.children.enumerated().map { index, child in
        let node = childNodes[child.callID] ?? CellNode(skin: skin, nested: true, collapsed: collapsed)
        node.update(child, live: live)
        if skin.claude { node.rules = index > 0 ? [(.top, skin.border, skin.hairline)] : [] }
        kept[child.callID] = node
        return node
      })
      childNodes = kept
    }
    output.gone = !(shown && !outputText.isEmpty && (!nested || open || unsuccessful))
    if !output.gone {
      output.update(outputText, language: cell.outputLanguage, part: unsuccessful ? .error : .output, limit: open ? nil : 10, tail: tail)
    }
    images.gone = !(shown && !cell.images.isEmpty)
    if !images.gone, images.items.count != cell.images.count {
      images.set(cell.images.map { ImageNode($0, maxHeight: 260) })
    }
  }

  override func removeFromSuperview() {
    timer?.invalidate()
    timer = nil
    super.removeFromSuperview()
  }
}
