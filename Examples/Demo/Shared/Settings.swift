import NanocodeKit
#if os(macOS)
import AppKit
#else
import UIKit
#endif

@MainActor
final class Trampoline: NSObject {
  let run: (Any) -> Void
  init(_ run: @escaping (Any) -> Void) { self.run = run }
  @objc func fire(_ sender: Any) { run(sender) }
}

@MainActor
final class Hosted: Node {
  let control: KitView
  let height: CGFloat?

  init(_ control: KitView, height: CGFloat? = nil) {
    self.control = control
    self.height = height
    super.init(frame: .zero)
    addSubview(control)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("created in code") }

  override func contentSize(_ width: CGFloat) -> CGSize {
    if let height { return CGSize(width: width, height: height) }
    #if os(macOS)
    return control.fittingSize
    #else
    return control.intrinsicContentSize
    #endif
  }

  override func arrange(_ rect: CGRect) { control.frame = rect }
}

@MainActor
final class SettingsNode: Stack {
  let model: AppModel
  let skin: Skin
  let close: () -> Void
  let pickFolder: () -> Void
  var targets: [Trampoline] = []
  var observer: Observer?
  let header = Stack(.horizontal, spacing: 8, align: .center)
  let content = Stack(.vertical, spacing: 26, align: .fill)
  var checks: [(IconNode, () -> Bool)] = []
  let account = Stack(.vertical, spacing: 0, align: .fill)
  let keys = Stack(.vertical, spacing: 0, align: .fill)
  let wallet = Stack(.vertical, spacing: 0, align: .fill)
  let plans = Stack(.vertical, spacing: 0, align: .fill)
  let servers = Stack(.vertical, spacing: 0, align: .fill)
  let cloud = Stack(.vertical, spacing: 0, align: .fill)
  let folder = Stack(.vertical, spacing: 0, align: .fill)
  let python = Stack(.vertical, spacing: 0, align: .fill)
  let computer = Stack(.vertical, spacing: 0, align: .fill)
  let hand = Stack(.vertical, spacing: 0, align: .fill)
  var paid: Node?
  var claudeCode = ""
  var handCommand = ""
  var handName: String = {
    #if os(macOS)
    Host.current().localizedName ?? "mac"
    #else
    UIDevice.current.name
    #endif
  }()

  init(model: AppModel, skin: Skin, close: @escaping () -> Void, pickFolder: @escaping () -> Void) {
    self.model = model
    self.skin = skin
    self.close = close
    self.pickFolder = pickFolder
    super.init(frame: .zero)
    axis = .vertical
    align = .fill
    fill = skin.sidebar
    build()
    observer = Observer { [weak self] in self?.refresh() }
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("created in code") }

  func keep(_ run: @escaping (Any) -> Void) -> Trampoline {
    let target = Trampoline(run)
    targets.append(target)
    return target
  }

  func text(_ value: String, _ size: CGFloat = 15, _ weight: KitFont.Weight = .regular, _ color: KitColor? = nil, lines: Int = 0) -> Label {
    Label(styled(value, skin.ui(size, weight), color ?? skin.text), lines: lines)
  }

  func mono(_ value: String, size: CGFloat = 13, weight: KitFont.Weight = .regular) -> TextNode {
    let node = TextNode()
    node.text = styled(value, .monospacedSystemFont(ofSize: size, weight: weight), skin.text)
    return node
  }

  func row(_ title: String, detail: String? = nil, color: KitColor? = nil, weight: KitFont.Weight = .regular, trailing: [Node] = []) -> Stack {
    var texts: [Node] = [text(title, 15, weight, color)]
    if let detail { texts.append(text(detail, 13, .regular, skin.muted)) }
    let column = Stack(.vertical, spacing: 2, align: .fill, texts)
    column.grow = 1
    let row = Stack(.horizontal, spacing: 12, align: .center, [column] + trailing)
    row.padding = Insets(v: 11, h: 16)
    row.minHeight = 46
    return row
  }

  func pressable(_ row: Stack, _ action: @escaping () -> Void) -> Pressable {
    let button = Pressable(.horizontal, spacing: 0, align: .fill, [row], action: action)
    row.grow = 1
    button.hoverFill = skin.hover
    return button
  }

