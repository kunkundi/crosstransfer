import UIKit
import UniformTypeIdentifiers

// Import while the extension owns the provider's temporary/security-scoped URL.
// The main app consumes committed batches after the user returns to it.
final class ShareViewController: UIViewController {
  private let label = UILabel()
  private let button = UIButton(type: .system)
  private var cancelled = false
  private var working = true
  private var chinese: Bool { Locale.preferredLanguages.first?.hasPrefix("zh") == true }

  override func viewDidLoad() {
    super.viewDidLoad()
    isModalInPresentation = true
    view.backgroundColor = .systemBackground
    label.numberOfLines = 0
    label.textAlignment = .center
    label.text = chinese ? "正在导入文件…" : "Importing files…"
    button.setTitle(chinese ? "取消" : "Cancel", for: .normal)
    button.addTarget(self, action: #selector(Finish), for: .touchUpInside)
    let stack = UIStackView(arrangedSubviews: [label, button])
    stack.axis = .vertical
    stack.spacing = 24
    stack.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
      stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
      stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
    ])
    Task { await ImportItems() }
  }

  @objc private func Finish() {
    cancelled = true
    if !working { extensionContext?.completeRequest(returningItems: nil) }
    else { button.isEnabled = false }
  }

  private func ImportItems() async {
    var batch: URL?
    do {
      guard let group = Bundle.main.object(forInfoDictionaryKey: "CTAppGroup") as? String,
            let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) else { throw CocoaError(.fileReadNoPermission) }
      let directory = container.appendingPathComponent("Inbox", isDirectory: true).appendingPathComponent(UUID().uuidString, isDirectory: true)
      batch = directory
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      let items = extensionContext?.inputItems as? [NSExtensionItem] ?? []
      let providers = items.flatMap { $0.attachments ?? [] }
      var names: [String] = []
      var content: [String] = []
      for (index, provider) in providers.enumerated() {
        if cancelled { throw CancellationError() }
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
          let item = try await LoadItem(provider, type: UTType.fileURL.identifier)
          guard let url = item as? URL else { throw CocoaError(.fileReadCorruptFile) }
          let name: String = try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
              do { continuation.resume(returning: try self.CopyFile(url, directory: directory, index: index)) }
              catch { continuation.resume(throwing: error) }
            }
          }
          names.append(name)
        } else if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
          let item = try await LoadItem(provider, type: UTType.url.identifier)
          if let url = item as? URL { content.append(url.absoluteString) }
        } else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
          let item = try await LoadItem(provider, type: UTType.plainText.identifier)
          if let text = item as? String { content.append(text) }
        } else if let type = provider.registeredTypeIdentifiers.first(where: { UTType($0)?.conforms(to: .data) == true }) {
          let name: String = try await withCheckedThrowingContinuation { continuation in
            provider.loadFileRepresentation(forTypeIdentifier: type) { url, error in
              do {
                guard let url = url else { throw error ?? CocoaError(.fileReadUnknown) }
                // Provider deletes this URL on callback return, so copy here.
                continuation.resume(returning: try self.CopyFile(url, directory: directory, index: index))
              } catch { continuation.resume(throwing: error) }
            }
          }
          names.append(name)
        } else { throw CocoaError(.fileReadUnsupportedScheme) }
      }
      guard !cancelled else { throw CancellationError() }
      guard !names.isEmpty || !content.isEmpty else { throw CocoaError(.fileReadUnknown) }
      let data = try JSONSerialization.data(withJSONObject: ["files": names, "content": content.joined(separator: "\n")])
      try data.write(to: directory.appendingPathComponent("manifest.json"), options: .atomic)
      label.text = chinese ? "已导入。请打开 CrossTransfer 生成取件码。" : "Imported. Open CrossTransfer to create a take-code."
    } catch {
      if let directory = batch { try? FileManager.default.removeItem(at: directory) }
      label.text = chinese ? "导入失败，请重试。\n\(error.localizedDescription)" : "Import failed. Please retry.\n\(error.localizedDescription)"
    }
    working = false
    button.isEnabled = true
    button.setTitle(chinese ? "完成" : "Done", for: .normal)
    if cancelled { extensionContext?.completeRequest(returningItems: nil) }
  }

  private func LoadItem(_ provider: NSItemProvider, type: String) async throws -> NSSecureCoding? {
    try await withCheckedThrowingContinuation { continuation in
      provider.loadItem(forTypeIdentifier: type, options: nil) { item, error in
        if let error = error { continuation.resume(throwing: error) }
        else { continuation.resume(returning: item) }
      }
    }
  }

  nonisolated private func CopyFile(_ source: URL, directory: URL, index: Int) throws -> String {
    let scoped = source.startAccessingSecurityScopedResource()
    defer { if scoped { source.stopAccessingSecurityScopedResource() } }
    var name = source.lastPathComponent
    if name.isEmpty || name == "." || name == ".." { name = "file-\(index)" }
    if name == "manifest.json" || FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path) {
      name = "\(index)-\(name)"
    }
    try FileManager.default.copyItem(at: source, to: directory.appendingPathComponent(name))
    return name
  }
}
