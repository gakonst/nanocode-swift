import Foundation
import NanocodeKit
import Observation
#if os(iOS)
import UIKit
#endif

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

enum Runner: String, CaseIterable, Identifiable {
  case device
  case cloudflare
  case vercel
  var id: String { rawValue }
  var label: String {
    switch self {
    case .device: "This device"
    case .cloudflare: "Cloudflare"
    case .vercel: "Vercel"
    }
  }
  var kind: RemoteKind? {
    switch self {
    case .device: nil
    case .cloudflare: .cloudflare
    case .vercel: .vercel
    }
  }

  static let models: [RemoteKind: [Provider: [String]]] = [
    .cloudflare: [.claude: ["claude-haiku-5-5", "claude-sonnet-5-5"], .codex: ["gpt-6-luna", "gpt-6.1-sol", "glm-5.3"]],
    .vercel: [.claude: ["claude-haiku-5-5", "claude-sonnet-5-5", "zai/glm-5.3", "moonshotai/kimi-k3"],
              .codex: ["gpt-6-luna", "gpt-6.1-sol", "glm-5.3", "kimi-k3"]],
  ]

  static let names: [String: String] = ["zai/glm-5.3": "GLM-5.3", "moonshotai/kimi-k3": "Kimi K3", "glm-5.3": "GLM-5.3", "kimi-k3": "Kimi K3"]
}

struct Conversation: Identifiable, Hashable {
  let id: String
  let title: String
  let model: String
  let provider: Provider
  let updatedAt: Date
  let remote: RemoteConversation?
}

struct ModelOption: Identifiable, Hashable {
  let id: String
  let name: String
}

enum Access: String, CaseIterable, Identifiable {
  case tempo
  case plan
  case keys
  var id: String { rawValue }
  var label: String {
    switch self {
    case .tempo: "Tempo Wallet"
    case .plan: "ChatGPT or Claude plan"
    case .keys: "API keys"
    }
  }
}

@MainActor
@Observable
final class AppModel {
  static let prompts = [
    "What device am I on? Use your tools.",
    "Write a JavaScript function that returns the first 20 primes, run it, and show the result.",
    "Write a WebAssembly program in WAT that prints the first 10 Fibonacci numbers, assemble it with wat2wasm and run it.",
    "Download python-3.12.0.wasm from vmware-labs/webassembly-language-runtimes on GitHub and run print(2**100) with it.",
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
  let plans: PlanMonitor
  let hand: HandMonitor
  let python: PythonHost
  var catalog: ModelCatalog?
  var conversations: [SessionSummary] = []
  var remotes: [RemoteConversation] = []
  var selection: String?
  var runner: Runner = .device
  var deviceHand = UserDefaults.standard.object(forKey: "deviceHand") as? Bool ?? true
  var cloudflareURL = UserDefaults.standard.string(forKey: "cloudflareURL") ?? "https://nanocode.xyz/cloudflare/"
  var vercelURL = UserDefaults.standard.string(forKey: "vercelURL") ?? "https://nanocode.xyz/vercel/api/chat"
  var cloudflareToken = ""
  var vercelToken = ""
  @ObservationIgnored var tokensLoaded = false
  @ObservationIgnored var keysLoaded = false
  @ObservationIgnored var walletLoaded = false
  @ObservationIgnored var plansLoaded = false
  let remoteStore: RemoteStore
  let cloudHand: HandMonitor
  @ObservationIgnored private var sessions: [String: RemoteSession] = [:]
  @ObservationIgnored private var handFor: String?
  var chat = Chat()
  var style: Style = .chatgpt
  var provider: Provider = .codex
  var model = "gpt-6-luna"
  var thinking = "low"
  var access: Access = .tempo
  var paidTools = UserDefaults.standard.bool(forKey: "paidTools")
  var anthropicKey = ""
  var openaiKey = ""
  var error: String?
  var opening = false
  var script: String?
  var machines: [String] = []
  var folder: URL?
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
    plans = PlanMonitor(runtime: runtime, store: KeychainSubscriptionStore(service: "xyz.nanocode.demo.plans"))
    cloudHand = HandMonitor(runtime: runtime, id: "cloud")
    python = PythonHost(runtime: runtime)
    do {
      remoteStore = try RemoteStore(directory: runtime.dataDirectory.appendingPathComponent("remote", isDirectory: true))
    } catch {
      fatalError("the remote conversation store did not open: \(error)")
    }
    if let saved = UserDefaults.standard.string(forKey: "NanocodeRunner").flatMap(Runner.init(rawValue:)) { runner = saved }
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
    restoreFolder()
    if access == .keys { loadKeys() }
    if runner != .device { loadTokens() }
  }

