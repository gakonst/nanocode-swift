import AppKit
import NanocodeUI
import SwiftUI

@MainActor
final class Delegate: NSObject, NSApplicationDelegate {
  var window: NSWindow?
  var runtime: NanocodeRuntime?
  var wallet: WalletMonitor?
  let chat = Chat()

  func applicationDidFinishLaunching(_ notification: Notification) {
    let controller = NanocodeChatViewController(chat: chat, theme: .nanocode, placeholder: "Ask nanocode anything")
    let window = NSWindow(contentViewController: controller)
    window.title = "nanocode"
    window.setContentSize(NSSize(width: 860, height: 680))
    window.styleMask.insert([.resizable, .titled, .closable, .miniaturizable])
    window.center()
    window.makeKeyAndOrderFront(nil)
    self.window = window
    NSApp.activate(ignoringOtherApps: true)
    Task { await start() }
  }

  func start() async {
    do {
      let runtime = try NanocodeRuntime.standard(named: "Nanocode AppKit")
      self.runtime = runtime
      let wallet = WalletMonitor(runtime: runtime, name: "nanocode AppKit")
      self.wallet = wallet
      await wallet.restore()
      if !wallet.connected { await wallet.useTempoCLI() }
      let session = try await runtime.open(SessionConfiguration(provider: .claude, model: "claude-haiku-5-5"))
      await chat.attach(session)
    } catch {
      NSAlert(error: error).runModal()
    }
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

let application = NSApplication.shared
let delegate = Delegate()
application.delegate = delegate
application.setActivationPolicy(.regular)
application.run()
