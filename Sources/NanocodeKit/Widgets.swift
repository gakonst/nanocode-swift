#if os(macOS)
import AppKit
#else
import UIKit
#endif

open class Hoverable: Stack {
  public var hoverFill: KitColor? { didSet { redraw() } }
  public var onHover: ((Bool) -> Void)?
  public var enabled = true { didSet { if enabled != oldValue { redraw(); onHover?(hovering && enabled) } } }
  public internal(set) var hovering = false {
    didSet { if hovering != oldValue { redraw(); onHover?(hovering && enabled) } }
  }

  open override var currentFill: KitColor? {
    hovering && enabled && hoverFill != nil ? hoverFill : fill
  }

  #if os(macOS)
  private var tracking: NSTrackingArea?

  open override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let tracking { removeTrackingArea(tracking) }
    let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
    addTrackingArea(area)
    tracking = area
  }

  open override func mouseEntered(with event: NSEvent) { hovering = true }
  open override func mouseExited(with event: NSEvent) { hovering = false }
  #else
  override func setup() {
    super.setup()
    addGestureRecognizer(UIHoverGestureRecognizer(target: self, action: #selector(hovered(_:))))
  }

  @objc func hovered(_ recognizer: UIHoverGestureRecognizer) {
    hovering = recognizer.state == .began || recognizer.state == .changed
  }
  #endif
}

open class Pressable: Hoverable {
  public var action: (() -> Void)?

  override func setup() {
    super.setup()
    axis = .horizontal
    align = .center
  }

  public convenience init(_ axis: Axis = .horizontal, spacing: CGFloat = 0, align: Align = .center, _ items: [Node] = [], action: (() -> Void)? = nil) {
    self.init(axis, spacing: spacing, align: align, items)
    self.action = action
  }

  #if os(macOS)
  open override func hitTest(_ point: NSPoint) -> NSView? {
    guard !isHidden, let superview else { return nil }
    return bounds.contains(convert(point, from: superview)) ? self : nil
  }

  open override var mouseDownCanMoveWindow: Bool { false }
  open override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
  open override func mouseDown(with event: NSEvent) {}

  open override func mouseUp(with event: NSEvent) {
    guard enabled, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
    action?()
  }
  #else
  open override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
    !isHidden && isUserInteractionEnabled && self.point(inside: point, with: event) ? self : nil
  }

  open override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) { hovering = true }
  open override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { hovering = false }

  open override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
    hovering = false
    guard enabled, let touch = touches.first, bounds.contains(touch.location(in: self)) else { return }
    action?()
  }
  #endif
}

public enum Glyph: Sendable {
  case arrowUp, chevron, check, compose, plus, sidebar, trash, stop

  var path: String {
    switch self {
    case .arrowUp: "M12 19V5M5 12l7-7 7 7"
    case .chevron: "M6 9l6 6 6-6"
    case .check: "M5 12.5l4.5 4.5L19 7.5"
    case .compose: "M12 4H6a2 2 0 0 0-2 2v12a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2v-6M17.5 3.5a2.1 2.1 0 0 1 3 3L12 15l-4 1 1-4z"
    case .plus: "M12 5v14M5 12h14"
    case .sidebar: "M6 4h12a3 3 0 0 1 3 3v10a3 3 0 0 1-3 3H6a3 3 0 0 1-3-3V7a3 3 0 0 1 3-3zM9 4v16"
    case .trash: "M4 7h16M10 11v6M14 11v6M6 7l1 12a2 2 0 0 0 2 2h6a2 2 0 0 0 2-2l1-12M9 7V4h6v3"
    case .stop: ""
    }
  }

  public var size: CGFloat {
    switch self {
    case .chevron, .trash: 16
    case .check: 18
    case .stop: 14
    default: 20
    }
  }

  @MainActor static var paths: [String: CGPath] = [:]

  @MainActor var cgPath: CGPath {
    if let cached = Glyph.paths[path] { return cached }
    let parsed = SVG.parse(path)
    Glyph.paths[path] = parsed
    return parsed
  }
}