  func loadKeys() {
    guard !keysLoaded else { return }
    keysLoaded = true
    anthropicKey = Self.secret("anthropic")
    openaiKey = Self.secret("openai")
  }

  func loadTokens() {
    guard !tokensLoaded else { return }
    tokensLoaded = true
    cloudflareToken = Self.secret("cloudflare")
    vercelToken = Self.secret("vercel")
  }

  func loadWallet() async {
    guard !walletLoaded else { return }
    walletLoaded = true
    await wallet.restore()
  }

  func loadPlans() async {
    guard !plansLoaded else { return }
    plansLoaded = true
    await plans.refresh()
  }

  func loadAccount() async {
    loadKeys()
    loadTokens()
    await loadWallet()
    await loadPlans()
  }

  func restoreFolder() {
    if let data = UserDefaults.standard.data(forKey: "workspaceFolder") {
      var stale = false
      if let url = try? URL(resolvingBookmarkData: data, bookmarkDataIsStale: &stale) {
        _ = url.startAccessingSecurityScopedResource()
        folder = url
        if stale, let fresh = try? url.bookmarkData() { UserDefaults.standard.set(fresh, forKey: "workspaceFolder") }
      }
    }
    try? FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    DemoTools.workspace = workspace
  }

  func useFolder(_ url: URL?) async {
    folder?.stopAccessingSecurityScopedResource()
    if let url {
      _ = url.startAccessingSecurityScopedResource()
      if let bookmark = try? url.bookmarkData() { UserDefaults.standard.set(bookmark, forKey: "workspaceFolder") }
    } else {
      UserDefaults.standard.removeObject(forKey: "workspaceFolder")
    }
    folder = url
    try? FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    DemoTools.workspace = workspace
    if runner == .device, !chat.pending { await newChat() }
  }

  var visible: [Conversation] {
    if let kind = runner.kind {
      return remotes.filter { $0.kind == kind && $0.provider == style.provider && $0.title != nil }.map {
        Conversation(id: $0.id, title: $0.title ?? "", model: $0.model, provider: $0.provider, updatedAt: $0.updatedAt, remote: $0)
      }
    }
    return conversations.filter { Provider(rawValue: $0.family) == style.provider }.map {
      Conversation(id: $0.id, title: $0.preview ?? "", model: $0.model, provider: Provider(rawValue: $0.family) ?? .claude,
                   updatedAt: $0.updatedAt, remote: nil)
    }
  }

  var models: [ModelOption] {
    guard let kind = runner.kind else { return (catalog?.models[style.provider] ?? []).map { ModelOption(id: $0.id, name: $0.name) } }
    return (Runner.models[kind]?[style.provider] ?? []).map { ModelOption(id: $0, name: catalog?.model($0)?.name ?? Runner.names[$0] ?? $0) }
  }

  var server: RemoteServer? {
    switch runner {
    case .device: nil
    case .cloudflare: RemoteServer.cloudflare(URL(string: cloudflareURL) ?? URL(string: "https://nanocode.xyz/cloudflare/")!, token: cloudflareToken)
    case .vercel: RemoteServer.vercel(URL(string: vercelURL) ?? URL(string: "https://nanocode.xyz/vercel/api/chat")!, token: vercelToken)
    }
  }

  func effort(_ model: String) -> String? {
    guard let entry = catalog?.model(model) else { return runner == .device ? nil : "low" }
    return entry.efforts.contains("low") ? "low" : entry.effort
  }

  func setRunner(_ runner: Runner) async {
    guard runner != self.runner else { return }
    self.runner = runner
    if runner != .device { loadTokens() }
    UserDefaults.standard.set(runner.rawValue, forKey: "NanocodeRunner")
    model = models.contains { $0.id == model } ? model : models.first { $0.id == style.model }?.id ?? models.first?.id ?? style.model
    thinking = effort(model) ?? thinking
    await refresh()
    if let first = visible.first { await open(first) } else { await newChat() }
  }

