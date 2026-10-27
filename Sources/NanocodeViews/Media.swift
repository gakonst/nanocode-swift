import SwiftUI
#if os(macOS)
import AppKit
public typealias PlatformImage = NSImage
#else
import UIKit
public typealias PlatformImage = UIImage
#endif

public enum DataURL {
  public static func decode(_ url: String) -> Data? {
    guard url.hasPrefix("data:"), let comma = url.firstIndex(of: ",") else { return nil }
    let header = url[url.index(url.startIndex, offsetBy: 5)..<comma]
    let payload = String(url[url.index(after: comma)...])
    if header.hasSuffix(";base64") { return Data(base64Encoded: payload, options: .ignoreUnknownCharacters) }
    return payload.removingPercentEncoding.map { Data($0.utf8) }
  }

  public static func encode(_ data: Data) -> String {
    "data:\(mime(data));base64,\(data.base64EncodedString())"
  }

  public static func mime(_ data: Data) -> String {
    let bytes = [UInt8](data.prefix(12))
    if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "image/png" }
    if bytes.starts(with: [0xFF, 0xD8, 0xFF]) { return "image/jpeg" }
    if bytes.starts(with: [0x47, 0x49, 0x46]) { return "image/gif" }
    if bytes.count >= 12, bytes[0..<4] == [0x52, 0x49, 0x46, 0x46], bytes[8..<12] == [0x57, 0x45, 0x42, 0x50] { return "image/webp" }
    return "image/png"
  }
}

public struct RemoteImage: View {
  let url: String
  var maxHeight: CGFloat
  @Environment(\.nanocodeTheme) private var theme

  public init(_ url: String, maxHeight: CGFloat = 320) {
    self.url = url
    self.maxHeight = maxHeight
  }

  public var body: some View {
    Group {
      if let data = DataURL.decode(url), let image = PlatformImage(data: data) {
        platform(image).resizable().scaledToFit()
      } else if let link = URL(string: url), link.scheme?.hasPrefix("http") == true {
        AsyncImage(url: link) { phase in
          if let image = phase.image { image.resizable().scaledToFit() } else { ProgressView() }
        }
      } else {
        Label("image", systemImage: "photo").foregroundStyle(theme.muted)
      }
    }
    .frame(maxHeight: maxHeight)
    .clipShape(RoundedRectangle(cornerRadius: 8))
  }

  func platform(_ image: PlatformImage) -> Image {
    #if os(macOS)
    Image(nsImage: image)
    #else
    Image(uiImage: image)
    #endif
  }
}