enum SVG {
  static func tokens(_ d: String) -> [String] {
    let expression = try! NSRegularExpression(pattern: #"[A-Za-z]|-?(?:\d+\.?\d*|\.\d+)"#)
    return expression.matches(in: d, range: NSRange(d.startIndex..., in: d)).map { String(d[Range($0.range, in: d)!]) }
  }

  static func parse(_ d: String) -> CGPath {
    let path = CGMutablePath()
    let tokens = tokens(d)
    var index = 0
    var command: Character = "M"
    var point = CGPoint.zero
    var start = CGPoint.zero
    func number() -> CGFloat {
      defer { index += 1 }
      return CGFloat(Double(tokens[index]) ?? 0)
    }
    while index < tokens.count {
      if let letter = tokens[index].first, letter.isLetter {
        command = letter
        index += 1
        if command == "z" || command == "Z" {
          path.closeSubpath()
          point = start
          continue
        }
      }
      let relative = command.isLowercase
      let base = relative ? point : .zero
      switch command {
      case "M", "m":
        point = CGPoint(x: base.x + number(), y: base.y + number())
        path.move(to: point)
        start = point
        command = relative ? "l" : "L"
      case "L", "l":
        point = CGPoint(x: base.x + number(), y: base.y + number())
        path.addLine(to: point)
      case "H", "h":
        point = CGPoint(x: (relative ? point.x : 0) + number(), y: point.y)
        path.addLine(to: point)
      case "V", "v":
        point = CGPoint(x: point.x, y: (relative ? point.y : 0) + number())
        path.addLine(to: point)
      case "A", "a":
        let radius = number()
        _ = number()
        _ = number()
        let large = number() != 0
        let sweep = number() != 0
        let end = CGPoint(x: base.x + number(), y: base.y + number())
        arc(path, from: point, to: end, radius: radius, large: large, sweep: sweep)
        point = end
      default:
        index += 1
      }
    }
    return path
  }

  static func arc(_ path: CGMutablePath, from: CGPoint, to: CGPoint, radius: CGFloat, large: Bool, sweep: Bool) {
    let dx = (from.x - to.x) / 2
    let dy = (from.y - to.y) / 2
    var r = radius
    let lambda = (dx * dx + dy * dy) / (r * r)
    if lambda > 1 { r *= lambda.squareRoot() }
    let numerator = max(0, r * r * r * r - r * r * dy * dy - r * r * dx * dx)
    let denominator = r * r * dy * dy + r * r * dx * dx
    let coefficient = (large == sweep ? -1 : 1) * (denominator == 0 ? 0 : (numerator / denominator).squareRoot())
    let cx = coefficient * dy + (from.x + to.x) / 2
    let cy = -coefficient * dx + (from.y + to.y) / 2
    let a = atan2((from.y - cy) / r, (from.x - cx) / r)
    var delta = atan2((to.y - cy) / r, (to.x - cx) / r) - a
    if sweep, delta < 0 { delta += 2 * .pi }
    if !sweep, delta > 0 { delta -= 2 * .pi }
    let segments = max(1, Int((abs(delta) / (.pi / 2)).rounded(.up)))
    let step = delta / CGFloat(segments)
    let k = 4 / 3 * tan(step / 4)
    var angle = a
    for _ in 0..<segments {
      let next = angle + step
      let p1 = CGPoint(x: cx + r * (cos(angle) - k * sin(angle)), y: cy + r * (sin(angle) + k * cos(angle)))
      let p2 = CGPoint(x: cx + r * (cos(next) + k * sin(next)), y: cy + r * (sin(next) - k * cos(next)))
      path.addCurve(to: CGPoint(x: cx + r * cos(next), y: cy + r * sin(next)), control1: p1, control2: p2)
      angle = next
    }
  }
}

public final class IconNode: Node {
  public var glyph: Glyph = .plus { didSet { redraw() } }
  public var size: CGFloat = 20 { didSet { invalidate() } }
  public var color: KitColor = .black { didSet { redraw() } }
  public var rotation: CGFloat = 0 { didSet { if rotation != oldValue { redraw() } } }

