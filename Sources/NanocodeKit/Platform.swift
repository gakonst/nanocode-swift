import Observation
#if os(macOS)
import AppKit
public typealias KitView = NSView
public typealias KitColor = NSColor
public typealias KitFont = NSFont
public typealias KitImage = NSImage
public typealias KitViewController = NSViewController
#else
import UIKit
public typealias KitView = UIView
public typealias KitColor = UIColor
public typealias KitFont = UIFont
public typealias KitImage = UIImage
public typealias KitViewController = UIViewController
#endif

let unbounded: CGFloat = 100_000

#if os(macOS)
typealias DrawingOptions = NSString.DrawingOptions
#else
typealias DrawingOptions = NSStringDrawingOptions
#endif

public extension KitColor {
  convenience init(hex: UInt32, alpha: CGFloat = 1) {
    let red = CGFloat(hex >> 16 & 0xff) / 255
    let green = CGFloat(hex >> 8 & 0xff) / 255
    let blue = CGFloat(hex & 0xff) / 255
    #if os(macOS)
    self.init(srgbRed: red, green: green, blue: blue, alpha: alpha)
    #else
    self.init(red: red, green: green, blue: blue, alpha: alpha)
    #endif
  }

  static func dynamic(light: KitColor, dark: KitColor) -> KitColor {
    #if os(macOS)
    KitColor(name: nil) { appearance in appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light }
    #else
    KitColor { traits in traits.userInterfaceStyle == .dark ? dark : light }
    #endif
  }

  static func dynamic(light: UInt32, dark: UInt32) -> KitColor {
    dynamic(light: KitColor(hex: light), dark: KitColor(hex: dark))
  }
}

public extension KitFont {
  static func sans(_ size: CGFloat, _ weight: KitFont.Weight = .regular) -> KitFont {
    .systemFont(ofSize: size, weight: weight)
  }

  static func mono(_ size: CGFloat, _ weight: KitFont.Weight = .regular) -> KitFont {
    .monospacedSystemFont(ofSize: size, weight: weight)
  }

  static let serifFamily: [String]? = {
    let families: [[String]] = [
      ["TiemposText-Regular", "TiemposText-Semibold", "TiemposText-RegularItalic", "TiemposText-Light"],
      ["IowanOldStyle-Roman", "IowanOldStyle-Bold", "IowanOldStyle-Italic", "IowanOldStyle-Roman"],
      ["Charter-Roman", "Charter-Bold", "Charter-Italic", "Charter-Roman"],
      ["Georgia", "Georgia-Bold", "Georgia-Italic", "Georgia"],
    ]
    return families.first { KitFont(name: $0[0], size: 12) != nil }
  }()

  static func serif(_ size: CGFloat, bold: Bool = false, italic: Bool = false, light: Bool = false) -> KitFont {
    guard let family = serifFamily else { return .systemFont(ofSize: size) }
    let name = bold ? family[1] : italic ? family[2] : light ? family[3] : family[0]
    return KitFont(name: name, size: size) ?? KitFont(name: family[0], size: size) ?? .systemFont(ofSize: size)
  }

  func with(bold: Bool = false, italic: Bool = false) -> KitFont {
    guard bold || italic else { return self }
    #if os(macOS)
    var traits: NSFontDescriptor.SymbolicTraits = fontDescriptor.symbolicTraits
    if bold { traits.insert(.bold) }
    if italic { traits.insert(.italic) }
    return KitFont(descriptor: fontDescriptor.withSymbolicTraits(traits), size: pointSize) ?? self
    #else
    var traits = fontDescriptor.symbolicTraits
    if bold { traits.insert(.traitBold) }
    if italic { traits.insert(.traitItalic) }
    return fontDescriptor.withSymbolicTraits(traits).map { KitFont(descriptor: $0, size: pointSize) } ?? self
    #endif
  }

  var natural: CGFloat {
    #if os(macOS)
    ceil(ascender - descender + leading)
    #else
    lineHeight
    #endif
  }
}

func paragraph(lineHeight: CGFloat? = nil, font: KitFont? = nil, alignment: NSTextAlignment = .natural, truncate: Bool = false) -> NSParagraphStyle {
  let style = NSMutableParagraphStyle()
  style.alignment = alignment
  if truncate { style.lineBreakMode = .byTruncatingTail }
  if let lineHeight {
    style.minimumLineHeight = lineHeight
    style.maximumLineHeight = lineHeight
  }
  return style
}

func baselineOffset(lineHeight: CGFloat?, font: KitFont) -> CGFloat {
  guard let lineHeight else { return 0 }
  return max(0, (lineHeight - font.natural) / 2)
}

public func styled(_ text: String, _ font: KitFont, _ color: KitColor, lineHeight: CGFloat? = nil, alignment: NSTextAlignment = .natural,
                   kern: CGFloat = 0) -> NSAttributedString {
  var attributes: [NSAttributedString.Key: Any] = [
    .font: font, .foregroundColor: color,
    .paragraphStyle: paragraph(lineHeight: lineHeight, font: font, alignment: alignment),
    .baselineOffset: baselineOffset(lineHeight: lineHeight, font: font),
  ]
  if kern != 0 { attributes[.kern] = kern }
  return NSAttributedString(string: text, attributes: attributes)
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

@MainActor
public func open(_ url: URL) {
  #if os(macOS)
  NSWorkspace.shared.open(url)
  #else
  UIApplication.shared.open(url)
  #endif
}

@MainActor
public final class Observer {
  private var active = true
  private let render: @MainActor () -> Void

  public init(_ render: @escaping @MainActor () -> Void) {
    self.render = render
    track()
  }

  private func track() {
    guard active else { return }
    withObservationTracking { render() } onChange: { [weak self] in
      Task { @MainActor in self?.track() }
    }
  }

  public func cancel() {
    active = false
  }
}
