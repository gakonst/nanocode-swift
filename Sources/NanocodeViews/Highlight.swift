import SwiftUI

public extension Highlight.Scope {
  func color(_ theme: NanocodeTheme) -> Color {
    switch self {
    case .comment, .punctuation: theme.muted
    case .keyword, .deleted: theme.danger
    case .function: theme.info
    case .attribute: theme.link
    case .string, .inserted: theme.success
    case .number: theme.warning
    }
  }
}

public extension Highlight {
  static func attributed(_ text: String, language: String, theme: NanocodeTheme = .standard) -> AttributedString? {
    guard let tokens = tokens(text, language: language) else { return nil }
    var result = AttributedString()
    for token in tokens {
      var part = AttributedString(token.text)
      if let scope = token.scope { part.foregroundColor = scope.color(theme) }
      result.append(part)
    }
    return result
  }
}