  public convenience init(_ glyph: Glyph, size: CGFloat? = nil, color: KitColor) {
    self.init(frame: .zero)
    self.glyph = glyph
    self.size = size ?? glyph.size
    self.color = color
  }

  public override func contentSize(_ width: CGFloat) -> CGSize { CGSize(width: size, height: size) }

  public override func draw(_ dirtyRect: CGRect) {
    super.draw(dirtyRect)
    guard let context = context() else { return }
    let rect = content
    context.saveGState()
    if glyph == .stop {
      let side = size * 12 / 14
      context.setFillColor(color.cgColor)
      context.addPath(CGPath(roundedRect: CGRect(x: rect.midX - side / 2, y: rect.midY - side / 2, width: side, height: side),
                             cornerWidth: 2, cornerHeight: 2, transform: nil))
      context.fillPath()
    } else {
      context.translateBy(x: rect.midX, y: rect.midY)
      context.rotate(by: rotation * .pi / 180)
      context.scaleBy(x: size / 24, y: size / 24)
      context.translateBy(x: -12, y: -12)
      context.addPath(glyph.cgPath)
      context.setStrokeColor(color.cgColor)
      context.setLineWidth(1.8)
      context.setLineCap(.round)
      context.setLineJoin(.round)
      context.strokePath()
    }
    context.restoreGState()
  }
}

#if os(macOS)
final class ReadOnlyText: NSTextView {
  override var mouseDownCanMoveWindow: Bool { false }
  override func scrollWheel(with event: NSEvent) { nextResponder?.scrollWheel(with: event) }
}
#endif

public final class TextNode: Node {
  public var text = NSAttributedString() {
    didSet {
      guard !text.isEqual(to: oldValue) else { return }
      #if os(macOS)
      view.textStorage?.setAttributedString(text)
      #else
      view.attributedText = text
      #endif
      invalidate()
    }
  }

  #if os(macOS)
  let view: ReadOnlyText
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
    view = ReadOnlyText(frame: .zero, textContainer: container)
    view.isEditable = false
    view.isSelectable = true
    view.drawsBackground = false
    view.textContainerInset = .zero
    view.isRichText = true
    view.isVerticallyResizable = false
    view.isHorizontallyResizable = false
    view.linkTextAttributes = [.cursor: NSCursor.pointingHand]
    #else
    view.isEditable = false
    view.isSelectable = true
    view.isScrollEnabled = false
    view.backgroundColor = .clear
    view.textContainerInset = .zero
    view.textContainer.lineFragmentPadding = 0
    view.linkTextAttributes = [:]
    view.dataDetectorTypes = []
    #endif
    super.init(frame: frame)
    addSubview(view)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("created in code") }


  public convenience init(_ text: NSAttributedString) {
    self.init(frame: .zero)
    self.text = text
    #if os(macOS)
    view.textStorage?.setAttributedString(text)
    #else
    view.attributedText = text
    #endif
  }

  public var balanced = false { didSet { invalidate() } }

  func fit(_ width: CGFloat) -> CGSize {
    #if os(macOS)
    container.size = CGSize(width: max(1, width), height: unbounded)
    manager.ensureLayout(for: container)
    let used = manager.usedRect(for: container)
    return CGSize(width: min(width, ceil(used.width)), height: ceil(used.height))
    #else
    let size = view.sizeThatFits(CGSize(width: max(1, width), height: unbounded))
    return CGSize(width: min(width, ceil(size.width)), height: ceil(size.height))
    #endif
  }

