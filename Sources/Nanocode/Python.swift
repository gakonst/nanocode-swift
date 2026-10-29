import Darwin
import Foundation
import Observation
import WebKit

@MainActor
@Observable
public final class PythonHost: NSObject, WKURLSchemeHandler {
  public enum State: Sendable, Equatable {
    case idle
    case loading
    case ready(version: String)
    case failed(String)
  }

  public static let scheme = "nanocode-python"
  public private(set) var state: State = .idle
  public let packages: [String]
  @ObservationIgnored let runtime: NanocodeRuntime
  @ObservationIgnored let cache: URL
  @ObservationIgnored var webView: WKWebView?
  @ObservationIgnored var booted: Task<String, Error>?
  @ObservationIgnored var stopped: Set<ObjectIdentifier> = []
  @ObservationIgnored var cancelled: Set<Int> = []

  public init(runtime: NanocodeRuntime, cache: URL? = nil, packages: [String] = ["numpy", "pandas", "matplotlib", "micropip"]) {
    self.runtime = runtime
    self.cache = cache ?? runtime.dataDirectory.appendingPathComponent("pyodide", isDirectory: true)
    self.packages = packages
    super.init()
  }

  public func start() {
    guard webView == nil else { return }
    let configuration = WKWebViewConfiguration()
    configuration.setURLSchemeHandler(self, forURLScheme: Self.scheme)
    let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 1, height: 1), configuration: configuration)
    self.webView = webView
    booted = Task { try await self.boot(webView) }
    runtime.setPythonHost { [weak self] request in
      guard let self else { throw NanocodeError("Python stopped") }
      return try await self.run(request)
    }
  }

  func boot(_ webView: WKWebView) async throws -> String {
    state = .loading
    do {
      webView.load(URLRequest(url: URL(string: "\(Self.scheme)://cdn.jsdelivr.net/__nanocode__/index.html")!))
      var waited = 0
      while (try? await webView.evaluateJavaScript("typeof nanocodePython")) as? String != "function" {
        waited += 1
        if waited > 600 { throw NanocodeError("the Python page did not load in 60 s") }
        try await Task.sleep(nanoseconds: 100_000_000)
      }
      guard let version = try await call(webView, "return await nanocodePreload(packages)", ["packages": packages]) as? String else {
        throw NanocodeError("Python reported no version")
      }
      state = .ready(version: version)
      return version
    } catch {
      state = .failed(error.localizedDescription)
      booted = nil
      throw error
    }
  }

  func run(_ request: String) async throws -> String {
    guard let webView else { throw NanocodeError("Python has not started") }
    let fields = try JSONSerialization.jsonObject(with: Data(request.utf8)) as? [String: Any] ?? [:]
    if let id = fields["cancel"] as? Int {
      cancelled.insert(id)
      _ = try await call(webView, "if (window.nanocodeCancel) nanocodeCancel(id)", ["id": id])
      return "{}"
    }
    let id = fields["id"] as? Int
    defer { if let id { cancelled.remove(id) } }
    if booted == nil { booted = Task { try await self.boot(webView) } }
    _ = try await booted?.value
    guard let reply = try await call(webView, "return await nanocodePython(request)", ["request": request]) as? String else {
      throw NanocodeError("Python answered nothing")
    }
    return reply
  }

  func call(_ webView: WKWebView, _ body: String, _ arguments: [String: Any]) async throws -> Any? {
    do {
      return try await webView.callAsyncJavaScript(body, arguments: arguments, in: nil, contentWorld: .page)
    } catch let error as NSError where error.userInfo["WKJavaScriptExceptionMessage"] != nil {
      throw NanocodeError("\(error.userInfo["WKJavaScriptExceptionMessage"] ?? "")")
    }
  }

  static let page = """
    <!doctype html>
    <html><head><meta charset="utf-8">
    <script src="/__nanocode__/python.js"></script>
    <script src="/__nanocode__/pyodide-host.js"></script>
    </head><body></body></html>
    """

  struct Reply {
    var data = Data()
    var type = "application/octet-stream"
    var error: String?
  }

  static func type(_ path: String) -> String {
    switch (path as NSString).pathExtension {
    case "html": "text/html; charset=utf-8"
    case "js", "mjs": "text/javascript; charset=utf-8"
    case "json": "application/json"
    case "wasm": "application/wasm"
    case "zip", "whl": "application/zip"
    default: "application/octet-stream"
    }
  }

  static func resource(_ name: String) throws -> Data {
    guard let file = Bundle.module.url(forResource: name, withExtension: "js") else { throw NanocodeError("\(name).js is missing from the package") }
    return try Data(contentsOf: file)
  }

  func cached(_ host: String, _ path: String) -> URL {
    var name = String(path.drop { $0 == "/" })
    if name.isEmpty || name.hasSuffix("/") { name += "__index__" }
    return cache.appendingPathComponent(host, isDirectory: true).appendingPathComponent(name)
  }

  func download(_ remote: URL, headers: [String: String], to saved: URL?) async throws -> Reply {
    if let saved, FileManager.default.fileExists(atPath: saved.path) {
      return Reply(data: try Data(contentsOf: saved), type: Self.type(saved.path))
    }
    var request = URLRequest(url: remote)
    for (name, value) in headers where name.lowercased() == "accept" { request.setValue(value, forHTTPHeaderField: name) }
    let (data, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
      throw NanocodeError("\(remote.absoluteString) answered \((response as? HTTPURLResponse)?.statusCode ?? 0)")
    }
    let type = http.value(forHTTPHeaderField: "Content-Type") ?? Self.type(remote.path)
    if let saved {
      try FileManager.default.createDirectory(at: saved.deletingLastPathComponent(), withIntermediateDirectories: true)
      try data.write(to: saved, options: .atomic)
    }
    return Reply(data: data, type: type)
  }

  func asset(_ request: URLRequest) async throws -> Reply {
    guard let url = request.url, let parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { throw NanocodeError("bad request") }
    let path = parts.path
    let query = Dictionary(parts.queryItems?.map { ($0.name, $0.value ?? "") } ?? [], uniquingKeysWith: { _, last in last })
    if path.hasPrefix("/__fs__/") { return HostFiles.answer(String(path.dropFirst("/__fs__/".count)), query, body: Self.body(request)) }
    switch path {
    case "/__nanocode__/index.html": return Reply(data: Data(Self.page.utf8), type: Self.type(path))
    case "/__nanocode__/python.js": return Reply(data: try Self.resource("python"), type: Self.type(path))
    case "/__nanocode__/pyodide-host.js": return Reply(data: try Self.resource("pyodide-host"), type: Self.type(path))
    case "/__nanocode__/cancelled":
      return Reply(data: Data((query["run"].flatMap(Int.init).map(cancelled.contains) == true ? "1" : "0").utf8), type: "text/plain")
    case "/__nanocode__/pip":
      let saved = cache.appendingPathComponent("wheels.json")
      if request.httpMethod == "POST" {
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try Self.body(request).write(to: saved, options: .atomic)
      }
      guard FileManager.default.fileExists(atPath: saved.path) else { return Reply(data: Data("[]".utf8), type: "application/json") }
      return Reply(data: try Data(contentsOf: saved), type: "application/json")
    default: break
    }
    if path.hasPrefix("/__proxy__/") {
      let rest = path.dropFirst("/__proxy__/".count)
      let host = String(rest.prefix { $0 != "/" })
      let inner = String(rest.dropFirst(host.count))
      guard ["pypi.org", "files.pythonhosted.org"].contains(host),
            let remote = URL(string: "https://\(host)\(inner)\(parts.percentEncodedQuery.map { "?" + $0 } ?? "")") else {
        throw NanocodeError("this page proxies only PyPI")
      }
      return try await download(remote, headers: request.allHTTPHeaderFields ?? [:], to: host == "pypi.org" ? nil : cached(host, inner))
    }
    let host = url.host ?? "cdn.jsdelivr.net"
    guard let remote = URL(string: "https://\(host)\(path)") else { throw NanocodeError("bad URL \(url)") }
    return try await download(remote, headers: [:], to: cached(host, path))
  }

  static func body(_ request: URLRequest) -> Data {
    if let body = request.httpBody { return body }
    guard let stream = request.httpBodyStream else { return Data() }
    stream.open()
    defer { stream.close() }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 1 << 16)
    while true {
      let count = stream.read(&buffer, maxLength: buffer.count)
      if count <= 0 { break }
      data.append(buffer, count: count)
    }
    return data
  }

  public func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
    guard let url = task.request.url else { return }
    let key = ObjectIdentifier(task)
    stopped.remove(key)
    let request = task.request
    Task {
      let result: Result<Reply, Error>
      do { result = .success(try await asset(request)) } catch { result = .failure(error) }
      guard !stopped.contains(key) else { return }
      switch result {
      case .success(let reply):
        var headers = ["Content-Type": reply.type, "Content-Length": String(reply.data.count), "Access-Control-Allow-Origin": "*"]
        if let error = reply.error { headers["X-Nanocode-Error"] = error }
        task.didReceive(HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)!)
        task.didReceive(reply.data)
        task.didFinish()
      case .failure(let error):
        task.didFailWithError(error)
      }
    }
  }

  public func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {
    stopped.insert(ObjectIdentifier(task))
  }
}

