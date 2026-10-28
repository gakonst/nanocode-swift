import NanocodeKit
import UIKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
  var window: UIWindow?
  let model = AppModel()
  var background: UIBackgroundTaskIdentifier = .invalid
  var observer: Observer?

  func application(_ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
    let controller = DemoController(model: model)
    let model = model
    controller.openSettings = { [weak controller] in
      let settings = SettingsController(model: model)
      let navigation = UINavigationController(rootViewController: settings)
      settings.navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .done, primaryAction: UIAction { [weak settings] _ in
        settings?.dismiss(animated: true)
      })
      controller?.present(navigation, animated: true)
    }
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
      Task { @MainActor in self.finish() }
    }
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
