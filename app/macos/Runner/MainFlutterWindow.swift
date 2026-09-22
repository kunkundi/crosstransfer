import Cocoa
import FlutterMacOS
import ObjectiveC
import UserNotifications

class MainFlutterWindow: NSWindow, UNUserNotificationCenterDelegate {
  private var notifications: FlutterMethodChannel?

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)
    EnableDropTargetFirstMouse(in: flutterViewController.view)
    notifications = FlutterMethodChannel(name: "com.crosstransfer/notifications", binaryMessenger: flutterViewController.engine.binaryMessenger)
    notifications?.setMethodCallHandler { [weak self] call, result in self?.HandleNotification(call, result: result) }

    super.awakeFromNib()
    // Both the main view and quick-drop basket use fixed window sizes.
    collectionBehavior.remove(.fullScreenPrimary)
    collectionBehavior.remove(.fullScreenAuxiliary)
    collectionBehavior.insert(.fullScreenNone)
    standardWindowButton(.zoomButton)?.isEnabled = false
  }

  private func EnableDropTargetFirstMouse(in rootView: NSView) {
    // desktop_drop 0.8.4 installs a full-window NSView above FlutterView. It
    // inherits NSView's default acceptsFirstMouse = false, so AppKit consumes
    // the first click on an inactive basket before Flutter sees it.
    guard let dropTarget = rootView.subviews.first(where: {
      NSStringFromClass(type(of: $0)) == "desktop_drop.DropTarget"
    }) else {
      NSLog("CrossTransfer: desktop_drop mouse target was not found")
      return
    }
    if dropTarget.acceptsFirstMouse(for: nil) { return }
    let selector = #selector(NSView.acceptsFirstMouse(for:))
    guard let baseMethod = class_getInstanceMethod(NSView.self, selector) else { return }
    let implementation = imp_implementationWithBlock(
      { (_: AnyObject, _: NSEvent?) -> Bool in true }
        as @convention(block) (AnyObject, NSEvent?) -> Bool
    )
    if !class_addMethod(
      type(of: dropTarget), selector, implementation, method_getTypeEncoding(baseMethod)
    ) {
      imp_removeBlock(implementation)
    }
    if !dropTarget.acceptsFirstMouse(for: nil) {
      NSLog("CrossTransfer: desktop_drop first-click support could not be enabled")
    }
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
