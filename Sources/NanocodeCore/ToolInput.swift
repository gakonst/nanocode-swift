import Foundation

public final class ToolInput {
  public private(set) var raw = ""
  public private(set) var fields: [(String, String)] = []
  private var object: Bool?
  private var depth = 0
  private var key: String?
  private var expectingKey = true
  private enum Role { case key, value, other }
  private var role: Role?
  private var value = ""
  private var pending = ""

  public init() {}

  private func set(_ key: String, _ value: String) {
    if let index = fields.firstIndex(where: { $0.0 == key }) { fields[index].1 = value } else { fields.append((key, value)) }
  }

  public func push(_ delta: String) {
    raw += delta
    let text = Array((pending + delta).unicodeScalars)
    pending = ""
    var index = 0
    if object == nil {
      guard let start = text.firstIndex(where: { !CharacterSet.whitespacesAndNewlines.contains($0) }) else { return }
      object = text[start] == "{"
      index = start + 1
    }
    guard object == true else { return }
    while index < text.count {
      if role == nil {
        let char = text[index]
        index += 1
        if char == "\"" {
          role = depth > 0 ? .other : expectingKey ? .key : key == nil ? .other : .value
          value = ""
        } else if depth == 0, char == ":" {
          expectingKey = false
        } else if depth == 0, char == "," {
          expectingKey = true
          key = nil
        } else if char == "{" || char == "[" {
          depth += 1
        } else if char == "}" || char == "]" {
          depth -= 1
        }
        continue
      }
      var end = index
      while end < text.count, text[end] != "\"", text[end] != "\\" { end += 1 }
      value.unicodeScalars.append(contentsOf: text[index..<end])
      if end >= text.count { break }
      if text[end] == "\"" {
        if role == .key { key = value }
        else if role == .value, let key { set(key, value); self.key = nil }
        role = nil
        value = ""
        index = end + 1
        continue
      }
      guard end + 1 < text.count else {
        pending = String(String.UnicodeScalarView(text[end...]))
        break
      }
      let escape = text[end + 1]
      if escape == "u" {
        guard end + 6 <= text.count else {
          pending = String(String.UnicodeScalarView(text[end...]))
          break
        }
        let hex = String(String.UnicodeScalarView(text[(end + 2)..<(end + 6)]))
        if let code = UInt32(hex, radix: 16) {
          if (0xD800...0xDBFF).contains(code), end + 12 > text.count {
            pending = String(String.UnicodeScalarView(text[end...]))
            break
          }
          if (0xD800...0xDBFF).contains(code), end + 12 <= text.count, text[end + 6] == "\\", text[end + 7] == "u",
             let low = UInt32(String(String.UnicodeScalarView(text[(end + 8)..<(end + 12)])), radix: 16),
             (0xDC00...0xDFFF).contains(low),
             let scalar = Unicode.Scalar(0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00)) {
            value.unicodeScalars.append(scalar)
            index = end + 12
            continue
          }
          if let scalar = Unicode.Scalar(code) { value.unicodeScalars.append(scalar) }
        }
        index = end + 6
      } else {
        switch escape {
        case "b": value += "\u{8}"
        case "f": value += "\u{c}"
        case "n": value += "\n"
        case "r": value += "\r"
        case "t": value += "\t"
        default: value.unicodeScalars.append(escape)
        }
        index = end + 2
      }
    }
    if role == .value, let key { set(key, value) }
  }

  public func text() -> String {
    if fields.isEmpty { return raw }
    if fields.count == 1 { return fields[0].1 }
    return fields.map { "\($0.0): \($0.1)" }.joined(separator: "\n")
  }

  public func arguments() -> JSON {
    object == true ? .object(Dictionary(fields.map { ($0.0, JSON.string($0.1)) }, uniquingKeysWith: { $1 })) : .string(raw)
  }
}
