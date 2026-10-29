import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#else
import UIKit
#endif

#if os(macOS)
final class InputText: NSTextView {
  var submit: (() -> Void)?

  override func doCommand(by selector: Selector) {
    if selector == #selector(insertNewline(_:)), !hasMarkedText(), !(NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false) {
      submit?()
      return
    }
    super.doCommand(by: selector)
  }

  override var mouseDownCanMoveWindow: Bool { false }
}
#endif

public final class InputNode: Node {
  public var onChange: (() -> Void)?
  public var onSubmit: (() -> Void)?
  public var line: CGFloat = 24
  public var maxLines = 10
  let hint = Label()
  var attributes: [NSAttributedString.Key: Any] = [:]
  #if os(macOS)
  let view: InputText
  let scroll = NSScrollView()
  let container: NSTextContainer
  let manager: NSLayoutManager
  #else
  let view = UITextView(usingTextLayoutManager: false)
  #endif

  public override init(frame: CGRect) {
    #if os(macOS)
    let storage = NSTextStorage()
    manager = NSLayoutManager()
    storage.addLayoutManager(manager)
    container = NSTextContainer(size: CGSize(width: 100, height: unbounded))
    container.lineFragmentPadding = 0
    container.widthTracksTextView = false
    manager.addTextContainer(container)
    view = InputText(frame: .zero, textContainer: container)
    view.isRichText = false
    view.allowsUndo = true
    view.drawsBackground = false
    view.textContainerInset = .zero
    view.isVerticallyResizable = true
    view.isHorizontallyResizable = false
    view.maxSize = CGSize(width: unbounded, height: unbounded)
    view.isAutomaticQuoteSubstitutionEnabled = false
    view.isAutomaticDashSubstitutionEnabled = false
    view.isAutomaticTextReplacementEnabled = false
    scroll.documentView = view
    scroll.drawsBackground = false
    scroll.borderType = .noBorder
    scroll.hasVerticalScroller = false
    scroll.autohidesScrollers = true
    scroll.scrollerStyle = .overlay
    scroll.verticalScrollElasticity = .none
    #else
    view.backgroundColor = .clear
    view.textContainerInset = .zero
    view.textContainer.lineFragmentPadding = 0
    view.isScrollEnabled = false
    #endif
    super.init(frame: frame)
    #if os(macOS)
    addSubview(scroll)
    view.submit = { [weak self] in self?.onSubmit?() }
    NotificationCenter.default.addObserver(forName: NSText.didChangeNotification, object: view, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated { self?.changed() }
    }
    #else
    addSubview(view)
    view.delegate = self
    #endif
    hint.isUserInteractionEnabledCompat = false
    hint.lines = 1
    addSubview(hint)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("created in code") }

  public var string: String {
    get { view.text ?? "" }
    set {
      let text = NSAttributedString(string: newValue, attributes: attributes)
      #if os(macOS)
      view.textStorage?.setAttributedString(text)
      view.setSelectedRange(NSRange(location: text.length, length: 0))
      #else
      view.attributedText = text
      #endif
      view.typingAttributes = attributes
      changed()
    }
  }

  public func configure(font: KitFont, color: KitColor, placeholder: String, placeholderColor: KitColor, caret: KitColor) {
    attributes = [.font: font, .foregroundColor: color, .paragraphStyle: paragraph(lineHeight: line),
                  .baselineOffset: baselineOffset(lineHeight: line, font: font)]
    view.typingAttributes = attributes
    #if os(macOS)
    view.font = font
    view.textColor = color
    view.insertionPointColor = caret
    view.defaultParagraphStyle = paragraph(lineHeight: line)
    if let storage = view.textStorage, storage.length > 0 { storage.setAttributes(attributes, range: NSRange(location: 0, length: storage.length)) }
    #else
    view.font = font
    view.textColor = color
    view.tintColor = caret
    if view.text.count > 0 { view.attributedText = NSAttributedString(string: view.text, attributes: attributes) }
    #endif
    hint.text = styled(placeholder, font, placeholderColor, lineHeight: line)
    invalidate()
  }

