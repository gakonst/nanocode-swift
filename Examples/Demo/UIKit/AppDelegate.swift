import NanocodeUI
import SwiftUI
import UIKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
  var window: UIWindow?
  var runtime: NanocodeRuntime?
  var wallet: WalletMonitor?
  let chat = Chat()

  func application(_ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
    let controller = NanocodeChatViewController(chat: chat, theme: .nanocode, placeholder: "Ask nanocode anything")
    controller.title = "nanocode"
    controller.navigationItem.rightBarButtonItem = UIBarButtonItem(
      image: UIImage(systemName: "creditcard"), style: .plain, target: self, action: #selector(showWallet))
    let window = UIWindow(frame: UIScreen.main.bounds)
    window.rootViewController = UINavigationController(rootViewController: controller)
    window.makeKeyAndVisible()
    self.window = window
    Task { @MainActor in await start() }
    return true
  }

  func start() async {
    do {
      let runtime = try NanocodeRuntime.standard(named: "Nanocode UIKit")
      self.runtime = runtime
      let wallet = WalletMonitor(runtime: runtime, name: "nanocode UIKit")
      self.wallet = wallet
      await wallet.restore()
      let session = try await runtime.open(SessionConfiguration(provider: .codex, model: "gpt-6-luna", thinking: "low"))
      await chat.attach(session)
    } catch {
      let alert = UIAlertController(title: "nanocode", message: error.localizedDescription, preferredStyle: .alert)
      alert.addAction(UIAlertAction(title: "OK", style: .default))
      window?.rootViewController?.present(alert, animated: true)
    }
  }

  @objc func showWallet() {
    guard let wallet else { return }
    let sheet = UIHostingController(rootView: WalletView(monitor: wallet).padding().nanocodeTheme(.nanocode))
    sheet.sheetPresentationController?.detents = [.medium()]
    window?.rootViewController?.present(sheet, animated: true)
  }
}
