#if os(macOS)
import AppKit
#else
import UIKit
#endif

public struct Skin: @unchecked Sendable {
  public var claude: Bool
  public var bg: KitColor
  public var sidebar: KitColor
  public var text: KitColor
  public var muted: KitColor
  public var faint: KitColor
  public var hover: KitColor
  public var bubble: KitColor
  public var border: KitColor
  public var composer: KitColor
  public var code: KitColor
  public var codeBar: KitColor
  public var menu: KitColor
  public var danger: KitColor
  public var accent: KitColor
  public var send: KitColor
  public var sendText: KitColor
  public var sendOff: KitColor
  public var spark: KitColor
  public var icon: KitColor
  public var inline: KitColor?
  public var hairline: CGFloat
  public var proseSize: CGFloat
  public var proseLine: CGFloat
  public var blockGap: CGFloat
  public var headings: [CGFloat]
  public var codeRadius: CGFloat
  public var inlineScale: CGFloat
  public var column: CGFloat
  public var syntax: Syntax

  public struct Syntax: @unchecked Sendable {
    public var comment: KitColor
    public var keyword: KitColor
    public var function: KitColor
    public var attribute: KitColor
    public var string: KitColor
    public var number: KitColor
    public var inserted: KitColor
    public var deleted: KitColor

    public static let github = Syntax(
      comment: .dynamic(light: 0x6e7781, dark: 0x8b949e), keyword: .dynamic(light: 0xcf222e, dark: 0xff7b72),
      function: .dynamic(light: 0x8250df, dark: 0xd2a8ff), attribute: .dynamic(light: 0x0550ae, dark: 0x79c0ff),
      string: .dynamic(light: 0x0a3069, dark: 0xa5d6ff), number: .dynamic(light: 0x0550ae, dark: 0x79c0ff),
      inserted: .dynamic(light: 0x116329, dark: 0x7ee787), deleted: .dynamic(light: 0x82071e, dark: 0xffa198))

    func color(_ scope: Highlight.Scope) -> KitColor {
      switch scope {
      case .comment, .punctuation: comment
      case .keyword: keyword
      case .function: function
      case .attribute: attribute
      case .string: string
      case .number: number
      case .inserted: inserted
      case .deleted: deleted
      }
    }
  }

  public static let chatgpt = Skin(
    claude: false, bg: .dynamic(light: 0xffffff, dark: 0x212121), sidebar: .dynamic(light: 0xf9f9f9, dark: 0x181818),
    text: .dynamic(light: 0x0d0d0d, dark: 0xececec), muted: .dynamic(light: 0x5d5d5d, dark: 0xafafaf),
    faint: .dynamic(light: 0x8f8f8f, dark: 0x8f8f8f), hover: .dynamic(light: 0xececec, dark: 0x2f2f2f),
    bubble: .dynamic(light: 0xf4f4f4, dark: 0x303030), border: .dynamic(light: 0xe5e5e5, dark: 0x3a3a3a),
    composer: .dynamic(light: 0xffffff, dark: 0x303030), code: .dynamic(light: 0xf9f9f9, dark: 0x171717),
    codeBar: .dynamic(light: 0xf0f0f0, dark: 0x2a2a2a), menu: .dynamic(light: 0xffffff, dark: 0x353535),
    danger: .dynamic(light: 0xd0352b, dark: 0xf87171), accent: .dynamic(light: 0x0d0d0d, dark: 0xffffff),
    send: .dynamic(light: 0x0d0d0d, dark: 0xffffff), sendText: .dynamic(light: 0xffffff, dark: 0x0d0d0d),
    sendOff: .dynamic(light: 0xd7d7d7, dark: 0x676767), spark: KitColor(hex: 0xd97757), icon: KitColor(hex: 0x10a37f),
    inline: nil, hairline: 1, proseSize: 16, proseLine: 1.5, blockGap: 16, headings: [26, 22, 19, 16],
    codeRadius: 14, inlineScale: 0.875, column: 768, syntax: .github)

