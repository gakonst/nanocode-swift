import Foundation

public enum JSON: Hashable, Sendable {
  case null
  case bool(Bool)
  case number(Double)
  case string(String)
  case array([JSON])
  case object([String: JSON])

  public subscript(key: String) -> JSON? {
    if case .object(let object) = self { return object[key] }
    return nil
  }

  public subscript(index: Int) -> JSON? {
    if case .array(let array) = self, array.indices.contains(index) { return array[index] }
    return nil
  }

  public var string: String? {
    if case .string(let value) = self { return value }
    return nil
  }

  public var number: Double? {
    if case .number(let value) = self { return value }
    return nil
  }

  public var int: Int? { number.map { Int($0) } }

  public var uint64: UInt64? { number.flatMap { $0 >= 0 ? UInt64($0) : nil } }

  public var bool: Bool? {
    if case .bool(let value) = self { return value }
    return nil
  }

  public var array: [JSON]? {
    if case .array(let value) = self { return value }
    return nil
  }

  public var object: [String: JSON]? {
    if case .object(let value) = self { return value }
    return nil
  }

  public var isNull: Bool {
    if case .null = self { return true }
    return false
  }

  public init(_ value: Any?) {
    switch value {
    case nil, is NSNull: self = .null
    case let value as String: self = .string(value)
    case let value as NSNumber:
      if CFGetTypeID(value) == CFBooleanGetTypeID() { self = .bool(value.boolValue) } else { self = .number(value.doubleValue) }
    case let value as [Any]: self = .array(value.map { JSON($0) })
    case let value as [String: Any]: self = .object(value.mapValues { JSON($0) })
    default: self = .null
    }
  }

  public var foundation: Any {
    switch self {
    case .null: NSNull()
    case .bool(let value): value
    case .number(let value): value
    case .string(let value): value
    case .array(let value): value.map(\.foundation)
    case .object(let value): value.mapValues(\.foundation)
    }
  }

  public static func parse(_ data: Data) throws -> JSON {
    JSON(try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]))
  }

  public static func parse(_ text: String) -> JSON? {
    try? parse(Data(text.utf8))
  }

  public func data(pretty: Bool = false) -> Data {
    var options: JSONSerialization.WritingOptions = [.fragmentsAllowed, .withoutEscapingSlashes]
    if pretty { options.formUnion([.prettyPrinted, .sortedKeys]) }
    return (try? JSONSerialization.data(withJSONObject: foundation, options: options)) ?? Data("null".utf8)
  }

  public func text(pretty: Bool = false) -> String {
    String(decoding: data(pretty: pretty), as: UTF8.self)
  }

  public static func encode<T: Encodable>(_ value: T) throws -> JSON {
    let encoder = JSONEncoder()
    encoder.keyEncodingStrategy = .convertToSnakeCase
    return try parse(encoder.encode(value))
  }

  public func decode<T: Decodable>(_ type: T.Type) throws -> T {
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    return try decoder.decode(type, from: data())
  }
}

extension JSON: Codable {
  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if container.decodeNil() { self = .null }
    else if let value = try? container.decode(Bool.self) { self = .bool(value) }
    else if let value = try? container.decode(Double.self) { self = .number(value) }
    else if let value = try? container.decode(String.self) { self = .string(value) }
    else if let value = try? container.decode([JSON].self) { self = .array(value) }
    else { self = .object(try container.decode([String: JSON].self)) }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .null: try container.encodeNil()
    case .bool(let value): try container.encode(value)
    case .number(let value): try container.encode(value)
    case .string(let value): try container.encode(value)
    case .array(let value): try container.encode(value)
    case .object(let value): try container.encode(value)
    }
  }
}

extension JSON: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral,
  ExpressibleByBooleanLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral, ExpressibleByNilLiteral
{
  public init(stringLiteral value: String) { self = .string(value) }
  public init(integerLiteral value: Int) { self = .number(Double(value)) }
  public init(floatLiteral value: Double) { self = .number(value) }
  public init(booleanLiteral value: Bool) { self = .bool(value) }
  public init(arrayLiteral elements: JSON...) { self = .array(elements) }
  public init(dictionaryLiteral elements: (String, JSON)...) {
    self = .object(Dictionary(elements, uniquingKeysWith: { $1 }))
  }
  public init(nilLiteral: ()) { self = .null }
}

extension Optional where Wrapped == String {
  var json: JSON { map(JSON.string) ?? .null }
}
