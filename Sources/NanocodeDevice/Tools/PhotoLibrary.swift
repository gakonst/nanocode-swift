#if os(iOS) || os(macOS)
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreLocation
import Foundation
import ImageIO
import MapKit
import Nanocode
import Photos
#if os(iOS)
import UIKit
#else
import AppKit
#endif
import UniformTypeIdentifiers
import Vision

extension DeviceKit {
  static let photoActions = ["search", "albums", "album_create", "album_add", "album_remove", "album_delete", "save", "favorite", "hide", "delete", "edit",
                             "revert", "index"]
  static let defaultScan = 300

  static let photoLibrary = HostTool(
    name: "photo_library",
    description: "The whole photo library on this \(DeviceTools.here), beyond photos' list and view. search: photos and videos by date, media, favorites, album, place (a place name, or latitude/longitude with radius_km), faces (at least this many people in it) and text in the picture (read on this \(DeviceTools.here) with Vision and remembered, so later searches are instant; scan says how many unread photos to read this time, and unscanned/next_before continue). albums: every album (yours, shared and smart). album_create, album_add, album_remove, album_delete manage albums. save: add an image or video from a file, base64 or a URL (optionally into an album). favorite and hide mark photos. delete: move photos to Recently Deleted (iOS asks the owner). edit: rotate, crop, filter or auto-enhance a photo as a new version (revert undoes it). index: how many photos have their text read. Ids come from photos list or search.",
    parameters: schema(photoActions, [
      "text": prop("string", "For search: words that appear in the picture (signs, receipts, documents, screenshots)."),
      "place": prop("string", "For search: a place name, such as Lisbon or the Acropolis."),
      "latitude": prop("number"), "longitude": prop("number"),
      "radius_km": prop("number", "For search with a place or coordinates: how far around (the place's size, or 1 km, by default)."),
      "faces": prop("integer", "For search: at least this many faces in the picture."),
      "from": when, "to": when,
      "media": choice(["image", "video", "screenshot", "live", "any"]),
      "favorites": prop("boolean", "For search: only favorites."),
      "album": prop("string", "An album name or id (search, album_add, album_remove, album_delete, save)."),
      "limit": prop("integer", "For search: how many matches (50 by default)."),
      "scan": prop("integer", "For search by text or faces: how many photos not read yet to read now (300 by default)."),
      "ids": list(prop("string"), "Photo ids."),
      "on": prop("boolean", "For favorite and hide: true to mark, false to unmark."),
      "title": prop("string", "For album_create."),
      "container": prop("string", "For save: the files container."),
      "path": prop("string", "For save: the file's path."),
      "base64": prop("string", "For save: image bytes."),
      "url": prop("string", "For save: an https image or video to download."),
      "rotate": choice(["90", "180", "270"], "For edit: degrees clockwise."),
      "crop": .object(["type": "object", "description": "For edit: x, y, width and height from 0 to 1 of the picture, from its top-left.",
                       "properties": .object(["x": prop("number"), "y": prop("number"), "width": prop("number"), "height": prop("number")])]),
      "filter": choice(["mono", "noir", "tonal", "chrome", "fade", "instant", "process", "transfer", "sepia", "vivid"]),
      "enhance": prop("boolean", "For edit: auto-enhance."),
    ])
  ) { call in try await gallery(call.input) }