  public static let claude = Skin(
    claude: true, bg: .dynamic(light: 0xfaf9f5, dark: 0x262624), sidebar: .dynamic(light: 0xf5f4ed, dark: 0x1f1e1d),
    text: .dynamic(light: 0x141413, dark: 0xf5f4ef), muted: .dynamic(light: 0x5e5d59, dark: 0xc2c0b6),
    faint: .dynamic(light: 0x8f8d86, dark: 0x9a9890), hover: .dynamic(light: 0xecebe3, dark: 0x30302e),
    bubble: .dynamic(light: 0xf0eee6, dark: 0x141413), border: .dynamic(light: 0xe3e1d7, dark: 0x3e3e38),
    composer: .dynamic(light: 0xffffff, dark: 0x30302e), code: .dynamic(light: 0xf5f4ef, dark: 0x1f1e1d),
    codeBar: .dynamic(light: 0xefede5, dark: 0x2a2a27), menu: .dynamic(light: 0xffffff, dark: 0x30302e),
    danger: .dynamic(light: 0xb42318, dark: 0xf87171), accent: KitColor(hex: 0xc96442), send: KitColor(hex: 0xc96442),
    sendText: KitColor(hex: 0xffffff), sendOff: KitColor(hex: 0xc96442), spark: KitColor(hex: 0xd97757),
    icon: .dynamic(light: 0x8f8d86, dark: 0x9a9890), inline: .dynamic(light: 0xb5452a, dark: 0xf0a58a),
    hairline: 0.5, proseSize: 16.5, proseLine: 1.65, blockGap: 14, headings: [24, 21, 18, 16.5],
    codeRadius: 10, inlineScale: 0.82, column: 740, syntax: .github)

  public func prose(_ size: CGFloat? = nil, bold: Bool = false, italic: Bool = false) -> KitFont {
    let size = size ?? proseSize
    if claude { return .serif(size, bold: bold, italic: italic) }
    return KitFont.sans(size, bold ? .bold : .regular).with(italic: italic)
  }

  public func ui(_ size: CGFloat, _ weight: KitFont.Weight = .regular) -> KitFont { .sans(size, weight) }
}

public enum Rich {
  public static func inline(_ source: String, skin: Skin, font: KitFont, color: KitColor, lineHeight: CGFloat?,
                            prose: Bool = true) -> NSAttributedString {
    let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace, failurePolicy: .returnPartiallyParsedIfPossible)
    let parsed = (try? AttributedString(markdown: source, options: options)) ?? AttributedString(source)
    let result = NSMutableAttributedString()
    let style = paragraph(lineHeight: lineHeight)
    for run in parsed.runs {
      let text = String(parsed[run.range].characters)
      let intent = run.inlinePresentationIntent ?? []
      var runFont = font
      var attributes: [NSAttributedString.Key: Any] = [.foregroundColor: color, .paragraphStyle: style]
      if intent.contains(.code) {
        runFont = .mono(font.pointSize * skin.inlineScale)
        attributes[.backgroundColor] = skin.bubble
        if let inline = skin.inline { attributes[.foregroundColor] = inline }
      } else {
        let bold = intent.contains(.stronglyEmphasized)
        let italic = intent.contains(.emphasized)
        if bold || italic {
          runFont = prose && skin.claude ? .serif(font.pointSize, bold: bold, italic: italic && !bold) : font.with(bold: bold, italic: italic)
        }
      }
      if intent.contains(.strikethrough) { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
      if let url = run.link {
        if url.absoluteString == MarkdownStream.incompleteLink {
          attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
        } else if ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") {
          attributes[.link] = url
          attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
          attributes[.underlineColor] = skin.claude && prose ? skin.accent : skin.faint
          if skin.claude, prose { attributes[.foregroundColor] = skin.accent }
        }
      }
      if run.imageURL != nil { continue }
      attributes[.font] = runFont
      attributes[.baselineOffset] = baselineOffset(lineHeight: lineHeight, font: font) + (runFont.pointSize < font.pointSize ? (font.natural - runFont.natural) / 4 : 0)
      result.append(NSAttributedString(string: text, attributes: attributes))
    }
    return result
  }

  public static func code(_ text: String, language: String, skin: Skin, font: KitFont, color: KitColor, lineHeight: CGFloat) -> NSAttributedString {
    let style = paragraph(lineHeight: lineHeight)
    let base: [NSAttributedString.Key: Any] = [
      .font: font, .foregroundColor: color, .paragraphStyle: style, .baselineOffset: baselineOffset(lineHeight: lineHeight, font: font),
    ]
    guard let tokens = Highlight.tokens(text, language: language) else { return NSAttributedString(string: text, attributes: base) }
    let result = NSMutableAttributedString()
    for token in tokens {
      var attributes = base
      if let scope = token.scope { attributes[.foregroundColor] = skin.syntax.color(scope) }
      result.append(NSAttributedString(string: token.text, attributes: attributes))
    }
    return result
  }
}
