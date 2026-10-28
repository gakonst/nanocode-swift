import NanocodeKit
#if os(macOS)
import AppKit
typealias StackView = NSStackView
#else
import UIKit
typealias StackView = UIStackView
#endif

@MainActor
final class Trampoline: NSObject {
  let run: (Any) -> Void
  init(_ run: @escaping (Any) -> Void) { self.run = run }
  @objc func fire(_ sender: Any) { run(sender) }
}

@MainActor
final class Form {
  var targets: [Trampoline] = []

  func target(_ run: @escaping (Any) -> Void) -> Trampoline {
    let target = Trampoline(run)
    targets.append(target)
    return target
  }

  func stack(_ views: [KitView] = [], vertical: Bool = true, spacing: CGFloat = 8) -> StackView {
    #if os(macOS)
    let stack = NSStackView(views: views)
    stack.orientation = vertical ? .vertical : .horizontal
    stack.alignment = vertical ? .leading : .centerY
    stack.spacing = spacing
    #else
    let stack = UIStackView(arrangedSubviews: views)
    stack.axis = vertical ? .vertical : .horizontal
    stack.alignment = vertical ? .fill : .center
    stack.spacing = spacing
    #endif
    return stack
  }

  func label(_ text: String, size: CGFloat = 13, weight: KitFont.Weight = .regular, secondary: Bool = false, mono: Bool = false,
             selectable: Bool = false, danger: Bool = false) -> KitView {
    let font: KitFont = mono ? .monospacedSystemFont(ofSize: size, weight: weight) : .systemFont(ofSize: size, weight: weight)
    #if os(macOS)
    let label = NSTextField(wrappingLabelWithString: text)
    label.font = font
    label.textColor = danger ? .systemRed : secondary ? .secondaryLabelColor : .labelColor
    label.isSelectable = selectable
    label.preferredMaxLayoutWidth = 440
    return label
    #else
    if selectable {
      let view = UITextView()
      view.text = text
      view.font = font
      view.isEditable = false
      view.isScrollEnabled = false
      view.backgroundColor = .secondarySystemBackground
      view.layer.cornerRadius = 8
      view.textContainerInset = UIEdgeInsets(top: 8, left: 6, bottom: 8, right: 6)
      return view
    }
    let label = UILabel()
    label.text = text
    label.font = font
    label.numberOfLines = 0
    label.textColor = danger ? .systemRed : secondary ? .secondaryLabel : .label
    return label
    #endif
  }

