import Cocoa
import FlutterMacOS
import XCTest

class RunnerTests: XCTestCase {

  func testDesktopDropAcceptsFirstMouse() {
    let dropTarget = NSApp.windows
      .flatMap { $0.contentViewController?.view.subviews ?? [] }
      .first { NSStringFromClass(type(of: $0)) == "desktop_drop.DropTarget" }
    XCTAssertNotNil(dropTarget, "desktop_drop should register its native drop view")
    XCTAssertTrue(dropTarget?.acceptsFirstMouse(for: nil) ?? false)
  }

}
