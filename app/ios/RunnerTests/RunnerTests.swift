import Darwin
import Foundation
import XCTest
@testable import Runner

final class RunnerTests: XCTestCase {
  func testImportedCopyCleanupProtectsInboxNewBatchesAndLinkTargets() throws {
    let fm = FileManager.default
    let base = fm.temporaryDirectory.appendingPathComponent("ct-cleanup-" + UUID().uuidString).resolvingSymlinksInPath()
    defer { try? fm.removeItem(at: base) }
    let root = base.appendingPathComponent("Imported")
    let inbox = base.appendingPathComponent("Inbox")
    let outside = base.appendingPathComponent("Received")
    let batch = root.appendingPathComponent(UUID().uuidString)
    let queued = root.appendingPathComponent(UUID().uuidString)
    for folder in [batch, queued, inbox, outside] { try fm.createDirectory(at: folder, withIntermediateDirectories: true) }
    try Data(repeating: 1, count: 4096).write(to: batch.appendingPathComponent("copy.bin"))
    try Data(repeating: 2, count: 1024).write(to: queued.appendingPathComponent("waiting.bin"))
    let sentinel = outside.appendingPathComponent("keep.bin")
    try Data("keep".utf8).write(to: sentinel)
    try fm.createSymbolicLink(at: batch.appendingPathComponent("external"), withDestinationURL: outside)
    try fm.createDirectory(at: inbox.appendingPathComponent(queued.lastPathComponent), withIntermediateDirectories: true)
    let store = try ImportedCopyStore(root: root, inbox: inbox)
    let preview = try store.Snapshot()
    XCTAssertEqual(preview["bytes"] as? Int64, 5120)
    XCTAssertEqual(preview["clearable_bytes"] as? Int64, 4096)
    XCTAssertEqual(preview["ids"] as? [String], [batch.lastPathComponent])
    let newer = root.appendingPathComponent(UUID().uuidString)
    try fm.createDirectory(at: newer, withIntermediateDirectories: true)
    _ = try store.Clear([batch.lastPathComponent, queued.lastPathComponent])
    XCTAssertFalse(fm.fileExists(atPath: batch.path))
    XCTAssertTrue(fm.fileExists(atPath: queued.path))
    XCTAssertTrue(fm.fileExists(atPath: newer.path))
    XCTAssertEqual(try Data(contentsOf: sentinel), Data("keep".utf8))
    XCTAssertThrowsError(try store.Clear(["../Received"]))
    let alias = base.appendingPathComponent("alias")
    try fm.createSymbolicLink(at: alias, withDestinationURL: outside)
    XCTAssertThrowsError(try ImportedCopyStore(root: alias, inbox: inbox))
  }

  func testFFISymbolsAreAvailableToProcessLookup() throws {
    let process = try XCTUnwrap(dlopen(nil, RTLD_NOW))
    defer { dlclose(process) }
    let symbols = ["CtCreate", "CtDestroy", "CtSetEventCallback", "CtSetEventCallbackOwned", "CtUpdateConfig", "CtShareCreate", "CtShareClose", "CtReceiveStart", "CtReceiveResume", "CtTransferPause", "CtTransferResume", "CtTransferCancel", "CtQuery", "CtFreeString", "CtVersion"]
    for symbol in symbols { XCTAssertNotNil(dlsym(process, symbol), symbol) }
    typealias Version = @convention(c) () -> UnsafePointer<CChar>?
    let version = unsafeBitCast(try XCTUnwrap(dlsym(process, "CtVersion")), to: Version.self)
    XCTAssertFalse(String(cString: try XCTUnwrap(version())).isEmpty)
  }
}