  func balance(_ width: CGFloat) -> CGFloat {
    let full = fit(width)
    guard balanced, full.height > 0, fit(unbounded).height < full.height else { return width }
    var low = width / 2
    var high = width
    while high - low > 2 {
      let middle = (low + high) / 2
      if fit(middle).height > full.height { low = middle } else { high = middle }
    }
    return ceil(high)
  }

  public override func contentSize(_ width: CGFloat) -> CGSize {
    guard text.length > 0 else { return .zero }
    return fit(balance(width))
  }

  public override func baseline(_ width: CGFloat) -> CGFloat {
    guard text.length > 0, let font = text.attribute(.font, at: 0, effectiveRange: nil) as? KitFont else { return padding.top }
    let style = text.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
    let line = (style?.minimumLineHeight ?? 0) > 0 ? style!.minimumLineHeight : font.natural
    return padding.top + max(0, line - font.natural) / 2 + font.ascender
  }

  public override func arrange(_ rect: CGRect) {
    let width = balanced ? min(rect.width, balance(rect.width)) : rect.width
    let frame = CGRect(x: rect.minX + (rect.width - width) / 2, y: rect.minY, width: width, height: rect.height)
    #if os(macOS)
    container.size = CGSize(width: max(1, width), height: unbounded)
    #endif
    view.frame = frame
  }
}

public final class ScrollNode: Node {
  public enum Axis: Sendable { case vertical, horizontal }
  public let document: Node
  public let axis: Axis
  public var maxHeight: CGFloat? { didSet { invalidate() } }
  public var sticks = false
  private var pinned = true

  #if os(macOS)
  final class Scroller: NSScrollView {
    var horizontal = false
    override func scrollWheel(with event: NSEvent) {
      if horizontal, abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX) { nextResponder?.scrollWheel(with: event) }
      else { super.scrollWheel(with: event) }
    }
  }
  let scroll = Scroller()
  #else
  let scroll = UIScrollView()
  #endif

  public init(_ document: Node, axis: Axis = .vertical, maxHeight: CGFloat? = nil) {
    self.document = document
    self.axis = axis
    self.maxHeight = maxHeight
    super.init(frame: .zero)
    #if os(macOS)
    scroll.horizontal = axis == .horizontal
    scroll.drawsBackground = false
    scroll.borderType = .noBorder
    scroll.hasVerticalScroller = axis == .vertical
    scroll.hasHorizontalScroller = axis == .horizontal
    scroll.autohidesScrollers = true
    scroll.scrollerStyle = .overlay
    scroll.horizontalScrollElasticity = axis == .horizontal ? .automatic : .none
    scroll.verticalScrollElasticity = axis == .vertical ? .automatic : .none
    scroll.documentView = document
    scroll.contentView.postsBoundsChangedNotifications = true
    NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated { self?.scrolled() }
    }
    #else
    scroll.showsHorizontalScrollIndicator = axis == .horizontal
    scroll.alwaysBounceVertical = axis == .vertical && maxHeight == nil
    scroll.keyboardDismissMode = .interactive
    scroll.addSubview(document)
    #endif
    document.onInvalidate = { [weak self] in self?.documentChanged() }
    addSubview(scroll)
    #if os(iOS)
    scroll.delegate = self
    #endif
  }


  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("created in code") }

  func documentChanged() {
    if axis == .vertical, maxHeight == nil { markNeedsLayout() } else { invalidate() }
  }

  public override func contentSize(_ width: CGFloat) -> CGSize {
    switch axis {
    case .horizontal: return CGSize(width: width, height: document.measure(unbounded).height)
    case .vertical:
      guard let maxHeight else { return CGSize(width: width, height: 0) }
      return CGSize(width: width, height: min(document.measure(width).height, maxHeight))
    }
  }

  var viewport: CGSize {
    #if os(macOS)
    scroll.contentSize
    #else
    scroll.bounds.size
    #endif
  }

  var offset: CGFloat {
    #if os(macOS)
    scroll.contentView.bounds.minY
    #else
    scroll.contentOffset.y
    #endif
  }

  func scrolled() {
    guard sticks else { return }
    pinned = offset + viewport.height >= document.frame.height - 24
  }

  #if os(macOS)
  public override func layout() {
    super.layout()
    layoutDocument()
  }
  #else
  public override func layoutSubviews() {
    super.layoutSubviews()
    layoutDocument()
  }

  #endif

  public override func arrange(_ rect: CGRect) {
    if scroll.frame != rect { scroll.frame = rect }
    layoutDocument()
  }

  func layoutDocument() {
    let size = viewport
    guard size.width > 0 else { return }
    let stick = sticks && pinned
    switch axis {
    case .horizontal:
      let natural = document.measure(unbounded)
      document.place(CGRect(x: 0, y: 0, width: max(natural.width, size.width), height: max(natural.height, size.height)))
    case .vertical:
      let natural = document.measure(size.width)
      document.place(CGRect(x: 0, y: 0, width: size.width, height: maxHeight == nil ? max(natural.height, size.height) : natural.height))
    }
    #if os(iOS)
    scroll.contentSize = document.frame.size
    #endif
    if stick { scrollToEnd() }
  }

  public func scrollToEnd() {
    let bottom = max(0, document.frame.height - viewport.height)
    #if os(macOS)
    scroll.contentView.scroll(to: CGPoint(x: 0, y: bottom))
    scroll.reflectScrolledClipView(scroll.contentView)
    #else
    scroll.contentOffset = CGPoint(x: 0, y: max(-scroll.adjustedContentInset.top, document.frame.height - scroll.bounds.height + scroll.adjustedContentInset.bottom))
    #endif
    pinned = true
  }
}

