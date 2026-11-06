#if os(macOS)
import Foundation

typealias JSON = [String: Any]

public struct ComputerHost: Sendable {
    public var name: String
    public var command: String
    public var environment: String
    public var server: String
    public var helperKey: String

    public init(name: String, command: String, environment: String, server: String, helperKey: String) {
        self.name = name
        self.command = command
        self.environment = environment
        self.server = server
        self.helperKey = helperKey
    }

    static var current = ComputerHost(name: "Nanocode", command: "nanocode-computer", environment: "NANOCODE_COMPUTER",
                                      server: "nanocode-computer", helperKey: "NanocodeComputerApp")
}

func setting(_ name: String) -> String? { env[ComputerHost.current.environment + "_" + name] }

let computerVersion = "0.1.0"

struct CUAError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

final class Box<T>: @unchecked Sendable {
    var value: T?
    init() {}
}

func runSync<T>(_ op: @escaping @Sendable () async throws -> T) throws -> T {
    let box = Box<Result<T, Error>>()
    let sem = DispatchSemaphore(value: 0)
    Task.detached {
        do { box.value = .success(try await op()) } catch { box.value = .failure(error) }
        sem.signal()
    }
    sem.wait()
    return try box.value!.get()
}

func sleepMs(_ ms: Int) { if ms > 0 { usleep(useconds_t(ms) * 1000) } }

let env = ProcessInfo.processInfo.environment

func argString(_ a: JSON, _ k: String) -> String? {
    if let s = a[k] as? String { return s }
    if let n = a[k] as? NSNumber { return n.stringValue }
    return nil
}

func argInt(_ a: JSON, _ k: String) -> Int? {
    if let n = a[k] as? NSNumber { return n.intValue }
    if let s = a[k] as? String { return Int(s.trimmingCharacters(in: .whitespaces)) }
    return nil
}

func argDouble(_ a: JSON, _ k: String) -> Double? {
    if let n = a[k] as? NSNumber { return n.doubleValue }
    if let s = a[k] as? String { return Double(s.trimmingCharacters(in: .whitespaces)) }
    return nil
}

func argBool(_ a: JSON, _ k: String) -> Bool {
    if let b = a[k] as? Bool { return b }
    if let s = a[k] as? String { return s == "true" || s == "1" }
    return false
}

let bidiMarks: Set<UInt32> = [0x200E, 0x200F, 0x202A, 0x202B, 0x202C, 0x202D, 0x202E, 0x2066, 0x2067, 0x2068, 0x2069]

func clip(_ s: String?, _ limit: Int = 300) -> String? {
    guard var s = s?.unicodeScalars.filter({ !bidiMarks.contains($0.value) }).map(String.init).joined()
        .trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
    s = s.replacingOccurrences(of: "\r\n", with: "\\n")
        .replacingOccurrences(of: "\n", with: "\\n")
        .replacingOccurrences(of: "\r", with: "\\n")
        .replacingOccurrences(of: "\"", with: "\\\"")
    if s.count > limit {
        let extra = s.count - limit
        s = String(s.prefix(limit)) + "...(+\(extra) chars)"
    }
    return s
}
#endif