  func changed() {
    hint.isHidden = !string.isEmpty
    invalidate()
    onChange?()
  }

  public func focus() {
    #if os(macOS)
    window?.makeFirstResponder(view)
    #else
    view.becomeFirstResponder()
    #endif
  }

  #if os(macOS)
  public override func hitTest(_ point: NSPoint) -> NSView? {
    guard !isHidden, let superview, frame.contains(point) else { return nil }
    return scroll.hitTest(convert(point, from: superview)) ?? view
  }
  #endif

  public override func contentSize(_ width: CGFloat) -> CGSize {
    #if os(macOS)
    container.size = CGSize(width: max(1, width), height: unbounded)
    manager.ensureLayout(for: container)
    let natural = manager.usedRect(for: container).height
    #else
    let natural = view.sizeThatFits(CGSize(width: max(1, width), height: unbounded)).height
    #endif
    let height = min(max(line, ceil(natural)), line * CGFloat(maxLines))
    #if os(iOS)
    view.isScrollEnabled = natural > line * CGFloat(maxLines)
    #else
    scroll.hasVerticalScroller = natural > line * CGFloat(maxLines)
    #endif
    return CGSize(width: width, height: height)
  }

  public override func arrange(_ rect: CGRect) {
    #if os(macOS)
    scroll.frame = rect
    container.size = CGSize(width: max(1, rect.width), height: unbounded)
    view.minSize = CGSize(width: rect.width, height: rect.height)
    view.frame.size.width = rect.width
    view.sizeToFit()
    #else
    view.frame = rect
    #endif
    hint.place(CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: line))
    hint.isHidden = !string.isEmpty
  }
}

#if os(macOS)
extension NSTextView {
  var text: String? { string }
}
#else
extension InputNode: UITextViewDelegate {
  public func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
    if text == "\n" {
      onSubmit?()
      return false
    }
    return true
  }

  public func textViewDidChange(_ textView: UITextView) { changed() }
}
#endif

extension KitView {
  var isUserInteractionEnabledCompat: Bool {
    get {
      #if os(macOS)
      true
      #else
      isUserInteractionEnabled
      #endif
    }
    set {
      #if os(iOS)
      isUserInteractionEnabled = newValue
      #endif
    }
  }
}

struct Pending: Identifiable, Hashable {
  let id = UUID()
  var name: String
  var size: Int
  var image: String?
  var file: URL?

  static func load(_ urls: [URL]) -> [Pending] {
    urls.map { url in
      let scoped = url.startAccessingSecurityScopedResource()
      defer { if scoped { url.stopAccessingSecurityScopedResource() } }
      let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
      if let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .image), type != .svg, let data = try? Data(contentsOf: url) {
        return Pending(name: url.lastPathComponent, size: size, image: DataURL.encode(data))
      }
      return Pending(name: url.lastPathComponent, size: size, file: url)
    }
  }
}

final class Chip: Stack {
  init(skin: Skin, item: Pending, remove: @escaping () -> Void) {
    super.init(frame: .zero)
    axis = .horizontal
    spacing = 8
    align = .center
    padding = Insets(v: 6, h: 10)
    fill = skin.bubble
    stroke = skin.text.withAlphaComponent(0.12)
    radius = 12
    maxWidth = 260
    var nodes: [Node] = []
    if let image = item.image { nodes.append(ImageNode(image, cover: CGSize(width: 36, height: 36)).rounded(8)) }
    let name = Label(styled(item.name, skin.ui(13), skin.text), lines: 1)
    name.shrink = true
    nodes.append(name)
    nodes.append(Label(styled(Format.bytes(item.size), skin.ui(13), skin.faint), lines: 1))
    let close = Pressable(.horizontal, align: .center, [Label(styled("×", skin.ui(16), skin.faint))], action: remove)
    nodes.append(close)
    set(nodes)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("created in code") }
}

