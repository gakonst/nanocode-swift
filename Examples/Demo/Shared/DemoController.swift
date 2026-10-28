import NanocodeKit
#if os(macOS)
import AppKit
#else
import UIKit
#endif

@MainActor
final class DemoController: KitViewController {
  let model: AppModel
  var openSettings: () -> Void = {}
  private var shown: CloneViewController?
  private var shownStyle: Style?
  private var pill: ClonePill?
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
    props.conversations = model.visible.map { CloneConversation(id: $0.id, title: $0.preview ?? "") }
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
    props.footer = "[\u{F8FF} on Mac](https://nanocode.xyz) · \(kit) · native agent in AppKit · built with [nanocode-swift](https://github.com/gakonst/nanocode-swift)"
    props.titlebarInset = 72
    #else
    props.footer = "[\u{F8FF} on iPhone](https://nanocode.xyz) · \(kit) · native agent in UIKit · built with [nanocode-swift](https://github.com/gakonst/nanocode-swift)"
    #endif
    if pill == nil || shownStyle != model.style {
      pill = ClonePill(skin: skin, title: "") { [weak self] in self?.openSettings() }
      pill?.shrink = true
    }
    pill?.title = walletLabel
    props.actions = pill.map { [$0] } ?? []
    return props
  }

  var walletLabel: String {
    if model.access == .keys { return "API keys" }
    if let account = model.wallet.status?.account { return account.count > 12 ? "\(account.prefix(6))…\(account.suffix(4))" : account }
    return model.wallet.connecting ? "Connecting…" : "Connect Tempo Wallet"
  }

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
