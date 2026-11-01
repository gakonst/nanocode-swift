#if os(iOS) || os(macOS)
import Foundation
import Nanocode

enum Entitlements {
  static let healthKey = "com.apple.developer.healthkit"
  static let homeKey = "com.apple.developer.homekit"
  static let nfcKey = "com.apple.developer.nfc.readersession.formats"
  static let walletKey = "com.apple.developer.pass-type-identifiers"
  static let focusKey = "com.apple.developer.usernotifications.communication"
  static let timeSensitiveKey = "com.apple.developer.usernotifications.time-sensitive"

  static let granted: Set<String> = load()

  static func has(_ key: String) -> Bool { granted.contains(key) }
  static var health: Bool { has(healthKey) }
  static var home: Bool { has(homeKey) }
  static var nfc: Bool { has(nfcKey) }
  static var wallet: Bool { has(walletKey) }
  static var focus: Bool { has(focusKey) }
  static var timeSensitive: Bool { has(timeSensitiveKey) }

  static func load() -> Set<String> {
    guard let url = Bundle.main.executableURL, let data = try? Data(contentsOf: url, options: .alwaysMapped),
          let plist = find(in: data),
          let object = try? PropertyListSerialization.propertyList(from: plist, format: nil) as? [String: Any] else { return [] }
    return Set(object.compactMap { key, value in truthy(value) ? key : nil })
  }

  static func truthy(_ value: Any) -> Bool {
    switch value {
    case let flag as Bool: flag
    case let list as [Any]: !list.isEmpty
    case let text as String: !text.isEmpty
    default: true
    }
  }

  static func find(in data: Data) -> Data? {
    let magic = word(data, 0, big: true)
    guard magic == 0xcafebabe || magic == 0xcafebabf else { return thin(data, 0) }
    let wide = magic == 0xcafebabf
    let stride = wide ? 32 : 20
    var slices: [(cpu: UInt32, offset: Int)] = []
    for index in 0..<Int(word(data, 4, big: true)) {
      let base = 8 + index * stride
      let offset = wide ? Int(long(data, base + 8, big: true)) : Int(word(data, base + 8, big: true))
      slices.append((word(data, base, big: true), offset))
    }
    let preferred = slices.filter { $0.cpu == 0x0100000c } + slices.filter { $0.cpu != 0x0100000c }
    for slice in preferred { if let found = thin(data, slice.offset) { return found } }
    return nil
  }

  static func thin(_ data: Data, _ start: Int) -> Data? {
    guard word(data, start, big: false) == 0xfeedfacf else { return nil }
    let commands = Int(word(data, start + 16, big: false))
    var cursor = start + 32
    var section: Data?
    for _ in 0..<commands {
      guard cursor + 8 <= data.count else { break }
      let command = word(data, cursor, big: false)
      let size = Int(word(data, cursor + 4, big: false))
      guard size >= 8 else { break }
      if command == 0x1d {
        let offset = start + Int(word(data, cursor + 8, big: false))
        if let found = signature(data, offset) { return found }
      } else if command == 0x19 {
        for index in 0..<Int(word(data, cursor + 64, big: false)) {
          let base = cursor + 72 + index * 80
          guard name(data, base) == "__entitlements" else { continue }
          let length = Int(long(data, base + 40, big: false))
          let offset = start + Int(word(data, base + 48, big: false))
          if length > 0, offset >= 0, offset + length <= data.count { section = data.subdata(in: offset..<(offset + length)) }
        }
      }
      cursor += size
    }
    return section
  }

  static func signature(_ data: Data, _ offset: Int) -> Data? {
    guard word(data, offset, big: true) == 0xfade0cc0 else { return nil }
    for index in 0..<Int(word(data, offset + 8, big: true)) {
      let entry = offset + 12 + index * 8
      guard word(data, entry, big: true) == 5 else { continue }
      let blob = offset + Int(word(data, entry + 4, big: true))
      guard word(data, blob, big: true) == 0xfade7171 else { continue }
      let length = Int(word(data, blob + 4, big: true))
      guard length > 8, blob + length <= data.count else { return nil }
      return data.subdata(in: (blob + 8)..<(blob + length))
    }
    return nil
  }

  static func word(_ data: Data, _ offset: Int, big: Bool) -> UInt32 {
    guard offset >= 0, offset + 4 <= data.count else { return 0 }
    let value = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) }
    return big ? UInt32(bigEndian: value) : UInt32(littleEndian: value)
  }

  static func long(_ data: Data, _ offset: Int, big: Bool) -> UInt64 {
    guard offset >= 0, offset + 8 <= data.count else { return 0 }
    let value = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt64.self) }
    return big ? UInt64(bigEndian: value) : UInt64(littleEndian: value)
  }

  static func name(_ data: Data, _ offset: Int) -> String {
    guard offset >= 0, offset + 16 <= data.count else { return "" }
    let bytes = data.subdata(in: offset..<(offset + 16)).prefix { $0 != 0 }
    return String(decoding: bytes, as: UTF8.self)
  }
}
#endif
