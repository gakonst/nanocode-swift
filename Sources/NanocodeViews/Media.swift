import SwiftUI
#if os(macOS)
import AppKit
public typealias PlatformImage = NSImage
#else
import UIKit
public typealias PlatformImage = UIImage
#endif

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