  func button(_ title: String, prominent: Bool = false, destructive: Bool = false, action: @escaping () -> Void) -> KitView {
    let target = target { _ in action() }
    #if os(macOS)
    let button = NSButton(title: title, target: target, action: #selector(Trampoline.fire(_:)))
    button.bezelStyle = .push
    if prominent { button.bezelColor = .controlAccentColor; button.keyEquivalent = "" }
    if destructive { button.hasDestructiveAction = true }
    return button
    #else
    var configuration: UIButton.Configuration = prominent ? .filled() : .gray()
    configuration.title = title
    if destructive { configuration.baseForegroundColor = .systemRed }
    let button = UIButton(configuration: configuration)
    button.addTarget(target, action: #selector(Trampoline.fire(_:)), for: .touchUpInside)
    return button
    #endif
  }

  func field(_ placeholder: String, value: String, secure: Bool = false, mono: Bool = false, changed: @escaping @MainActor (String) -> Void) -> KitView {
    #if os(macOS)
    let field: NSTextField = secure ? NSSecureTextField() : NSTextField()
    field.placeholderString = placeholder
    field.stringValue = value
    if mono { field.font = .monospacedSystemFont(ofSize: 12, weight: .regular) }
    field.translatesAutoresizingMaskIntoConstraints = false
    field.widthAnchor.constraint(equalToConstant: 440).isActive = true
    NotificationCenter.default.addObserver(forName: NSControl.textDidChangeNotification, object: field, queue: .main) { _ in
      MainActor.assumeIsolated { changed(field.stringValue) }
    }
    return field
    #else
    let field = UITextField()
    field.placeholder = placeholder
    field.text = value
    field.isSecureTextEntry = secure
    field.borderStyle = .roundedRect
    field.autocapitalizationType = .none
    field.autocorrectionType = .no
    if mono { field.font = .monospacedSystemFont(ofSize: 13, weight: .regular) }
    let target = target { sender in changed((sender as? UITextField)?.text ?? "") }
    field.addTarget(target, action: #selector(Trampoline.fire(_:)), for: .editingChanged)
    return field
    #endif
  }

  func segmented(_ options: [String], selected: Int, changed: @escaping (Int) -> Void) -> KitView {
    #if os(macOS)
    let target = target { sender in changed((sender as? NSSegmentedControl)?.selectedSegment ?? 0) }
    let control = NSSegmentedControl(labels: options, trackingMode: .selectOne, target: target, action: #selector(Trampoline.fire(_:)))
    control.selectedSegment = selected
    return control
    #else
    let control = UISegmentedControl(items: options)
    control.selectedSegmentIndex = selected
    let target = target { sender in changed((sender as? UISegmentedControl)?.selectedSegmentIndex ?? 0) }
    control.addTarget(target, action: #selector(Trampoline.fire(_:)), for: .valueChanged)
    return control
    #endif
  }

  func toggle(_ title: String, isOn: Bool, changed: @escaping (Bool) -> Void) -> KitView {
    #if os(macOS)
    let target = target { sender in changed((sender as? NSButton)?.state == .on) }
    let box = NSButton(checkboxWithTitle: title, target: target, action: #selector(Trampoline.fire(_:)))
    box.state = isOn ? .on : .off
    return box
    #else
    let control = UISwitch()
    control.isOn = isOn
    let target = target { sender in changed((sender as? UISwitch)?.isOn ?? false) }
    control.addTarget(target, action: #selector(Trampoline.fire(_:)), for: .valueChanged)
    return stack([label(title), control], vertical: false, spacing: 12)
    #endif
  }

  func clear(_ stack: StackView) {
    for view in stack.arrangedSubviews {
      stack.removeArrangedSubview(view)
      view.removeFromSuperview()
    }
  }
}

@MainActor
final class SettingsController: KitViewController {
  let model: AppModel
  let form = Form()
  var observer: Observer?
  let wallet: StackView
  let computer: StackView
  let hand: StackView
  var keys: KitView?
  let plansBox: StackView
  var plansObserver: Observer?
  var claudeCode = ""
  var servers: KitView?
  let cloud: StackView
  var handCommand = ""
  var handName: String = {
    #if os(macOS)
    Host.current().localizedName ?? "mac"
    #else
    UIDevice.current.name
    #endif
  }()

  init(model: AppModel) {
    self.model = model
    wallet = form.stack()
    computer = form.stack()
    hand = form.stack()
    cloud = form.stack()
    plansBox = form.stack(spacing: 10)
    super.init(nibName: nil, bundle: nil)
    title = "Settings"
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("created in code") }

  func section(_ title: String, _ views: [KitView]) -> KitView {
    form.stack([form.label(title, size: 15, weight: .semibold)] + views, spacing: 8)
  }

  override func loadView() {
    let keys = form.stack([
      form.field("Anthropic API key", value: model.anthropicKey, secure: true) { [weak self] in self?.model.anthropicKey = $0; self?.model.saveKeys() },
      form.field("OpenAI API key", value: model.openaiKey, secure: true) { [weak self] in self?.model.openaiKey = $0; self?.model.saveKeys() },
    ])
    keys.isHidden = model.access != .keys
    self.keys = keys
    let servers = form.stack([
      form.label("Cloudflare deployment", secondary: true),
      form.field("https://nanocode.xyz/cloudflare/", value: model.cloudflareURL, mono: true) { [weak self] in self?.model.cloudflareURL = $0; self?.model.saveServers() },
      form.field("Access token (optional)", value: model.cloudflareToken, secure: true) { [weak self] in self?.model.cloudflareToken = $0; self?.model.saveServers() },
      form.label("Vercel deployment", secondary: true),
      form.field("https://nanocode.xyz/vercel/api/chat", value: model.vercelURL, mono: true) { [weak self] in self?.model.vercelURL = $0; self?.model.saveServers() },
      form.field("Access token (optional)", value: model.vercelToken, secure: true) { [weak self] in self?.model.vercelToken = $0; self?.model.saveServers() },
      form.toggle("Run the Cloudflare agent's tools and cells on this device", isOn: model.deviceHand) { [weak self] on in
        guard let self else { return }
        Task { await self.model.setDeviceHand(on) }
      },
      cloud,
    ])
    servers.isHidden = model.runner == .device
    self.servers = servers
    let content = form.stack([
      section("Where the agent runs", [
        form.label("On this device the agent and its durable journal live in the app. On Cloudflare or Vercel it runs in the demo's durable session, keeps going while this device sleeps, and the app catches up from where it left off.", secondary: true),
        form.segmented(Runner.allCases.map(\.label), selected: Runner.allCases.firstIndex(of: model.runner) ?? 0) { [weak self] index in
          guard let self else { return }
          let runner = Runner.allCases[index]
          self.servers?.isHidden = runner == .device
          Task { await self.model.setRunner(runner) }
        },
        servers,
      ]),
      section("Appearance", [
        form.segmented(Style.allCases.map(\.label), selected: Style.allCases.firstIndex(of: model.style) ?? 0) { [weak self] index in
          guard let self else { return }
          let style = Style.allCases[index]
          Task { await self.model.setStyle(style) }
        },
      ]),
      section("Models", [
        form.segmented(Access.allCases.map(\.label), selected: Access.allCases.firstIndex(of: model.access) ?? 0) { [weak self] index in
          guard let self else { return }
          let access = Access.allCases[index]
          self.keys?.isHidden = access != .keys
          Task { await self.model.setAccess(access) }
        },
        keys,
        plansBox,
      ]),
      section("Tempo Wallet", [
        wallet,
        form.toggle("Paid tools from Mercator and the Tempo gateway", isOn: model.paidTools) { [weak self] in self?.model.paidTools = $0; self?.model.saveKeys() },
      ]),
      section("Computer", [computer]),
      section("This device as a hand", [
        form.label("Paste the command a nanocode session shows, such as nc hand 'wss://…' --token …", secondary: true),
        form.field("nc hand 'wss://…' --token …", value: handCommand, mono: true) { [weak self] in self?.handCommand = $0 },
        form.field("Name", value: handName) { [weak self] in self?.handName = $0 },
        hand,
      ]),
      section("Workspace", [form.label(model.workspace.path, size: 12, secondary: true, mono: true, selectable: true)]),
    ], spacing: 22)
    #if os(macOS)
    let document = Flipped()
    content.translatesAutoresizingMaskIntoConstraints = false
    document.addSubview(content)
    NSLayoutConstraint.activate([
      content.topAnchor.constraint(equalTo: document.topAnchor, constant: 24),
      content.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 28),
      content.trailingAnchor.constraint(lessThanOrEqualTo: document.trailingAnchor, constant: -28),
      content.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -24),
    ])
    let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 520, height: 640))
    scroll.hasVerticalScroller = true
    scroll.drawsBackground = false
    scroll.documentView = document
    document.translatesAutoresizingMaskIntoConstraints = false
    document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor).isActive = true
    view = scroll
    #else
    let scroll = UIScrollView()
    scroll.backgroundColor = .systemGroupedBackground
    content.translatesAutoresizingMaskIntoConstraints = false
    scroll.addSubview(content)
    NSLayoutConstraint.activate([
      content.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 20),
      content.leadingAnchor.constraint(equalTo: scroll.frameLayoutGuide.leadingAnchor, constant: 20),
      content.trailingAnchor.constraint(equalTo: scroll.frameLayoutGuide.trailingAnchor, constant: -20),
      content.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -20),
    ])
    view = scroll
    #endif
    observer = Observer { [weak self] in self?.refresh() }
    plansObserver = Observer { [weak self] in self?.renderPlans() }
  }

