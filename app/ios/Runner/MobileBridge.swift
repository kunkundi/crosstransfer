import Flutter
import UIKit

final class MobileBridge {
  private let channel: FlutterMethodChannel
  private var background_task: UIBackgroundTaskIdentifier = .invalid
  private var transfer_active = false
  private var background_expired = false

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "com.crosstransfer/mobile", binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, result in self?.Handle(call, result: result) }
    NotificationCenter.default.addObserver(self, selector: #selector(DidEnterBackground), name: UIScene.didEnterBackgroundNotification, object: nil)
    NotificationCenter.default.addObserver(self, selector: #selector(WillEnterForeground), name: UIScene.willEnterForegroundNotification, object: nil)
  }

  private func Handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    do {
      switch call.method {
      case "SetTransferActive":
        transfer_active = call.arguments as? Bool ?? false
        UIApplication.shared.isIdleTimerDisabled = transfer_active
        if !transfer_active { EndBackgroundTask() }
        else if UIApplication.shared.applicationState == .background { BeginBackgroundTask() }
        result(nil)
      case "ReadInbox":
        // File copies can be large; never block Flutter's platform thread.
        DispatchQueue.global(qos: .userInitiated).async {
          do {
            let items = try self.ReadInbox()
            DispatchQueue.main.async { result(items) }
          } catch {
            DispatchQueue.main.async { result(FlutterError(code: "inbox", message: error.localizedDescription, details: nil)) }
          }
        }
      case "AcknowledgeInbox":
        guard let id = call.arguments as? String, UUID(uuidString: id) != nil else { throw CocoaError(.fileReadInvalidFileName) }
        if let inbox = InboxDirectory() {
          let batch = inbox.appendingPathComponent(id)
          if FileManager.default.fileExists(atPath: batch.path) { try FileManager.default.removeItem(at: batch) }
        }
        result(nil)
      case "ShareLink":
        guard let link = call.arguments as? String, let view = Presenter() else { throw CocoaError(.featureUnsupported) }
        let sheet = UIActivityViewController(activityItems: [link], applicationActivities: nil)
        sheet.popoverPresentationController?.sourceView = view.view
        sheet.popoverPresentationController?.sourceRect = CGRect(x: view.view.bounds.midX, y: view.view.bounds.midY, width: 1, height: 1)
        view.present(sheet, animated: true)
        result(nil)
      case "ExportDirectory":
        guard let path = call.arguments as? String, let view = Presenter() else { throw CocoaError(.featureUnsupported) }
        let directory = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        let documents = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true).resolvingSymlinksInPath()
        guard directory.path.hasPrefix(documents.path + "/") else { throw CocoaError(.fileReadNoPermission) }
        view.present(UIDocumentPickerViewController(forExporting: [directory], asCopy: true), animated: true)
        result(nil)
      default: result(FlutterMethodNotImplemented)
      }
    } catch {
      result(FlutterError(code: "mobile", message: error.localizedDescription, details: nil))
    }
  }

  @objc private func DidEnterBackground() { if transfer_active { BeginBackgroundTask() } }
  @objc private func WillEnterForeground() {
    EndBackgroundTask()
    if background_expired {
      background_expired = false
      channel.invokeMethod("BackgroundExpired", arguments: nil)
    }
    channel.invokeMethod("InboxChanged", arguments: nil)
  }

  private func BeginBackgroundTask() {
    guard background_task == .invalid, !background_expired else { return }
    background_task = UIApplication.shared.beginBackgroundTask(withName: "CrossTransfer") { [weak self] in
      guard let self = self else { return }
      self.background_expired = true
      self.channel.invokeMethod("BackgroundExpired", arguments: nil)
      self.EndBackgroundTask()
    }
  }
  private func EndBackgroundTask() {
    guard background_task != .invalid else { return }
    UIApplication.shared.endBackgroundTask(background_task)
    background_task = .invalid
  }

  private func Presenter() -> UIViewController? {
    let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first { $0.activationState == .foregroundActive }
    var view = scene?.windows.first { $0.isKeyWindow }?.rootViewController
    while let presented = view?.presentedViewController { view = presented }
    return view
  }

  private func InboxDirectory() -> URL? {
    guard let group = Bundle.main.object(forInfoDictionaryKey: "CTAppGroup") as? String else { return nil }
    return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)?.appendingPathComponent("Inbox", isDirectory: true)
  }

  private func ReadInbox() throws -> [[String: Any]] {
    let fm = FileManager.default
    guard let inbox = InboxDirectory(), fm.fileExists(atPath: inbox.path) else { return [] }
    let documents = try fm.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
    var result: [[String: Any]] = []
    for batch in try fm.contentsOfDirectory(at: inbox, includingPropertiesForKeys: nil).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
      let id = batch.lastPathComponent
      guard UUID(uuidString: id) != nil,
            let data = try? Data(contentsOf: batch.appendingPathComponent("manifest.json")),
            let manifest = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let names = manifest["files"] as? [String] else { continue }
      let destination = documents.appendingPathComponent("Imported", isDirectory: true).appendingPathComponent(id, isDirectory: true)
      try fm.createDirectory(at: destination, withIntermediateDirectories: true)
      var paths: [String] = []
      for name in names {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\\") else { throw CocoaError(.fileReadInvalidFileName) }
        let source = batch.appendingPathComponent(name)
        let target = destination.appendingPathComponent(name)
        if !fm.fileExists(atPath: target.path) {
          // Copy to a sibling then rename so a killed import cannot become a partial send.
          let temp = destination.appendingPathComponent(".import-" + UUID().uuidString)
          do {
            try fm.copyItem(at: source, to: temp)
            try fm.moveItem(at: temp, to: target)
          } catch { try? fm.removeItem(at: temp); throw error }
        }
        paths.append(target.path)
      }
      result.append(["id": id, "paths": paths, "content": manifest["content"] as? String ?? ""])
    }
    return result
  }
}
