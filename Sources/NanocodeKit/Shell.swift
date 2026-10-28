#if os(macOS)
import AppKit
#else
import UIKit
#endif

public struct CloneModel: Hashable, Sendable {
  public var id: String
  public var label: String
  public var detail: String?

  public init(id: String, label: String, detail: String? = nil) {
    self.id = id
    self.label = label
    self.detail = detail
  }
}

public struct ClonePicker {
  public var models: [CloneModel]
  public var current: String
  public var bound: Bool
  public var choose: @MainActor (String) -> Void

  public init(models: [CloneModel], current: String, bound: Bool = false, choose: @escaping @MainActor (String) -> Void) {
    self.models = models
    self.current = current
    self.bound = bound
    self.choose = choose
  }
}

public struct CloneConversation: Hashable, Sendable {
  public var id: String
  public var title: String

  public init(id: String, title: String) {
    self.id = id
    self.title = title
  }
}

public struct CloneProps {
  public var conversations: [CloneConversation] = []
  public var current: String?
  public var canCreate = true
  public var canSelect = true
  public var create: @MainActor () -> Void = {}
  public var select: @MainActor (String) -> Void = { _ in }
  public var remove: @MainActor (String) -> Void = { _ in }
  public var picker: ClonePicker?
  public var title: String?
  public var heading: String?
  public var prompts: [String] = []
  public var actions: [Node] = []
  public var sidebar: Node?
  public var footer: String?
  public var titlebarInset: CGFloat = 0

  public init() {}
}

public final class ClonePill: Pressable {
  let skin: Skin
  let label = Label()

  public init(skin: Skin, title: String, wraps: Bool = false, action: @escaping @MainActor () -> Void) {
    self.skin = skin
    self.wraps = wraps
    super.init(frame: .zero)
    axis = .horizontal
    align = .center
    padding = Insets(v: 6, h: 12)
    radius = 999
    stroke = skin.border
    hoverFill = KitColor(white: 0.5, alpha: 0.12)
    label.lines = wraps ? 0 : 1
    set([label])
    self.action = action
    self.title = title
    label.text = text(title)
  }

  let wraps: Bool

  func text(_ title: String) -> NSAttributedString {
    styled(title, skin.ui(13), skin.text, lineHeight: wraps ? 18 : nil, alignment: wraps ? .center : .natural)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("created in code") }

  public var title = "" {
    didSet { label.text = text(title) }
  }
}

@MainActor
func iconButton(_ glyph: Glyph, skin: Skin, size: CGFloat, action: @escaping () -> Void) -> Pressable {
  let icon = IconNode(glyph, color: skin.muted)
  let button = Pressable(.horizontal, align: .center, [icon], action: action)
  button.justify = .center
  button.fixedWidth = size
  button.fixedHeight = size
  button.radius = 8
  button.hoverFill = skin.hover
  return button
}

func footerText(_ markdown: String, skin: Skin) -> NSAttributedString {
  let text = NSMutableAttributedString(attributedString: Rich.inline(markdown, skin: skin, font: skin.ui(12), color: skin.faint, lineHeight: 18, prose: false))
  let style = NSMutableParagraphStyle()
  style.alignment = .center
  style.minimumLineHeight = 18
  style.maximumLineHeight = 18
  text.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: text.length))
  return text
}

final class Hero: Stack {
  var ratio: CGFloat = 0.12

  override func arrange(_ rect: CGRect) {
    super.arrange(CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height * (1 - ratio)))
  }
}

public final class ConversationNode: Stack {
  public let skin: Skin
  public private(set) var chat: Chat
  public let composer: ComposerNode
  public var props = CloneProps() { didSet { renderProps() } }
  public var wide: Bool? { didSet { if wide != oldValue { renderProps() } } }
  let hero = Hero()
  let heading = Label()
  let spark = Label()
  let headingRow = Stack(.horizontal, spacing: 12, align: .center)
  let prompts = Flow()
  let heroFooter = TextNode()
  let log: LogNode
  let scroll: ScrollNode
  let bottom = Stack(.vertical, spacing: 0, align: .fill)
  let bottomFooter = TextNode()
  var observer: Observer?
  var empty: Bool?

