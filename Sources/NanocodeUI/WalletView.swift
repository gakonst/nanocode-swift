import SwiftUI

public struct WalletView: View {
  let monitor: WalletMonitor
  var allowsTempoCLI: Bool
  @Environment(\.openURL) private var openURL
  @Environment(\.nanocodeTheme) private var theme

  public init(monitor: WalletMonitor, allowsTempoCLI: Bool = false) {
    self.monitor = monitor
    #if os(macOS)
    self.allowsTempoCLI = allowsTempoCLI
    #else
    self.allowsTempoCLI = false
    #endif
  }

  static func short(_ value: String) -> String {
    value.count > 12 ? "\(value.prefix(6))…\(value.suffix(4))" : value
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack(spacing: 10) {
        Image(systemName: "creditcard").font(.system(size: 18)).foregroundStyle(theme.accent)
        VStack(alignment: .leading, spacing: 2) {
          Text("Tempo Wallet").font(.body(theme.bodySize, weight: .semibold))
          if let account = monitor.status?.account {
            Text("\(Self.short(account)) · \(monitor.status?.source == "tempo-cli" ? "Tempo CLI" : "access key")")
              .font(.mono(theme.codeSize)).foregroundStyle(theme.muted)
          } else {
            Text("Models and tools are paid per request in MACH over MPP.").font(.body(theme.bodySize - 2)).foregroundStyle(theme.muted)
          }
        }
        Spacer()
      }
      if let prompt = monitor.prompt {
        VStack(alignment: .leading, spacing: 8) {
          Text("Approve this device in Tempo Wallet").font(.body(theme.bodySize - 1, weight: .medium))
          Text(prompt.userCode).font(.mono(28, weight: .bold)).textSelection(.enabled)
          Button("Open Tempo Wallet") { openURL(prompt.verificationURIComplete ?? prompt.verificationURI) }
            .buttonStyle(.borderedProminent).tint(theme.accent)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.surface, in: RoundedRectangle(cornerRadius: 12))
      }
      if let status = monitor.status, status.connected {
        HStack {
          Text("Spent").foregroundStyle(theme.muted)
          Spacer()
          Text("\(status.total) MACH").font(.mono(theme.codeSize, weight: .semibold))
        }
        ForEach(status.services) { service in
          HStack {
            Image(systemName: service.model ? "cpu" : "wrench.and.screwdriver").foregroundStyle(theme.muted).frame(width: 16)
            Text(service.id).lineLimit(1).truncationMode(.middle)
            Spacer()
            Text("\(service.spent) \(service.symbol) · \(service.requests)×").font(.mono(theme.codeSize - 1)).foregroundStyle(theme.muted)
          }
          .font(.body(theme.bodySize - 2))
        }
        HStack {
          Button("Add MACH") {
            Task { if let url = await monitor.fundingURL() { openURL(url) } }
          }
          Spacer()
          Button("Disconnect", role: .destructive) { Task { await monitor.disconnect() } }
        }
      } else if monitor.prompt == nil {
        HStack {
          Button {
            Task { await monitor.connect() }
          } label: {
            if monitor.connecting { ProgressView().controlSize(.small) } else { Text("Connect Tempo Wallet") }
          }
          .buttonStyle(.borderedProminent).tint(theme.accent)
          .disabled(monitor.connecting)
          if allowsTempoCLI {
            Button("Use Tempo CLI wallet") { Task { await monitor.useTempoCLI() } }
          }
        }
      }
      if let error = monitor.error {
        Text(error).font(.body(theme.bodySize - 2)).foregroundStyle(theme.danger).textSelection(.enabled)
      }
    }
  }
}

public struct HandView: View {
  let monitor: HandMonitor
  var tools: [HostTool]
  var workspace: URL?
  @State private var command = ""
  @State private var name = HandView.deviceName
  @Environment(\.nanocodeTheme) private var theme

  public init(monitor: HandMonitor, tools: [HostTool] = [], workspace: URL? = nil) {
    self.monitor = monitor
    self.tools = tools
    self.workspace = workspace
  }

