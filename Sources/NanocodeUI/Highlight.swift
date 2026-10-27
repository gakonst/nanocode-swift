import SwiftUI
public enum Highlight {
  public enum Scope: Hashable, Sendable {
    case comment, keyword, function, attribute, string, number, punctuation, inserted, deleted

    public func color(_ theme: NanocodeTheme) -> Color {
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

  public struct Token: Hashable, Sendable {
    public let text: String
    public let scope: Scope?
  }

  enum Family { case script, rust, go, python, shell, swift, cLike, json, yaml, toml, css, markup, sql, diff }

  struct Language {
    let family: Family
    var keywords: Set<String> = []
    var constants: Set<String> = ["true", "false"]
    var lineComments: [String] = ["//"]
    var blockComment: (String, String)? = ("/*", "*/")
    var quotes: Set<Character> = ["\"", "'"]
  }

  static let scriptKeywords: Set<String> = [
    "abstract", "as", "async", "await", "break", "case", "catch", "class", "const", "continue", "debugger", "declare", "default", "delete",
    "do", "else", "enum", "export", "extends", "finally", "for", "from", "function", "get", "if", "implements", "import", "in", "instanceof",
    "interface", "keyof", "let", "namespace", "new", "of", "private", "protected", "public", "readonly", "return", "satisfies", "set",
    "static", "switch", "throw", "try", "type", "typeof", "var", "void", "while", "with", "yield",
  ]

  static let languages: [String: Language] = {
    let script = Language(family: .script, keywords: scriptKeywords, constants: ["true", "false", "null", "undefined", "NaN", "Infinity"],
                          quotes: ["\"", "'", "`"])
    let rust = Language(family: .rust, keywords: [
      "as", "async", "await", "break", "const", "continue", "crate", "dyn", "else", "enum", "extern", "fn", "for", "if", "impl", "in", "let",
      "loop", "match", "mod", "move", "mut", "pub", "ref", "return", "static", "struct", "super", "trait", "type", "unsafe", "use", "where", "while",
    ], quotes: ["\""])
    let go = Language(family: .go, keywords: [
      "break", "case", "chan", "const", "continue", "default", "defer", "else", "fallthrough", "for", "func", "go", "goto", "if", "import",
      "interface", "map", "package", "range", "return", "select", "struct", "switch", "type", "var",
    ], constants: ["true", "false", "nil", "iota"], quotes: ["\"", "'", "`"])
    let python = Language(family: .python, keywords: [
      "and", "as", "assert", "async", "await", "break", "class", "continue", "def", "del", "elif", "else", "except", "finally", "for", "from",
      "global", "if", "import", "in", "is", "lambda", "nonlocal", "not", "or", "pass", "raise", "return", "try", "while", "with", "yield",
    ], constants: ["True", "False", "None"], lineComments: ["#"], blockComment: nil)
    let shell = Language(family: .shell, keywords: [
      "if", "then", "else", "elif", "fi", "for", "while", "until", "do", "done", "case", "esac", "in", "function", "return", "export", "local",
      "select", "declare", "readonly", "unset",
    ], constants: [], lineComments: ["#"], blockComment: nil)
    let swift = Language(family: .swift, keywords: [
      "actor", "as", "associatedtype", "async", "await", "break", "case", "catch", "class", "continue", "default", "defer", "deinit", "do",
      "else", "enum", "extension", "fallthrough", "fileprivate", "for", "func", "guard", "if", "import", "in", "init", "inout", "internal",
      "is", "let", "nonisolated", "open", "operator", "private", "protocol", "public", "repeat", "return", "some", "static", "struct",
      "subscript", "switch", "throw", "throws", "try", "typealias", "var", "where", "while",
    ], constants: ["true", "false", "nil"], quotes: ["\""])
    let cLike = Language(family: .cLike, keywords: [
      "abstract", "auto", "break", "case", "catch", "class", "const", "continue", "default", "delete", "do", "else", "enum", "extends",
      "extern", "final", "finally", "for", "goto", "if", "implements", "import", "inline", "interface", "namespace", "new", "operator",
      "override", "package", "private", "protected", "public", "register", "return", "sizeof", "static", "struct", "switch", "template",
      "this", "throw", "throws", "try", "typedef", "typename", "union", "using", "virtual", "volatile", "while",
    ], constants: ["true", "false", "null", "nullptr", "NULL"])
    let sql = Language(family: .sql, keywords: [
      "select", "from", "where", "and", "or", "not", "insert", "into", "values", "update", "set", "delete", "create", "table", "drop", "alter",
      "add", "index", "on", "join", "left", "right", "inner", "outer", "group", "by", "order", "having", "limit", "offset", "as", "distinct",
      "union", "all", "primary", "key", "references", "foreign", "default", "is", "null", "in", "exists", "case", "when", "then", "else",
      "end", "returning", "with", "asc", "desc", "begin", "commit", "rollback", "unique", "constraint", "if",
    ], constants: ["true", "false"], lineComments: ["--"])
    var map: [String: Language] = [:]
    for name in ["ts", "typescript", "tsx", "js", "javascript", "jsx", "mjs", "cjs", "mts", "cts"] { map[name] = script }
    for name in ["rust", "rs"] { map[name] = rust }
    map["go"] = go; map["golang"] = go
    for name in ["python", "py"] { map[name] = python }
    for name in ["bash", "sh", "shell", "zsh", "console", "shellscript"] { map[name] = shell }
    map["swift"] = swift
    for name in ["c", "h", "cpp", "c++", "cc", "hpp", "java", "kotlin", "kt", "csharp", "cs", "c#", "scala", "dart"] { map[name] = cLike }
    for name in ["json", "jsonc", "json5"] { map[name] = Language(family: .json, constants: ["true", "false", "null"]) }
    for name in ["yaml", "yml"] { map[name] = Language(family: .yaml, constants: ["true", "false", "null", "yes", "no", "on", "off"], lineComments: ["#"], blockComment: nil) }
    map["toml"] = Language(family: .toml, lineComments: ["#"], blockComment: nil)
    for name in ["css", "scss", "less"] { map[name] = Language(family: .css, constants: [], lineComments: name == "css" ? [] : ["//"]) }
    for name in ["html", "xml", "svg", "vue", "svelte"] { map[name] = Language(family: .markup, constants: [], lineComments: [], blockComment: ("<!--", "-->")) }
    for name in ["sql", "postgres", "postgresql", "sqlite", "mysql"] { map[name] = sql }
    for name in ["diff", "patch"] { map[name] = Language(family: .diff) }
    return map
  }()
  static let maxLine = 2000
  public static func tokens(_ text: String, language: String) -> [Token]? {
    let name = language.split(separator: " ").first.map { $0.lowercased() } ?? ""
    guard let spec = languages[name] else { return nil }
    if spec.family == .diff { return diff(text) }
    var lexer = Lexer(chars: Array(text), spec: spec)
    lexer.run()
    return lexer.merged()
  }
  public static func attributed(_ text: String, language: String, theme: NanocodeTheme = .standard) -> AttributedString? {
    guard let tokens = tokens(text, language: language) else { return nil }
    var result = AttributedString()
    for token in tokens {
      var part = AttributedString(token.text)
      if let scope = token.scope { part.foregroundColor = scope.color(theme) }
      result.append(part)
    }
    return result
  }

  static func diff(_ text: String) -> [Token] {
    var tokens: [Token] = []
    for (index, line) in text.components(separatedBy: "\n").enumerated() {
      if index > 0 { tokens.append(Token(text: "\n", scope: nil)) }
      if line.hasPrefix("+++") || line.hasPrefix("---") || line.hasPrefix("@@") {
        tokens.append(Token(text: line, scope: line.hasPrefix("@@") ? .attribute : .keyword))
      } else if let marker = line.first, marker == "+" || marker == "-" {
        tokens.append(Token(text: String(marker), scope: .punctuation))
        tokens.append(Token(text: String(line.dropFirst()), scope: marker == "+" ? .inserted : .deleted))
      } else {
        tokens.append(Token(text: line, scope: nil))
      }
    }
    return tokens
  }

  struct Lexer {
    let chars: [Character]
    let spec: Language
    var i = 0
    var out: [Token] = []
    var commandStart = true

    func peek(_ offset: Int = 0) -> Character? { i + offset < chars.count ? chars[i + offset] : nil }
    func starts(_ s: String, at index: Int? = nil) -> Bool {
      let from = index ?? i
      var k = from
      for c in s { guard k < chars.count, chars[k] == c else { return false }; k += 1 }
      return true
    }
    mutating func emit(_ from: Int, _ scope: Scope?) { if i > from { out.append(Token(text: String(chars[from..<i]), scope: scope)) } }

    func previousSignificant(_ before: Int) -> Character? {
      var k = before - 1
      while k >= 0, chars[k] == " " || chars[k] == "\t" { k -= 1 }
      return k >= 0 ? chars[k] : nil
    }
    func nextSignificant(_ after: Int) -> Character? {
      var k = after
      while k < chars.count, chars[k] == " " || chars[k] == "\t" { k += 1 }
      return k < chars.count ? chars[k] : nil
    }
    func previousWord(_ index: Int) -> String {
      var k = index - 1
      while k >= 0, chars[k] == " " || chars[k] == "\t" { k -= 1 }
      let end = k + 1
      while k >= 0, chars[k].isLetter || chars[k].isNumber || chars[k] == "_" { k -= 1 }
      return String(chars[(k + 1)..<end])
    }

    mutating func run(until terminator: Character? = nil) {
      var depth = 0
      while i < chars.count {
        let c = chars[i]
        if let terminator {
          if c == "{" { depth += 1 } else if c == terminator { if depth == 0 { return }; depth -= 1 }
        }
        step()
      }
    }

    mutating func lineEnd() -> Int {
      var k = i
      while k < chars.count, chars[k] != "\n" { k += 1 }
      return k
    }

    mutating func step() {
      let start = i
      let c = chars[i]
      if c == "\n" { i += 1; commandStart = true; emit(start, nil); return }
      if c == " " || c == "\t" || c == "\r" { while let p = peek(), p == " " || p == "\t" || p == "\r" { i += 1 }; emit(start, nil); return }
      if start == 0 || chars[start - 1] == "\n", lineEnd() - start > maxLine { i = lineEnd(); emit(start, nil); return }
      for marker in spec.lineComments where starts(marker) {
        if spec.family == .shell, start > 0, !chars[start - 1].isWhitespace { break }
        i = lineEnd(); emit(start, .comment); return
      }
      if let (open, close) = spec.blockComment, starts(open) {
        i += open.count
        while i < chars.count, !starts(close) { i += 1 }
        i = min(chars.count, i + close.count)
        emit(start, .comment); return
      }
      switch spec.family {
      case .markup: if markup() { return }
      case .rust: if c == "#", peek(1) == "[" || (peek(1) == "!" && peek(2) == "[") { attribute(); return }
      case .python, .swift: if c == "@", peek(1)?.isLetter == true { i += 1; word(); emit(start, .attribute); return }
      case .shell:
        if c == "$" { variable(); return }
        if c == "-", start == 0 || chars[start - 1].isWhitespace, peek(1).map({ $0 == "-" || $0.isLetter }) == true {
          while let p = peek(), !p.isWhitespace, !";|&)".contains(p) { i += 1 }
          emit(start, nil); commandStart = false; return
        }
      case .yaml, .toml:
        if c.isLetter || c == "_", keyAhead() { word(extra: "-."); emit(start, .attribute); return }
        if spec.family == .toml, c == "[", start == 0 || chars[start - 1] == "\n" { i = lineEnd(); emit(start, .keyword); return }
      case .css:
        if c == "#" || c == ".", peek(1)?.isLetter == true, nextSignificantBrace() { i += 1; word(extra: "-"); emit(start, .function); return }
        if c.isLetter || c == "-", keyAhead() { word(extra: "-"); emit(start, .attribute); return }
      default: break
      }
      if spec.quotes.contains(c) || (spec.family == .python && (c == "f" || c == "r" || c == "b") && peek(1).map { spec.quotes.contains($0) } == true) {
        string(); return
      }
      if spec.family == .rust, c == "'", peek(1)?.isLetter == true, peek(2) != "'" { i += 1; word(); emit(start, nil); return }
      if spec.family == .rust, c == "'" { string(); return }
      if c.isNumber || (c == "." && peek(1)?.isNumber == true) {
        let prior = start > 0 ? chars[start - 1] : " "
        if !(prior.isLetter || prior == "_") {
          while let p = peek(), p.isLetter || p.isNumber || p == "_" || p == "." && peek(1)?.isNumber == true { i += 1 }
          emit(start, .number); commandStart = false; return
        }
      }
      if c.isLetter || c == "_" || (c == "$" && spec.family == .script) {
        identifier(); return
      }
      if spec.family == .shell, c == "|" || c == ";" || c == "&" || c == "(" {
        while let p = peek(), "|;&(".contains(p) { i += 1 }
        emit(start, .punctuation); commandStart = true; return
      }
      i += 1
      if "(){}[];,.".contains(c) { emit(start, .punctuation); return }
      if "=+-*/%!<>&|^~?:".contains(c) {
        while let p = peek(), "=+-*/%!<>&|^~?:".contains(p), !(p == "/" && (peek(1) == "/" || peek(1) == "*")) { i += 1 }
        emit(start, .punctuation); return
      }
      emit(start, nil)
    }

    mutating func word(extra: String = "") {
      while let p = peek(), p.isLetter || p.isNumber || p == "_" || extra.contains(p) { i += 1 }
    }
    func keyAhead() -> Bool {
      guard i == 0 || chars[i - 1].isWhitespace || chars[i - 1] == "{" || chars[i - 1] == ";" else { return false }
      var k = i
      while k < chars.count, chars[k].isLetter || chars[k].isNumber || "_-.".contains(chars[k]) { k += 1 }
      var lineStart = i
      while lineStart > 0, chars[lineStart - 1] == " " || chars[lineStart - 1] == "\t" || chars[lineStart - 1] == "-" { lineStart -= 1 }
      let first = lineStart == 0 || chars[lineStart - 1] == "\n" || spec.family == .css
      while k < chars.count, chars[k] == " " { k += 1 }
      guard first, k < chars.count else { return false }
      return spec.family == .toml ? chars[k] == "=" : chars[k] == ":" && (k + 1 == chars.count || chars[k + 1].isWhitespace || spec.family == .css)
    }

    func nextSignificantBrace() -> Bool {
      var k = i
      while k < chars.count, chars[k] != "\n", chars[k] != ";" { if chars[k] == "{" || chars[k] == "," { return true }; k += 1 }
      return false
    }

    mutating func identifier() {
      let start = i
      i += 1
      word(extra: spec.family == .script ? "$" : spec.family == .shell ? "-." : "")
      let text = String(chars[start..<i])
      let before = previousSignificant(start)
      let next = nextSignificant(i)
      var scope: Scope?
      let member = before == "." && !(start >= 2 && chars[start - 2] == ".")
      if spec.family == .shell {
        if spec.keywords.contains(text) { scope = .keyword } else if commandStart { scope = .function }
        commandStart = spec.keywords.contains(text)
        emit(start, scope)
        return
      }
      if spec.family == .json { emit(start, spec.constants.contains(text) ? .number : nil); return }
      if spec.family == .yaml || spec.family == .toml || spec.family == .css {
        emit(start, spec.constants.contains(text) ? .number : nil); return
      }
      let keywords = spec.family == .sql ? Set(spec.keywords.map { $0 }) : spec.keywords
      let key = spec.family == .sql ? text.lowercased() : text
      let defining = ["function", "fn", "def", "func"].contains(previousWord(start))
      if !member, keywords.contains(key) {
        scope = .keyword
      } else if !member, spec.constants.contains(text) {
        scope = .number
      } else if defining || next == "(" || (spec.family == .rust && next == "!" && (i + 1 < chars.count && chars[i + 1] != "=")) {
        scope = text.first!.isUppercase && !defining ? nil : .function
        if spec.family == .rust, next == "!" { scope = .function; while peek() == " " { i += 1 }; i += 1 }
      } else if text.count > 1, text == text.uppercased(), text.contains(where: \.isLetter), !member {
        scope = .number
      }
      emit(start, scope)
    }

    mutating func variable() {
      let start = i
      i += 1
      if peek() == "{" { while let p = peek(), p != "}" { i += 1 }; if peek() == "}" { i += 1 } }
      else if peek() == "(" { emit(start, .punctuation); return }
      else { word() ; if i == start + 1, let p = peek(), "?@#*!$0123456789".contains(p) { i += 1 } }
      emit(start, nil)
      commandStart = false
    }

    mutating func string() {
      let start = i
      while let p = peek(), !spec.quotes.contains(p) { i += 1 }
      let quote = chars[i]
      i += 1
      if spec.family == .script || spec.family == .python || spec.family == .swift, starts(String(repeating: quote, count: 2)), quote != "`",
         spec.family != .script {
        i += 2
        while i < chars.count, !starts(String(repeating: quote, count: 3)) { i += 1 }
        i = min(chars.count, i + 3)
        emit(start, .string); commandStart = false; return
      }
      var scope: Scope = .string
      while i < chars.count, chars[i] != quote {
        if chars[i] == "\\" { i += 2; continue }
        if chars[i] == "\n", quote != "`", spec.family != .shell { break }
        if quote == "`", spec.family == .script, starts("${") {
          emit(start, .string)
          let open = i
          i += 2
          emit(open, nil)
          run(until: "}")
          let close = i
          if i < chars.count { i += 1 }
          emit(close, nil)
          string(continuing: quote)
          return
        }
        if spec.family == .shell, quote == "\"", chars[i] == "$" {
          emit(start, .string)
          variable()
          string(continuing: quote)
          return
        }
        i += 1
      }
      if i < chars.count, chars[i] == quote { i += 1 }
      if spec.family == .json, nextSignificant(i) == ":" { scope = .attribute }
      emit(start, scope)
      commandStart = false
    }
    mutating func string(continuing quote: Character) {
      let start = i
      while i < chars.count, chars[i] != quote {
        if chars[i] == "\\" { i += 2; continue }
        if quote == "`", starts("${") {
          emit(start, .string)
          let open = i
          i += 2
          emit(open, nil)
          run(until: "}")
          let close = i
          if i < chars.count { i += 1 }
          emit(close, nil)
          string(continuing: quote)
          return
        }
        if spec.family == .shell, chars[i] == "$" { emit(start, .string); variable(); string(continuing: quote); return }
        i += 1
      }
      if i < chars.count { i += 1 }
      i = min(i, chars.count)
      emit(start, .string)
    }
    mutating func attribute() {
      let start = i
      i += chars[i + 1] == "!" ? 3 : 2
      emit(start, .punctuation)
      let name = i
      word(extra: ":")
      emit(name, .attribute)
      run(until: "]")
      let close = i
      if i < chars.count { i += 1 }
      emit(close, .punctuation)
    }
    mutating func markup() -> Bool {
      let start = i
      guard chars[i] == "<", let next = peek(1), next.isLetter || next == "/" || next == "!" || next == "?" else { return false }
      i += next == "/" ? 2 : 1
      emit(start, .punctuation)
      let name = i
      word(extra: "-:!?")
      emit(name, .keyword)
      while i < chars.count, chars[i] != ">" {
        let from = i
        if chars[i] == "\"" || chars[i] == "'" {
          let quote = chars[i]; i += 1
          while i < chars.count, chars[i] != quote { i += 1 }
          if i < chars.count { i += 1 }
          emit(from, .string)
        } else if chars[i].isLetter {
          word(extra: "-:")
          emit(from, .attribute)
        } else {
          i += 1
          emit(from, chars[from].isWhitespace ? nil : .punctuation)
        }
      }
      let close = i
      if i < chars.count { i += 1 }
      emit(close, .punctuation)
      return true
    }
    func merged() -> [Token] {
      var result: [Token] = []
      for token in out {
        if let last = result.last, last.scope == token.scope {
          result[result.count - 1] = Token(text: last.text + token.text, scope: token.scope)
        } else { result.append(token) }
      }
      return result
    }
  }
}