// Uses the same process symbol lookup as Dart. The test server listens on
// localhost:19090; tools/test_ios_native.sh owns its isolated process.
private final class NativeAPI {
  typealias Create = @convention(c) (UnsafePointer<CChar>?) -> UnsafeMutableRawPointer?
  typealias Destroy = @convention(c) (UnsafeMutableRawPointer?) -> Void
  typealias Query = @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?) -> UnsafePointer<CChar>?
  typealias Free = @convention(c) (UnsafePointer<CChar>?) -> Void
  typealias Event = @convention(c) (UnsafePointer<CChar>?, UnsafeMutableRawPointer?) -> Void
  typealias SetEvent = @convention(c) (UnsafeMutableRawPointer?, Event?, UnsafeMutableRawPointer?) -> Void
  typealias Start = @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?, UnsafePointer<CChar>?, UnsafeMutablePointer<UnsafePointer<CChar>?>?) -> Int32
  let handle: UnsafeMutableRawPointer
  let CreateCore: Create
  let DestroyCore: Destroy
  let QueryCore: Query
  let FreeString: Free
  let SetEventCallback: SetEvent
  let Share: Start
  let Receive: Start

  init() throws {
    handle = try XCTUnwrap(dlopen(nil, RTLD_NOW))
    CreateCore = unsafeBitCast(try XCTUnwrap(dlsym(handle, "CtCreate")), to: Create.self)
    DestroyCore = unsafeBitCast(try XCTUnwrap(dlsym(handle, "CtDestroy")), to: Destroy.self)
    QueryCore = unsafeBitCast(try XCTUnwrap(dlsym(handle, "CtQuery")), to: Query.self)
    FreeString = unsafeBitCast(try XCTUnwrap(dlsym(handle, "CtFreeString")), to: Free.self)
    SetEventCallback = unsafeBitCast(try XCTUnwrap(dlsym(handle, "CtSetEventCallback")), to: SetEvent.self)
    Share = unsafeBitCast(try XCTUnwrap(dlsym(handle, "CtShareCreate")), to: Start.self)
    Receive = unsafeBitCast(try XCTUnwrap(dlsym(handle, "CtReceiveStart")), to: Start.self)
  }
  deinit { dlclose(handle) }

  func Snapshot(_ core: UnsafeMutableRawPointer) throws -> [String: Any] {
    let pointer = try XCTUnwrap("{\"what\":\"all\"}".withCString { QueryCore(core, $0) })
    defer { FreeString(pointer) }
    return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(String(cString: pointer).utf8)) as? [String: Any])
  }
}

private final class NativeEvents {
  private let lock = NSLock()
  private var retries = 0
  private var paths: Set<String> = []
  func Record(_ json: UnsafePointer<CChar>) {
    guard let event = try? JSONSerialization.jsonObject(with: Data(String(cString: json).utf8)) as? [String: Any] else { return }
    lock.lock()
    defer { lock.unlock() }
    if event["type"] as? String == "signal_state", event["state"] as? String == "reconnecting" { retries += 1 }
    if let path = event["path"] as? String { paths.insert(path) }
  }
  func SawPath(_ path: String) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return paths.contains(path)
  }
  func Attach(_ api: NativeAPI, core: UnsafeMutableRawPointer) {
    api.SetEventCallback(core, { json, context in
      guard let json, let context else { return }
      Unmanaged<NativeEvents>.fromOpaque(context).takeUnretainedValue().Record(json)
    }, Unmanaged.passUnretained(self).toOpaque())
  }
  var count: Int {
    lock.lock()
    defer { lock.unlock() }
    return retries
  }
}