  static var deviceName: String {
    #if os(macOS)
    Host.current().localizedName ?? "mac"
    #else
    UIDevice.current.name
    #endif
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 10) {
        Image(systemName: "hand.raised").font(.system(size: 18)).foregroundStyle(monitor.state.online ? theme.success : theme.muted)
        VStack(alignment: .leading, spacing: 2) {
          Text("This device as a hand").font(.body(theme.bodySize, weight: .semibold))
          Text(monitor.state.label).font(.body(theme.bodySize - 2)).foregroundStyle(theme.muted).lineLimit(2)
        }
        Spacer()
      }
      if monitor.running {
        if let items = monitor.status?.items, !items.isEmpty {
          ForEach(items) { item in
            HStack {
              Text(item.kind).font(.mono(theme.codeSize - 1)).foregroundStyle(theme.muted).frame(width: 44, alignment: .leading)
              Text(item.label).font(.mono(theme.codeSize - 1)).lineLimit(1).truncationMode(.middle)
              Spacer()
            }
          }
        }
        Button("Disconnect", role: .destructive) { Task { await monitor.stop() } }
      } else {
        Text("Paste the command a nanocode session shows, such as nc hand 'wss://…' --token …").font(.body(theme.bodySize - 2))
          .foregroundStyle(theme.muted)
        TextField("nc hand 'wss://…' --token …", text: $command, axis: .vertical).font(.mono(theme.codeSize)).lineLimit(1...3)
          .textFieldStyle(.roundedBorder)
        TextField("Name", text: $name).textFieldStyle(.roundedBorder)
        Button("Connect") {
          guard let parsed = HandConfiguration.parse(command: command) else {
            monitor.error = "That is not a hand command: it needs a ws:// or wss:// URL and --token."
            return
          }
          let slug = name.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }
          Task {
            await monitor.start(HandConfiguration(url: parsed.url, token: parsed.token, name: String(slug), workspace: workspace, tools: tools))
          }
        }
        .buttonStyle(.borderedProminent).tint(theme.accent)
        .disabled(command.isEmpty)
      }
      if let error = monitor.error {
        Text(error).font(.body(theme.bodySize - 2)).foregroundStyle(theme.danger)
      }
    }
  }
}

public struct MachineConnectView: View {
  let relay: HandRelay
  let machines: [String]
  @State private var copied = false
  @Environment(\.nanocodeTheme) private var theme

  public init(relay: HandRelay, machines: [String]) {
    self.relay = relay
    self.machines = machines
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 10) {
        Image(systemName: "desktopcomputer").font(.system(size: 18)).foregroundStyle(machines.isEmpty ? theme.muted : theme.success)
        VStack(alignment: .leading, spacing: 2) {
          Text(machines.isEmpty ? "Connect a computer" : "Running on \(machines.joined(separator: ", "))")
            .font(.body(theme.bodySize, weight: .semibold))
          Text(machines.isEmpty ? "Run this in a terminal, and the agent's commands run there." : "Commands and Code Mode cells run on that machine.")
            .font(.body(theme.bodySize - 2)).foregroundStyle(theme.muted)
        }
        Spacer()
      }
      HStack(alignment: .top) {
        Text(relay.command).font(.mono(theme.codeSize - 1)).textSelection(.enabled).lineLimit(4)
        Spacer(minLength: 6)
        Button {
          Pasteboard.copy(relay.command)
          copied = true
        } label: {
          Image(systemName: copied ? "checkmark" : "doc.on.doc").foregroundStyle(theme.muted)
        }
        .buttonStyle(.plain)
      }
      .padding(10)
      .background(theme.popover, in: RoundedRectangle(cornerRadius: 8))
    }
  }
}

public struct ModelMenu: View {
  let catalog: ModelCatalog?
  @Binding var provider: Provider
  @Binding var model: String
  @Binding var thinking: String
  var providers: [Provider: [String]]?
  @Environment(\.nanocodeTheme) private var theme

  public init(catalog: ModelCatalog?, provider: Binding<Provider>, model: Binding<String>, thinking: Binding<String>,
              providers: [Provider: [String]]? = nil) {
    self.catalog = catalog
    _provider = provider
    _model = model
    _thinking = thinking
    self.providers = providers
  }

  func models(_ provider: Provider) -> [ModelEntry] {
    let all = catalog?.models[provider] ?? []
    guard let allowed = providers?[provider] else { return all }
    return allowed.compactMap { id in all.first { $0.id == id } }
  }

  public var body: some View {
    let entry = catalog?.model(model)
    HStack(spacing: 6) {
      Menu {
        ForEach(Provider.allCases) { family in
          let options = models(family)
          if !options.isEmpty {
            Section(family == .claude ? "Claude" : "Codex") {
              ForEach(options) { option in
                Button {
                  provider = family
                  model = option.id
                  thinking = option.effort
                } label: {
                  if option.id == model { Label(option.name, systemImage: "checkmark") } else { Text(option.name) }
                }
              }
            }
          }
        }
      } label: {
        Text(entry?.name ?? model).font(.body(theme.bodySize - 2, weight: .medium))
      }
      .fixedSize()
      if let entry, entry.efforts.count > 1 {
        Menu {
          ForEach(entry.efforts, id: \.self) { effort in
            Button {
              thinking = effort
            } label: {
              if effort == thinking { Label(effort, systemImage: "checkmark") } else { Text(effort) }
            }
          }
        } label: {
          Text(thinking.isEmpty ? entry.effort : thinking).font(.body(theme.bodySize - 2)).foregroundStyle(theme.muted)
        }
        .fixedSize()
      }
    }
  }
}
