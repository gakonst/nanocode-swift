import NanocodeKit
import UIKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
  var window: UIWindow?
  let model = AppModel()

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
}