public final class ComposerNode: Stack {
  let skin: Skin
  public private(set) var chat: Chat
  public let input = InputNode()
  let chips = Flow()
  let attach = Pressable()
  let send = Pressable()
  let sendIcon: IconNode
  let model = Pressable()
  let modelLabel = Label()
  let modelChevron: IconNode
  var attachments: [Pending] = [] { didSet { renderChips() } }
  var picker: ClonePicker? { didSet { renderPicker() } }
  var openMenu: ((Node) -> Void)?
  var dragging = false { didSet { stroke = dragging ? skin.faint : ring; strokeWidth = dragging ? 2 : 0.5 } }
  var ring: KitColor
  #if os(iOS)
  var picking: Picking?
  #endif

  public init(skin: Skin, chat: Chat) {
    self.skin = skin
    self.chat = chat
    sendIcon = IconNode(.arrowUp, size: skin.claude ? 18 : 20, color: skin.sendText)
    modelChevron = IconNode(.chevron, color: skin.muted)
    ring = .dynamic(light: KitColor(white: 0, alpha: skin.claude ? 0.12 : 0.1), dark: KitColor(white: 1, alpha: skin.claude ? 0.12 : 0.14))
    super.init(frame: .zero)
    axis = .vertical
    align = .fill
    fill = skin.composer
    stroke = ring
    strokeWidth = 0.5
    chips.spacing = 8
    attach.set([IconNode(.plus, color: skin.text)])
    attach.justify = .center
    attach.action = { [weak self] in self?.pick() }
    send.set([sendIcon])
    send.justify = .center
    send.action = { [weak self] in self?.submit() }
    input.onSubmit = { [weak self] in self?.submit() }
    input.onChange = { [weak self] in self?.refresh() }
    input.grow = 1
    if skin.claude {
      radius = 20
      spacing = 6
      padding = Insets(top: 14, left: 16, bottom: 10, right: 12)
      attach.fixedWidth = 32
      attach.fixedHeight = 32
      attach.radius = 10
      attach.stroke = skin.text.withAlphaComponent(0.15)
      attach.hoverFill = skin.hover
      send.fixedWidth = 32
      send.fixedHeight = 32
      send.radius = 10
      send.fill = skin.send
      model.set([modelLabel, modelChevron])
      model.spacing = 2
      model.padding = Insets(v: 6, h: 8)
      model.radius = 8
      model.hoverFill = skin.hover
      model.action = { [weak self] in
        guard let self else { return }
        self.openMenu?(self.model)
      }
      model.onHover = { [weak self] _ in self?.renderPicker() }
      modelLabel.lines = 1
      let row = Stack(.horizontal, spacing: 8, align: .center, [attach, Spacer(), model, send])
      set([chips, input, row])
    } else {
      radius = 28
      padding = Insets(v: 10, h: 10)
      chips.padding = Insets(top: 4, left: 10, bottom: 6)
      attach.fixedWidth = 36
      attach.fixedHeight = 36
      attach.radius = 18
      attach.hoverFill = skin.bubble
      send.fixedWidth = 36
      send.fixedHeight = 36
      send.radius = 18
      input.padding = Insets(v: 6, h: 0)
      let row = Stack(.horizontal, spacing: 8, align: .end, [attach, input, send])
      set([chips, row])
    }
    shadowed()
    renderChips()
    renderPicker()
    refresh()
    #if os(macOS)
    registerForDraggedTypes([.fileURL])
    #endif
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("created in code") }

  public func attach(_ chat: Chat) {
    self.chat = chat
    refresh()
  }

  var empty: Bool { input.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && attachments.isEmpty }

