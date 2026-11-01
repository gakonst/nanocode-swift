#if os(iOS)
import Foundation
import Nanocode
import UIKit
import UniformTypeIdentifiers

extension DeviceKit {
  static let fileActions = ["containers", "list", "read", "write", "delete", "move", "copy", "mkdir", "info", "pick", "export", "share"]
  static let readBytes = 262_144
  static let mostReadBytes = 5 * 1024 * 1024

  static let fileProperties: [String: JSON] = [
    "container": choice(["documents", "library", "caches", "tmp", "group", "picked"],
                        "Where the path is: documents (default; visible in the Files app under \(DeviceTools.settings.app)), library, caches, tmp, group (shared with the widget), picked (files the owner picked)."),
    "path": prop("string", "A path inside the container, such as notes/today.md; empty for its top."),
    "to": prop("string", "For move and copy: the new path."),
    "to_container": prop("string", "For move and copy: the new container; the same one by default."),
    "text": prop("string", "For write: text to write."),
    "base64": prop("string", "For write: bytes to write."),
    "append": prop("boolean", "For write: add to the end instead of replacing."),
    "as": choice(["text", "base64", "image"], "For read: text (default), base64 bytes, or an image to look at."),
    "offset": prop("integer", "For read: start at this byte."),
    "length": prop("integer", "For read: read this many bytes (256 KiB by default); next_offset continues."),
    "recursive": prop("boolean", "For list: include everything below."),
    "types": list(prop("string"), "For pick: file types such as pdf, image, text, public.spreadsheet or an extension; anything by default."),
    "multiple": prop("boolean", "For pick: let the owner pick several files."),
  ]

  static let files = HostTool(
    name: "files",
    description: "Files on this iPhone. \(DeviceTools.settings.app)'s own containers (documents, library, caches, tmp, group, picked): containers, list, info, read (text, base64 or an image, paged by byte offset), write, delete, move, copy, mkdir. pick: the owner picks files from the Files app (iCloud Drive, other apps, servers); copies land in the picked container. export: save one of \(DeviceTools.settings.app)'s files where the owner chooses in Files. share: the share sheet for a file. pick, export and share need \(DeviceTools.settings.app) open.",
    parameters: schema(fileActions, fileProperties),
    content: true
  ) { call in try await fileSystem(call.input) }

  static func container(_ name: String?) throws -> URL {
    let manager = FileManager.default
    switch name ?? "documents" {
    case "documents": return try manager.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
    case "library": return try manager.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
    case "caches": return try manager.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
    case "tmp": return manager.temporaryDirectory
    case "group":
      guard let url = manager.containerURL(forSecurityApplicationGroupIdentifier: DeviceTools.settings.appGroup ?? "") else {
        throw NanocodeError("this build has no app group container (it was signed without App Groups)")
      }
      return url
    case "picked":
      let url = try manager.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("Picked", isDirectory: true)
      try manager.createDirectory(at: url, withIntermediateDirectories: true)
      return url
    default: throw NanocodeError("container is documents, library, caches, tmp, group or picked")
    }
  }

