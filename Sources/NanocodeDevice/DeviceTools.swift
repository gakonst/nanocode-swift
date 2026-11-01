#if os(iOS) || os(macOS)
import AVFoundation
import CoreLocation
#if os(iOS)
import CoreMotion
#endif
import EventKit
import Foundation
import ImageIO
import Nanocode
import os
import Photos
import Speech
#if os(iOS)
import UIKit
#else
import AppKit
#endif
import UniformTypeIdentifiers
import Vision
#if os(iOS)
import VisionKit
#endif

public struct DeviceSettings: Sendable {
  public var app: String
  public var hand: String
  public var scheme: String
  public var appGroup: String?
  public var buildKey: String?
  public var reasons: [String: String]
  public var composer: DeviceComposer?

  public init(app: String, hand: String = "iphone", scheme: String, appGroup: String? = nil, buildKey: String? = nil,
              reasons: [String: String] = [:], composer: DeviceComposer? = nil) {
    self.app = app
    self.hand = hand
    self.scheme = scheme
    self.appGroup = appGroup
    self.buildKey = buildKey
    self.reasons = reasons
    self.composer = composer
  }
}

#if os(iOS)
public typealias DevicePresenter = UIViewController
#else
public typealias DevicePresenter = NSWindow
#endif

public struct DeviceComposer: Sendable {
  public var available: @MainActor @Sendable (_ kind: String) throws -> Bool
  public var compose: @MainActor @Sendable (_ kind: String, _ to: [String], _ subject: String, _ body: String, _ from: DevicePresenter) async throws -> String

  public init(available: @escaping @MainActor @Sendable (_ kind: String) throws -> Bool,
              compose: @escaping @MainActor @Sendable (_ kind: String, _ to: [String], _ subject: String, _ body: String, _ from: DevicePresenter) async throws -> String) {
    self.available = available
    self.compose = compose
  }
}

public enum DeviceTools {
  private static let configured = OSAllocatedUnfairLock(initialState: DeviceSettings(app: "this app", scheme: ""))

  public static var settings: DeviceSettings { configured.withLock { $0 } }

  public static func configure(_ settings: DeviceSettings) { configured.withLock { $0 = settings } }

  public static var all: [HostTool] {
    [openURL, speak, photos, listen] + (settings.composer == nil ? [] : [compose]) + cameras + DeviceKit.tools
  }

  static func schema(_ properties: [String: JSON], required: [String] = []) -> JSON {
    ["type": "object", "properties": .object(properties), "required": .array(required.map(JSON.string)), "additionalProperties": false]
  }

  static func actions(_ names: [String]) -> JSON {
    ["type": "string", "enum": .array(names.map(JSON.string))]
  }

  static func stamp(_ date: Date?) -> JSON {
    guard let date else { return .null }
    return .string(date.formatted(Date.ISO8601FormatStyle(timeZone: .current)))
  }