#if os(iOS)
extension ScrollNode: UIScrollViewDelegate {
  public func scrollViewDidScroll(_ scrollView: UIScrollView) { scrolled() }
}
#endif

public final class Flow: Stack {
  public var centered = false { didSet { invalidate() } }

  func rows(_ width: CGFloat) -> [[(Node, CGSize)]] {
    var rows: [[(Node, CGSize)]] = [[]]
    var used: CGFloat = 0
    for node in visible {
      let size = node.measure(width)
      if !rows[rows.count - 1].isEmpty, used + spacing + size.width > width {
        rows.append([])
        used = 0
      }
      used += (rows[rows.count - 1].isEmpty ? 0 : spacing) + size.width
      rows[rows.count - 1].append((node, size))
    }
    return rows.filter { !$0.isEmpty }
  }

  public override func contentSize(_ width: CGFloat) -> CGSize {
    let rows = rows(width)
    let height = rows.reduce(0) { $0 + ($1.map(\.1.height).max() ?? 0) } + spacing * CGFloat(max(0, rows.count - 1))
    let widest = rows.map { row in row.reduce(0) { $0 + $1.1.width } + spacing * CGFloat(max(0, row.count - 1)) }.max() ?? 0
    return CGSize(width: centered ? width : widest, height: height)
  }

  public override func arrange(_ rect: CGRect) {
    var y = rect.minY
    for row in rows(rect.width) {
      let width = row.reduce(0) { $0 + $1.1.width } + spacing * CGFloat(max(0, row.count - 1))
      var x = centered ? rect.minX + (rect.width - width) / 2 : rect.minX
      let height = row.map(\.1.height).max() ?? 0
      for (node, size) in row {
        node.place(CGRect(x: x, y: y, width: size.width, height: size.height))
        x += size.width + spacing
      }
      y += height + spacing
    }
  }
}

public final class ImageNode: Node {
  public var source = "" { didSet { if source != oldValue { load() } } }
  public var maxHeight: CGFloat = 320 { didSet { invalidate() } }
  public var cover: CGSize? { didSet { invalidate() } }
  private var image: KitImage?
  private var task: Task<Void, Never>?

  public convenience init(_ source: String, maxHeight: CGFloat = 320, cover: CGSize? = nil) {
    self.init(frame: .zero)
    self.maxHeight = maxHeight
    self.cover = cover
    self.source = source
    load()
  }

