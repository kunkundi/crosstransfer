import Cocoa
import FlutterMacOS
import UserNotifications

class MainFlutterWindow: NSWindow, UNUserNotificationCenterDelegate {
  private var notifications: FlutterMethodChannel?
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)
    notifications = FlutterMethodChannel(name: "com.crosstransfer/notifications", binaryMessenger: flutterViewController.engine.binaryMessenger)
    notifications?.setMethodCallHandler { [weak self] call, result in self?.HandleNotification(call, result: result) }

    super.awakeFromNib()
  }

  private func HandleNotification(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let center = UNUserNotificationCenter.current()
    switch call.method {
    case "InitNotifications":
      center.delegate = self
      center.requestAuthorization(options: [.alert, .sound]) { _, error in
        DispatchQueue.main.async { result(error == nil) }
      }
    case "ShowNotification":
      let args = call.arguments as? [String: Any] ?? [:]
      let content = UNMutableNotificationContent()
      content.title = args["title"] as? String ?? "CrossTransfer"
      content.body = args["body"] as? String ?? ""
      content.sound = .default
      center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)) { error in
        DispatchQueue.main.async {
          if let error = error { result(FlutterError(code: "notification", message: error.localizedDescription, details: nil)) }
          else { result(nil) }
        }
      }
    default: result(FlutterMethodNotImplemented)
    }
  }

  func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                              withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
    completionHandler([.banner, .list, .sound])
  }

  func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                              withCompletionHandler completionHandler: @escaping () -> Void) {
    DispatchQueue.main.async {
      self.makeKeyAndOrderFront(nil)
      NSApp.activate(ignoringOtherApps: true)
      completionHandler()
    }
  }
}
