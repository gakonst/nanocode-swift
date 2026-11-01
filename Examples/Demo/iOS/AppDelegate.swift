import NanocodeDevice
import NanocodeKit
import UIKit
import UserNotifications

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
  var window: UIWindow?
  let model = AppModel()
  var background: UIBackgroundTaskIdentifier = .invalid
  var observer: Observer?

  func application(_ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
    let controller = DemoController(model: model)
    let window = UIWindow(frame: UIScreen.main.bounds)
    window.rootViewController = controller
    window.makeKeyAndVisible()
    self.window = window
    Task { await model.start() }
    return true
  }

  func applicationDidEnterBackground(_ application: UIApplication) {
    guard model.chat.pending, background == .invalid else { return }
    background = application.beginBackgroundTask(withName: "nanocode turn") { [weak self] in self?.finish() }
    observer = Observer { [weak self] in
      guard let self, !self.model.chat.pending else { return }
      let reply = self.model.chat.entries.last { $0.kind == .assistant }?.text ?? ""
      Task { @MainActor in
        await Self.notify(reply)
        self.finish()
      }
    }
  }

  func application(_ app: UIApplication, open url: URL, options: [UIApplication.OpenURLOptionsKey: Any] = [:]) -> Bool {
    ShortcutCallbacks.handle(url)
  }

  static func notify(_ text: String) async {
    let center = UNUserNotificationCenter.current()
    guard await center.notificationSettings().authorizationStatus == .authorized else { return }
    let content = UNMutableNotificationContent()
    content.title = "Nanocode"
    content.body = text.isEmpty ? "Your answer is ready." : String(text.prefix(180))
    try? await center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
  }

  func applicationWillEnterForeground(_ application: UIApplication) {
    finish()
    guard let backend = model.chat.backend else { return }
    Task { await backend.resume() }
  }

  func finish() {
    observer?.cancel()
    observer = nil
    guard background != .invalid else { return }
    UIApplication.shared.endBackgroundTask(background)
    background = .invalid
  }
}