  public init(skin: Skin, chat: Chat) {
    self.skin = skin
    self.chat = chat
    composer = ComposerNode(skin: skin, chat: chat)
    log = LogNode(skin: skin)
    scroll = ScrollNode(log)
    super.init(frame: .zero)
    axis = .vertical
    align = .fill
    scroll.sticks = true
    scroll.grow = 1
    hero.axis = .vertical
    hero.align = .center
    hero.justify = .center
    hero.grow = 1
    hero.padding = Insets(v: 0, h: 16)
    hero.ratio = skin.claude ? 0.14 : 0.12
    prompts.spacing = 8
    prompts.centered = true
    prompts.maxWidth = 720
    prompts.spaceBefore = 12
    heroFooter.spaceBefore = skin.claude ? 18 : 16
    bottomFooter.spaceBefore = 8
    heroFooter.balanced = true
    bottomFooter.balanced = true
    bottom.maxWidth = skin.column
    bottom.padding = Insets(top: 0, left: 16, bottom: 8, right: 16)
    composer.maxWidth = skin.claude ? 680 : 768
    if skin.claude {
      spark.text = styled("✻", .systemFont(ofSize: 36), skin.spark)
      headingRow.set([spark, heading])
      headingRow.padding = Insets(bottom: 28)
    } else {
      headingRow.set([heading])
      headingRow.padding = Insets(bottom: 28)
    }
    holder.set([bottom])
    holder.gone = true
    set([hero, scroll, holder])
    renderProps()
    observe()
  }

  let holder = Stack(.vertical, spacing: 0, align: .center)

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("created in code") }

  public func attach(_ chat: Chat) {
    self.chat = chat
    composer.attach(chat)
    observe()
  }

  func observe() {
    observer?.cancel()
    observer = Observer { [weak self] in self?.render() }
  }

  var isWide: Bool { wide ?? (bounds.width >= 768) }

  func renderProps() {
    let title = props.heading ?? (skin.claude ? Clone.greeting() : "What can I help with?")
    heading.text = skin.claude
      ? styled(title, .serif(isWide ? 40 : 30, light: true), skin.text, kern: isWide ? -0.8 : -0.6)
      : styled(title, skin.ui(isWide ? 28 : 24), skin.text, alignment: .center, kern: -0.28)
    spark.text = styled("✻", .systemFont(ofSize: isWide ? 36 : 28), skin.spark)
    prompts.set(props.prompts.map { prompt in
      let pill = ClonePill(skin: skin, title: prompt, wraps: true) { [weak self] in
        guard let self else { return }
        let chat = self.chat
        Task { await chat.send(prompt) }
      }
      pill.padding = Insets(v: 7, h: 12)
      return pill
    })
    prompts.gone = props.prompts.isEmpty
    let footer = props.footer.map { footerText($0, skin: skin) } ?? NSAttributedString()
    heroFooter.text = footer
    bottomFooter.text = footer
    heroFooter.gone = props.footer == nil
    bottomFooter.gone = props.footer == nil
    composer.picker = props.picker
    render()
  }

  func render() {
    let turns = chat.turns
    let isEmpty = turns.isEmpty
    if isEmpty != empty {
      empty = isEmpty
      if isEmpty {
        bottom.set([])
        hero.set([headingRow, composer, prompts, heroFooter])
      } else {
        hero.set([])
        bottom.set([composer, bottomFooter])
      }
      hero.gone = !isEmpty
      scroll.gone = isEmpty
      holder.gone = isEmpty
    }
    _ = chat.pending
    _ = chat.error
    _ = chat.waiting
    log.update(chat, wide: isWide)
    composer.refresh()
  }

}

final class ChatRow: Hoverable {
  let skin: Skin
  let title = Label()
  let open = Pressable()
  let trash: Pressable
  var current = false { didSet { paint() } }
  var narrow = false { didSet { paint() } }

  init(skin: Skin, item: CloneConversation, select: @escaping () -> Void, remove: @escaping () -> Void) {
    self.skin = skin
    trash = Pressable(.horizontal, align: .center, [IconNode(.trash, color: skin.muted)], action: remove)
    super.init(frame: .zero)
    axis = .horizontal
    align = .center
    radius = skin.claude ? 8 : 10
    hoverFill = skin.hover
    title.lines = 1
    title.grow = 1
    open.set([title])
    open.grow = 1
    open.padding = skin.claude ? Insets(v: 7, h: 8) : Insets(v: 8, h: 10)
    open.action = select
    trash.padding = Insets(6)
    trash.radius = skin.claude ? 0 : 6
    trash.onHover = { [weak self] hovering in
      guard let self else { return }
      (self.trash.items.first as? IconNode)?.color = hovering ? skin.danger : skin.muted
    }
    onHover = { [weak self] _ in self?.paint() }
    set([open, trash])
    self.item = item
    title.text = styled(item.title.isEmpty ? "New chat" : item.title, skin.ui(14), skin.text)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("created in code") }

