#if os(macOS)
import AppKit
#else
import UIKit
#endif

public struct Insets: Equatable, Sendable {
  public var top: CGFloat
  public var left: CGFloat
  public var bottom: CGFloat
  public var right: CGFloat

  public init(top: CGFloat = 0, left: CGFloat = 0, bottom: CGFloat = 0, right: CGFloat = 0) {
    self.top = top
    self.left = left
    self.bottom = bottom
    self.right = right
  }

  public init(_ all: CGFloat) { self.init(top: all, left: all, bottom: all, right: all) }
  public init(v: CGFloat, h: CGFloat) { self.init(top: v, left: h, bottom: v, right: h) }
  public static let zero = Insets()
  public var horizontal: CGFloat { left + right }
  public var vertical: CGFloat { top + bottom }
}

public enum Edge: Sendable { case top, left, bottom, right }

@MainActor
func context() -> CGContext? {
  #if os(macOS)
  NSGraphicsContext.current?.cgContext
  #else
  UIGraphicsGetCurrentContext()
  #endif
}

open class Node: KitView {
  public var padding = Insets.zero { didSet { if padding != oldValue { invalidate() } } }
  public var fill: KitColor? { didSet { redraw() } }
  public var stroke: KitColor? { didSet { redraw() } }
  public var strokeWidth: CGFloat = 1 { didSet { redraw() } }
  public var radius: CGFloat = 0 { didSet { redraw(); clip() } }
  public var rules: [(Edge, KitColor, CGFloat)] = [] { didSet { redraw() } }
  public var maxWidth: CGFloat = unbounded { didSet { if maxWidth != oldValue { invalidate() } } }
  public var fixedWidth: CGFloat? { didSet { if fixedWidth != oldValue { invalidate() } } }
  public var fixedHeight: CGFloat? { didSet { if fixedHeight != oldValue { invalidate() } } }
  public var minHeight: CGFloat = 0 { didSet { if minHeight != oldValue { invalidate() } } }
  public var grow: CGFloat = 0
  public var shrink = false
  public var spaceBefore: CGFloat?
  public var clips = false { didSet { clip() } }
  public var gone = false { didSet { if gone != oldValue { isHidden = gone; invalidate() } } }
  public var onInvalidate: (() -> Void)?
  private var cached: (CGFloat, CGSize)?
  private var dirty = true

  public override init(frame: CGRect) {
    super.init(frame: frame)
    setup()
  }

  public convenience init() { self.init(frame: .zero) }

  @available(*, unavailable)
  public required init?(coder: NSCoder) { fatalError("Node is created in code") }