  static func date(_ value: JSON?) -> Date? {
    if let number = value?.number { return Date(timeIntervalSince1970: number > 100_000_000_000 ? number / 1000 : number) }
    guard let text = value?.string?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
    for options: ISO8601DateFormatter.Options in [[.withInternetDateTime, .withFractionalSeconds], [.withInternetDateTime]] {
      let formatter = ISO8601DateFormatter()
      formatter.formatOptions = options
      if let date = formatter.date(from: text) { return date }
    }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = .current
    for format in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm", "yyyy-MM-dd"] {
      formatter.dateFormat = format
      if let date = formatter.date(from: text) { return date }
    }
    return nil
  }

  static func limit(_ input: JSON, _ fallback: Int, most: Int) -> Int {
    min(max(input["limit"]?.int ?? fallback, 1), most)
  }

  static func gate(_ name: String) async throws {
    switch await DeviceCapability.permission(name) {
    case .granted: return
    case .prompt:
      throw NanocodeError("\(DeviceCapability.named(name)?.label ?? name) access hasn't been asked for on this \(DeviceTools.here) yet. Ask first with tools.hands({ request: { hand: \"\(DeviceTools.settings.hand)\", capability: \"\(name)\", reason } }), saying why.")
    case .denied:
      throw NanocodeError("\(DeviceCapability.named(name)?.label ?? name) access is off for this app; the owner can turn it on in \(DeviceTools.settingsApp) › \(DeviceTools.settings.app).")
    }
  }

  static let viewEdge = 2576
  static let viewPixels = 4784 * 28 * 28
  static let frameBudget = 7 * 1024 * 1024
  static let qualities: [Double] = [0.85, 0.7, 0.55, 0.4]

  struct Preview: Sendable {
    let jpeg: Data
    let width: Int
    let height: Int
    let originalWidth: Int
    let originalHeight: Int
    var dataURL: String { "data:image/jpeg;base64," + jpeg.base64EncodedString() }
    var encodedBytes: Int { (jpeg.count + 2) / 3 * 4 + 23 }
  }

  struct Frame: @unchecked Sendable {
    let image: CGImage
    let originalWidth: Int
    let originalHeight: Int

    init(_ data: Data) throws {
      guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else {
        throw NanocodeError("the image could not be read")
      }
      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
      let width = properties?[kCGImagePropertyPixelWidth] as? Int ?? 0
      let height = properties?[kCGImagePropertyPixelHeight] as? Int ?? 0
      let orientation = properties?[kCGImagePropertyOrientation] as? Int ?? 1
      let (shownWidth, shownHeight) = orientation >= 5 ? (height, width) : (width, height)
      let longest = Double(max(shownWidth, shownHeight, 1))
      let area = Double(max(shownWidth, 1) * max(shownHeight, 1))
      let scale = min(1, Double(DeviceTools.viewEdge) / longest, (Double(DeviceTools.viewPixels) / area).squareRoot())
      let options: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceShouldCacheImmediately: true,
        kCGImageSourceThumbnailMaxPixelSize: shownWidth > 0 && shownHeight > 0 ? max(Int((longest * scale).rounded(.down)), 1) : DeviceTools.viewEdge,
      ]
      guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { throw NanocodeError("the image could not be decoded") }
      self.image = image
      originalWidth = shownWidth
      originalHeight = shownHeight
    }

    func encode(quality: Double) throws -> Preview {
      let output = NSMutableData()
      guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else {
        throw NanocodeError("the image could not be encoded")
      }
      CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
      guard CGImageDestinationFinalize(destination) else { throw NanocodeError("the image could not be encoded") }
      return Preview(jpeg: output as Data, width: image.width, height: image.height, originalWidth: originalWidth, originalHeight: originalHeight)
    }
  }

  static func preview(_ data: Data, quality: Double = 0.85) throws -> Preview {
    try Frame(data).encode(quality: quality)
  }

  static func fitted(_ frame: Frame, within budget: Int) throws -> Preview? {
    for quality in qualities {
      let preview = try frame.encode(quality: quality)
      if preview.encodedBytes <= budget { return preview }
    }
    return nil
  }

  static func images(_ ids: [String], load: @Sendable (String) async throws -> (data: Data, about: JSON)) async -> ToolResult {
    var content: [ToolContent] = []
    var listed: [JSON] = []
    var left = frameBudget
    var deferred: [String] = []
    for id in ids {
      if !deferred.isEmpty { deferred.append(id); continue }
      do {
        let (data, about) = try await load(id)
        guard let preview = try fitted(try Frame(data), within: left) else { deferred.append(id); continue }
        left -= preview.encodedBytes
        var shown = about.object ?? ["id": .string(id)]
        shown["shown_width"] = .number(Double(preview.width))
        shown["shown_height"] = .number(Double(preview.height))
        let entry = JSON.object(shown)
        content.append(.text(entry.text(pretty: false)))
        content.append(.image(dataURL: preview.dataURL))
        listed.append(entry)
      } catch {
        let failed: JSON = ["id": .string(id), "error": .string(error.localizedDescription)]
        content.append(.text(failed.text(pretty: false)))
        listed.append(failed)
      }
    }
    if !deferred.isEmpty {
      let note: JSON = [
        "not_included": .array(deferred.map(JSON.string)),
        "why": .string("one answer from this \(DeviceTools.here) carries at most 8 MiB (the session's REMOTE_MAX_FRAME_BYTES); these did not fit after the images above, so view them in another call"),
      ]
      content.append(.text(note.text(pretty: false)))
      listed.append(note)
    }
    return .content(content, structured: .array(listed))
  }

  static func recognize(_ data: Data) -> String {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return "" }
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = true
    try? VNImageRequestHandler(cgImage: image).perform([request])
    return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
  }

  static func image(_ data: Data, description: JSON) throws -> ToolResult {
    let frame = try Frame(data)
    guard let shot = try fitted(frame, within: frameBudget) else {
      throw NanocodeError("the image doesn't fit in the 8 MiB one answer from this \(DeviceTools.here) can carry (the session's REMOTE_MAX_FRAME_BYTES) even at JPEG quality \(qualities.last ?? 0)")
    }
    var shown = description.object ?? [:]
    shown["shown_width"] = .number(Double(shot.width))
    shown["shown_height"] = .number(Double(shot.height))
    return .content([.text(JSON.object(shown).text(pretty: true)), .image(dataURL: shot.dataURL)], structured: .object(shown))
  }

  #if os(iOS)
  @MainActor static func open(_ url: URL) { UIApplication.shared.open(url) }

  @MainActor static func top() throws -> UIViewController {
    let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    guard var controller = scenes.flatMap(\.windows).first(where: \.isKeyWindow)?.rootViewController ?? scenes.first?.windows.first?.rootViewController else {
      throw NanocodeError("the app is not on screen")
    }
    while let presented = controller.presentedViewController { controller = presented }
    return controller
  }
  #else
  @MainActor static func open(_ url: URL) { NSWorkspace.shared.open(url) }

  @MainActor static func top() throws -> NSWindow {
    guard let window = NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first(where: \.isVisible) else {
      throw NanocodeError("the app is not on screen")
    }
    return window
  }
  #endif

  #if os(iOS)
  static let here = "iPhone"
  static let settingsApp = "iOS Settings"

  @MainActor public static var environment: HandEnvironment {
    let device = UIDevice.current
    return HandEnvironment(platform: "ios", osVersion: "\(device.systemName) \(device.systemVersion), \(device.model)")
  }
  static func cgImage(_ image: UIImage) -> CGImage? { image.cgImage }
  #else
  static let here = "Mac"
  static let settingsApp = "System Settings"

  @MainActor public static var environment: HandEnvironment {
    HandEnvironment(platform: "darwin", osVersion: ProcessInfo.processInfo.operatingSystemVersionString)
  }
  static func cgImage(_ image: NSImage) -> CGImage? { image.cgImage(forProposedRect: nil, context: nil, hints: nil) }
  static let cameras: [HostTool] = []
  #endif

  static let openURL = HostTool(
    name: "open_url",
    description: "Opens an http or https URL in the browser on this \(DeviceTools.here).",
    parameters: schema(["url": ["type": "string", "description": "The http(s) URL to open."]], required: ["url"])
  ) { call in
    guard let text = call.input["url"]?.string, let url = URL(string: text), ["http", "https"].contains(url.scheme ?? "") else {
      throw NanocodeError("open_url takes an http or https URL")
    }
    await open(url)
    return .text("Opened \(url.absoluteString).")
  }

  @MainActor static let speaker = AVSpeechSynthesizer()

  static let speak = HostTool(
    name: "speak",
    description: "Speaks text aloud on this \(DeviceTools.here).",
    parameters: schema(["text": ["type": "string"], "language": ["type": "string", "description": "A BCP 47 language such as en-US."]], required: ["text"])
  ) { call in
    guard let text = call.input["text"]?.string else { throw NanocodeError("speak takes text") }
    let language = call.input["language"]?.string
    await MainActor.run {
      let utterance = AVSpeechUtterance(string: text)
      if let language { utterance.voice = AVSpeechSynthesisVoice(language: language) }
      speaker.speak(utterance)
    }
    return .text("Speaking.")
  }

  static let photos = HostTool(
    name: "photos",
    description: "The photo library on this \(DeviceTools.here). list: recent photos and videos, newest first. view: look at photos (ids, several per call; a video shows its poster frame), each returned as an image at up to 2576 px and 3.75 megapixels, as large as the models use; in a Code Mode cell pass the result's image items to image(). One answer carries at most 8 MiB, usually several photos: ones that don't fit are listed as not_included, so view those in another call. text: read the text in photos.",
    parameters: schema([
      "action": actions(["list", "view", "text"]),
      "limit": ["type": "integer", "description": "For list: how many, 20 by default and at most 200."],
      "since": ["type": "string", "description": "For list: an ISO 8601 date; only items taken after it."],
      "until": ["type": "string", "description": "For list: an ISO 8601 date; only items taken before it."],
      "media": ["type": "string", "enum": ["image", "video", "any"]],
      "favorites": ["type": "boolean", "description": "For list: only favorites."],
      "ids": ["type": "array", "items": ["type": "string"], "description": "Ids from list, for view and text."],
      "id": ["type": "string", "description": "One id from list, for view and text (the same as ids with one id)."],
    ], required: ["action"]),
    content: true
  ) { call in try await photoLibrary(call.input) }

  static func photoLibrary(_ input: JSON) async throws -> ToolResult {
    try await gate("photos")
    let ids = (input["ids"]?.array?.compactMap(\.string) ?? []) + (input["id"]?.string.map { [$0] } ?? [])
    switch input["action"]?.string {
    case "list":
      let options = PHFetchOptions()
      options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
      options.fetchLimit = limit(input, 20, most: 200)
      var predicates: [NSPredicate] = []
      switch input["media"]?.string {
      case "image": predicates.append(NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue))
      case "video": predicates.append(NSPredicate(format: "mediaType == %d", PHAssetMediaType.video.rawValue))
      default: break
      }
      if let since = date(input["since"]) { predicates.append(NSPredicate(format: "creationDate > %@", since as NSDate)) }
      if let until = date(input["until"]) { predicates.append(NSPredicate(format: "creationDate < %@", until as NSDate)) }
      if input["favorites"]?.bool == true { predicates.append(NSPredicate(format: "favorite == YES")) }
      if !predicates.isEmpty { options.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: predicates) }
      let assets = PHAsset.fetchAssets(with: options)
      return .json(.array((0..<assets.count).map { describe(assets.object(at: $0)) }))
    case "view":
      guard !ids.isEmpty else { throw NanocodeError("view takes ids of photos from list") }
      return await images(ids) { id in
        guard let asset = asset(id) else { throw NanocodeError("no photo has the id \(id)") }
        return (try await photoData(asset), describe(asset))
      }
    case "text":
      guard !ids.isEmpty else { throw NanocodeError("text takes ids of photos from list") }
      var read: [JSON] = []
      for id in ids {
        guard let asset = asset(id) else { read.append(["id": .string(id), "error": .string("no photo has the id \(id)")]); continue }
        do {
          read.append(["id": .string(id), "text": .string(recognize(try await photoData(asset)))])
        } catch {
          read.append(["id": .string(id), "error": .string(error.localizedDescription)])
        }
      }
      return .json(ids.count == 1 && input["ids"] == nil ? read[0] : .array(read))
    default:
      throw NanocodeError("photos takes the action list, view or text")
    }
  }

  static func asset(_ id: String) -> PHAsset? {
    PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject
  }

  static func describe(_ asset: PHAsset) -> JSON {
    var object: [String: JSON] = [
      "id": .string(asset.localIdentifier), "date": stamp(asset.creationDate),
      "media": .string(asset.mediaType == .video ? "video" : asset.mediaType == .image ? "image" : "other"),
      "width": .number(Double(asset.pixelWidth)), "height": .number(Double(asset.pixelHeight)), "favorite": .bool(asset.isFavorite),
    ]
    if asset.mediaType == .video { object["seconds"] = .number(asset.duration.rounded()) }
    if let location = asset.location {
      object["latitude"] = .number(location.coordinate.latitude)
      object["longitude"] = .number(location.coordinate.longitude)
    }
    return .object(object)
  }

  static func photoData(_ asset: PHAsset) async throws -> Data {
    if asset.mediaType == .video { return try await posterData(asset) }
    return try await withCheckedThrowingContinuation { continuation in
      let options = PHImageRequestOptions()
      options.isNetworkAccessAllowed = true
      options.deliveryMode = .highQualityFormat
      options.version = .current
      PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) { data, _, _, info in
        if let data {
          continuation.resume(returning: data)
        } else {
          let error = info?[PHImageErrorKey] as? Error
          continuation.resume(throwing: NanocodeError("the photo could not be loaded\(error.map { ": \($0.localizedDescription)" } ?? "")"))
        }
      }
    }
  }

  struct Poster: @unchecked Sendable { let image: CGImage }

  static func posterData(_ asset: PHAsset) async throws -> Data {
    let poster: Poster = try await withCheckedThrowingContinuation { continuation in
      let options = PHImageRequestOptions()
      options.isNetworkAccessAllowed = true
      options.deliveryMode = .highQualityFormat
      options.version = .current
      PHImageManager.default().requestImage(for: asset, targetSize: CGSize(width: viewEdge, height: viewEdge), contentMode: .aspectFit, options: options) { image, info in
        if info?[PHImageResultIsDegradedKey] as? Bool == true { return }
        if let image = image.flatMap(Self.cgImage) {
          continuation.resume(returning: Poster(image: image))
        } else {
          let error = info?[PHImageErrorKey] as? Error
          continuation.resume(throwing: NanocodeError("the video's poster frame could not be loaded\(error.map { ": \($0.localizedDescription)" } ?? "")"))
        }
      }
    }
    let output = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else {
      throw NanocodeError("the video's poster frame could not be encoded")
    }
    CGImageDestinationAddImage(destination, poster.image, [kCGImageDestinationLossyCompressionQuality: 0.95] as CFDictionary)
    guard CGImageDestinationFinalize(destination) else { throw NanocodeError("the video's poster frame could not be encoded") }
    return output as Data
  }

  nonisolated(unsafe) static let events = EKEventStore()

  @MainActor static let locator = CLLocationManager()

  static func position() async throws -> CLLocation {
    let fix = try await withThrowingTaskGroup(of: CLLocation?.self) { group in
      group.addTask {
        for try await update in CLLocationUpdate.liveUpdates() {
          if let location = update.location, location.horizontalAccuracy >= 0, location.horizontalAccuracy < 1000 { return location }
        }
        return nil
      }
      group.addTask {
        try await Task.sleep(for: .seconds(20))
        return nil
      }
      let first = try await group.next() ?? nil
      group.cancelAll()
      return first
    }
    guard let fix else { throw NanocodeError("this \(DeviceTools.here) did not find its location within 20 seconds") }
    return fix
  }

  static let listen = HostTool(
    name: "listen",
    description: "Records the microphone on this \(DeviceTools.here) for some seconds and returns what was said.",
    parameters: schema([
      "seconds": ["type": "number", "description": "How long to record, 5 by default and at most 60."],
      "language": ["type": "string", "description": .string("A BCP 47 language such as en-US; the \(DeviceTools.here)'s by default.")],
    ])
  ) { call in
    try await gate("microphone")
    let recorder = try Recorder(language: call.input["language"]?.string)
    return .json(["text": .string(try await recorder.run(seconds: min(max(call.input["seconds"]?.number ?? 5, 1), 60)))])
  }

  final class Recorder: @unchecked Sendable {
    let engine = AVAudioEngine()
    let request = SFSpeechAudioBufferRecognitionRequest()
    let recognizer: SFSpeechRecognizer
    let lock = NSLock()
    var task: SFSpeechRecognitionTask?
    var heard = ""
    var outcome: Result<String, Error>?
    var waiter: CheckedContinuation<String, Error>?

    init(language: String?) throws {
      guard let recognizer = language.map({ SFSpeechRecognizer(locale: Locale(identifier: $0)) }) ?? SFSpeechRecognizer(), recognizer.isAvailable else {
        throw NanocodeError("speech recognition is not available for this language right now")
      }
      self.recognizer = recognizer
    }

    func run(seconds: Double) async throws -> String {
      #if os(iOS)
      let session = AVAudioSession.sharedInstance()
      try session.setCategory(.record, mode: .measurement, options: .duckOthers)
      try session.setActive(true, options: .notifyOthersOnDeactivation)
      defer { try? session.setActive(false, options: .notifyOthersOnDeactivation) }
      #endif
      let input = engine.inputNode
      let format = input.outputFormat(forBus: 0)
      request.shouldReportPartialResults = true
      request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
      task = recognizer.recognitionTask(with: request) { @Sendable [self] result, error in
        if let result {
          lock.withLock { heard = result.bestTranscription.formattedString }
          if result.isFinal { finish(.success(result.bestTranscription.formattedString)) }
        } else if let error {
          finish(lock.withLock { heard.isEmpty } ? .failure(error) : .success(lock.withLock { heard }))
        }
      }
      input.installTap(onBus: 0, bufferSize: 4096, format: format) { [request] buffer, _ in request.append(buffer) }
      engine.prepare()
      try engine.start()
      try await Task.sleep(for: .seconds(seconds))
      engine.stop()
      input.removeTap(onBus: 0)
      request.endAudio()
      Task { [self] in
        try? await Task.sleep(for: .seconds(5))
        finish(.success(lock.withLock { heard }))
      }
      let text = try await withCheckedThrowingContinuation { continuation in
        lock.lock()
        if let outcome {
          lock.unlock()
          continuation.resume(with: outcome)
        } else {
          waiter = continuation
          lock.unlock()
        }
      }
      task?.cancel()
      return text
    }

    func finish(_ result: Result<String, Error>) {
      lock.lock()
      guard outcome == nil else {
        lock.unlock()
        return
      }
      outcome = result
      let waiter = self.waiter
      self.waiter = nil
      lock.unlock()
      waiter?.resume(with: result)
    }
  }

  static let compose = HostTool(
    name: "compose",
    description: "Opens a prefilled text message or email on this \(DeviceTools.here) for the owner to review and send; it sends nothing itself.",
    parameters: schema([
      "kind": ["type": "string", "enum": ["message", "email"]],
      "to": ["type": "array", "items": ["type": "string"], "description": "Phone numbers or email addresses."],
      "subject": ["type": "string"],
      "body": ["type": "string"],
    ], required: ["kind"])
  ) { call in try await draft(call.input) }

  @MainActor static func draft(_ input: JSON) async throws -> ToolResult {
    let recipients = input["to"]?.array?.compactMap(\.string) ?? []
    let presenter = try top()
    let email = input["kind"]?.string == "email"
    guard let composer = settings.composer else { throw NanocodeError("\(settings.app) does not draft messages or email") }
    guard try composer.available(email ? "email" : "message") else {
      throw NanocodeError(email ? "this \(DeviceTools.here) has no Mail account set up" : "this \(DeviceTools.here) cannot send text messages")
    }
    let result = try await composer.compose(email ? "email" : "message", recipients, input["subject"]?.string ?? "",
                                            input["body"]?.string ?? "", presenter)
    return .text(email ? "The email was \(result)." : "The message was \(result).")
  }

  #if os(iOS)
  @MainActor final class Capture: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate, @preconcurrency VNDocumentCameraViewControllerDelegate {
    var photo: CheckedContinuation<UIImage?, Never>?
    var scan: CheckedContinuation<[UIImage], Never>?

    func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
      picker.dismiss(animated: true)
      photo?.resume(returning: info[.originalImage] as? UIImage)
      photo = nil
    }

    func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
      picker.dismiss(animated: true)
      photo?.resume(returning: nil)
      photo = nil
    }

    func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFinishWith result: VNDocumentCameraScan) {
      controller.dismiss(animated: true)
      scan?.resume(returning: (0..<result.pageCount).map { result.imageOfPage(at: $0) })
      scan = nil
    }

    func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
      controller.dismiss(animated: true)
      scan?.resume(returning: [])
      scan = nil
    }

    func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFailWithError error: Error) {
      controller.dismiss(animated: true)
      scan?.resume(returning: [])
      scan = nil
    }
  }

  static let cameras = [camera]

  static let camera = HostTool(
    name: "camera",
    description: "Opens the camera on this \(DeviceTools.here) for the owner: photo takes one picture and returns it as an image (up to 2576 px and 3.75 megapixels), scan scans document pages and returns each page's text and image; in a Code Mode cell pass the result's image items to image().",
    parameters: schema(["mode": ["type": "string", "enum": ["photo", "scan"]]]),
    content: true
  ) { call in
    try await gate("camera")
    if call.input["mode"]?.string == "scan" {
      let pages = try await scanPages()
      guard !pages.isEmpty else { return .text("The owner cancelled the scan.") }
      return await images(pages.indices.map { "page-\($0 + 1)" }) { id in
        guard let index = Int(id.dropFirst(5)).map({ $0 - 1 }), pages.indices.contains(index) else { throw NanocodeError("no scanned page \(id)") }
        let data = try encoded(pages[index])
        return (data, ["page": .number(Double(index + 1)), "text": .string(recognize(data))])
      }
    }
    guard let shot = try await takePhoto() else { return .text("The owner cancelled the photo.") }
    return try image(try encoded(shot), description: ["width": .number(Double(shot.pixelWidth)), "height": .number(Double(shot.pixelHeight))])
  }

  struct Shot: @unchecked Sendable {
    let image: CGImage
    let orientation: CGImagePropertyOrientation
    var pixelWidth: Int { [.left, .right, .leftMirrored, .rightMirrored].contains(orientation) ? image.height : image.width }
    var pixelHeight: Int { [.left, .right, .leftMirrored, .rightMirrored].contains(orientation) ? image.width : image.height }

    init?(_ picture: UIImage?) {
      guard let picture, let image = picture.cgImage else { return nil }
      self.image = image
      orientation = switch picture.imageOrientation {
      case .up: .up
      case .down: .down
      case .left: .left
      case .right: .right
      case .upMirrored: .upMirrored
      case .downMirrored: .downMirrored
      case .leftMirrored: .leftMirrored
      case .rightMirrored: .rightMirrored
      @unknown default: .up
      }
    }
  }

  static func encoded(_ shot: Shot) throws -> Data {
    let output = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else {
      throw NanocodeError("the picture could not be encoded")
    }
    CGImageDestinationAddImage(destination, shot.image, [
      kCGImageDestinationLossyCompressionQuality: 0.95, kCGImagePropertyOrientation: shot.orientation.rawValue,
    ] as CFDictionary)
    guard CGImageDestinationFinalize(destination) else { throw NanocodeError("the picture could not be encoded") }
    return output as Data
  }

  @MainActor static func scanPages() async throws -> [Shot] {
    guard VNDocumentCameraViewController.isSupported else { throw NanocodeError("this \(DeviceTools.here) cannot scan documents") }
    let presenter = try top()
    let capture = Capture()
    let controller = VNDocumentCameraViewController()
    controller.delegate = capture
    let pages = await withCheckedContinuation { continuation in
      capture.scan = continuation
      presenter.present(controller, animated: true)
    }
    withExtendedLifetime(capture) {}
    return pages.compactMap { Shot($0) }
  }

  @MainActor static func takePhoto() async throws -> Shot? {
    guard UIImagePickerController.isSourceTypeAvailable(.camera) else { throw NanocodeError("this \(DeviceTools.here) has no camera available") }
    let presenter = try top()
    let capture = Capture()
    let controller = UIImagePickerController()
    controller.sourceType = .camera
    controller.delegate = capture
    let shot = await withCheckedContinuation { continuation in
      capture.photo = continuation
      presenter.present(controller, animated: true)
    }
    withExtendedLifetime(capture) {}
    return Shot(shot)
  }

  nonisolated(unsafe) static let pedometer = CMPedometer()
  nonisolated(unsafe) static let activities = CMMotionActivityManager()

  static func steps(_ start: Date, _ end: Date) async throws -> [String: JSON] {
    try await withCheckedThrowingContinuation { continuation in
      pedometer.queryPedometerData(from: start, to: end) { data, error in
        guard let data else {
          continuation.resume(throwing: error ?? NanocodeError("motion data is not available"))
          return
        }
        var object: [String: JSON] = ["steps": .number(data.numberOfSteps.doubleValue)]
        if let distance = data.distance { object["distance_m"] = .number(distance.doubleValue.rounded()) }
        if let floors = data.floorsAscended { object["floors_up"] = .number(floors.doubleValue) }
        if let floors = data.floorsDescended { object["floors_down"] = .number(floors.doubleValue) }
        continuation.resume(returning: object)
      }
    }
  }

  static func moved(_ start: Date, _ end: Date) async -> JSON {
    await withCheckedContinuation { continuation in
      activities.queryActivityStarting(from: start, to: end, to: OperationQueue()) { found, _ in
        let found = found ?? []
        var minutes: [String: Double] = [:]
        for (index, activity) in found.enumerated() {
          let until = index + 1 < found.count ? found[index + 1].startDate : end
          let kind = activity.walking ? "walking" : activity.running ? "running" : activity.cycling ? "cycling"
            : activity.automotive ? "vehicle" : activity.stationary ? "stationary" : "unknown"
          minutes[kind, default: 0] += until.timeIntervalSince(activity.startDate) / 60
        }
        continuation.resume(returning: .object(minutes.mapValues { .number($0.rounded()) }))
      }
    }
  }
  #endif
}
#endif
