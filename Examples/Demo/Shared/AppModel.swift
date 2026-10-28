import Foundation
import NanocodeKit
import Observation

enum Style: String, CaseIterable, Identifiable {
  case chatgpt
  case claude
  var id: String { rawValue }
  var label: String { self == .chatgpt ? "ChatGPT" : "Claude" }
  var provider: Provider { self == .chatgpt ? .codex : .claude }
  var model: String { self == .chatgpt ? "gpt-6-luna" : "claude-haiku-5-5" }

  static let about: [String: String] = [
    "glm-5.3": "Open-weight model from Z.ai",
    "gpt-6-luna": "Fast for everyday questions",
    "gpt-6.1-sol": "Thinks longer for harder problems",
    "kimi-k3": "Open-weight model from Moonshot AI",
    "claude-haiku-5-5": "Fastest for quick answers",
    "claude-sonnet-5-5": "Smart, efficient model for everyday use",
  ]
}

enum Access: String, CaseIterable, Identifiable {
  case tempo
  case keys
  var id: String { rawValue }
  var label: String { self == .tempo ? "Tempo Wallet (MPP)" : "API keys" }
}

@MainActor
@Observable
final class AppModel {
  static let instructions = """
    You are the nanocode demo running natively inside an app on the user's \(AppModel.platform). \
    Code Mode cells run in QuickJS on this device, and device tools (device_info, open_url, clipboard, speak) act on it. \
    Keep answers short and show your work with tools when it helps.
    """

  static let prompts = [
    "What device am I on? Use your tools.",
    "Write a JavaScript function that returns the first 20 primes, run it, and show the result.",
    "Read me a haiku about agents running on phones.",
    "Search the web for today's top tech story and summarize it in two sentences.",
  ]

  static var platform: String {
    #if os(macOS)
    "Mac"
    #else
    "iPhone or iPad"
    #endif
  }

  let runtime: NanocodeRuntime
  let wallet: WalletMonitor
  let hand: HandMonitor
  var catalog: ModelCatalog?
  var conversations: [SessionSummary] = []
  var selection: String?
  var chat = Chat()
  var style: Style = .chatgpt
  var provider: Provider = .codex
  var model = "gpt-6-luna"
  var thinking = "low"
  var access: Access = .tempo
  var paidTools = UserDefaults.standard.bool(forKey: "paidTools")
  var anthropicKey = AppModel.secret("anthropic")
  var openaiKey = AppModel.secret("openai")
  var error: String?
  var opening = false
  var machines: [String] = []
  let relay: HandRelay
  @ObservationIgnored private var watcher: Task<Void, Never>?

  init() {
    do {
      runtime = try NanocodeRuntime.standard(named: "Nanocode Demo")
    } catch {
      fatalError("the nanocode runtime did not start: \(error)")
    }
    wallet = WalletMonitor(runtime: runtime, name: "nanocode for \(AppModel.platform)", website: "https://nanocode.xyz")
    hand = HandMonitor(runtime: runtime)
    if let token = UserDefaults.standard.string(forKey: "relayToken") {
      relay = HandRelay(token: token)
    } else {
      relay = HandRelay()
      UserDefaults.standard.set(relay.token, forKey: "relayToken")
    }
    if let saved = UserDefaults.standard.string(forKey: "access").flatMap(Access.init(rawValue:)) { access = saved }
    if let saved = UserDefaults.standard.string(forKey: "NanocodeStyle").flatMap(Style.init(rawValue:)) { style = saved }
    provider = style.provider
    model = style.model
  }

  var visible: [SessionSummary] {
    conversations.filter { Provider(rawValue: $0.family) == style.provider }
  }

  var models: [ModelEntry] { catalog?.models[style.provider] ?? [] }

  var bound: Bool { !chat.entries.isEmpty }

  func setStyle(_ style: Style) async {
    guard style != self.style else { return }
    self.style = style
    UserDefaults.standard.set(style.rawValue, forKey: "NanocodeStyle")
    provider = style.provider
    model = models.contains { $0.id == style.model } ? style.model : models.first?.id ?? style.model
    thinking = catalog?.model(model)?.effort ?? thinking
    if let first = visible.first { await open(first) } else { await newChat() }
  }

  func choose(_ id: String) async {
    model = id
    thinking = catalog?.model(id)?.effort ?? thinking
    await newChat()
  }

  var workspace: URL { runtime.dataDirectory.appendingPathComponent("workspace", isDirectory: true) }