  func renderPlans() {
    let plans = model.plans
    plansBox.isHidden = model.access != .plan
    form.clear(plansBox)
    plansBox.addArrangedSubview(form.label("Turns run on this device and are billed to your own ChatGPT or Claude subscription. Sign-ins stay in this device's Keychain.", secondary: true))
    for provider in [Provider.codex, .claude] {
      let name = provider == .codex ? "ChatGPT" : "Claude"
      let status = plans.status[provider]
      let busy = plans.busy.contains(provider)
      var views: [KitView] = []
      if status?.isSignedIn == true {
        let account = status?.accountID.map { " as \($0.count > 14 ? "\($0.prefix(8))…" : $0)" } ?? ""
        views.append(form.label("\(name): signed in\(account)", weight: .medium))
        views.append(form.button("Sign out of \(name)", destructive: true) { Task { await plans.signOut(provider) } })
      } else if let signIn = plans.signIns[provider] {
        switch signIn.step {
        case .enterCode(let url, let code):
          views.append(form.label("Enter this code on the ChatGPT page that opened (\(url.host() ?? url.absoluteString)):", secondary: true))
          views.append(form.label(code, size: 26, weight: .bold, mono: true, selectable: true))
          views.append(form.stack([
            form.button("Open ChatGPT sign-in", prominent: true) { NanocodeKit.open(url) },
            form.button("Cancel") { plans.cancel(provider) },
          ], vertical: false))
          views.append(form.label("Waiting for you to approve it…", size: 12, secondary: true))
        case .openURL(let url):
          views.append(form.label("Sign in on the Claude page that opened, then paste the code it shows here.", secondary: true))
          views.append(form.field("Paste the code", value: claudeCode, mono: true) { [weak self] in self?.claudeCode = $0 })
          views.append(form.stack([
            form.button(busy ? "Finishing…" : "Finish sign-in", prominent: true) { [weak self] in
              guard let self else { return }
              let code = self.claudeCode
              Task {
                await plans.complete(provider, code: code)
                if plans.isSignedIn(provider) {
                  self.claudeCode = ""
                  await self.model.signedIn()
                }
              }
            },
            form.button("Open Claude sign-in") { NanocodeKit.open(url) },
            form.button("Cancel") { plans.cancel(provider) },
          ], vertical: false))
        }
      } else {
        views.append(form.label("\(name): \(status.map { $0.state.replacingOccurrences(of: "_", with: " ") } ?? "signed out")", secondary: true))
        views.append(form.button(busy ? "Starting…" : "Sign in with \(name)", prominent: true) { [weak self] in
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
      plansBox.addArrangedSubview(form.stack(views, spacing: 6))
    }
    if let error = plans.error { plansBox.addArrangedSubview(form.label(error, danger: true)) }
  }

  func refresh() {
    form.clear(cloud)
    if model.runner == .cloudflare, model.deviceHand {
      let state = model.cloudHand.state
      cloud.addArrangedSubview(form.label("Hand \(AppModel.handName): \(state.label)", size: 12, secondary: true))
      if let error = model.cloudHand.error { cloud.addArrangedSubview(form.label(error, danger: true)) }
    }
    let monitor = model.wallet
    form.clear(wallet)
    if let account = monitor.status?.account {
      wallet.addArrangedSubview(form.label("\(account) · \(monitor.status?.source == "tempo-cli" ? "Tempo CLI" : "access key")", size: 12, secondary: true, mono: true, selectable: true))
    } else {
      wallet.addArrangedSubview(form.label("Models and tools are paid per request in MACH over MPP.", secondary: true))
    }
    if let prompt = monitor.prompt {
      wallet.addArrangedSubview(form.label("Approve this device in Tempo Wallet"))
      wallet.addArrangedSubview(form.label(prompt.userCode, size: 26, weight: .bold, mono: true, selectable: true))
      wallet.addArrangedSubview(form.button("Open Tempo Wallet", prominent: true) { NanocodeKit.open(prompt.verificationURIComplete ?? prompt.verificationURI) })
    }
    if let status = monitor.status, status.connected {
      wallet.addArrangedSubview(form.label("Spent \(status.total) MACH", weight: .medium))
      for service in status.services {
        wallet.addArrangedSubview(form.label("\(service.id) · \(service.spent) \(service.symbol) · \(service.requests)×", size: 12, secondary: true))
      }
      wallet.addArrangedSubview(form.stack([
        form.button("Add MACH") { Task { if let url = await monitor.fundingURL() { NanocodeKit.open(url) } } },
        form.button("Disconnect", destructive: true) { Task { await monitor.disconnect() } },
      ], vertical: false))
    } else if monitor.prompt == nil {
      var buttons = [form.button(monitor.connecting ? "Connecting…" : "Connect Tempo Wallet", prominent: true) { Task { await monitor.connect() } }]
      #if os(macOS)
      buttons.append(form.button("Use Tempo CLI wallet") { Task { await monitor.useTempoCLI() } })
      #endif
      wallet.addArrangedSubview(form.stack(buttons, vertical: false))
    }
    if let error = monitor.error { wallet.addArrangedSubview(form.label(error, danger: true)) }

    form.clear(computer)
    let machines = model.machines
    computer.addArrangedSubview(form.label(machines.isEmpty ? "Run this in a terminal, and the agent's commands run there." : "Running on \(machines.joined(separator: ", ")). Commands and Code Mode cells run on that machine.", secondary: true))
    let command = model.relay.command
    computer.addArrangedSubview(form.label(command, size: 11, mono: true, selectable: true))
    computer.addArrangedSubview(form.button("Copy command") { Pasteboard.copy(command) })

    form.clear(hand)
    let monitorHand = model.hand
    hand.addArrangedSubview(form.label(monitorHand.state.label, secondary: true))
    if monitorHand.running {
      for item in monitorHand.status?.items ?? [] {
        hand.addArrangedSubview(form.label("\(item.kind)  \(item.label)", size: 12, secondary: true, mono: true))
      }
      hand.addArrangedSubview(form.button("Disconnect", destructive: true) { Task { await monitorHand.stop() } })
    } else {
      hand.addArrangedSubview(form.button("Connect", prominent: true) { [weak self] in self?.connectHand() })
    }
    if let error = monitorHand.error { hand.addArrangedSubview(form.label(error, danger: true)) }
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

#if os(macOS)
final class Flipped: NSView {
  override var isFlipped: Bool { true }
}
#endif