  var item: CloneConversation? {
    didSet { title.text = styled(item.map { $0.title.isEmpty ? "New chat" : $0.title } ?? "", skin.ui(14), skin.text) }
  }

  func paint() {
    fill = current ? skin.hover : nil
    trash.alphaValueCompat = hovering || narrow ? 1 : 0
  }
}

final class SidebarNode: Stack {
  let skin: Skin
  let top = Stack(.horizontal, spacing: 8, align: .center)
  let newChat: Pressable
  let section = Label()
  let list = Stack(.vertical, spacing: 1, align: .fill)
  let scroll: ScrollNode
  let close: Pressable
  let compose: Pressable
  let brand = Label()
  var rows: [String: ChatRow] = [:]
  var extra: Node?
  var onToggle: () -> Void = {}
  var onCreate: () -> Void = {}

  init(skin: Skin) {
    self.skin = skin
    scroll = ScrollNode(list)
    var toggle: () -> Void = {}
    var create: () -> Void = {}
    close = iconButton(.sidebar, skin: skin, size: skin.claude ? 34 : 36) { toggle() }
    compose = iconButton(.compose, skin: skin, size: 36) { create() }
    if skin.claude {
      let plus = IconNode(.plus, size: 16, color: KitColor(hex: 0xffffff))
      let circle = Stack(.horizontal, spacing: 0, align: .center, [plus])
      circle.justify = .center
      circle.fixedWidth = 26
      circle.fixedHeight = 26
      circle.radius = 13
      circle.fill = skin.accent
      newChat = Pressable(.horizontal, spacing: 10, align: .center, [circle, Label(styled("New chat", skin.ui(14, .medium), skin.accent))])
      newChat.padding = Insets(v: 6, h: 8)
    } else {
      newChat = Pressable(.horizontal, spacing: 10, align: .center, [IconNode(.compose, color: skin.text), Label(styled("New chat", skin.ui(14), skin.text))])
      newChat.padding = Insets(v: 8, h: 10)
    }
    super.init(frame: .zero)
    toggle = { [weak self] in self?.onToggle() }
    create = { [weak self] in self?.onCreate() }
    newChat.action = { [weak self] in self?.onCreate() }
    newChat.radius = 10
    newChat.hoverFill = skin.hover
    axis = .vertical
    align = .fill
    spacing = 2
    fill = skin.sidebar
    padding = Insets(skin.claude ? 10 : 8)
    if skin.claude {
      rules = [(.right, skin.border, skin.hairline)]
      top.set([close, brand])
      top.padding = Insets(bottom: 10)
      section.text = styled("Recents", skin.ui(12, .medium), skin.faint)
      section.padding = Insets(top: 20, left: 8, bottom: 6, right: 8)
    } else {
      top.set([close, Spacer(), compose])
      top.padding = Insets(bottom: 8)
      section.text = styled("Chats", skin.ui(14), skin.faint)
      section.padding = Insets(top: 18, left: 10, bottom: 6, right: 10)
    }
    scroll.grow = 1
    set([top, newChat, section, scroll])
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("created in code") }

  func update(_ props: CloneProps, narrow: Bool) {
    top.padding.left = props.titlebarInset
    brand.text = styled(props.title ?? "Claude", .serif(19), skin.text, kern: -0.19)
    brand.lines = 1
    brand.shrink = true
    newChat.enabled = props.canCreate
    compose.enabled = props.canCreate
    var kept: [String: ChatRow] = [:]
    list.set(props.conversations.map { item in
      let row = rows[item.id] ?? ChatRow(skin: skin, item: item, select: { props.select(item.id) }, remove: { props.remove(item.id) })
      if row.item != item { row.item = item }
      row.open.action = { [weak self] in
        props.select(item.id)
        if narrow { self?.onToggle() }
      }
      row.trash.action = { props.remove(item.id) }
      row.current = item.id == props.current
      row.narrow = narrow
      kept[item.id] = row
      return row
    })
    rows = kept
    if extra !== props.sidebar {
      extra = props.sidebar
      set([top, newChat, section, scroll] + (props.sidebar.map { [$0] } ?? []))
    }
  }
}

