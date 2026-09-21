// Launch the packaged app through Launch Services with isolated test settings.
// Directly executing Contents/MacOS/... can leave it unregistered, causing a
// subsequent `open -a` URL to start a second process with the user's settings.
import Cocoa

guard CommandLine.arguments.count == 3,
      let link = URL(string: CommandLine.arguments[2]) else { exit(2) }
let bundle = URL(fileURLWithPath: CommandLine.arguments[1])
let configuration = NSWorkspace.OpenConfiguration()
configuration.environment = ProcessInfo.processInfo.environment
configuration.createsNewApplicationInstance = true
configuration.promptsUserIfNeeded = false
var application: NSRunningApplication?
var stopping = false
var stopTime: Date?

signal(SIGTERM, SIG_IGN)
let stop = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
stop.setEventHandler {
  stopping = true
  stopTime = Date()
  application?.terminate()
}
stop.resume()

NSWorkspace.shared.open([link], withApplicationAt: bundle, configuration: configuration) { app, error in
  DispatchQueue.main.async {
    guard let app = app, error == nil else {
      fputs("Launch Services failed: \(String(describing: error))\n", stderr)
      exit(1)
    }
    application = app
    print("Test app PID: \(app.processIdentifier)")
    fflush(stdout)
    if stopping { app.terminate() }
  }
}
let timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
  if let app = application {
    if app.isTerminated { exit(stopping ? 0 : 1) }
    if let since = stopTime, Date().timeIntervalSince(since) > 3 { app.forceTerminate() }
  }
}
RunLoop.main.run()