  static func gallery(_ input: JSON) async throws -> ToolResult {
    try await DeviceTools.gate("photos")
    switch input["action"]?.string {
    case "search": return .json(try await photoSearch(input))
    case "albums":
      var albums: [JSON] = []
      for (kind, type) in [("album", PHAssetCollectionType.album), ("smart", .smartAlbum)] {
        let found = PHAssetCollection.fetchAssetCollections(with: type, subtype: .any, options: nil)
        found.enumerateObjects { collection, _, _ in
          let count = PHAsset.fetchAssets(in: collection, options: nil).count
          guard kind == "album" || count > 0 else { return }
          albums.append(["id": .string(collection.localIdentifier), "title": .string(collection.localizedTitle ?? ""), "kind": .string(kind),
                         "shared": .bool(collection.assetCollectionSubtype == .albumCloudShared), "count": .number(Double(count)),
                         "editable": .bool(collection.canPerform(.addContent))])
        }
      }
      return .json(.array(albums))
    case "album_create":
      let title = try need(input, "title", for: "album_create")
      nonisolated(unsafe) var id = ""
      try await PHPhotoLibrary.shared().performChanges {
        id = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: title).placeholderForCreatedAssetCollection.localIdentifier
      }
      return .json(["id": .string(id), "title": .string(title)])
    case "album_add", "album_remove":
      let action = input["action"]?.string ?? ""
      let album = try findAlbum(try need(input, "album", for: action))
      let assets = try photos(input)
      try await PHPhotoLibrary.shared().performChanges {
        let change = PHAssetCollectionChangeRequest(for: album)
        if action == "album_add" { change?.addAssets(assets as NSArray) } else { change?.removeAssets(assets as NSArray) }
      }
      let key = action == "album_add" ? "added" : "removed"
      return .json(.object(["album": .string(album.localizedTitle ?? ""), key: .number(Double(assets.count))]))
    case "album_delete":
      let album = try findAlbum(try need(input, "album", for: "album_delete"))
      try await foreground("Deleting an album")
      try await PHPhotoLibrary.shared().performChanges { PHAssetCollectionChangeRequest.deleteAssetCollections([album] as NSArray) }
      return .json(["deleted": .string(album.localizedTitle ?? "")])
    case "save":
      return .json(try await savePhoto(input))
    case "favorite", "hide":
      let action = input["action"]?.string ?? ""
      let assets = try photos(input)
      let on = input["on"]?.bool ?? true
      try await PHPhotoLibrary.shared().performChanges {
        for asset in assets {
          let change = PHAssetChangeRequest(for: asset)
          if action == "favorite" { change.isFavorite = on } else { change.isHidden = on }
        }
      }
      return .json(.object(["changed": .number(Double(assets.count)), action: .bool(on)]))
    case "delete":
      try await foreground("Deleting photos")
      let assets = try photos(input)
      try await PHPhotoLibrary.shared().performChanges { PHAssetChangeRequest.deleteAssets(assets as NSArray) }
      return .json(["deleted": .number(Double(assets.count)), "where": "Recently Deleted"])
    case "edit":
      return .json(try await editPhoto(input))
    case "revert":
      let assets = try photos(input)
      try await PHPhotoLibrary.shared().performChanges {
        for asset in assets { PHAssetChangeRequest(for: asset).revertAssetContentToOriginal() }
      }
      return .json(["reverted": .number(Double(assets.count))])
    case "index":
      let read = await PhotoIndex.shared.count()
      let total = PHAsset.fetchAssets(with: .image, options: nil).count
      return .json(["read": .number(Double(read)), "photos": .number(Double(total))])
    default:
      throw unknown("photo_library", photoActions)
    }
  }

  static func photos(_ input: JSON) throws -> [PHAsset] {
    let ids = texts(input, "ids")
    guard !ids.isEmpty else { throw NanocodeError("\(input["action"]?.string ?? "this") takes ids") }
    let found = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
    var assets: [PHAsset] = []
    found.enumerateObjects { asset, _, _ in assets.append(asset) }
    let missing = Set(ids).subtracting(assets.map(\.localIdentifier))
    guard missing.isEmpty else { throw NanocodeError("no photo has the id \(missing.sorted().joined(separator: ", "))") }
    return assets
  }

  static func findAlbum(_ key: String) throws -> PHAssetCollection {
    if let found = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [key], options: nil).firstObject { return found }
    var match: PHAssetCollection?
    for type in [PHAssetCollectionType.album, .smartAlbum] {
      PHAssetCollection.fetchAssetCollections(with: type, subtype: .any, options: nil).enumerateObjects { collection, _, stop in
        if collection.localizedTitle?.localizedCaseInsensitiveCompare(key) == .orderedSame {
          match = collection
          stop.pointee = true
        }
      }
      if match != nil { break }
    }
    guard let match else { throw NanocodeError("no album is called \(key); albums lists them") }
    return match
  }

  static func entry(_ asset: PHAsset, extra: [String: JSON] = [:]) -> JSON {
    var object: [String: JSON] = [
      "id": .string(asset.localIdentifier), "date": DeviceTools.stamp(asset.creationDate),
      "media": .string(asset.mediaType == .video ? "video" : asset.mediaType == .image ? "image" : "other"),
      "width": .number(Double(asset.pixelWidth)), "height": .number(Double(asset.pixelHeight)), "favorite": .bool(asset.isFavorite),
    ]
    if asset.mediaSubtypes.contains(.photoScreenshot) { object["screenshot"] = .bool(true) }
    if asset.mediaType == .video { object["seconds"] = .number(asset.duration.rounded()) }
    if let location = asset.location {
      object["latitude"] = .number(location.coordinate.latitude)
      object["longitude"] = .number(location.coordinate.longitude)
    }
    object.merge(extra) { _, new in new }
    return .object(object)
  }

  static func photoSearch(_ input: JSON) async throws -> JSON {
    let options = PHFetchOptions()
    options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
    options.includeHiddenAssets = false
    var predicates: [NSPredicate] = []
    switch input["media"]?.string ?? "any" {
    case "image": predicates.append(NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue))
    case "video": predicates.append(NSPredicate(format: "mediaType == %d", PHAssetMediaType.video.rawValue))
    case "screenshot": predicates.append(NSPredicate(format: "(mediaSubtypes & %d) != 0", PHAssetMediaSubtype.photoScreenshot.rawValue))
    case "live": predicates.append(NSPredicate(format: "(mediaSubtypes & %d) != 0", PHAssetMediaSubtype.photoLive.rawValue))
    case "any": break
    default: throw NanocodeError("media is image, video, screenshot, live or any")
    }
    if let since = DeviceTools.date(input["from"]) { predicates.append(NSPredicate(format: "creationDate >= %@", since as NSDate)) }
    if let until = DeviceTools.date(input["to"]) { predicates.append(NSPredicate(format: "creationDate <= %@", until as NSDate)) }
    if input["favorites"]?.bool == true { predicates.append(NSPredicate(format: "favorite == YES")) }
    if !predicates.isEmpty { options.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: predicates) }
    let fetched = if let album = text(input, "album") { PHAsset.fetchAssets(in: try findAlbum(album), options: options) } else { PHAsset.fetchAssets(with: options) }

    var center: CLLocation?
    var radius: Double?
    if let latitude = input["latitude"]?.number, let longitude = input["longitude"]?.number {
      center = CLLocation(latitude: latitude, longitude: longitude)
      radius = (input["radius_km"]?.number ?? 1) * 1000
    } else if let place = text(input, "place") {
      let request = MKLocalSearch.Request()
      request.naturalLanguageQuery = place
      let response = try await MKLocalSearch(request: request).start()
      guard let item = response.mapItems.first else { throw NanocodeError("Apple Maps found no place called \(place)") }
      center = location(of: item)
      let span = response.boundingRegion.span
      let size = max(span.latitudeDelta, span.longitudeDelta) * 111_000 / 2
      radius = input["radius_km"]?.number.map { $0 * 1000 } ?? max(size, 1000)
    }
    let words = (text(input, "text") ?? "").folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).split(separator: " ").map(String.init)
    let faces = input["faces"]?.int
    let wantsVision = !words.isEmpty || faces != nil
    let limit = try count(input, 50, most: 100_000)
    let budget = try count(input, defaultScan, most: 1_000_000, key: "scan")

    var candidates: [PHAsset] = []
    fetched.enumerateObjects { asset, _, _ in
      if let center, let radius {
        guard let spot = asset.location, spot.distance(from: center) <= radius else { return }
      }
      if wantsVision, asset.mediaType != .image { return }
      candidates.append(asset)
    }
    guard wantsVision else {
      return ["total": .number(Double(candidates.count)), "items": .array(candidates.prefix(limit).map { entry($0) })]
    }
    var matches: [JSON] = []
    var scanned = 0
    var unscanned = 0
    var oldestScanned: Date?
    for asset in candidates {
      if matches.count >= limit { break }
      var seen = await PhotoIndex.shared.entry(asset.localIdentifier)
      if seen == nil {
        guard scanned < budget else {
          unscanned += 1
          continue
        }
        if let read = await PhotoIndex.read(asset) {
          await PhotoIndex.shared.store(asset.localIdentifier, read)
          seen = read
        }
        scanned += 1
        oldestScanned = asset.creationDate
      }
      guard let seen else { continue }
      let haystack = seen.text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
      guard words.allSatisfy({ haystack.contains($0) }), seen.faces >= (faces ?? 0) else { continue }
      var extra: [String: JSON] = ["faces": .number(Double(seen.faces))]
      if !words.isEmpty { extra["text"] = .string(seen.text) }
      matches.append(entry(asset, extra: extra))
    }
    await PhotoIndex.shared.flush()
    return ["items": .array(matches), "read_now": .number(Double(scanned)), "unscanned": .number(Double(unscanned)),
            "next_before": unscanned > 0 ? DeviceTools.stamp(oldestScanned) : .null,
            "note": unscanned > 0 ? "Some photos weren't read yet; search again with a larger scan, or with to set to next_before to continue." : .null]
  }

  static func savePhoto(_ input: JSON) async throws -> JSON {
    var data: Data
    var name = "image"
    if let base64 = text(input, "base64") {
      guard let decoded = Data(base64Encoded: base64) else { throw NanocodeError("base64 is not valid base64") }
      data = decoded
    } else if let link = text(input, "url") {
      guard let url = URL(string: link), url.scheme == "https" else { throw NanocodeError("url must be https") }
      let (bytes, response) = try await URLSession.shared.data(from: url)
      if let status = (response as? HTTPURLResponse)?.statusCode, !(200..<300).contains(status) { throw NanocodeError("the download answered \(status)") }
      data = bytes
      name = url.lastPathComponent
    } else if text(input, "path") != nil {
      let url = try fileURL(input)
      data = try Data(contentsOf: url)
      name = url.lastPathComponent
    } else {
      throw NanocodeError("save takes a path, base64 or a url")
    }
    let type = CGImageSourceCreateWithData(data as CFData, nil).flatMap { CGImageSourceGetType($0) as String? }.flatMap(UTType.init)
      ?? UTType(filenameExtension: (name as NSString).pathExtension)
    let video = type?.conforms(to: .movie) == true
    guard video || type?.conforms(to: .image) == true else { throw NanocodeError("that is neither an image nor a video") }
    let album = try text(input, "album").map(findAlbum)
    let staged = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "." + (type?.preferredFilenameExtension ?? "dat"))
    try data.write(to: staged)
    defer { try? FileManager.default.removeItem(at: staged) }
    data = Data()
    nonisolated(unsafe) var id = ""
    try await PHPhotoLibrary.shared().performChanges {
      let request = PHAssetCreationRequest.forAsset()
      request.addResource(with: video ? .video : .photo, fileURL: staged, options: nil)
      if let placeholder = request.placeholderForCreatedAsset {
        id = placeholder.localIdentifier
        if let album { PHAssetCollectionChangeRequest(for: album)?.addAssets([placeholder] as NSArray) }
      }
    }
    return ["id": .string(id), "media": .string(video ? "video" : "image"), "album": string(album?.localizedTitle)]
  }

  static func editPhoto(_ input: JSON) async throws -> JSON {
    guard let asset = try photos(input).first else { throw NanocodeError("edit takes the id of a photo") }
    guard asset.mediaType == .image else { throw NanocodeError("edit works on photos") }
    guard asset.canPerform(.content) else { throw NanocodeError("that photo can't be edited") }
    let editing: PHContentEditingInput = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<EditingInput, Error>) in
      let options = PHContentEditingInputRequestOptions()
      options.isNetworkAccessAllowed = true
      asset.requestContentEditingInput(with: options) { editing, info in
        if let editing { continuation.resume(returning: EditingInput(value: editing)) } else {
          continuation.resume(throwing: (info[PHContentEditingInputErrorKey] as? Error) ?? NanocodeError("the photo could not be opened for editing"))
        }
      }
    }.value
    guard let source = editing.fullSizeImageURL, var image = CIImage(contentsOf: source, options: [.applyOrientationProperty: true]) else {
      throw NanocodeError("the photo could not be read")
    }
    var steps: [String] = []
    if input["enhance"]?.bool == true {
      for filter in image.autoAdjustmentFilters() {
        filter.setValue(image, forKey: kCIInputImageKey)
        if let output = filter.outputImage { image = output }
      }
      steps.append("enhance")
    }
    if let crop = input["crop"]?.object {
      guard let x = crop["x"]?.number, let y = crop["y"]?.number, let width = crop["width"]?.number, let height = crop["height"]?.number,
            x >= 0, y >= 0, width > 0, height > 0, x + width <= 1.0001, y + height <= 1.0001 else {
        throw NanocodeError("crop takes x, y, width and height between 0 and 1")
      }
      let extent = image.extent
      let rect = CGRect(x: extent.minX + x * extent.width, y: extent.minY + (1 - y - height) * extent.height, width: width * extent.width, height: height * extent.height)
      image = image.cropped(to: rect)
      image = image.transformed(by: CGAffineTransform(translationX: -rect.minX, y: -rect.minY))
      steps.append("crop")
    }
    if let rotate = input["rotate"]?.string {
      let orientation: CGImagePropertyOrientation = switch rotate {
      case "90": .right
      case "180": .down
      case "270": .left
      default: throw NanocodeError("rotate is 90, 180 or 270")
      }
      image = image.oriented(orientation)
      steps.append("rotate \(rotate)")
    }
    if let name = text(input, "filter") {
      let filter: CIFilter & CIFilterProtocol = switch name {
      case "mono": CIFilter.photoEffectMono()
      case "noir": CIFilter.photoEffectNoir()
      case "tonal": CIFilter.photoEffectTonal()
      case "chrome": CIFilter.photoEffectChrome()
      case "fade": CIFilter.photoEffectFade()
      case "instant": CIFilter.photoEffectInstant()
      case "process": CIFilter.photoEffectProcess()
      case "transfer": CIFilter.photoEffectTransfer()
      case "sepia": CIFilter.sepiaTone()
      case "vivid": CIFilter.vibrance()
      default: throw NanocodeError("filter is mono, noir, tonal, chrome, fade, instant, process, transfer, sepia or vivid")
      }
      filter.setValue(image, forKey: kCIInputImageKey)
      if name == "vivid" { filter.setValue(0.8, forKey: kCIInputAmountKey) }
      guard let output = filter.outputImage else { throw NanocodeError("the filter failed") }
      image = output
      steps.append(name)
    }
    guard !steps.isEmpty else { throw NanocodeError("edit takes rotate, crop, filter or enhance") }
    let output = PHContentEditingOutput(contentEditingInput: editing)
    output.adjustmentData = PHAdjustmentData(formatIdentifier: "xyz.gakonst.personal.edit", formatVersion: "1",
                                             data: Data(steps.joined(separator: ",").utf8))
    let context = CIContext()
    guard let space = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB) else { throw NanocodeError("the photo has no color space") }
    try context.writeJPEGRepresentation(of: image, to: output.renderedContentURL, colorSpace: space,
                                        options: [CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): 0.92])
    try await PHPhotoLibrary.shared().performChanges { PHAssetChangeRequest(for: asset).contentEditingOutput = output }
    return ["id": .string(asset.localIdentifier), "edits": .array(steps.map(JSON.string))]
  }
}