  func saveServers() {
    UserDefaults.standard.set(cloudflareURL, forKey: "cloudflareURL")
    UserDefaults.standard.set(vercelURL, forKey: "vercelURL")
    UserDefaults.standard.set(deviceHand, forKey: "deviceHand")
    guard tokensLoaded else { return }
    for (name, value) in [("cloudflare", cloudflareToken), ("vercel", vercelToken)] {
      if value.isEmpty { Keychain.remove(service: "xyz.nanocode.demo.keys", account: name) }
      else { try? Keychain.save(Data(value.utf8), service: "xyz.nanocode.demo.keys", account: name) }
    }
  }

  var bound: Bool { !chat.entries.isEmpty }

  func setStyle(_ style: Style) async {
    guard style != self.style else { return }
    self.style = style
    UserDefaults.standard.set(style.rawValue, forKey: "NanocodeStyle")
    provider = style.provider
    model = models.contains { $0.id == style.model } ? style.model : models.first?.id ?? style.model
    thinking = effort(model) ?? catalog?.model(model)?.effort ?? thinking
    if let first = visible.first { await open(first) } else { await newChat() }
  }

  func choose(_ id: String) async {
    model = id
    thinking = effort(id) ?? catalog?.model(id)?.effort ?? thinking
    await newChat()
  }

  var workspace: URL { folder ?? runtime.dataDirectory.appendingPathComponent("workspace", isDirectory: true) }

  static func secret(_ name: String) -> String {
    Keychain.load(service: "xyz.nanocode.demo.keys", account: name).map { String(decoding: $0, as: UTF8.self) } ?? ""
  }

  func saveKeys() {
    for (name, value) in [("anthropic", anthropicKey), ("openai", openaiKey)] where keysLoaded {
      if value.isEmpty { Keychain.remove(service: "xyz.nanocode.demo.keys", account: name) }
      else { try? Keychain.save(Data(value.utf8), service: "xyz.nanocode.demo.keys", account: name) }
    }
    UserDefaults.standard.set(access.rawValue, forKey: "access")
    UserDefaults.standard.set(paidTools, forKey: "paidTools")
  }