final class ModelList: Stack {
  init(skin: Skin, picker: ClonePicker, close: @escaping () -> Void) {
    super.init(frame: .zero)
    axis = .vertical
    align = .fill
    padding = Insets(6)
    fill = skin.menu
    radius = skin.claude ? 14 : 16
    stroke = .dynamic(light: KitColor(white: 0, alpha: skin.claude ? 0.12 : 0.2), dark: KitColor(white: 1, alpha: skin.claude ? 0.12 : 0.2))
    strokeWidth = 0.5
    fixedWidth = skin.claude ? 280 : 300
    var nodes: [Node] = []
    if !skin.claude {
      let title = Label(styled("Model", skin.ui(13), skin.faint))
      title.padding = Insets(v: 6, h: 10)
      nodes.append(title)
    }
    for model in picker.models {
      let text = Stack(.vertical, spacing: 0, align: .fill, [
        Label(styled(model.label, skin.ui(14, .medium), skin.text), lines: 1),
        Label(styled(model.detail ?? model.id, skin.ui(skin.claude ? 12.5 : 13), skin.muted), lines: 1),
      ])
      text.grow = 1
      let check = IconNode(.check, color: skin.claude ? skin.accent : skin.text)
      check.gone = model.id != picker.current
      let item = Pressable(.horizontal, spacing: 8, align: .center, [text, check]) {
        picker.choose(model.id)
        close()
      }
      item.padding = Insets(v: 8, h: 10)
      item.radius = skin.claude ? 8 : 10
      item.hoverFill = skin.hover
      nodes.append(item)
    }
    if picker.bound {
      let note = Label(styled("This chat keeps its model. Another model starts a new chat.", skin.ui(12), skin.muted, lineHeight: 17))
      note.padding = Insets(top: 8, left: 10, bottom: 4, right: 10)
      note.rules = [(.top, skin.border, skin.hairline)]
      note.spaceBefore = 6
      nodes.append(note)
    }
    set(nodes)
    #if os(macOS)
    layer?.shadowOffset = CGSize(width: 0, height: -4)
    layer?.shadowColor = CGColor(gray: 0, alpha: 1)
    layer?.shadowOpacity = skin.claude ? 0.08 : 0.12
    layer?.shadowRadius = skin.claude ? 10 : 8
    #else
    layer.shadowOffset = CGSize(width: 0, height: 4)
    layer.shadowColor = CGColor(gray: 0, alpha: 1)
    layer.shadowOpacity = skin.claude ? 0.08 : 0.12
    layer.shadowRadius = skin.claude ? 10 : 8
    #endif
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("created in code") }
}

final class MenuOverlay: Node {
  let list: ModelList
  let catcher = Pressable()
  weak var anchor: Node?
  let above: Bool

  init(list: ModelList, anchor: Node, above: Bool, close: @escaping () -> Void) {
    self.list = list
    self.anchor = anchor
    self.above = above
    super.init(frame: .zero)
    catcher.action = close
    addSubview(catcher)
    addSubview(list)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("created in code") }

  override func arrange(_ rect: CGRect) {
    catcher.place(bounds)
    guard let anchor else { return }
    let box = anchor.convert(anchor.bounds, to: self)
    let size = list.measure(rect.width)
    let x = above ? box.maxX - size.width : box.minX
    let y = above ? box.minY - 6 - size.height : box.maxY + 4
    list.place(CGRect(x: max(8, min(x, rect.width - size.width - 8)), y: max(8, y), width: size.width, height: size.height))
  }
}

public final class CloneNode: Node {
  public let skin: Skin
  public var props: CloneProps { didSet { conversation.props = props; render() } }
  public let conversation: ConversationNode
  let sidebar: SidebarNode
  let header = Stack(.horizontal)
  let open: Pressable
  let new: Pressable
  let titleLabel = Label()
  let model = Pressable()
  let modelLabel = Label()
  let modelChevron: IconNode
  let lead = Spacer()
  let trail = Spacer()
  let main = Stack(.vertical)
  let scrim = Pressable()
  var overlay: MenuOverlay?
  var sidebarOpen: Bool?
  var wide = true
  var observer: Observer?