actor PhotoIndex {
  static let shared = PhotoIndex()
  static let side: CGFloat = 1600

  struct Seen: Codable, Sendable {
    let text: String
    let faces: Int
  }

  private var entries: [String: Seen]?
  private var dirty = false

  private var file: URL? {
    try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
      .appendingPathComponent("PhotoIndex.json")
  }

  private func load() -> [String: Seen] {
    if let entries { return entries }
    let loaded = file.flatMap { try? Data(contentsOf: $0) }.flatMap { try? JSONDecoder().decode([String: Seen].self, from: $0) } ?? [:]
    entries = loaded
    return loaded
  }

  func entry(_ id: String) -> Seen? { load()[id] }

  func count() -> Int { load().count }

  func store(_ id: String, _ seen: Seen) {
    var all = load()
    all[id] = seen
    entries = all
    dirty = true
  }

  func flush() {
    guard dirty, let entries, let file, let data = try? JSONEncoder().encode(entries) else { return }
    try? data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    dirty = false
  }

  static func read(_ asset: PHAsset) async -> Seen? {
    let image: CGImage? = await withCheckedContinuation { continuation in
      let options = PHImageRequestOptions()
      options.isNetworkAccessAllowed = true
      options.deliveryMode = .highQualityFormat
      options.resizeMode = .fast
      PHImageManager.default().requestImage(for: asset, targetSize: CGSize(width: side, height: side), contentMode: .aspectFit, options: options) { image, _ in
        continuation.resume(returning: image.flatMap(DeviceTools.cgImage))
      }
    }
    guard let image else { return nil }
    let text = VNRecognizeTextRequest()
    text.recognitionLevel = .accurate
    text.usesLanguageCorrection = true
    text.automaticallyDetectsLanguage = true
    let faces = VNDetectFaceRectanglesRequest()
    try? VNImageRequestHandler(cgImage: image).perform([text, faces])
    let words = (text.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    return Seen(text: words, faces: faces.results?.count ?? 0)
  }
}

struct EditingInput: @unchecked Sendable {
  let value: PHContentEditingInput
}
#endif
