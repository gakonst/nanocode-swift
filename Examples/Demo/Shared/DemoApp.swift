import NanocodeUI
import SwiftUI

@main
struct DemoApp: App {
  @State private var model = AppModel()

  var body: some Scene {
    main
    #if os(macOS)
    Settings {
      SettingsView()
        .environment(model)
        .nanocodeTheme(.nanocode)
        .frame(width: 520, height: 640)
    }
    #endif
  }

  var main: some Scene {
    WindowGroup {
      RootView()
        .environment(model)
        .nanocodeTheme(.nanocode)
        .tint(NanocodeTheme.nanocode.accent)
        .task { await model.start() }
    }
    #if os(macOS)
    .defaultSize(width: 1100, height: 760)
    #endif
  }
}

struct RootView: View {
  @Environment(AppModel.self) private var model
  @State private var settings = false

  var body: some View {
    NavigationSplitView {
      Sidebar()
        .navigationTitle("Nanocode")
        #if os(macOS)
        .navigationSplitViewColumnWidth(min: 200, ideal: 240)
        #endif
    } detail: {
      ConversationView(settings: $settings)
    }
    .sheet(isPresented: $settings) {
      NavigationStack {
        SettingsView()
          .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { settings = false } } }
      }
      .environment(model)
      .nanocodeTheme(.nanocode)
      #if os(macOS)
      .frame(width: 520, height: 640)
      #endif
    }
  }
}

struct Sidebar: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    List(selection: Binding(get: { model.selection }, set: { id in
      guard let id, id != model.selection, let summary = model.conversations.first(where: { $0.id == id }) else { return }
      Task { await model.open(summary) }
    })) {
      ForEach(model.conversations) { summary in
        VStack(alignment: .leading, spacing: 2) {
          Text(summary.preview ?? "New chat").lineLimit(1)
          Text("\(summary.model) · \(summary.updatedAt.formatted(.relative(presentation: .named)))")
            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .tag(summary.id)
        .contextMenu {
          Button("Close", role: .destructive) { Task { await model.delete(summary) } }
        }
      }
    }
    .toolbar {
      ToolbarItem {
        Button {
          Task { await model.newChat() }
        } label: {
          Label("New chat", systemImage: "square.and.pencil")
        }
      }
    }
    .refreshable { await model.refresh() }
  }
}

struct ConversationView: View {
  @Environment(AppModel.self) private var model
  @Environment(\.nanocodeTheme) private var theme
  @Binding var settings: Bool

  var body: some View {
    @Bindable var model = model
    ChatView(chat: model.chat, placeholder: "Ask nanocode anything") {
      Welcome()
    }
    .id(model.selection)
    .toolbar {
      ToolbarItem(placement: .principal) {
        ModelMenu(catalog: model.catalog, provider: $model.provider, model: $model.model,
                  thinking: Binding(get: { model.thinking }, set: { value in Task { await model.setThinking(value) } }))
      }
      ToolbarItem(placement: .primaryAction) {
        Button { settings = true } label: {
          Label(model.wallet.connected ? "\(model.wallet.status?.total ?? "") MACH" : "Connect", systemImage: "creditcard")
        }
      }
    }
    .onChange(of: model.model) { _, _ in
      if model.chat.entries.isEmpty { Task { await model.newChat() } }
    }
    .onChange(of: model.chat.pending) { _, pending in
      if !pending { Task { await model.refresh() } }
    }
    .overlay(alignment: .top) {
      if let error = model.error {
        Text(error).font(.callout).foregroundStyle(.white).padding(10).background(theme.danger, in: Capsule()).padding()
      }
    }
  }
}

struct Welcome: View {
  @Environment(AppModel.self) private var model
  @Environment(\.nanocodeTheme) private var theme

  static let prompts = [
    "What device am I on? Use your tools.",
    "Write a JavaScript function that returns the first 20 primes, run it, and show the result.",
    "Read me a haiku about agents running on phones.",
    "Search the web for today's top tech story and summarize it in two sentences.",
  ]

  var body: some View {
    VStack(spacing: 18) {
      Text("nanocode").font(.system(size: 34, weight: .bold, design: .monospaced))
      Text("A Claude or Codex agent running natively on this \(AppModel.platform), paid per request with Tempo machine payments.")
        .multilineTextAlignment(.center).foregroundStyle(theme.muted).frame(maxWidth: 420)
      if !model.wallet.connected, model.access == .tempo {
        WalletView(monitor: model.wallet, allowsTempoCLI: true)
          .padding(16)
          .background(theme.surface, in: RoundedRectangle(cornerRadius: 14))
          .frame(maxWidth: 440)
      }
      VStack(spacing: 8) {
        ForEach(Self.prompts, id: \.self) { prompt in
          Button {
            Task { await model.chat.send(prompt) }
          } label: {
            Text(prompt).font(.callout).frame(maxWidth: 440, alignment: .leading).padding(10)
              .background(theme.surface, in: RoundedRectangle(cornerRadius: 10))
          }
          .buttonStyle(.plain)
        }
      }
    }
    .padding(.top, 40)
  }
}

struct SettingsView: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    @Bindable var model = model
    Form {
      Section("Models") {
        Picker("Pay with", selection: $model.access) {
          ForEach(Access.allCases) { access in Text(access.label).tag(access) }
        }
        if model.access == .keys {
          SecureField("Anthropic API key", text: $model.anthropicKey)
          SecureField("OpenAI API key", text: $model.openaiKey)
        }
      }
      if model.access == .tempo {
        Section("Wallet") {
          WalletView(monitor: model.wallet, allowsTempoCLI: true)
        }
      }
      Section("Hand") {
        HandView(monitor: model.hand, tools: DemoTools.all, workspace: model.workspace)
      }
      Section("Workspace") {
        Text(model.workspace.path).font(.caption.monospaced()).textSelection(.enabled)
      }
    }
    .formStyle(.grouped)
    .navigationTitle("Settings")
    .onDisappear { model.saveKeys() }
  }
}