  public init(skin: Skin, chat: Chat, props: CloneProps) {
    self.skin = skin
    self.props = props
    conversation = ConversationNode(skin: skin, chat: chat)
    sidebar = SidebarNode(skin: skin)
    var toggle: () -> Void = {}
    var create: () -> Void = {}
    open = iconButton(.sidebar, skin: skin, size: skin.claude ? 34 : 36) { toggle() }
    new = iconButton(skin.claude ? .plus : .compose, skin: skin, size: skin.claude ? 34 : 36) { create() }
    modelChevron = IconNode(.chevron, color: skin.faint)
    super.init(frame: .zero)
    toggle = { [weak self] in self?.toggle() }
    create = { [weak self] in self?.create() }
    fill = skin.bg
    sidebar.onToggle = { [weak self] in self?.toggle() }
    sidebar.onCreate = { [weak self] in self?.create() }
    scrim.fill = KitColor(white: 0, alpha: skin.claude ? 0.35 : 0.4)
    scrim.action = { [weak self] in self?.toggle() }
    model.set([modelLabel, modelChevron])
    model.spacing = 4
    model.padding = Insets(v: 6, h: 10)
    model.radius = 10
    model.hoverFill = skin.hover
    model.action = { [weak self] in
      guard let self else { return }
      self.showMenu(self.model, above: false)
    }
    modelLabel.lines = 1
    titleLabel.lines = 1
    header.align = .center
    header.fixedHeight = 52
    header.spacing = skin.claude ? 6 : 4
    conversation.grow = 1
    conversation.composer.openMenu = { [weak self] anchor in self?.showMenu(anchor, above: true) }
    main.set([header, conversation])
    addSubview(main)
    addSubview(scrim)
    addSubview(sidebar)
    conversation.props = props
    render()
    observer = Observer { [weak self] in
      guard let self else { return }
      _ = self.conversation.chat.entries.isEmpty
      self.renderHeader()
    }
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("created in code") }

  public func attach(_ chat: Chat) {
    conversation.attach(chat)
    observer?.cancel()
    observer = Observer { [weak self] in
      guard let self else { return }
      _ = self.conversation.chat.entries.isEmpty
      self.renderHeader()
    }
  }

  var isOpen: Bool { sidebarOpen ?? wide }

  func toggle() {
    sidebarOpen = !isOpen
    render()
    invalidate()
  }

  func create() {
    props.create()
    if !wide { sidebarOpen = false; render() }
  }

  func render() {
    sidebar.update(props, narrow: !wide)
    renderHeader()
  }

  func renderHeader() {
    let edge = !isOpen || !wide
    open.gone = !edge
    new.gone = !edge
    new.enabled = props.canCreate
    var nodes: [Node] = [open]
    if skin.claude {
      let current = props.conversations.first { $0.id == props.current }?.title
      let empty = conversation.chat.entries.isEmpty
      titleLabel.text = styled(empty ? " " : (current?.isEmpty == false ? current! : "New chat"), skin.ui(14), skin.text, alignment: .center)
      titleLabel.grow = 1
      nodes += [titleLabel] + props.actions + [new]
      header.padding = Insets(top: 0, left: 10 + (edge ? props.titlebarInset : 0), bottom: 0, right: 10)
    } else {
      if let picker = props.picker, let current = picker.models.first(where: { $0.id == picker.current }) ?? picker.models.first {
        modelLabel.text = styled(current.label, skin.ui(18), skin.text)
        nodes += [wide ? Node() : lead, model]
      } else {
        titleLabel.text = styled(props.title ?? "ChatGPT", skin.ui(18), skin.text)
        titleLabel.grow = 0
        titleLabel.padding = Insets(v: 6, h: 10)
        nodes += [wide ? Node() : lead, titleLabel]
      }
      nodes += props.actions + [trail, new]
      header.padding = Insets(top: 0, left: 8 + (edge ? props.titlebarInset : 0), bottom: 0, right: 8)
    }
    header.set(nodes.filter { !($0 is Spacer && $0 === lead && wide) })
    conversation.wide = wide
  }

  func showMenu(_ anchor: Node, above: Bool) {
    guard let picker = props.picker else { return }
    closeMenu()
    let overlay = MenuOverlay(list: ModelList(skin: skin, picker: picker) { [weak self] in self?.closeMenu() }, anchor: anchor, above: above) { [weak self] in
      self?.closeMenu()
    }
    self.overlay = overlay
    addSubview(overlay)
    overlay.place(bounds)
  }