enum HostFiles {
  static func name(_ code: Int32) -> String {
    switch code {
    case ENOENT: "ENOENT"
    case EEXIST: "EEXIST"
    case ENOTDIR: "ENOTDIR"
    case EISDIR: "EISDIR"
    case ENOTEMPTY: "ENOTEMPTY"
    case EACCES: "EACCES"
    case EPERM: "EPERM"
    case EINVAL: "EINVAL"
    case EXDEV: "EXDEV"
    case ENOSPC: "ENOSPC"
    case ELOOP: "ELOOP"
    case EBUSY: "EBUSY"
    case EROFS: "EROFS"
    case EFBIG: "EFBIG"
    case ENAMETOOLONG: "ENAMETOOLONG"
    default: "EIO"
    }
  }

  static func failed() -> PythonHost.Reply { PythonHost.Reply(error: name(errno)) }

  static func json(_ value: Any) -> PythonHost.Reply {
    PythonHost.Reply(data: (try? JSONSerialization.data(withJSONObject: value)) ?? Data(), type: "application/json")
  }

  static func milliseconds(_ time: timespec) -> Double { Double(time.tv_sec) * 1000 + Double(time.tv_nsec) / 1_000_000 }

  static func info(_ path: String, follow: Bool = false) -> [String: Any]? {
    var buffer = Darwin.stat()
    guard (follow ? stat(path, &buffer) : lstat(path, &buffer)) == 0 else { return nil }
    return [
      "mode": Int(buffer.st_mode), "size": Int(buffer.st_size), "nlink": Int(buffer.st_nlink),
      "atime": milliseconds(buffer.st_atimespec), "mtime": milliseconds(buffer.st_mtimespec), "ctime": milliseconds(buffer.st_ctimespec),
    ]
  }

