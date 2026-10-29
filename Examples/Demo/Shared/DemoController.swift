import NanocodeKit
#if os(macOS)
import AppKit
#else
import UIKit
#endif

@MainActor
final class DemoController: KitViewController {
  let model: AppModel
  private var shown: CloneViewController?
  private var shownStyle: Style?
  private var account: AccountRow?
  private var settings: SettingsNode?
  private var settingsStyle: Style?
  private var observer: Observer?
  private var reported: String?
  private var pending = false

  init(model: AppModel) {
    self.model = model
    super.init(nibName: nil, bundle: nil)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("created in code") }

  override func loadView() {
    #if os(macOS)
    view = NSView(frame: NSRect(x: 0, y: 0, width: 1100, height: 760))
    #else
    view = UIView()
    #endif
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    observer = Observer { [weak self] in self?.render() }
    if UserDefaults.standard.bool(forKey: "NanocodeSettings") { showSettings() }
  }

  var skin: Skin { model.style == .chatgpt ? .chatgpt : .claude }

  func render() {
    let style = model.style
    let props = makeProps()
    if let shown, shownStyle == style {
      shown.clone.props = props
      if shown.clone.conversation.chat !== model.chat { shown.clone.attach(model.chat) }
    } else {
      shown?.view.removeFromSuperview()
      shown?.removeFromParent()
      let next = CloneViewController(skin: skin, chat: model.chat, props: props)
      addChild(next)
      next.view.frame = view.bounds
      #if os(macOS)
      next.view.autoresizingMask = [.width, .height]
      #else
      next.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
      #endif
      view.addSubview(next.view)
      shown = next
      shownStyle = style
      #if os(macOS)
      DispatchQueue.main.async { next.clone.conversation.composer.focus() }
      #endif
    }
    if let script = model.script, let composer = shown?.clone.conversation.composer {
      model.script = nil
      Task { @MainActor in
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        for character in script {
          composer.input.string.append(character)
          try? await Task.sleep(nanoseconds: 28_000_000)
        }
        try? await Task.sleep(nanoseconds: 400_000_000)
        composer.submit()
      }
    }
    if settings != nil, settingsStyle != style {
      hideSettings()
      showSettings()
    }
    let busy = model.chat.pending
    if pending, !busy { Task { await model.refresh() } }
    pending = busy
    if let error = model.error, error != reported {
      reported = error
      alert(error)
    }
  }

  func makeProps() -> CloneProps {
    let model = model
    var props = CloneProps()
    props.conversations = model.visible.map { CloneConversation(id: $0.id, title: $0.title) }
    props.current = model.selection
    props.canCreate = !model.opening
    props.canSelect = !model.opening
    props.create = { Task { await model.newChat() } }
    props.select = { id in
      guard let summary = model.visible.first(where: { $0.id == id }), id != model.selection else { return }
      Task { await model.open(summary) }
    }
    props.remove = { id in
      guard let summary = model.visible.first(where: { $0.id == id }) else { return }
      Task { await model.delete(summary) }
    }
    props.picker = ClonePicker(
      models: model.models.map { CloneModel(id: $0.id, label: $0.name, detail: Style.about[$0.id]) },
      current: model.model, bound: model.bound
    ) { id in Task { await model.choose(id) } }
    props.title = model.style == .claude ? "Claude-style demo" : nil
    props.prompts = AppModel.prompts
    let kit = model.style == .chatgpt ? "ChatGPT-style demo" : "Claude-style demo"
    #if os(macOS)
    let (device, toolkit) = ("Mac", "AppKit")
    props.titlebarInset = 72
    #else
    let (device, toolkit) = ("iPhone", "UIKit")
    #endif
    let agent = switch model.runner {
    case .device: "native agent in \(toolkit)"
    case .cloudflare: "\(toolkit) app, durable agent in a [Cloudflare Durable Object](https://nanocode.xyz/cloudflare)"
    case .vercel: "\(toolkit) app, durable agent in [Vercel Functions](https://nanocode.xyz/vercel)"
    }
    props.footer = "[\u{F8FF} on \(device)](https://nanocode.xyz) · \(kit) · \(agent) · built with [nanocode-swift](https://github.com/gakonst/nanocode-swift)"
    if account == nil || shownStyle != model.style {
      account = AccountRow(skin: skin) { [weak self] in self?.showSettings() }
    }
    let (title, detail) = status
    account?.update(title: title, detail: detail)
    props.sidebar = account
    return props
  }