extension RunnerTests {
  private func Wait(_ predicate: () throws -> Bool, seconds: TimeInterval = 30) throws {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
      if try predicate() { return }
      RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }
    XCTFail("Timed out waiting for iOS native transfer")
    throw NSError(domain: "CrossTransferTests", code: 1)
  }

  private func Transfer(_ relay: String) throws {
    let api = try NativeAPI()
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("ct-native-" + UUID().uuidString)
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root) }
    let source = root.appendingPathComponent("source")
    try fm.createDirectory(at: source.appendingPathComponent("子目录/empty"), withIntermediateDirectories: true)
    let payload = Data((0..<(1024 * 1024 + 37)).map { UInt8($0 % 251) })
    try payload.write(to: source.appendingPathComponent("子目录/中文.bin"))
    try Data().write(to: source.appendingPathComponent("zero.bin"))
    let destination = root.appendingPathComponent("received")
    func Create(_ name: String) throws -> UnsafeMutableRawPointer {
      let config: [String: Any] = ["data_dir": root.appendingPathComponent(name).path,
        "save_dir": destination.path, "platform": "ios-test", "log_level": "warn",
        "server": ["host": "127.0.0.1", "port": 19090, "tls": false],
        "turn_mode": "off", "ws_relay": relay]
      let json = String(data: try JSONSerialization.data(withJSONObject: config), encoding: .utf8)!
      return try XCTUnwrap(json.withCString { api.CreateCore($0) })
    }
    let sender = try Create("sender")
    defer { api.DestroyCore(sender) }
    let receiver = try Create("receiver")
    let events = NativeEvents()
    events.Attach(api, core: receiver)
    defer {
      api.DestroyCore(receiver)
      withExtendedLifetime(events) {}
    }
    try Wait { try api.Snapshot(sender)["signal_connected"] as? Bool == true && api.Snapshot(receiver)["signal_connected"] as? Bool == true }
    var share_id: UnsafePointer<CChar>?
    let paths = String(data: try JSONSerialization.data(withJSONObject: [source.path]), encoding: .utf8)!
    let share_status = paths.withCString { api.Share(sender, $0, nil, &share_id) }
    XCTAssertEqual(share_status, 0)
    api.FreeString(share_id)
    var code = ""
    try Wait {
      let shares = try api.Snapshot(sender)["shares"] as? [[String: Any]] ?? []
      code = shares.first?["code"] as? String ?? ""
      return !code.isEmpty
    }
    var transfer_id: UnsafePointer<CChar>?
    let receive_status = code.withCString { code in destination.path.withCString { api.Receive(receiver, code, $0, &transfer_id) } }
    XCTAssertEqual(receive_status, 0)
    api.FreeString(transfer_id)
    try Wait({
      let receives = try api.Snapshot(receiver)["receives"] as? [[String: Any]] ?? []
      if let state = receives.first?["state"] as? String, state == "failed" {
        XCTFail("Receive failed: \(receives)")
        throw NSError(domain: "CrossTransferTests", code: 2)
      }
      return receives.first?["state"] as? String == "completed"
    }, seconds: 60)
    XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("source/子目录/中文.bin")), payload)
    XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("source/zero.bin")).count, 0)
    XCTAssertTrue(fm.fileExists(atPath: destination.appendingPathComponent("source/子目录/empty").path))
    // The once-share closes as soon as it completes and may already have
    // removed the live session from CtQuery. Keep its emitted path as evidence.
    XCTAssertTrue(events.SawPath(relay == "force" ? "relay" : "p2p"))
  }

  func testNativeP2PTransfer() throws { try Transfer("off") }
  func testNativeRelayTransfer() throws { try Transfer("force") }

  func testUnavailableServerReconnectAndShutdown() throws {
    let api = try NativeAPI()
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("ct-reconnect-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    // Reserve a loopback port without listening, so connection failures are
    // deterministic and no independently running service can accept the client.
    let socketFD = socket(AF_INET, SOCK_STREAM, 0)
    XCTAssertGreaterThanOrEqual(socketFD, 0)
    defer { close(socketFD) }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    let bound = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.bind(socketFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    XCTAssertEqual(bound, 0)
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let named = withUnsafeMutablePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(socketFD, $0, &length) }
    }
    XCTAssertEqual(named, 0)
    let port = UInt16(bigEndian: address.sin_port)
    let config: [String: Any] = ["data_dir": root.path, "server": ["host": "127.0.0.1", "port": port, "tls": false]]
    let json = String(data: try JSONSerialization.data(withJSONObject: config), encoding: .utf8)!
    let core = try XCTUnwrap(json.withCString { api.CreateCore($0) })
    let events = NativeEvents()
    var destroyed = false
    defer {
      if !destroyed { api.DestroyCore(core) }
      withExtendedLifetime(events) {}
    }
    events.Attach(api, core: core)
    try Wait({ events.count >= 3 }, seconds: 30)
    XCTAssertFalse(try api.Snapshot(core)["signal_connected"] as? Bool ?? true)
    let start = Date()
    api.DestroyCore(core)
    destroyed = true
    XCTAssertLessThan(Date().timeIntervalSince(start), 2, "Shutdown must interrupt reconnect/ping waits")
  }
}