  func setup() {
    #if os(macOS)
    wantsLayer = true
    layerContentsRedrawPolicy = .onSetNeedsDisplay
    #else
    backgroundColor = .clear
    isOpaque = false
    contentMode = .redraw
    registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (node: Node, _: UITraitCollection) in node.appearanceChanged() }
    #endif
  }

  #if os(macOS)
  open override var isFlipped: Bool { true }

  open override func layout() {
    super.layout()
    if superview as? Node == nil, onInvalidate == nil { arrange(content) }
  }

  open override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    appearanceChanged()
  }
  #else
  open override func layoutSubviews() {
    super.layoutSubviews()
    if superview as? Node == nil, onInvalidate == nil { arrange(content) }
  }
  #endif

  open func appearanceChanged() { redraw() }

  public func redraw() {
    #if os(macOS)
    needsDisplay = true
    #else
    setNeedsDisplay()
    #endif
  }

  public func markNeedsLayout() {
    #if os(macOS)
    needsLayout = true
    #else
    setNeedsLayout()
    #endif
  }

  func clip() {
    #if os(macOS)
    layer?.cornerRadius = clips ? radius : 0
    layer?.masksToBounds = clips
    #else
    layer.cornerRadius = clips ? radius : 0
    clipsToBounds = clips
    #endif
  }

  public func cg(_ color: KitColor) -> CGColor {
    #if os(macOS)
    var result = color.cgColor
    effectiveAppearance.performAsCurrentDrawingAppearance { result = color.cgColor }
    return result
    #else
    return color.resolvedColor(with: traitCollection).cgColor
    #endif
  }

  var content: CGRect {
    CGRect(x: padding.left, y: padding.top, width: max(0, bounds.width - padding.horizontal), height: max(0, bounds.height - padding.vertical))
  }

  public final func measure(_ available: CGFloat) -> CGSize {
    if gone { return .zero }
    let width = fixedWidth ?? min(available, maxWidth)
    if let cached, cached.0 == width { return cached.1 }
    let inner = contentSize(max(0, width - padding.horizontal))
    let size = CGSize(width: fixedWidth ?? min(width, ceil(inner.width) + padding.horizontal),
                      height: fixedHeight ?? max(minHeight, ceil(inner.height) + padding.vertical))
    cached = (width, size)
    return size
  }

  open func contentSize(_ width: CGFloat) -> CGSize { .zero }

  open func arrange(_ rect: CGRect) {}

  open func baseline(_ width: CGFloat) -> CGFloat { measure(width).height }

  public func place(_ rect: CGRect) {
    let moved = frame.size != rect.size
    if frame != rect { frame = rect }
    if moved { redraw() }
    guard moved || dirty else { return }
    dirty = false
    arrange(content)
  }

  public func invalidate() {
    cached = nil
    dirty = true
    if let parent = superview as? Node { parent.invalidate() }
    else if let onInvalidate { onInvalidate() }
    else { markNeedsLayout() }
  }

  open var currentFill: KitColor? { fill }

  open override func draw(_ dirtyRect: CGRect) {
    guard let context = context() else { return }
    let box = bounds
    if let fill = currentFill {
      context.setFillColor(fill.cgColor)
      let corner = min(radius, box.width / 2, box.height / 2)
      context.addPath(CGPath(roundedRect: box, cornerWidth: corner, cornerHeight: corner, transform: nil))
      context.fillPath()
    }
    for (edge, color, width) in rules {
      context.setFillColor(color.cgColor)
      switch edge {
      case .top: context.fill(CGRect(x: 0, y: 0, width: box.width, height: width))
      case .bottom: context.fill(CGRect(x: 0, y: box.height - width, width: box.width, height: width))
      case .left: context.fill(CGRect(x: 0, y: 0, width: width, height: box.height))
      case .right: context.fill(CGRect(x: box.width - width, y: 0, width: width, height: box.height))
      }
    }
    if let stroke {
      let inset = box.insetBy(dx: strokeWidth / 2, dy: strokeWidth / 2)
      context.setStrokeColor(stroke.cgColor)
      context.setLineWidth(strokeWidth)
      let corner = max(0, min(radius - strokeWidth / 2, inset.width / 2, inset.height / 2))
      context.addPath(CGPath(roundedRect: inset, cornerWidth: corner, cornerHeight: corner, transform: nil))
      context.strokePath()
    }
  }
}

open class Stack: Node {
  public enum Axis: Sendable { case vertical, horizontal }
  public enum Align: Sendable { case start, center, end, fill, baseline }
  public enum Justify: Sendable { case start, center, end, between }

  public var axis: Axis = .vertical { didSet { invalidate() } }
  public var spacing: CGFloat = 0 { didSet { if spacing != oldValue { invalidate() } } }
  public var align: Align = .fill { didSet { invalidate() } }
  public var justify: Justify = .start { didSet { invalidate() } }
  public private(set) var items: [Node] = []

  public convenience init(_ axis: Axis, spacing: CGFloat = 0, align: Align = .fill, _ items: [Node] = []) {
    self.init(frame: .zero)
    self.axis = axis
    self.spacing = spacing
    self.align = align
    set(items)
  }

  public func set(_ nodes: [Node]) {
    if nodes.count == items.count, zip(nodes, items).allSatisfy({ $0 === $1 }) { return }
    for node in items where !nodes.contains(where: { $0 === node }) { node.removeFromSuperview() }
    for node in nodes where node.superview !== self { addSubview(node) }
    items = nodes
    invalidate()
  }

  public func append(_ node: Node) { set(items + [node]) }

  var visible: [Node] { items.filter { !$0.gone } }

  func gap(before node: Node, index: Int) -> CGFloat {
    index == 0 ? 0 : node.spaceBefore ?? spacing
  }