  var status: (String, String) {
    switch model.runner {
    case .cloudflare: return ("Cloudflare", model.cloudHand.state.online && model.deviceHand ? "This device is the agent's hand" : "Durable agent on nanocode.xyz")
    case .vercel: return ("Vercel", "Durable agent on nanocode.xyz")
    case .device: break
    }
    switch model.access {
    case .keys:
      return ("API keys", "Billed to your Anthropic or OpenAI key")
    case .plan:
      let name = model.style.provider == .codex ? "ChatGPT" : "Claude"
      return ("\(name) plan", model.plans.isSignedIn(model.style.provider) ? "Signed in" : "Not signed in")
    case .tempo:
      guard let status = model.wallet.status, status.connected, let account = status.account else {
        return ("Tempo Wallet", model.wallet.connecting ? "Connecting…" : "Not connected")
      }
      let short = account.count > 12 ? "\(account.prefix(6))…\(account.suffix(4))" : account
      return ("Tempo Wallet", "\(short) · \(status.total) MACH spent")
    }
  }

  func showSettings() {
    if let settings, settings.superview != nil { return }
    model.loadKeys()
    model.loadTokens()
    let model = model
    Task {
      await model.loadWallet()
      await model.loadPlans()
    }
    let page = SettingsNode(model: model, skin: skin, close: { [weak self] in self?.hideSettings() }, pickFolder: { [weak self] in self?.chooseFolder() })
    page.frame = view.bounds
    #if os(macOS)
    page.autoresizingMask = [.width, .height]
    page.padding = Insets(top: 22)
    #else
    page.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    page.padding = Insets(top: view.safeAreaInsets.top, bottom: view.safeAreaInsets.bottom)
    #endif
    view.addSubview(page)
    settings = page
    settingsStyle = model.style
  }

  func hideSettings() {
    settings?.removeFromSuperview()
    settings = nil
  }

  func chooseFolder() {
    #if os(macOS)
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.canCreateDirectories = true
    panel.prompt = "Use as Workspace"
    guard let window = view.window else { return }
    panel.beginSheetModal(for: window) { [weak self] response in
      guard response == .OK, let url = panel.url, let model = self?.model else { return }
      Task { await model.useFolder(url) }
    }
    #else
    let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder])
    picker.delegate = self
    present(picker, animated: true)
    #endif
  }

  #if os(iOS)
  override func viewSafeAreaInsetsDidChange() {
    super.viewSafeAreaInsetsDidChange()
    settings?.padding = Insets(top: view.safeAreaInsets.top, bottom: view.safeAreaInsets.bottom)
  }
  #endif

  func alert(_ message: String) {
    #if os(macOS)
    let alert = NSAlert()
    alert.messageText = "nanocode"
    alert.informativeText = message
    if let window = view.window { alert.beginSheetModal(for: window) } else { alert.runModal() }
    #else
    let alert = UIAlertController(title: "nanocode", message: message, preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: "OK", style: .default))
    present(alert, animated: true)
    #endif
  }
}

#if os(iOS)
extension DemoController: UIDocumentPickerDelegate {
  func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
    guard let url = urls.first else { return }
    let model = model
    Task { await model.useFolder(url) }
  }
}
#endif

@MainActor
final class AccountRow: Pressable {
  let skin: Skin
  let initial = Label()
  let name = Label()
  let detail = Label()

  init(skin: Skin, action: @escaping () -> Void) {
    self.skin = skin
    super.init(frame: .zero)
    let circle = Stack(.horizontal, spacing: 0, align: .center, [initial])
    circle.justify = .center
    circle.fixedWidth = 28
    circle.fixedHeight = 28
    circle.radius = 14
    circle.fill = skin.claude ? skin.accent : skin.text
    name.lines = 1
    detail.lines = 1
    let text = Stack(.vertical, spacing: 1, align: .start, [name, detail])
    text.grow = 1
    text.shrink = true
    axis = .horizontal
    align = .center
    spacing = 10
    padding = Insets(v: 8, h: skin.claude ? 8 : 10)
    radius = skin.claude ? 8 : 10
    hoverFill = skin.hover
    set([circle, text])
    self.action = action
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("created in code") }

  func update(title: String, detail text: String) {
    initial.text = styled(String(title.prefix(1)).uppercased(), skin.ui(13, .semibold), skin.claude ? .white : skin.bg)
    name.text = styled(title, skin.ui(14, .medium), skin.text)
    detail.text = styled(text, skin.ui(12), skin.muted)
  }
}