  static func fileURL(_ input: JSON, path key: String = "path", container containerKey: String = "container") throws -> URL {
    let root = try container(text(input, containerKey) ?? (containerKey == "to_container" ? text(input, "container") : nil)).standardizedFileURL
    let relative = (input[key]?.string ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
    let url = (relative.isEmpty ? root : root.appendingPathComponent(relative)).standardizedFileURL
    guard url.path == root.path || url.path.hasPrefix(root.path + "/") else { throw NanocodeError("\(key) must stay inside the container") }
    return url
  }

  static func relative(_ url: URL, in root: URL) -> String {
    let base = root.standardizedFileURL.path
    let path = url.standardizedFileURL.path
    return path.hasPrefix(base + "/") ? String(path.dropFirst(base.count + 1)) : path == base ? "" : path
  }

  static func info(_ url: URL, root: URL) -> JSON {
    let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .contentTypeKey])
    var object: [String: JSON] = ["path": .string(relative(url, in: root)), "name": .string(url.lastPathComponent),
                                  "kind": .string(values?.isDirectory == true ? "folder" : "file")]
    if let size = values?.fileSize { object["bytes"] = .number(Double(size)) }
    if let modified = values?.contentModificationDate { object["modified"] = DeviceTools.stamp(modified) }
    if let type = values?.contentType { object["type"] = .string(type.identifier) }
    return .object(object)
  }

  static func fileSystem(_ input: JSON) async throws -> ToolResult {
    let manager = FileManager.default
    switch input["action"]?.string {
    case "containers":
      return .json(.array(["documents", "library", "caches", "tmp", "group", "picked"].map { name in
        ["name": .string(name), "available": .bool((try? container(name)) != nil)]
      }))
    case "list":
      let root = try container(text(input, "container"))
      let url = try fileURL(input)
      var found: [URL] = []
      if input["recursive"]?.bool == true {
        let walker = manager.enumerator(at: url, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey])
        while let next = walker?.nextObject() as? URL { found.append(next) }
      } else {
        found = try manager.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey])
      }
      let sorted = found.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
      return .json(try page(sorted.map { info($0, root: root) }, input, 200, most: 100_000))
    case "info":
      let url = try fileURL(input)
      guard manager.fileExists(atPath: url.path) else { throw NanocodeError("nothing is at \(input["path"]?.string ?? "")") }
      return .json(info(url, root: try container(text(input, "container"))))
    case "read":
      let url = try fileURL(input)
      let handle = try FileHandle(forReadingFrom: url)
      defer { try? handle.close() }
      let total = Int(try handle.seekToEnd())
      let kind = input["as"]?.string ?? "text"
      if kind == "image" {
        try handle.seek(toOffset: 0)
        let bytes = try handle.readToEnd() ?? Data()
        return try DeviceTools.image(bytes, description: ["path": .string(input["path"]?.string ?? ""), "bytes": .number(Double(total))])
      }
      let offset = max(input["offset"]?.int ?? 0, 0)
      let length = input["length"]?.int ?? readBytes
      guard length >= 1, length <= mostReadBytes else {
        throw NanocodeError("length is 1 to \(mostReadBytes) bytes: one answer from this iPhone carries at most 8 MiB (the session's REMOTE_MAX_FRAME_BYTES) and base64 grows bytes by a third; page with offset")
      }
      try handle.seek(toOffset: UInt64(min(offset, total)))
      let bytes = try handle.read(upToCount: length) ?? Data()
      let end = min(offset, total) + bytes.count
      var object: [String: JSON] = ["path": .string(input["path"]?.string ?? ""), "bytes": .number(Double(total)), "offset": .number(Double(min(offset, total))),
                                    "next_offset": end < total ? .number(Double(end)) : .null]
      if kind == "base64" {
        object["base64"] = .string(bytes.base64EncodedString())
      } else {
        guard let text = String(data: bytes, encoding: .utf8) ?? (end < total ? String(decoding: bytes, as: UTF8.self) : nil) else {
          throw NanocodeError("that file is not UTF-8 text; read it as base64 or image")
        }
        object["text"] = .string(text)
      }
      return .json(.object(object))
    case "write":
      let url = try fileURL(input)
      let data: Data
      if let base64 = input["base64"]?.string {
        guard let decoded = Data(base64Encoded: base64) else { throw NanocodeError("base64 is not valid base64") }
        data = decoded
      } else if let text = input["text"]?.string {
        data = Data(text.utf8)
      } else {
        throw NanocodeError("write takes text or base64")
      }
      try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      if input["append"]?.bool == true, manager.fileExists(atPath: url.path) {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
      } else {
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
      }
      return .json(info(url, root: try container(text(input, "container"))))
    case "delete":
      let url = try fileURL(input)
      guard url != (try container(text(input, "container"))).standardizedFileURL else { throw NanocodeError("delete takes a path, not the whole container") }
      try manager.removeItem(at: url)
      return .json(["deleted": .string(input["path"]?.string ?? "")])
    case "move", "copy":
      let from = try fileURL(input)
      let to = try fileURL(input, path: "to", container: "to_container")
      try manager.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
      if input["action"]?.string == "move" { try manager.moveItem(at: from, to: to) } else { try manager.copyItem(at: from, to: to) }
      return .json(info(to, root: try container(text(input, "to_container") ?? text(input, "container"))))
    case "mkdir":
      let url = try fileURL(input)
      try manager.createDirectory(at: url, withIntermediateDirectories: true)
      return .json(info(url, root: try container(text(input, "container"))))
    case "pick":
      try await foreground("Picking files")
      let types = try texts(input, "types").map(contentType)
      let picked = try await pick(types.isEmpty ? [.item] : types, multiple: input["multiple"]?.bool ?? false)
      guard !picked.isEmpty else { return .text("The owner cancelled.") }
      let root = try container("picked")
      var copies: [JSON] = []
      for url in picked {
        let target = root.appendingPathComponent(UUID().uuidString.prefix(8).lowercased() + "-" + url.lastPathComponent)
        try manager.copyItem(at: url, to: target)
        copies.append(info(target, root: root))
      }
      return .json(["container": "picked", "files": .array(copies)])
    case "export":
      try await foreground("Exporting a file")
      let url = try fileURL(input)
      guard manager.fileExists(atPath: url.path) else { throw NanocodeError("nothing is at \(input["path"]?.string ?? "")") }
      let saved = try await export(url)
      return .text(saved ? "The owner saved \(url.lastPathComponent) in Files." : "The owner cancelled.")
    case "share":
      try await foreground("Sharing a file")
      let url = try fileURL(input)
      guard manager.fileExists(atPath: url.path) else { throw NanocodeError("nothing is at \(input["path"]?.string ?? "")") }
      let outcome = try await share([url])
      return .text(outcome)
    default:
      throw unknown("files", fileActions)
    }
  }

  static func contentType(_ name: String) throws -> UTType {
    switch name.lowercased() {
    case "pdf": return .pdf
    case "image", "images", "photo": return .image
    case "text": return .text
    case "audio": return .audio
    case "movie", "video": return .movie
    case "spreadsheet": return .spreadsheet
    case "presentation": return .presentation
    case "archive", "zip": return .archive
    case "json": return .json
    case "any", "item", "file": return .item
    default:
      if let type = UTType(name) ?? UTType(filenameExtension: name.trimmingCharacters(in: CharacterSet(charactersIn: "."))) { return type }
      throw NanocodeError("\(name) is not a file type")
    }
  }

  @MainActor final class Picker: NSObject, UIDocumentPickerDelegate {
    var done: CheckedContinuation<[URL], Never>?

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
      done?.resume(returning: urls)
      done = nil
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
      done?.resume(returning: [])
      done = nil
    }
  }

  @MainActor static func pick(_ types: [UTType], multiple: Bool) async throws -> [URL] {
    let presenter = try DeviceTools.top()
    let delegate = Picker()
    let controller = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: true)
    controller.allowsMultipleSelection = multiple
    controller.delegate = delegate
    let urls = await withCheckedContinuation { continuation in
      delegate.done = continuation
      presenter.present(controller, animated: true)
    }
    withExtendedLifetime(delegate) {}
    return urls
  }

  @MainActor static func export(_ url: URL) async throws -> Bool {
    let presenter = try DeviceTools.top()
    let delegate = Picker()
    let controller = UIDocumentPickerViewController(forExporting: [url], asCopy: true)
    controller.delegate = delegate
    let urls = await withCheckedContinuation { continuation in
      delegate.done = continuation
      presenter.present(controller, animated: true)
    }
    withExtendedLifetime(delegate) {}
    return !urls.isEmpty
  }

  @MainActor static func share(_ items: [Any]) async throws -> String {
    let presenter = try DeviceTools.top()
    let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
    controller.popoverPresentationController?.sourceView = presenter.view
    return await withCheckedContinuation { continuation in
      controller.completionWithItemsHandler = { activity, completed, _, error in
        if let error { continuation.resume(returning: "Sharing failed: \(error.localizedDescription)") }
        else if completed { continuation.resume(returning: "Shared\(activity.map { " with \($0.rawValue)" } ?? "").") }
        else { continuation.resume(returning: "The owner closed the share sheet.") }
      }
      presenter.present(controller, animated: true)
    }
  }
}
#endif