  public func refresh() {
    let pending = chat.pending || !chat.live.isEmpty
    let stopping = pending && empty
    let disabled = !stopping && empty
    let placeholder = skin.claude ? (pending ? "Add to the response…" : "How can I help you today?") : (pending ? "Steer the response" : "Ask anything")
    if input.hint.text.string != placeholder {
      input.configure(font: skin.ui(16), color: skin.text, placeholder: placeholder, placeholderColor: skin.faint, caret: skin.text)
    }
    sendIcon.glyph = stopping ? .stop : .arrowUp
    sendIcon.size = stopping ? 14 : skin.claude ? 18 : 20
    send.enabled = !disabled
    if skin.claude {
      send.alphaValueCompat = disabled ? 0.45 : 1
    } else {
      send.fill = disabled ? skin.sendOff : skin.send
    }
  }

  func renderChips() {
    chips.set(attachments.map { item in Chip(skin: skin, item: item) { [weak self] in self?.attachments.removeAll { $0.id == item.id } } })
    chips.gone = attachments.isEmpty
    refresh()
  }

  func renderPicker() {
    guard skin.claude else { return }
    let current = picker.flatMap { picker in picker.models.first { $0.id == picker.current } ?? picker.models.first }
    model.gone = current == nil
    let color = model.hovering ? skin.text : skin.muted
    modelLabel.text = styled(current?.label ?? "", skin.ui(13.5), color)
    modelChevron.color = color
  }

  public func submit() {
    if chat.pending, empty {
      Task { await chat.stop() }
      return
    }
    guard !empty else { return }
    let prompt = input.string.trimmingCharacters(in: .whitespacesAndNewlines)
    let images = attachments.compactMap(\.image)
    let files = attachments.compactMap(\.file)
    input.string = ""
    attachments = []
    let target = chat
    Task { await target.send(prompt, images: images, files: files) }
  }

  public func focus() { input.focus() }

  #if os(macOS)
  public override func mouseDown(with event: NSEvent) { input.focus() }
  #else
  public override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { input.focus() }
  #endif

  func add(_ urls: [URL]) {
    attachments += Pending.load(urls)
  }

  func shadowed() {
    let dark: Bool
    #if os(macOS)
    dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    guard let layer else { return }
    layer.shadowOffset = CGSize(width: 0, height: -4)
    #else
    dark = traitCollection.userInterfaceStyle == .dark
    layer.shadowOffset = CGSize(width: 0, height: 4)
    #endif
    layer.shadowColor = CGColor(gray: 0, alpha: 1)
    layer.shadowOpacity = Float(skin.claude ? (dark ? 0.25 : 0.05) : (dark ? 0.4 : 0.08))
    layer.shadowRadius = skin.claude ? 10 : 8
  }

  public override func appearanceChanged() {
    super.appearanceChanged()
    shadowed()
  }

  func pick() {
    #if os(macOS)
    let panel = NSOpenPanel()
    panel.allowsMultipleSelection = true
    panel.canChooseDirectories = false
    if let window {
      panel.beginSheetModal(for: window) { [weak self] response in
        if response == .OK { self?.add(panel.urls) }
      }
    } else if panel.runModal() == .OK {
      add(panel.urls)
    }
    #else
    var responder: UIResponder? = self
    while let next = responder, !(next is UIViewController) { responder = next.next }
    guard let controller = responder as? UIViewController else { return }
    let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true)
    picker.allowsMultipleSelection = true
    let picking = Picking { [weak self] urls in self?.add(urls) }
    picker.delegate = picking
    self.picking = picking
    controller.present(picker, animated: true)
    #endif
  }

  #if os(macOS)
  public override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
    dragging = true
    return .copy
  }

  public override func draggingExited(_ sender: NSDraggingInfo?) { dragging = false }

  public override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
    dragging = false
    let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    add(urls)
    return !urls.isEmpty
  }
  #endif
}

#if os(iOS)
final class Picking: NSObject, UIDocumentPickerDelegate {
  let done: ([URL]) -> Void
  init(_ done: @escaping ([URL]) -> Void) { self.done = done }
  func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) { done(urls) }
}
#endif
