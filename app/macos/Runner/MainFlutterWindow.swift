import Cocoa
import FlutterMacOS
import ObjectiveC
import UserNotifications

// Decoration must never participate in mouse targeting or the responder chain.
private final class GlassBackgroundView: NSVisualEffectView {
  override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

class MainFlutterWindow: NSWindow, UNUserNotificationCenterDelegate {
  private var notifications: FlutterMethodChannel?
  private var navigation: FlutterMethodChannel?
  private var navigationItems: [NSMenuItem] = []
  private var glassBackground: NSVisualEffectView?

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    flutterViewController.backgroundColor = .clear

    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    // Flutter's root wrapper already contains its rendering view. Place the
    // backdrop behind that view, keeping the standard controller/responder
    // chain intact for pointer events, first clicks and keyboard focus.
    let rootView = flutterViewController.view
    let glass = GlassBackgroundView(frame: rootView.bounds)
    glass.material = .underWindowBackground
    glass.blendingMode = .behindWindow
    glass.state = .followsWindowActiveState
    glass.autoresizingMask = [.width, .height]
    rootView.addSubview(glass, positioned: .below, relativeTo: nil)
    glassBackground = glass

    RegisterGeneratedPlugins(registry: flutterViewController)
    EnableDropTargetFirstMouse(in: flutterViewController.view)
    notifications = FlutterMethodChannel(name: "com.crosstransfer/notifications", binaryMessenger: flutterViewController.engine.binaryMessenger)
    notifications?.setMethodCallHandler { [weak self] call, result in self?.HandleNotification(call, result: result) }
    navigation = FlutterMethodChannel(name: "com.crosstransfer/navigation", binaryMessenger: flutterViewController.engine.binaryMessenger)
    navigation?.setMethodCallHandler { [weak self] call, result in
      guard call.method == "Configure",
            let args = call.arguments as? [String: Any],
            let labels = args["labels"] as? [String], labels.count == 3 else {
        result(FlutterMethodNotImplemented)
        return
      }
      self?.ConfigureNavigation(labels)
      result(nil)
    }

    super.awakeFromNib()
    UpdateGlassAppearance()
    NSWorkspace.shared.notificationCenter.addObserver(
      self, selector: #selector(UpdateGlassAppearance),
      name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
      object: nil
    )
    // The compact desktop window uses a fixed size.
    collectionBehavior.remove(.fullScreenPrimary)
    collectionBehavior.remove(.fullScreenAuxiliary)
    collectionBehavior.insert(.fullScreenNone)
    standardWindowButton(.zoomButton)?.isEnabled = false
  }

  deinit {
    NSWorkspace.shared.notificationCenter.removeObserver(self)
  }

  @objc private func UpdateGlassAppearance() {
    let reduceTransparency = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
    glassBackground?.isHidden = reduceTransparency
    backgroundColor = reduceTransparency ? .windowBackgroundColor : .clear
    // window_manager also sets isOpaque to false when configuring decorations;
    // the opaque fallback is supplied by backgroundColor either way.
    isOpaque = false
  }

  private func ConfigureNavigation(_ labels: [String]) {
    guard let menu = NSApp.mainMenu else { return }
    // Identify the standard Settings item by its key equivalent so this works
    // when AppKit localizes or renames Preferences to Settings.
    if let settings = menu.items.first?.submenu?.items.first(where: { $0.keyEquivalent == "," }) {
      settings.title = labels[2] + "…"
      settings.target = self
      settings.action = #selector(SelectPage(_:))
      settings.tag = 2
    }
    if navigationItems.isEmpty,
       let viewMenu = menu.items.compactMap({ $0.submenu }).first(where: {
         $0.items.contains(where: { $0.action == #selector(NSWindow.toggleFullScreen(_:)) })
       }) {
      for index in 0..<3 {
        let item = NSMenuItem(title: labels[index], action: #selector(SelectPage(_:)), keyEquivalent: "\(index + 1)")
        item.keyEquivalentModifierMask = .command
        item.tag = index
        item.target = self
        viewMenu.insertItem(item, at: index)
        navigationItems.append(item)
      }
      viewMenu.insertItem(.separator(), at: 3)
    }
    for (index, item) in navigationItems.enumerated() {
      item.title = labels[index]
    }
  }

  @objc private func SelectPage(_ sender: NSMenuItem) {
    makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    navigation?.invokeMethod("SelectPage", arguments: sender.tag)
  }

  private func EnableDropTargetFirstMouse(in rootView: NSView) {
    // desktop_drop 0.8.4 installs a full-window NSView above FlutterView. It
    // inherits NSView's default acceptsFirstMouse = false, so AppKit consumes
    // the first click on an inactive window before Flutter sees it.
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
