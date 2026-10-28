import NanocodeKit
import UIKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
  var window: UIWindow?
  var runtime: NanocodeRuntime?
  var wallet: WalletMonitor?
  let chat = Chat()

  func application(_ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
    let controller = NanocodeChatViewController(chat: chat, skin: .chatgpt)
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
    let status = wallet.status
    let message = status?.account.map { "\($0)\nSpent \(status?.total ?? "0") MACH" } ?? "No wallet is connected."
    let alert = UIAlertController(title: "Tempo Wallet", message: message, preferredStyle: .alert)
    if status?.account == nil {
      alert.addAction(UIAlertAction(title: "Connect", style: .default) { _ in Task { await wallet.connect() } })
    }
    alert.addAction(UIAlertAction(title: "OK", style: .cancel))
    window?.rootViewController?.present(alert, animated: true)
  }
}