  func widths(_ nodes: [Node], _ width: CGFloat) -> [CGFloat] {
    var result = [CGFloat](repeating: 0, count: nodes.count)
    var used = nodes.enumerated().reduce(0) { $0 + gap(before: $1.element, index: $1.offset) }
    for (index, node) in nodes.enumerated() where node.grow == 0 && !node.shrink {
      result[index] = node.measure(max(0, width - used)).width
      used += result[index]
    }
    for (index, node) in nodes.enumerated() where node.grow == 0 && node.shrink {
      result[index] = node.measure(max(0, width - used)).width
      used += result[index]
    }
    let growth = nodes.reduce(0) { $0 + $1.grow }
    if growth > 0 {
      let extra = max(0, width - used)
      for (index, node) in nodes.enumerated() where node.grow > 0 { result[index] = extra * node.grow / growth }
    }
    return result
  }

  open override func contentSize(_ width: CGFloat) -> CGSize {
    let nodes = visible
    switch axis {
    case .vertical:
      var height: CGFloat = 0
      var widest: CGFloat = 0
      for (index, node) in nodes.enumerated() {
        let size = node.measure(width)
        height += gap(before: node, index: index) + size.height
        widest = max(widest, size.width)
      }
      return CGSize(width: align == .fill ? width : widest, height: height)
    case .horizontal:
      let widths = widths(nodes, width)
      var height: CGFloat = 0
      var ascent: CGFloat = 0
      var descent: CGFloat = 0
      for (index, node) in nodes.enumerated() {
        let size = node.measure(widths[index])
        height = max(height, size.height)
        if align == .baseline {
          let line = node.baseline(widths[index])
          ascent = max(ascent, line)
          descent = max(descent, size.height - line)
        }
      }
      if align == .baseline { height = max(height, ascent + descent) }
      let total = widths.reduce(0, +) + nodes.enumerated().reduce(0) { $0 + gap(before: $1.element, index: $1.offset) }
      return CGSize(width: nodes.contains { $0.grow > 0 } ? width : total, height: height)
    }
  }

  open override func baseline(_ width: CGFloat) -> CGFloat {
    guard let first = visible.first else { return padding.top }
    switch axis {
    case .vertical: return padding.top + first.baseline(width - padding.horizontal)
    case .horizontal:
      let nodes = visible
      let widths = widths(nodes, width - padding.horizontal)
      return padding.top + zip(nodes, widths).map { $0.baseline($1) }.max()!
    }
  }

  open override func arrange(_ rect: CGRect) {
    let nodes = visible
    switch axis {
    case .vertical:
      let sizes = nodes.map { $0.measure(rect.width) }
      let gaps = nodes.enumerated().map { gap(before: $1, index: $0) }
      let total = sizes.reduce(0) { $0 + $1.height } + gaps.reduce(0, +)
      let extra = rect.height - total
      let growth = nodes.reduce(0) { $0 + $1.grow }
      var y = rect.minY
      var between: CGFloat = 0
      if growth == 0, extra > 0 {
        switch justify {
        case .center: y += extra / 2
        case .end: y += extra
        case .between where nodes.count > 1: between = extra / CGFloat(nodes.count - 1)
        default: break
        }
      }
      for (index, node) in nodes.enumerated() {
        y += gaps[index] + (index > 0 ? between : 0)
        let height = sizes[index].height + (growth > 0 ? max(0, extra) * node.grow / growth : 0)
        let width = align == .fill ? rect.width : min(sizes[index].width, rect.width)
        let x: CGFloat = switch align {
        case .center: rect.minX + (rect.width - width) / 2
        case .end: rect.maxX - width
        default: rect.minX
        }
        node.place(CGRect(x: x, y: y, width: width, height: height))
        y += height
      }
    case .horizontal:
      let widths = widths(nodes, rect.width)
      let gaps = nodes.enumerated().map { gap(before: $1, index: $0) }
      let total = widths.reduce(0, +) + gaps.reduce(0, +)
      let extra = rect.width - total
      var x = rect.minX
      var between: CGFloat = 0
      if extra > 0, !nodes.contains(where: { $0.grow > 0 }) {
        switch justify {
        case .center: x += extra / 2
        case .end: x += extra
        case .between where nodes.count > 1: between = extra / CGFloat(nodes.count - 1)
        default: break
        }
      }
      let line = align == .baseline ? zip(nodes, widths).map { $0.baseline($1) }.max() ?? 0 : 0
      for (index, node) in nodes.enumerated() {
        x += gaps[index] + (index > 0 ? between : 0)
        let size = node.measure(widths[index])
        let height = align == .fill ? rect.height : min(size.height, rect.height)
        let y: CGFloat = switch align {
        case .center: rect.minY + (rect.height - height) / 2
        case .end: rect.maxY - height
        case .baseline: rect.minY + line - node.baseline(widths[index])
        default: rect.minY
        }
        node.place(CGRect(x: x, y: y, width: widths[index], height: height))
        x += widths[index]
      }
    }
  }
}

