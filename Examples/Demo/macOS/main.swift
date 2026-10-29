import AppKit
import NanocodeKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  let model = AppModel()
  var window: NSWindow?
  var controller: DemoController?

  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.mainMenu = menu()
    if let appearance = UserDefaults.standard.string(forKey: "NanocodeAppearance") {
      NSApp.appearance = NSAppearance(named: appearance == "dark" ? .darkAqua : .aqua)
    }
    let controller = DemoController(model: model)
    self.controller = controller
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 760),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
    window.titlebarAppearsTransparent = true
    window.titleVisibility = .hidden
    window.toolbar = NSToolbar(identifier: "Nanocode")
    window.toolbarStyle = .unified
    window.titlebarSeparatorStyle = .none
    window.title = "Nanocode"
    window.contentViewController = controller
    window.setContentSize(NSSize(width: 1100, height: 760))
    window.minSize = NSSize(width: 420, height: 480)
    window.center()
    window.setFrameAutosaveName("Nanocode")
    let background = UserDefaults.standard.bool(forKey: "NanocodeBackground")
    if background { window.orderFront(nil) } else { window.makeKeyAndOrderFront(nil) }
    self.window = window
    if let size = UserDefaults.standard.string(forKey: "NanocodeWindow")?.split(separator: "x").compactMap({ Double($0) }), size.count == 2 {
      requested = NSSize(width: size[0], height: size[1])
      fit()
      NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification, object: window, queue: .main) { [weak self] _ in
        MainActor.assumeIsolated { self?.fit() }
      }
    }
    if !background { NSApp.activate(ignoringOtherApps: true) }
    Task { await model.start() }
  }

  var requested: NSSize?
  let launched = Date()

  func fit() {
    guard let window, let requested, window.contentLayoutRect.size != requested, Date().timeIntervalSince(launched) < 20 else { return }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
      guard let self, let window = self.window, window.contentLayoutRect.size != requested else { return }
      window.setContentSize(requested)
    }
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

  @objc func showSettings() {
    window?.makeKeyAndOrderFront(nil)
    controller?.showSettings()
  }

  @objc func newChat() { Task { await model.newChat() } }
  @objc func chatgpt() { Task { await model.setStyle(.chatgpt) } }
  @objc func claude() { Task { await model.setStyle(.claude) } }
  @objc func onDevice() { Task { await model.setRunner(.device) } }
  @objc func onCloudflare() { Task { await model.setRunner(.cloudflare) } }
  @objc func onVercel() { Task { await model.setRunner(.vercel) } }

  func menu() -> NSMenu {
    let main = NSMenu()
    func add(_ title: String, _ items: [NSMenuItem]) {
      let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
      let menu = NSMenu(title: title)
      items.forEach(menu.addItem)
      item.submenu = menu
      main.addItem(item)
    }
    func item(_ title: String, _ action: Selector?, _ key: String, _ modifiers: NSEvent.ModifierFlags = .command, target: AnyObject? = nil) -> NSMenuItem {
      let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
      item.keyEquivalentModifierMask = modifiers
      item.target = target
      return item
    }
    add("Nanocode", [
      item("About Nanocode", #selector(NSApplication.orderFrontStandardAboutPanel(_:)), ""),
      .separator(),
      item("Settings…", #selector(showSettings), ",", target: self),
      .separator(),
      item("Hide Nanocode", #selector(NSApplication.hide(_:)), "h"),
      item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
      .separator(),
      item("Quit Nanocode", #selector(NSApplication.terminate(_:)), "q"),
    ])
    add("File", [
      item("New Chat", #selector(newChat), "n", target: self),
      item("Close Window", #selector(NSWindow.performClose(_:)), "w"),
    ])
    add("Edit", [
      item("Undo", Selector(("undo:")), "z"),
      item("Redo", Selector(("redo:")), "z", [.command, .shift]),
      .separator(),
      item("Cut", #selector(NSText.cut(_:)), "x"),
      item("Copy", #selector(NSText.copy(_:)), "c"),
      item("Paste", #selector(NSText.paste(_:)), "v"),
      item("Select All", #selector(NSText.selectAll(_:)), "a"),
    ])
    add("View", [
      item("ChatGPT Style", #selector(chatgpt), "1", target: self),
      item("Claude Style", #selector(claude), "2", target: self),
      .separator(),
      item("Run on This Device", #selector(onDevice), "1", [.command, .option], target: self),
      item("Run on Cloudflare", #selector(onCloudflare), "2", [.command, .option], target: self),
      item("Run on Vercel", #selector(onVercel), "3", [.command, .option], target: self),
    ])
    add("Window", [
      item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
      item("Zoom", #selector(NSWindow.performZoom(_:)), ""),
    ])
    return main
  }
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.regular)
application.run()
