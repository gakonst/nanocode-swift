import SwiftUI
@_exported import Nanocode

public struct NanocodeTheme: Sendable {
  public var foreground: Color
  public var muted: Color
  public var faint: Color
  public var border: Color
  public var surface: Color
  public var popover: Color
  public var accent: Color
  public var link: Color
  public var danger: Color
  public var success: Color
  public var warning: Color
  public var info: Color
  public var userBubble: Color
  public var bodySize: CGFloat
  public var codeSize: CGFloat
  public var lineHeight: CGFloat
  public var columnWidth: CGFloat

  public init(foreground: Color = .primary, muted: Color = .secondary, faint: Color = Color.secondary.opacity(0.12),
              border: Color = Color.secondary.opacity(0.22), surface: Color = Color.secondary.opacity(0.06),
              popover: Color = Color.secondary.opacity(0.08), accent: Color = .accentColor, link: Color = .blue,
              danger: Color = Color(red: 0.86, green: 0.24, blue: 0.27), success: Color = Color(red: 0.16, green: 0.6, blue: 0.36),
              warning: Color = Color(red: 0.8, green: 0.5, blue: 0.1), info: Color = Color(red: 0.36, green: 0.42, blue: 0.9),
              userBubble: Color = Color.secondary.opacity(0.12), bodySize: CGFloat = 15, codeSize: CGFloat = 12.5,
              lineHeight: CGFloat = 1.5, columnWidth: CGFloat = 760) {
    self.foreground = foreground
    self.muted = muted
    self.faint = faint
    self.border = border
    self.surface = surface
    self.popover = popover
    self.accent = accent
    self.link = link
    self.danger = danger
    self.success = success
    self.warning = warning
    self.info = info
    self.userBubble = userBubble
    self.bodySize = bodySize
    self.codeSize = codeSize
    self.lineHeight = lineHeight
    self.columnWidth = columnWidth
  }

  public static let standard = NanocodeTheme()

  public static let nanocode = NanocodeTheme(
    accent: Color(red: 0.98, green: 0.45, blue: 0.09), link: Color(red: 0.98, green: 0.45, blue: 0.09),
    userBubble: Color(red: 0.98, green: 0.45, blue: 0.09).opacity(0.12))
}

private struct ThemeKey: EnvironmentKey {
  static let defaultValue = NanocodeTheme.standard
}

public extension EnvironmentValues {
  var nanocodeTheme: NanocodeTheme {
    get { self[ThemeKey.self] }
    set { self[ThemeKey.self] = newValue }
  }
}

public extension View {
  func nanocodeTheme(_ theme: NanocodeTheme) -> some View {
    environment(\.nanocodeTheme, theme)
  }
}

extension Font {
  static func body(_ size: CGFloat, weight: Font.Weight = .regular) -> Font { .system(size: size, weight: weight) }
  static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font { .system(size: size, weight: weight, design: .monospaced) }
}

extension View {
  func lineHeight(_ multiple: CGFloat, size: CGFloat) -> some View {
    lineSpacing(max(0, size * (multiple - 1.2)))
  }
}