  func closeMenu() {
    overlay?.removeFromSuperview()
    overlay = nil
  }

  #if os(iOS)
  var keyboard: CGFloat = 0 { didSet { if keyboard != oldValue { markNeedsLayout() } } }
  var watching = false

  public override func didMoveToWindow() {
    super.didMoveToWindow()
    guard !watching, window != nil else { return }
    watching = true
    NotificationCenter.default.addObserver(forName: UIResponder.keyboardWillChangeFrameNotification, object: nil, queue: .main) { [weak self] note in
      let frame = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect) ?? .zero
      MainActor.assumeIsolated {
        guard let self, let window = self.window else { return }
        let local = self.convert(frame, from: window.screen.coordinateSpace)
        self.keyboard = max(0, self.bounds.maxY - local.minY)
      }
    }
    NotificationCenter.default.addObserver(forName: UIResponder.keyboardWillHideNotification, object: nil, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated { self?.keyboard = 0 }
    }
  }

  public override func safeAreaInsetsDidChange() {
    super.safeAreaInsetsDidChange()
    markNeedsLayout()
  }
  #endif

  var safe: Insets {
    #if os(iOS)
    Insets(top: safeAreaInsets.top, left: safeAreaInsets.left, bottom: max(safeAreaInsets.bottom, keyboard), right: safeAreaInsets.right)
    #else
    .zero
    #endif
  }

  public override func arrange(_ rect: CGRect) {
    let nowWide = bounds.width >= 768
    if nowWide != wide {
      wide = nowWide
      sidebarOpen = nil
      render()
    }
    let inset = safe
    let area = CGRect(x: inset.left, y: inset.top, width: bounds.width - inset.horizontal, height: bounds.height - inset.vertical)
    let width: CGFloat = wide ? (skin.claude ? 288 : 260) : min(300, bounds.width * 0.85)
    if wide {
      scrim.gone = true
      sidebar.gone = !isOpen
      let offset = isOpen ? width : 0
      if isOpen { sidebar.place(CGRect(x: area.minX, y: area.minY, width: width, height: area.height)) }
      main.place(CGRect(x: area.minX + offset, y: area.minY, width: area.width - offset, height: area.height))
    } else {
      main.place(area)
      scrim.gone = !isOpen
      sidebar.gone = !isOpen
      if isOpen {
        scrim.place(bounds)
        sidebar.place(CGRect(x: 0, y: 0, width: width + inset.left, height: bounds.height))
        sidebar.padding = Insets(top: inset.top + (skin.claude ? 10 : 8), left: inset.left + (skin.claude ? 10 : 8), bottom: inset.bottom + (skin.claude ? 10 : 8), right: skin.claude ? 10 : 8)
      }
    }
    overlay?.place(bounds)
  }
}

open class CloneViewController: KitViewController {
  public let clone: CloneNode

  public init(skin: Skin, chat: Chat, props: CloneProps) {
    clone = CloneNode(skin: skin, chat: chat, props: props)
    super.init(nibName: nil, bundle: nil)
  }

  @available(*, unavailable)
  public required init?(coder: NSCoder) { fatalError("created in code") }

  open override func loadView() {
    #if os(macOS)
    clone.frame = CGRect(x: 0, y: 0, width: 1100, height: 760)
    #endif
    view = clone
  }

  #if os(macOS)
  open override func viewDidAppear() {
    super.viewDidAppear()
    clone.conversation.composer.focus()
  }
  #else
  open override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    clone.conversation.composer.focus()
  }
  #endif
}

open class NanocodeChatViewController: KitViewController {
  public let conversation: ConversationNode

  public init(chat: Chat, skin: Skin = .chatgpt, props: CloneProps = CloneProps()) {
    conversation = ConversationNode(skin: skin, chat: chat)
    conversation.fill = skin.bg
    conversation.props = props
    super.init(nibName: nil, bundle: nil)
  }

  @available(*, unavailable)
  public required init?(coder: NSCoder) { fatalError("created in code") }

  open override func loadView() {
    #if os(macOS)
    conversation.frame = CGRect(x: 0, y: 0, width: 760, height: 640)
    #endif
    view = conversation
  }

  #if os(macOS)
  open override func viewDidAppear() {
    super.viewDidAppear()
    conversation.composer.focus()
  }
  #else
  open override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    conversation.composer.focus()
  }
  #endif
}