  func load() {
    task?.cancel()
    image = nil
    if let data = DataURL.decode(source) {
      image = KitImage(data: data)
    } else if source.hasPrefix("/") {
      image = KitImage(contentsOfFile: source)
    } else if let url = URL(string: source), url.scheme == "https" || url.scheme == "http" {
      task = Task { [weak self] in
        guard let (data, _) = try? await URLSession.shared.data(from: url), !Task.isCancelled else { return }
        self?.image = KitImage(data: data)
        self?.invalidate()
        self?.redraw()
      }
    }
    invalidate()
    redraw()
  }

  public override func contentSize(_ width: CGFloat) -> CGSize {
    if let cover { return cover }
    guard let image, image.size.width > 0, image.size.height > 0 else { return CGSize(width: min(width, 120), height: 60) }
    let scale = min(1, width / image.size.width, maxHeight / image.size.height)
    return CGSize(width: image.size.width * scale, height: image.size.height * scale)
  }

  public override func draw(_ dirtyRect: CGRect) {
    super.draw(dirtyRect)
    guard let image, let context = context() else { return }
    let rect = content
    context.saveGState()
    let corner = min(radius, rect.width / 2, rect.height / 2)
    context.addPath(CGPath(roundedRect: rect, cornerWidth: corner, cornerHeight: corner, transform: nil))
    context.clip()
    var target = rect
    if cover != nil, image.size.width > 0, image.size.height > 0 {
      let scale = max(rect.width / image.size.width, rect.height / image.size.height)
      let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
      target = CGRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height)
    }
    #if os(macOS)
    image.draw(in: target, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    #else
    image.draw(in: target)
    #endif
    context.restoreGState()
  }
}

public final class Spinner: Node {
  public enum Kind { case ring, glyph(String, CGFloat) }
  public var kind: Kind = .ring { didSet { rebuild() } }
  public var color: KitColor = .black { didSet { recolor() } }
  public var track: KitColor = .gray { didSet { recolor() } }
  public var period: CFTimeInterval = 0.8 { didSet { animate() } }
  public var spinning = true { didSet { if spinning != oldValue { animate() } } }
  public var fading: CFTimeInterval? { didSet { animate() } }
  private let shape = CAShapeLayer()
  private let ring = CAShapeLayer()
  private let glyph = CATextLayer()

  public convenience init(_ kind: Kind, color: KitColor, track: KitColor? = nil, period: CFTimeInterval) {
    self.init(frame: .zero)
    self.kind = kind
    self.color = color
    if let track { self.track = track }
    self.period = period
    rebuild()
  }

  var host: CALayer {
    #if os(macOS)
    layer!
    #else
    layer
    #endif
  }

  func rebuild() {
    shape.removeFromSuperlayer()
    ring.removeFromSuperlayer()
    glyph.removeFromSuperlayer()
    switch kind {
    case .ring:
      host.addSublayer(shape)
      host.addSublayer(ring)
    case .glyph(let text, let size):
      glyph.string = text
      glyph.font = KitFont.systemFont(ofSize: size)
      glyph.fontSize = size
      glyph.alignmentMode = .center
      #if os(macOS)
      glyph.contentsScale = window?.backingScaleFactor ?? 2
      #else
      glyph.contentsScale = UIScreen.main.scale
      #endif
      host.addSublayer(glyph)
    }
    recolor()
    invalidate()
    animate()
  }

  func recolor() {
    shape.fillColor = nil
    shape.strokeColor = cg(track)
    shape.lineWidth = 2
    ring.fillColor = nil
    ring.strokeColor = cg(color)
    ring.lineWidth = 2
    glyph.foregroundColor = cg(color)
  }

  public override func appearanceChanged() {
    super.appearanceChanged()
    recolor()
  }

  public override func contentSize(_ width: CGFloat) -> CGSize {
    switch kind {
    case .ring: CGSize(width: 10, height: 10)
    case .glyph(_, let size): CGSize(width: ceil(size * 1.05), height: ceil(size * 1.2))
    }
  }

