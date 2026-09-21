import Flutter
import UIKit
import AVFoundation

final class MobileBridge {
  private let channel: FlutterMethodChannel
  private var background_task: UIBackgroundTaskIdentifier = .invalid
  private var transfer_active = false
  private var background_expired = false
  private var scanner: QrScannerController?

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "com.crosstransfer/mobile", binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, result in self?.Handle(call, result: result) }
    NotificationCenter.default.addObserver(self, selector: #selector(DidEnterBackground), name: UIScene.didEnterBackgroundNotification, object: nil)
    NotificationCenter.default.addObserver(self, selector: #selector(WillEnterForeground), name: UIScene.willEnterForegroundNotification, object: nil)
  }

  private func Handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    do {
      switch call.method {
      case "ScanCode":
        guard scanner == nil, let view = Presenter() else { throw CocoaError(.featureUnsupported) }
        let labels = call.arguments as? [String: String] ?? [:]
        let scan = QrScannerController(title: labels["title"] ?? "CrossTransfer", cancel: labels["cancel"] ?? "Cancel") { [weak self] value in
          self?.scanner = nil
          result(value)
        }
        scanner = scan
        view.present(scan, animated: true)
      case "CancelScan":
        scanner?.Finish(nil)
        result(nil)
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

// System camera APIs keep QR capture independent of third-party model SDKs.
// Camera configuration/start/stop run on one serial queue, never the UI thread.
private final class QrScannerController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
  private let session = AVCaptureSession()
  private let camera_queue = DispatchQueue(label: "com.crosstransfer.qr")
  private var preview: AVCaptureVideoPreviewLayer!
  private var configured = false // camera_queue only
  private var finished = false // main queue only
  private let scan_title: String
  private let cancel_title: String
  private let completion: (Any?) -> Void

  init(title: String, cancel: String, completion: @escaping (Any?) -> Void) {
    scan_title = title
    cancel_title = cancel
    self.completion = completion
    super.init(nibName: nil, bundle: nil)
    modalPresentationStyle = .fullScreen
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .black
    preview = AVCaptureVideoPreviewLayer(session: session)
    preview.videoGravity = .resizeAspectFill
    view.layer.addSublayer(preview)
    let bar = UIStackView()
    bar.translatesAutoresizingMaskIntoConstraints = false
    bar.axis = .horizontal
    bar.alignment = .center
    bar.spacing = 16
    let label = UILabel()
    label.text = scan_title
    label.textColor = .white
    label.font = .preferredFont(forTextStyle: .headline)
    label.numberOfLines = 0
    let cancel = UIButton(type: .system)
    cancel.setTitle(cancel_title, for: .normal)
    cancel.tintColor = .white
    cancel.setContentHuggingPriority(.required, for: .horizontal)
    cancel.addTarget(self, action: #selector(Cancel), for: .touchUpInside)
    bar.addArrangedSubview(label)
    bar.addArrangedSubview(cancel)
    let shade = UIView()
    shade.backgroundColor = UIColor.black.withAlphaComponent(0.65)
    shade.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(shade)
    view.addSubview(bar)
    NSLayoutConstraint.activate([
      bar.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 20),
      bar.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -20),
      bar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
      bar.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
      shade.topAnchor.constraint(equalTo: view.topAnchor),
      shade.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      shade.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      shade.bottomAnchor.constraint(equalTo: bar.bottomAnchor, constant: 12),
    ])
    NotificationCenter.default.addObserver(self, selector: #selector(Stop), name: UIScene.willDeactivateNotification, object: nil)
    NotificationCenter.default.addObserver(self, selector: #selector(Start), name: UIScene.didActivateNotification, object: nil)
    NotificationCenter.default.addObserver(self, selector: #selector(CameraFailed), name: .AVCaptureSessionRuntimeError, object: session)
  }

  override func viewDidAppear(_ animated: Bool) { super.viewDidAppear(animated); Start() }
  override func viewWillDisappear(_ animated: Bool) { super.viewWillDisappear(animated); Stop() }
  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    preview.frame = view.bounds
    // The iOS 15 deployment target also supports older devices without rotation coordinators.
    if let orientation = view.window?.windowScene?.interfaceOrientation,
       let video = AVCaptureVideoOrientation(rawValue: orientation.rawValue),
       preview.connection?.isVideoOrientationSupported == true { preview.connection?.videoOrientation = video }
  }

  @objc private func Start() {
    guard !finished, view.window != nil else { return }
    switch AVCaptureDevice.authorizationStatus(for: .video) {
    case .authorized: RunCamera()
    case .notDetermined:
      AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
        DispatchQueue.main.async {
          guard let self = self, !self.finished else { return }
          if granted { self.RunCamera() } else { self.CameraFailed() }
        }
      }
    default: CameraFailed()
    }
  }

  private func RunCamera() {
    guard !finished, UIApplication.shared.applicationState == .active else { return }
    camera_queue.async {
      do {
        if !self.configured {
          self.session.beginConfiguration()
          defer { self.session.commitConfiguration() }
          guard let device = AVCaptureDevice.default(for: .video) else { throw CocoaError(.featureUnsupported) }
          let input = try AVCaptureDeviceInput(device: device)
          let output = AVCaptureMetadataOutput()
          guard self.session.canAddInput(input), self.session.canAddOutput(output) else { throw CocoaError(.featureUnsupported) }
          self.session.addInput(input)
          self.session.addOutput(output)
          guard output.availableMetadataObjectTypes.contains(.qr) else { throw CocoaError(.featureUnsupported) }
          output.setMetadataObjectsDelegate(self, queue: .main)
          output.metadataObjectTypes = [.qr]
          self.configured = true
        }
        if !self.session.isRunning { self.session.startRunning() }
      } catch { DispatchQueue.main.async { self.CameraFailed() } }
    }
  }

  @objc private func Stop() { camera_queue.async { if self.session.isRunning { self.session.stopRunning() } } }
  @objc private func Cancel() { Finish(nil) }
  @objc private func CameraFailed() {
    if !Thread.isMainThread { DispatchQueue.main.async { self.CameraFailed() }; return }
    Finish(FlutterError(code: "camera", message: "Camera unavailable or permission denied", details: nil))
  }

  func Finish(_ value: Any?) {
    guard !finished else { return }
    finished = true
    NotificationCenter.default.removeObserver(self)
    Stop()
    dismiss(animated: true) { self.completion(value) }
  }

  func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput objects: [AVMetadataObject], from connection: AVCaptureConnection) {
    if let value = objects.compactMap({ ($0 as? AVMetadataMachineReadableCodeObject)?.stringValue }).first { Finish(value) }
  }
}