  func choice(_ title: String, detail: String? = nil, selected: @escaping () -> Bool, _ action: @escaping () -> Void) -> Node {
    let check = IconNode(.check, size: 18, color: skin.claude ? skin.accent : skin.text)
    checks.append((check, selected))
    return pressable(row(title, detail: detail, trailing: [check]), action)
  }

  func action(_ title: String, detail: String? = nil, destructive: Bool = false, strong: Bool = false, disclosure: Bool = false, _ run: @escaping () -> Void) -> Node {
    let chevron = IconNode(.chevron, size: 14, color: skin.faint)
    chevron.rotation = -90
    let tint = destructive ? skin.danger : strong ? (skin.claude ? skin.accent : skin.text) : skin.text
    return pressable(row(title, detail: detail, color: tint, weight: strong ? .semibold : .regular, trailing: disclosure ? [chevron] : []), run)
  }

  func toggle(_ title: String, detail: String? = nil, isOn: Bool, _ changed: @escaping (Bool) -> Void) -> Node {
    #if os(macOS)
    let control = NSSwitch()
    control.state = isOn ? .on : .off
    control.target = keep { sender in changed((sender as? NSSwitch)?.state == .on) }
    control.action = #selector(Trampoline.fire(_:))
    #else
    let control = UISwitch()
    control.isOn = isOn
    if skin.claude { control.onTintColor = skin.accent }
    control.addTarget(keep { sender in changed((sender as? UISwitch)?.isOn ?? false) }, action: #selector(Trampoline.fire(_:)), for: .valueChanged)
    #endif
    return row(title, detail: detail, trailing: [Hosted(control)])
  }

  func field(_ placeholder: String, value: String, secure: Bool = false, mono: Bool = false, _ changed: @escaping @MainActor (String) -> Void) -> Node {
    let font: KitFont = mono ? .monospacedSystemFont(ofSize: 14, weight: .regular) : skin.ui(15)
    #if os(macOS)
    let field: NSTextField = secure ? NSSecureTextField() : NSTextField()
    field.placeholderString = placeholder
    field.stringValue = value
    field.isBordered = false
    field.drawsBackground = false
    field.focusRingType = .none
    field.font = font
    field.textColor = skin.text
    field.cell?.usesSingleLineMode = true
    field.lineBreakMode = .byTruncatingTail
    NotificationCenter.default.addObserver(forName: NSControl.textDidChangeNotification, object: field, queue: .main) { _ in
      MainActor.assumeIsolated { changed(field.stringValue) }
    }
    let hosted = Hosted(field, height: 20)
    #else
    let field = UITextField()
    field.placeholder = placeholder
    field.text = value
    field.isSecureTextEntry = secure
    field.font = font
    field.textColor = skin.text
    field.autocapitalizationType = .none
    field.autocorrectionType = .no
    field.clearButtonMode = .whileEditing
    field.addTarget(keep { sender in changed((sender as? UITextField)?.text ?? "") }, action: #selector(Trampoline.fire(_:)), for: .editingChanged)
    let hosted = Hosted(field, height: 24)
    #endif
    let row = Stack(.horizontal, spacing: 0, align: .center, [hosted])
    hosted.grow = 1
    row.padding = Insets(v: 12, h: 16)
    row.minHeight = 46
    return row
  }

  func note(_ value: String, color: KitColor? = nil) -> Node {
    let label = text(value, 13, .regular, color ?? skin.muted)
    label.padding = Insets(v: 10, h: 16)
    return label
  }

  func block(_ node: Node) -> Node {
    let wrapper = Stack(.vertical, spacing: 0, align: .fill, [node])
    wrapper.padding = Insets(v: 10, h: 16)
    return wrapper
  }

  func card(_ box: Stack, _ rows: [Node]) {
    for (index, row) in rows.enumerated() { row.rules = index == 0 ? [] : [(.top, skin.border, skin.hairline)] }
    box.set(rows)
  }

  func makeCard(_ rows: [Node]) -> Stack {
    let box = Stack(.vertical, spacing: 0, align: .fill)
    card(box, rows)
    return style(box)
  }

  func style(_ box: Stack) -> Stack {
    box.fill = skin.bg
    box.stroke = skin.border
    box.strokeWidth = skin.hairline
    box.radius = 14
    box.clips = true
    return box
  }

  func section(_ title: String, _ boxes: [Node], footer: String? = nil) -> Node {
    let heading = text(title, 13, .medium, skin.muted)
    heading.padding = Insets(left: 16, bottom: 6, right: 16)
    var items: [Node] = [heading]
    let cards = Stack(.vertical, spacing: 10, align: .fill, boxes)
    items.append(cards)
    if let footer {
      let label = text(footer, 12, .regular, skin.faint)
      label.padding = Insets(top: 6, left: 16, right: 16)
      items.append(label)
    }
    return Stack(.vertical, spacing: 0, align: .fill, items)
  }

  func build() {
    let done = Pressable(.horizontal, spacing: 0, align: .center, [text("Done", 15, .semibold, skin.claude ? skin.accent : skin.text)]) { [weak self] in self?.close() }
    done.padding = Insets(v: 6, h: 12)
    done.radius = 8
    done.hoverFill = skin.hover
    let title = text("Settings", 17, .semibold)
    let left = Spacer()
    let right = Spacer()
    header.set([left, title, right, done])
    header.padding = Insets(v: 10, h: 12)
    header.rules = [(.bottom, skin.border, skin.hairline)]

    let model = model
    let access = makeCard(Access.allCases.map { option in
      choice(option.label, detail: option == .tempo ? "Pay per request in MACH over MPP" : option == .plan ? "Your own ChatGPT or Claude subscription" : "Your Anthropic and OpenAI keys",
             selected: { model.access == option }) { Task { await model.setAccess(option) } }
    })
    card(keys, [
      field("Anthropic API key", value: model.anthropicKey, secure: true) { model.anthropicKey = $0; model.saveKeys() },
      field("OpenAI API key", value: model.openaiKey, secure: true) { model.openaiKey = $0; model.saveKeys() },
    ])
    let paid = makeCard([toggle("Paid tools", detail: "Mercator and the Tempo gateway, paid per call", isOn: model.paidTools) { model.paidTools = $0; model.saveKeys() }])
    self.paid = paid
    let runner = makeCard(Runner.allCases.map { option in
      choice(option.label, detail: option == .device ? "The agent and its journal live in this app" : "A durable session that keeps going while this device sleeps",
             selected: { model.runner == option }) { Task { await model.setRunner(option) } }
    })
    card(servers, [
      field("https://nanocode.xyz/cloudflare/", value: model.cloudflareURL, mono: true) { model.cloudflareURL = $0; model.saveServers() },
      field("Cloudflare access token (optional)", value: model.cloudflareToken, secure: true) { model.cloudflareToken = $0; model.saveServers() },
      field("https://nanocode.xyz/vercel/api/chat", value: model.vercelURL, mono: true) { model.vercelURL = $0; model.saveServers() },
      field("Vercel access token (optional)", value: model.vercelToken, secure: true) { model.vercelToken = $0; model.saveServers() },
      toggle("Run cloud tools on this device", detail: "The Cloudflare agent's cells and device tools run here", isOn: model.deviceHand) { on in Task { await model.setDeviceHand(on) } },
    ])
    let styles = makeCard(Style.allCases.map { option in
      choice(option.label, selected: { model.style == option }) { Task { await model.setStyle(option) } }
    })
    let handFields = makeCard([
      field("nc hand 'wss://…' --token …", value: "", mono: true) { [weak self] in self?.handCommand = $0 },
      field("Name", value: handName) { [weak self] in self?.handName = $0 },
    ])
    content.set([
      section("Account", [access, style(wallet), style(plans), style(keys), paid]),
      section("Where the agent runs", [runner, style(servers), style(cloud)]),
      section("Appearance", [styles]),
      section("Python", [style(python)], footer: "The shell's python, python3 and pip run Pyodide in a hidden web view on this device, with its files cached for use offline."),
      section("Workspace", [style(folder)], footer: "Sessions, the shell, device tools and this device's hand work on this folder's real files."),
      section("Computer", [style(computer)], footer: "Run the command on a computer, and the agent's commands and cells run there."),
      section("This device as a hand", [handFields, style(hand)], footer: "Paste the command a nanocode session shows to run its tools on this device."),
    ])
    content.padding = Insets(top: 20, left: 16, bottom: 48, right: 16)
    content.maxWidth = 680
    let column = Stack(.vertical, spacing: 0, align: .center, [content])
    let scroll = ScrollNode(column)
    scroll.grow = 1
    set([header, scroll])
  }

  func refresh() {
    let tint = skin.claude ? skin.accent : skin.text
    for (check, selected) in checks { check.color = selected() ? tint : .clear }
    let model = model
    let device = model.runner == .device
    keys.gone = !device || model.access != .keys
    paid?.gone = !device || model.access != .tempo
    wallet.gone = !device || model.access != .tempo
    plans.gone = !device || model.access != .plan
    servers.gone = device
    cloud.gone = model.runner != .cloudflare || !model.deviceHand
    if !cloud.gone {
      card(cloud, [row("Hand \(AppModel.handName)", detail: model.cloudHand.error ?? model.cloudHand.state.label)])
    }
    renderWallet()
    renderPlans()
    let status: String = switch model.python.state {
    case .idle: "Not started"
    case .loading: "Loading Pyodide and its packages…"
    case .ready(let version): "Python \(version) on Pyodide"
    case .failed(let error): error
    }
    card(python, [
      row("Status", trailing: [text(status, 15, .regular, skin.muted, lines: 1)]),
      row("Preloaded", detail: model.python.packages.joined(separator: ", ")),
    ])
    var folderRows: [Node] = [
      row(model.folder == nil ? "The app's folder" : model.folder?.lastPathComponent ?? "Folder", detail: model.folder == nil ? "Inside the app's data" : "Chosen by you"),
      block(mono(model.workspace.path, size: 12)),
      action("Choose Folder…", disclosure: true) { [weak self] in self?.pickFolder() },
    ]
    if model.folder != nil { folderRows.append(action("Use the App's Folder") { Task { await model.useFolder(nil) } }) }
    card(folder, folderRows)
    let machines = model.machines
    let command = model.relay.command
    card(computer, [
      row(machines.isEmpty ? "No computer attached" : "Running on \(machines.joined(separator: ", "))", detail: machines.isEmpty ? nil : "Commands and Code Mode cells run on that machine"),
      block(mono(command, size: 11)),
      action("Copy Command") { Pasteboard.copy(command) },
    ])
    let monitor = model.hand
    var handRows: [Node] = [row("Status", trailing: [text(monitor.state.label, 15, .regular, skin.muted, lines: 1)])]
    if monitor.running {
      for item in monitor.status?.items ?? [] { handRows.append(row(item.kind, detail: item.label)) }
      handRows.append(action("Disconnect", destructive: true) { Task { await monitor.stop() } })
    } else {
      handRows.append(action("Connect", strong: true) { [weak self] in self?.connectHand() })
    }
    if let error = monitor.error { handRows.append(note(error, color: skin.danger)) }
    card(hand, handRows)
  }

  func renderWallet() {
    let monitor = model.wallet
    var rows: [Node] = []
    if let status = monitor.status, status.connected, let account = status.account {
      rows.append(row("Wallet", detail: status.source == "tempo-cli" ? "Tempo CLI" : "Access key from Tempo Wallet"))
      rows.append(block(mono(account, size: 12)))
      rows.append(row("Spent", trailing: [text("\(status.total) MACH", 15, .regular, skin.muted, lines: 1)]))
      for service in status.services {
        rows.append(row(service.id, detail: "\(service.requests) requests", trailing: [text("\(service.spent) \(service.symbol)", 15, .regular, skin.muted, lines: 1)]))
      }
      rows.append(action("Add MACH", disclosure: true) { Task { if let url = await monitor.fundingURL() { NanocodeKit.open(url) } } })
      rows.append(action("Disconnect", destructive: true) { Task { await monitor.disconnect() } })
    } else if let prompt = monitor.prompt {
      rows.append(row("Approve this device in Tempo Wallet"))
      rows.append(block(mono(prompt.userCode, size: 28, weight: .bold)))
      rows.append(action("Open Tempo Wallet", strong: true, disclosure: true) { NanocodeKit.open(prompt.verificationURIComplete ?? prompt.verificationURI) })
    } else {
      rows.append(row("Tempo Wallet", detail: "Models and tools are paid per request in MACH over MPP."))
      rows.append(action(monitor.connecting ? "Connecting…" : "Connect Tempo Wallet", strong: true) { Task { await monitor.connect() } })
      #if os(macOS)
      rows.append(action("Use Tempo CLI Wallet") { Task { await monitor.useTempoCLI() } })
      #endif
    }
    if let error = monitor.error { rows.append(note(error, color: skin.danger)) }
    card(wallet, rows)
  }

  func renderPlans() {
    let plans = model.plans
    var rows: [Node] = []
    for provider in [Provider.codex, .claude] {
      let name = provider == .codex ? "ChatGPT" : "Claude"
      let status = plans.status[provider]
      let busy = plans.busy.contains(provider)
      if status?.isSignedIn == true {
        let account = status?.accountID.map { $0.count > 14 ? "\($0.prefix(8))…" : $0 }
        rows.append(row(name, detail: account.map { "Signed in as \($0)" } ?? "Signed in"))
        rows.append(action("Sign Out of \(name)", destructive: true) { Task { await plans.signOut(provider) } })
      } else if let signIn = plans.signIns[provider] {
        switch signIn.step {
        case .enterCode(let url, let code):
          rows.append(row(name, detail: "Enter this code on the page that opened (\(url.host() ?? url.absoluteString))"))
          rows.append(block(mono(code, size: 28, weight: .bold)))
          rows.append(action("Open ChatGPT Sign-In", strong: true, disclosure: true) { NanocodeKit.open(url) })
          rows.append(action("Cancel") { plans.cancel(provider) })
          rows.append(note("Waiting for you to approve it…"))
        case .openURL(let url):
          rows.append(row(name, detail: "Sign in on the Claude page that opened, then paste the code it shows."))
          rows.append(field("Paste the code", value: claudeCode, mono: true) { [weak self] in self?.claudeCode = $0 })
          rows.append(action(busy ? "Finishing…" : "Finish Sign-In", strong: true) { [weak self] in
            guard let self else { return }
            let code = self.claudeCode
            Task {
              await plans.complete(provider, code: code)
              if plans.isSignedIn(provider) {
                self.claudeCode = ""
                await self.model.signedIn()
              }
            }
          })
          rows.append(action("Open Claude Sign-In", disclosure: true) { NanocodeKit.open(url) })
          rows.append(action("Cancel") { plans.cancel(provider) })
        }
      } else {
        rows.append(row(name, detail: status.map { $0.state.replacingOccurrences(of: "_", with: " ").capitalized } ?? "Signed out"))
        rows.append(action(busy ? "Starting…" : "Sign In with \(name)", strong: true, disclosure: true) { [weak self] in
          Task {
            guard let signIn = await plans.signIn(provider) else { return }
            switch signIn.step {
            case .enterCode(let url, _), .openURL(let url): NanocodeKit.open(url)
            }
            if provider == .codex {
              while plans.signIns[provider] != nil { try? await Task.sleep(nanoseconds: 1_000_000_000) }
              if plans.isSignedIn(provider) { await self?.model.signedIn() }
            }
          }
        })
      }
    }
    if let error = plans.error { rows.append(note(error, color: skin.danger)) }
    card(self.plans, rows)
  }

  func connectHand() {
    guard let parsed = HandConfiguration.parse(command: handCommand) else {
      model.hand.error = "That is not a hand command: it needs a ws:// or wss:// URL and --token."
      return
    }
    let slug = String(handName.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" })
    let configuration = HandConfiguration(url: parsed.url, token: parsed.token, name: slug, workspace: model.workspace, tools: DemoTools.all)
    let monitor = model.hand
    Task { await monitor.start(configuration) }
  }
}