  static func answer(_ operation: String, _ query: [String: String], body: Data) -> PythonHost.Reply {
    let path = query["p"] ?? ""
    let number = { (key: String) in Int64(Double(query[key] ?? "") ?? 0) }
    switch operation {
    case "stat":
      guard let info = info(path, follow: query["f"] == "1") else { return failed() }
      return json(info)
    case "list":
      guard let directory = opendir(path) else { return failed() }
      defer { closedir(directory) }
      var entries: [[Any]] = []
      while let entry = readdir(directory) {
        let name = withUnsafeBytes(of: entry.pointee.d_name) { raw in
          String(decoding: raw.prefix(Int(entry.pointee.d_namlen)), as: UTF8.self)
        }
        if name == "." || name == ".." { continue }
        if let info = info((path == "/" ? "" : path) + "/" + name) { entries.append([name, info]) }
      }
      return json(entries)
    case "read":
      let descriptor = open(path, O_RDONLY)
      guard descriptor >= 0 else { return failed() }
      defer { close(descriptor) }
      var data = Data(count: Int(max(0, number("n"))))
      let count = data.withUnsafeMutableBytes { pread(descriptor, $0.baseAddress, $0.count, off_t(number("o"))) }
      guard count >= 0 else { return failed() }
      data.count = count
      return PythonHost.Reply(data: data)
    case "write":
      let descriptor = open(path, O_WRONLY | O_CREAT, 0o644)
      guard descriptor >= 0 else { return failed() }
      defer { close(descriptor) }
      let count = body.withUnsafeBytes { pwrite(descriptor, $0.baseAddress, $0.count, off_t(number("o"))) }
      guard count == body.count else { return failed() }
      return json(["written": count])
    case "op":
      let other = query["q"] ?? ""
      let mode = mode_t(number("m"))
      let result: Int32
      switch query["k"] {
      case "mkdir": result = mkdir(path, mode == 0 ? 0o755 : mode)
      case "create":
        let descriptor = open(path, O_WRONLY | O_CREAT | O_TRUNC, mode == 0 ? 0o644 : mode)
        result = descriptor >= 0 ? close(descriptor) : -1
      case "rmdir": result = rmdir(path)
      case "unlink": result = unlink(path)
      case "rename": result = rename(path, other)
      case "truncate": result = truncate(path, off_t(number("n")))
      case "symlink": result = symlink(other, path)
      case "chmod": result = chmod(path, mode)
      case "utime":
        let times = [number("a"), number("m")].map { timeval(tv_sec: Int($0 / 1000), tv_usec: Int32(($0 % 1000) * 1000)) }
        result = utimes(path, times)
      case "readlink":
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
        let count = readlink(path, &buffer, Int(PATH_MAX))
        guard count >= 0 else { return failed() }
        return json(["target": String(decoding: buffer.prefix(count).map { UInt8(bitPattern: $0) }, as: UTF8.self)])
      default: return PythonHost.Reply(error: "EINVAL")
      }
      return result == 0 ? json([:]) : failed()
    default:
      return PythonHost.Reply(error: "EINVAL")
    }
  }
}
