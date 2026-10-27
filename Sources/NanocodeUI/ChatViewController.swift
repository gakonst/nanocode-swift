import SwiftUI

#if os(macOS)
import AppKit

public final class NanocodeChatViewController: NSHostingController<AnyView> {
  public let chat: Chat

  public init(chat: Chat, theme: NanocodeTheme = .standard, placeholder: String = "Ask anything") {
    self.chat = chat
    super.init(rootView: AnyView(ChatView(chat: chat, placeholder: placeholder).nanocodeTheme(theme)))
  }

  @available(*, unavailable)
  @MainActor required dynamic init?(coder: NSCoder) {
    fatalError("NanocodeChatViewController is created in code")
  }
}
#else
import UIKit

public final class NanocodeChatViewController: UIHostingController<AnyView> {
  public let chat: Chat

  public init(chat: Chat, theme: NanocodeTheme = .standard, placeholder: String = "Ask anything") {
    self.chat = chat
    super.init(rootView: AnyView(ChatView(chat: chat, placeholder: placeholder).nanocodeTheme(theme)))
  }

  @available(*, unavailable)
  @MainActor required dynamic init?(coder: NSCoder) {
    fatalError("NanocodeChatViewController is created in code")
  }
}
#endif