  func start() async {
    python.start()
    catalog = try? await runtime.models()
    if access == .tempo { await loadWallet() }
    if access == .plan { await loadPlans() }
    if UserDefaults.standard.string(forKey: "NanocodeWallet") == "cli" { await wallet.useTempoCLI() }
    if let provider = UserDefaults.standard.string(forKey: "NanocodeProvider").flatMap(Provider.init(rawValue:)),
       let model = UserDefaults.standard.string(forKey: "NanocodeModel") {
      self.provider = provider
      self.model = model
      style = provider == .claude ? .claude : .chatgpt
    }
    thinking = (runner == .device ? catalog?.model(model)?.effort : effort(model)) ?? thinking
    await refresh()
    machines = await relay.hands()
    watch()
    if let script = UserDefaults.standard.string(forKey: "NanocodeShell") {
      let runtime = runtime
      let directory = workspace
      Task {
        let started = Date()
        do {
          let result = try await runtime.runShell(script, in: directory)
          print(result.stdout + result.stderr + "[shell] exit \(result.exitCode) in \(String(format: "%.1f", Date().timeIntervalSince(started))) s")
        } catch {
          print("[shell] \(error.localizedDescription)")
        }
        fflush(stdout)
      }
    }
    if let command = UserDefaults.standard.string(forKey: "NanocodeHand"), let parsed = HandConfiguration.parse(command: command) {
      await hand.start(HandConfiguration(url: parsed.url, token: parsed.token, name: Self.handName, workspace: workspace, tools: DemoTools.all))
    }
    if let prompt = UserDefaults.standard.string(forKey: "NanocodePrompt") {
      await newChat()
      if UserDefaults.standard.bool(forKey: "NanocodeType") { script = prompt } else { await chat.send(prompt) }
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
    remotes = remoteStore.conversations()
  }

  func authentication(for provider: Provider) -> Authentication {
    switch access {
    case .tempo: return .tempo
    case .plan: return .plan
    case .keys: return .apiKey(provider == .claude ? anthropicKey : openaiKey)
    }
  }

  func configuration(id: String, provider: Provider, model: String, thinking: String?) -> SessionConfiguration {
    var configuration = SessionConfiguration(
      sessionID: id, provider: provider, model: model, thinking: thinking,
      authentication: authentication(for: provider), workspace: workspace, tools: DemoTools.all,
      environment: SessionEnvironment(cwd: workspace.path))
    configuration.paidTools = paidTools && wallet.connected
    if !machines.isEmpty {
      configuration.hands = [relay.brain()]
      configuration.environment = nil
    }
    return configuration
  }

  func newChat() async {
    if let server {
      let session = RemoteSession.create(server: server, store: remoteStore, provider: style.provider, model: model, thinking: effort(model))
      await open(remote: session)
      return
    }
    await open(id: Identifier.uuidv7(), provider: provider, model: model, thinking: thinking)
  }

  func open(_ conversation: Conversation) async {
    if let record = conversation.remote, let server {
      await open(remote: sessions[record.id] ?? RemoteSession(server: server, store: remoteStore, conversation: record))
      return
    }
    await open(id: conversation.id, provider: conversation.provider, model: conversation.model, thinking: nil)
  }

  func open(remote session: RemoteSession) async {
    error = nil
    sessions[session.id] = session
    let chat = Chat()
    self.chat = chat
    selection = session.id
    model = session.record.model
    await chat.attach(session)
    await refresh()
    await attachHand(session)
  }

  static var handName: String {
    #if os(macOS)
    let name = Host.current().localizedName ?? "mac"
    #else
    let name = UIDevice.current.name
    #endif
    let slug = String(name.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }).split(separator: "-").joined(separator: "-")
    return slug.isEmpty ? "device" : String(slug.prefix(40))
  }

  func attachHand(_ session: RemoteSession) async {
    guard session.server.kind == .cloudflare, deviceHand else {
      session.hand = nil
      if handFor != nil {
        handFor = nil
        await cloudHand.stop()
      }
      return
    }
    if handFor == session.id, cloudHand.state.online {
      session.hand = Self.handName
      return
    }
    do {
      let access = try await session.handAccess(name: Self.handName)
      await cloudHand.stop()
      handFor = session.id
      await cloudHand.start(HandConfiguration(url: access.url.absoluteString, token: access.token, name: Self.handName,
                                              workspace: workspace, tools: DemoTools.all))
      for _ in 0..<40 where !cloudHand.state.online {
        try? await Task.sleep(nanoseconds: 250_000_000)
      }
      session.hand = cloudHand.state.online ? Self.handName : nil
    } catch {
      session.hand = nil
      cloudHand.error = error.localizedDescription
    }
  }

  func setAccess(_ access: Access) async {
    guard access != self.access else { return }
    self.access = access
    switch access {
    case .keys: loadKeys()
    case .tempo: await loadWallet()
    case .plan: await loadPlans()
    }
    saveKeys()
    if runner == .device, !chat.pending { await newChat() }
  }

  func signedIn() async {
    await plans.refresh()
    if access != .plan { access = .plan }
    saveKeys()
    if runner == .device, !chat.pending { await newChat() }
  }

  func setDeviceHand(_ on: Bool) async {
    deviceHand = on
    saveServers()
    if let session = chat.backend as? RemoteSession { await attachHand(session) }
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

  func delete(_ conversation: Conversation) async {
    if conversation.remote != nil {
      (sessions.removeValue(forKey: conversation.id) ?? conversation.remote.flatMap { record in
        server.map { RemoteSession(server: $0, store: remoteStore, conversation: record) }
      })?.delete()
      remotes.removeAll { $0.id == conversation.id }
    } else {
      try? await runtime.command("close", ["session": .string(conversation.id)])
      conversations.removeAll { $0.id == conversation.id }
    }
    if conversation.id == selection { await newChat() }
  }

  func setThinking(_ thinking: String) async {
    self.thinking = thinking
    try? await chat.session?.settings(thinking: thinking)
  }
}
