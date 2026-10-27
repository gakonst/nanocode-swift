import PhotosUI
import SwiftUI

public struct ComposerView: View {
  let chat: Chat
  var placeholder: String
  var allowsImages: Bool
  @State private var text = ""
  @State private var images: [String] = []
  @State private var picked: [PhotosPickerItem] = []
  @FocusState private var focused: Bool
  @Environment(\.nanocodeTheme) private var theme

  public init(chat: Chat, placeholder: String = "Ask anything", allowsImages: Bool = true) {
    self.chat = chat
    self.placeholder = placeholder
    self.allowsImages = allowsImages
  }

  var canSend: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !images.isEmpty }

  public var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      if !images.isEmpty { attachments }
      HStack(alignment: .bottom, spacing: 8) {
        if allowsImages { picker }
        field
        button
      }
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 8)
    .background(RoundedRectangle(cornerRadius: 20).fill(theme.surface))
    .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(theme.border, lineWidth: 1))
    .frame(maxWidth: theme.columnWidth)
    .onChange(of: picked) { _, items in load(items) }
    .onAppear { focused = true }
  }

  var attachments: some View {
    ScrollView(.horizontal) {
      HStack {
        ForEach(Array(images.enumerated()), id: \.offset) { index, image in
          RemoteImage(image, maxHeight: 56).overlay(alignment: .topTrailing) { remove(index) }
        }
      }
    }
  }

  func remove(_ index: Int) -> some View {
    Button { images.remove(at: index) } label: {
      Image(systemName: "xmark.circle.fill").foregroundStyle(Color.white, Color.black.opacity(0.6))
    }
    .buttonStyle(.plain)
    .padding(2)
  }

  var picker: some View {
    PhotosPicker(selection: $picked, maxSelectionCount: 4, matching: .images) {
      Image(systemName: "photo.on.rectangle").font(.system(size: 16)).foregroundStyle(theme.muted)
    }
    .buttonStyle(.plain)
    .padding(.bottom, 6)
  }

  var field: some View {
    let field = TextField(placeholder, text: $text, axis: .vertical)
      .textFieldStyle(.plain)
      .font(Font.system(size: theme.bodySize))
      .lineLimit(1...8)
      .focused($focused)
      .padding(.vertical, 6)
      .onSubmit { send() }
    #if os(macOS)
    return field.onKeyPress(.return, phases: .down) { press in
      if press.modifiers.contains(.shift) { return KeyPress.Result.ignored }
      send()
      return KeyPress.Result.handled
    }
    #else
    return field
    #endif
  }

  var stopping: Bool { chat.pending && !canSend }

  var button: some View {
    let tint: Color = canSend || chat.pending ? theme.accent : theme.muted.opacity(0.5)
    let symbol = stopping ? "stop.circle.fill" : "arrow.up.circle.fill"
    return Button {
      if stopping { stop() } else { send() }
    } label: {
      Image(systemName: symbol).font(.system(size: 26)).foregroundStyle(tint)
    }
    .buttonStyle(.plain)
    .disabled(!canSend && !chat.pending)
  }

  func load(_ items: [PhotosPickerItem]) {
    guard !items.isEmpty else { return }
    Task {
      for item in items {
        if let data = try? await item.loadTransferable(type: Data.self) { images.append(DataURL.encode(data)) }
      }
      picked = []
    }
  }

  func send() {
    guard canSend else { return }
    let prompt = text
    let attached = images
    text = ""
    images = []
    Task { await chat.send(prompt, images: attached) }
  }

  func stop() {
    Task { await chat.stop() }
  }
}

public struct ChatView<Empty: View>: View {
  let chat: Chat
  var placeholder: String
  let empty: Empty
  @Environment(\.nanocodeTheme) private var theme

  public init(chat: Chat, placeholder: String = "Ask anything", @ViewBuilder empty: () -> Empty) {
    self.chat = chat
    self.placeholder = placeholder
    self.empty = empty()
  }

  public var body: some View {
    VStack(spacing: 0) {
      TranscriptView(chat.state) { empty }
      ComposerView(chat: chat, placeholder: placeholder)
        .padding(.horizontal, 14)
        .padding(.bottom, 12)
        .padding(.top, 4)
    }
  }
}

public extension ChatView where Empty == EmptyView {
  init(chat: Chat, placeholder: String = "Ask anything") {
    self.init(chat: chat, placeholder: placeholder) { EmptyView() }
  }
}

public extension Chat {
  var state: TranscriptState {
    TranscriptState(entries: entries, live: live, pending: pending, error: error, waiting: waiting)
  }
}