  static func secret(_ name: String) -> String {
    Keychain.load(service: "xyz.nanocode.demo.keys", account: name).map { String(decoding: $0, as: UTF8.self) } ?? ""
  }

  func saveKeys() {
    for (name, value) in [("anthropic", anthropicKey), ("openai", openaiKey)] {
      if value.isEmpty { Keychain.remove(service: "xyz.nanocode.demo.keys", account: name) }
      else { try? Keychain.save(Data(value.utf8), service: "xyz.nanocode.demo.keys", account: name) }
    }
    UserDefaults.standard.set(access.rawValue, forKey: "access")
    UserDefaults.standard.set(paidTools, forKey: "paidTools")
  }

  func start() async {
    catalog = try? await runtime.models()
    await wallet.restore()
    if UserDefaults.standard.string(forKey: "NanocodeWallet") == "cli" { await wallet.useTempoCLI() }
    if let provider = UserDefaults.standard.string(forKey: "NanocodeProvider").flatMap(Provider.init(rawValue:)),
       let model = UserDefaults.standard.string(forKey: "NanocodeModel") {
      self.provider = provider
      self.model = model
      style = provider == .claude ? .claude : .chatgpt
    }
    thinking = catalog?.model(model)?.effort ?? thinking
    await refresh()
    machines = await relay.hands()
    watch()
    if let prompt = UserDefaults.standard.string(forKey: "NanocodePrompt") {
      await newChat()
      await chat.send(prompt)
    } else if !UserDefaults.standard.bool(forKey: "NanocodeNew"), let first = visible.first {
      await open(first)
    } else {
      await newChat()
    }
  }

  func watch() {
    watcher?.cancel()
    watcher = Task { @MainActor [weak self] in
      while !Task.isCancelled {
        let attached = !(self?.machines.isEmpty ?? true)
        try? await Task.sleep(nanoseconds: attached ? 20_000_000_000 : 3_000_000_000)
        guard let self else { return }
        let machines = await self.relay.hands()
        guard machines != self.machines else { continue }
        let changed = machines.isEmpty != self.machines.isEmpty
        self.machines = machines
        if changed, let id = self.selection, !self.chat.pending {
          let summary = self.conversations.first { $0.id == id }
          await self.open(id: id, provider: summary.flatMap { Provider(rawValue: $0.family) } ?? self.provider,
                          model: summary?.model ?? self.model, thinking: nil)
        }
      }
    }
  }

  func refresh() async {
    conversations = (try? await runtime.sessions())?.filter { $0.preview != nil || $0.id == selection } ?? []
  }

  func authentication(for provider: Provider) -> Authentication {
    switch access {
    case .tempo: return .tempo
    case .keys: return .apiKey(provider == .claude ? anthropicKey : openaiKey)
    }
  }

  func configuration(id: String, provider: Provider, model: String, thinking: String?) -> SessionConfiguration {
    var configuration = SessionConfiguration(
      sessionID: id, provider: provider, model: model, thinking: thinking, instructions: Self.instructions,
      authentication: authentication(for: provider), workspace: workspace, tools: DemoTools.all,
      environment: SessionEnvironment(cwd: workspace.path))
    configuration.paidTools = paidTools && wallet.connected
    if !machines.isEmpty {
      configuration.hands = [relay.brain()]
      configuration.environment = nil
      configuration.instructions = Self.instructions + " The user's computer \(machines.joined(separator: ", ")) is attached: commands and cells run there, not on this device."
    }
    return configuration
  }

  func newChat() async {
    await open(id: Identifier.uuidv7(), provider: provider, model: model, thinking: thinking)
  }

  func open(_ summary: SessionSummary) async {
    let family = Provider(rawValue: summary.family) ?? .claude
    await open(id: summary.id, provider: family, model: summary.model, thinking: nil)
  }

  func open(id: String, provider: Provider, model: String, thinking: String?) async {
    opening = true
    defer { opening = false }
    error = nil
    do {
      let session = try await runtime.open(configuration(id: id, provider: provider, model: model, thinking: thinking))
      let chat = Chat()
      chat.workspace = machines.isEmpty ? workspace : nil
      self.chat = chat
      selection = id
      await chat.attach(session)
      await refresh()
    } catch {
      self.error = error.localizedDescription
    }
  }

  func delete(_ summary: SessionSummary) async {
    try? await runtime.command("close", ["session": .string(summary.id)])
    conversations.removeAll { $0.id == summary.id }
    if summary.id == selection { await newChat() }
  }

  func setThinking(_ thinking: String) async {
    self.thinking = thinking
    try? await chat.session?.settings(thinking: thinking)
  }
}
