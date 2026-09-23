import Cocoa
import FlutterMacOS
import XCTest

class RunnerTests: XCTestCase {

  private func Descendants(_ view: NSView) -> [NSView] {
    [view] + view.subviews.flatMap { Descendants($0) }
  }

  func testDesktopDropAcceptsFirstMouse() {
    let dropTarget = NSApp.windows
      .compactMap { $0.contentView }
      .flatMap { Descendants($0) }
      .first { NSStringFromClass(type(of: $0)) == "desktop_drop.DropTarget" }
    XCTAssertNotNil(dropTarget, "desktop_drop should register its native drop view")
    XCTAssertTrue(dropTarget?.acceptsFirstMouse(for: nil) ?? false)
  }

  func testGlassBackdropPreservesTransparentFlutterAndDropLayer() {
    let flutter = NSApp.windows.compactMap { $0.contentViewController as? FlutterViewController }.first
    XCTAssertNotNil(flutter)
    let glass = flutter?.view.subviews.compactMap { $0 as? NSVisualEffectView }.first
    XCTAssertNotNil(glass)
    XCTAssertEqual(glass?.blendingMode, .behindWindow)
    XCTAssertEqual(glass?.material, .underWindowBackground)
    XCTAssertEqual(flutter?.backgroundColor?.alphaComponent, 0)
    XCTAssertEqual(glass?.isHidden, NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency)
    XCTAssertTrue(flutter?.view.subviews.first === glass)
    XCTAssertNil(glass?.hitTest(.zero), "The backdrop must not consume clicks")
  }

  func testNavigationRegionAcceptsFirstMouseAcrossEntireTabStrip() throws {
    let flutter = try XCTUnwrap(NSApp.windows.compactMap {
      $0.contentViewController as? FlutterViewController
    }.first)
    let root = flutter.view
    // NSView.hitTest takes a point in the superview coordinate system. Check
    // the label and both edges of all three tabs, including inactive clicks.
    for fraction in [0.05, 0.17, 0.30, 0.37, 0.50, 0.63, 0.70, 0.83, 0.95] {
      let point = NSPoint(x: root.bounds.width * fraction, y: root.bounds.height - 20)
      let target = try XCTUnwrap(root.hitTest(root.convert(point, to: root.superview)))
      XCTAssertFalse(target is NSVisualEffectView)
      XCTAssertTrue(target.acceptsFirstMouse(for: nil))
      XCTAssertTrue(target.isDescendant(of: root))
    }
  }

}