  public override func arrange(_ rect: CGRect) {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    switch kind {
    case .ring:
      let box = CGRect(x: rect.midX - 5, y: rect.midY - 5, width: 10, height: 10)
      for layer in [shape, ring] {
        layer.bounds = CGRect(origin: .zero, size: box.size)
        layer.position = CGPoint(x: box.midX, y: box.midY)
      }
      shape.path = CGPath(ellipseIn: CGRect(x: 1, y: 1, width: 8, height: 8), transform: nil)
      let arc = CGMutablePath()
      arc.addArc(center: CGPoint(x: 5, y: 5), radius: 4, startAngle: -.pi / 2, endAngle: 0, clockwise: false)
      ring.path = arc
    case .glyph(_, let size):
      glyph.bounds = CGRect(x: 0, y: 0, width: rect.width, height: size * 1.2)
      glyph.position = CGPoint(x: rect.midX, y: rect.midY)
    }
    CATransaction.commit()
    animate()
  }

  func animate() {
    let target: CALayer = { if case .ring = kind { return ring } else { return glyph } }()
    if spinning {
      if target.animation(forKey: "spin") == nil {
        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        spin.fromValue = 0
        #if os(macOS)
        spin.toValue = -2 * CGFloat.pi
        #else
        spin.toValue = 2 * CGFloat.pi
        #endif
        spin.duration = period
        spin.repeatCount = .infinity
        target.add(spin, forKey: "spin")
      }
    } else {
      target.removeAnimation(forKey: "spin")
    }
    if let fading {
      if target.animation(forKey: "fade") == nil {
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0.4
        fade.duration = fading / 2
        fade.autoreverses = true
        fade.repeatCount = .infinity
        fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        target.add(fade, forKey: "fade")
      }
    } else {
      target.removeAnimation(forKey: "fade")
    }
  }
}

public final class Pulse: Node {
  public var color: KitColor = .black { didSet { dot.backgroundColor = cg(color) } }
  private let dot = CALayer()

  public convenience init(color: KitColor) {
    self.init(frame: .zero)
    self.color = color
    #if os(macOS)
    layer?.addSublayer(dot)
    #else
    layer.addSublayer(dot)
    #endif
    dot.cornerRadius = 6
    dot.backgroundColor = cg(color)
    let scale = CABasicAnimation(keyPath: "transform.scale")
    scale.fromValue = 1
    scale.toValue = 0.7
    let opacity = CABasicAnimation(keyPath: "opacity")
    opacity.fromValue = 1
    opacity.toValue = 0.6
    let group = CAAnimationGroup()
    group.animations = [scale, opacity]
    group.duration = 0.6
    group.autoreverses = true
    group.repeatCount = .infinity
    group.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
    dot.add(group, forKey: "pulse")
  }

  public override func appearanceChanged() {
    super.appearanceChanged()
    dot.backgroundColor = cg(color)
  }

  public override func contentSize(_ width: CGFloat) -> CGSize { CGSize(width: 12, height: 12) }

  public override func arrange(_ rect: CGRect) {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    dot.bounds = CGRect(x: 0, y: 0, width: 12, height: 12)
    dot.position = CGPoint(x: rect.midX, y: rect.midY)
    CATransaction.commit()
  }
}

public extension Node {
  func fade(_ period: CFTimeInterval?) {
    #if os(macOS)
    guard let layer else { return }
    #endif
    if let period {
      guard layer.animation(forKey: "fade") == nil else { return }
      let fade = CABasicAnimation(keyPath: "opacity")
      fade.fromValue = 1
      fade.toValue = 0.4
      fade.duration = period / 2
      fade.autoreverses = true
      fade.repeatCount = .infinity
      fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
      layer.add(fade, forKey: "fade")
    } else {
      layer.removeAnimation(forKey: "fade")
    }
  }
}