public final class Spacer: Node {
  override func setup() {
    super.setup()
    grow = 1
  }
}

public final class Rule: Node {
  public convenience init(_ color: KitColor, thickness: CGFloat = 1) {
    self.init(frame: .zero)
    fill = color
    fixedHeight = thickness
  }
}

public final class Label: Node {
  public var text = NSAttributedString() {
    didSet { if !text.isEqual(to: oldValue) { prepared = nil; invalidate(); redraw() } }
  }
  public var lines = 0 { didSet { if lines != oldValue { prepared = nil; invalidate(); redraw() } } }
  private var prepared: NSAttributedString?
  private var shimmer: CAGradientLayer?
  private var shimmerWidth: CGFloat = 0

  public convenience init(_ text: NSAttributedString, lines: Int = 0) {
    self.init(frame: .zero)
    self.text = text
    self.lines = lines
  }

  var drawn: NSAttributedString {
    if let prepared { return prepared }
    var result = text
    if lines == 1, text.length > 0 {
      let copy = NSMutableAttributedString(attributedString: text)
      copy.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: copy.length)) { value, range, _ in
        let style = ((value as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        copy.addAttribute(.paragraphStyle, value: style, range: range)
      }
      result = copy
    }
    prepared = result
    return result
  }

  var options: DrawingOptions { [.usesLineFragmentOrigin, .usesFontLeading] }

  public override func contentSize(_ width: CGFloat) -> CGSize {
    guard text.length > 0 else { return .zero }
    if lines == 1 {
      let natural = drawn.boundingRect(with: CGSize(width: unbounded, height: unbounded), options: options, context: nil)
      return CGSize(width: min(ceil(natural.width), width), height: ceil(natural.height))
    }
    let rect = drawn.boundingRect(with: CGSize(width: max(1, width), height: unbounded), options: options, context: nil)
    return CGSize(width: min(ceil(rect.width), width), height: ceil(rect.height))
  }

  public override func baseline(_ width: CGFloat) -> CGFloat {
    guard text.length > 0, let font = text.attribute(.font, at: 0, effectiveRange: nil) as? KitFont else { return padding.top }
    let style = text.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
    let line = (style?.minimumLineHeight ?? 0) > 0 ? style!.minimumLineHeight : font.natural
    return padding.top + max(0, line - font.natural) / 2 + font.ascender
  }

  public override func draw(_ dirtyRect: CGRect) {
    super.draw(dirtyRect)
    let rect = content
    drawn.draw(with: CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: max(rect.height, 1)),
               options: lines == 1 ? options.union(.truncatesLastVisibleLine) : options, context: nil)
  }

  public var shimmering: Bool = false {
    didSet { if shimmering != oldValue { updateShimmer() } }
  }

  func updateShimmer() {
    #if os(macOS)
    guard let layer else { return }
    #endif
    if !shimmering {
      layer.mask = nil
      shimmer = nil
      shimmerWidth = 0
      return
    }
    let gradient = CAGradientLayer()
    gradient.startPoint = CGPoint(x: 0, y: 0.5)
    gradient.endPoint = CGPoint(x: 1, y: 0.5)
    let dim = CGColor(gray: 1, alpha: 0.62)
    let bright = CGColor(gray: 1, alpha: 1)
    gradient.colors = [dim, dim, bright, dim, dim]
    gradient.locations = [0, 0.35, 0.5, 0.65, 1]
    layer.mask = gradient
    shimmer = gradient
    layoutShimmer()
  }

  func layoutShimmer() {
    guard let shimmer else { return }
    let width = max(bounds.width, 1)
    guard width != shimmerWidth || shimmer.animation(forKey: "shimmer") == nil else { return }
    shimmerWidth = width
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    shimmer.frame = CGRect(x: -width, y: 0, width: width * 3, height: bounds.height)
    CATransaction.commit()
    let animation = CABasicAnimation(keyPath: "position.x")
    animation.fromValue = width * 1.5
    animation.toValue = -width * 0.5
    animation.duration = 1.6
    animation.repeatCount = .infinity
    shimmer.add(animation, forKey: "shimmer")
  }

  public override func arrange(_ rect: CGRect) {
    layoutShimmer()
  }
}
