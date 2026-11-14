// VerificationShot.swift: the offscreen camera a native app's verification screenshots are taken with
// (claude-config#2696, #2950). Test code only: copy this file unchanged into the app's test target, and
// add one test that hands it the app's frame list:
//
//     final class VerificationScreens: XCTestCase {
//       @MainActor func testShot() throws {
//         try VerificationShot.shoot([
//           "invoice-list": { VerificationShot.Frame(rows: seed.invoices.count) { InvoiceList(seed) } },
//         ])
//       }
//     }
//
// The verification skill's shoot_native.py runs that test through the project's commands.native_shot
// with VERIFICATION_SHOT_* naming one frame, and keeps the picture only when the test passed, wrote a
// PNG the asked width, and reported at least the asked rows. An ordinary test run names no frame, and
// the test skips. Its fixture suite is scripts/test-shoot-native-swift.sh, which builds this file in a
// SwiftPM package and shoots it for real.
//
// Adapted from Ovation's OffscreenShot.swift, and it keeps that camera's measured choices:
//
// NEVER ORDERED FRONT, AND NO APP ACTIVATED. The window is ordered BACK at a position far outside every
// display: a window never ordered in does not draw its layer backed subviews, and one ordered front
// would take the front window from whoever is using the Mac.
//
// THE THEME IS THE WINDOW'S, not only SwiftUI's. Materials and the standard control colours come from
// the window's appearance, so a light shot asked for on a dark Mac drew dark chrome under light text.
//
// NOT RELEASED ON CLOSE. A window made in code releases itself on close, a second release under ARC;
// the test process then died at teardown, which xcodebuild reports as a run of zero tests that passes.
//
// THE SURFACE AT ITS OWN WIDTH over a window coloured backdrop, and at least the asked height: a frame
// drawing more rows than fit grows taller, as the web shot captures the whole page.
import AppKit
import SwiftUI
import XCTest

@MainActor
enum VerificationShot {

  /// One frame of the app's frame list: what to draw, and how many rows of its population it drew.
  /// The count is the app's to state from the seed it drew, and the run refuses a picture short of it.
  struct Frame {
    let view: AnyView
    let rows: Int

    init(rows: Int = 0, @ViewBuilder _ content: () -> some View) {
      self.view = AnyView(content())
      self.rows = rows
    }
  }

  /// What the run asked for, read from the environment shoot_native.py set.
  struct Request: Equatable {
    let frame: String
    let width: Int
    let height: Int
    let dark: Bool
    let file: URL
    let rowsFile: URL
  }

  enum Failure: Error, CustomStringConvertible {
    case missing(String)
    case notAPositiveWholeNumber(String, String)
    case notATheme(String)
    case unknownFrame(String, known: [String])
    case nothingToDraw
    case couldNotEncode

    var description: String {
      switch self {
      case .missing(let name):
        return "VerificationShot: \(name) is unset or empty, and a shot needs it"
      case .notAPositiveWholeNumber(let name, let value):
        return "VerificationShot: \(name) is \"\(value)\", which is not a whole number of points above 0"
      case .notATheme(let value):
        return "VerificationShot: VERIFICATION_SHOT_THEME is \"\(value)\", which is neither light nor dark"
      case .unknownFrame(let frame, let known):
        return "VerificationShot: this test has no frame \"\(frame)\"; its frames are \(known.joined(separator: ", "))"
      case .nothingToDraw:
        return "VerificationShot: the window's content view could not be cached, so nothing was drawn"
      case .couldNotEncode:
        return "VerificationShot: the drawing could not be encoded as a PNG"
      }
    }
  }

  static let prefix = "VERIFICATION_SHOT_"

  /// The request in `env`, or nil when it names no frame (an ordinary test run). Each name is read
  /// bare, then with xcodebuild's TEST_RUNNER_ prefix, since shoot_native.py sets both.
  static func request(from env: [String: String]) throws -> Request? {
    func value(_ key: String) -> String? {
      let found = env[prefix + key] ?? env["TEST_RUNNER_" + prefix + key]
      return found?.isEmpty == false ? found : nil
    }
    func required(_ key: String) throws -> String {
      guard let found = value(key) else { throw Failure.missing(prefix + key) }
      return found
    }
    func points(_ key: String) throws -> Int {
      let text = try required(key)
      guard text.allSatisfy({ $0.isASCII && $0.isNumber }), let n = Int(text), n > 0 else {
        throw Failure.notAPositiveWholeNumber(prefix + key, text)
      }
      return n
    }
    guard let frame = value("FRAME") else { return nil }
    let theme = try required("THEME")
    guard theme == "light" || theme == "dark" else { throw Failure.notATheme(theme) }
    return Request(frame: frame, width: try points("WIDTH"), height: try points("HEIGHT"), dark: theme == "dark",
                   file: URL(fileURLWithPath: try required("FILE")),
                   rowsFile: URL(fileURLWithPath: try required("ROWS_FILE")))
  }

  /// Draws the frame the run named, writes its PNG and its row count, and FAILS on a frame `frames`
  /// does not hold, since a test that passed without drawing would read as a shot taken. With no
  /// frame named it skips, so the app's ordinary test run is untouched.
  static func shoot(_ frames: [String: () -> Frame],
                    env: [String: String] = ProcessInfo.processInfo.environment) throws {
    guard let request = try request(from: env) else {
      throw XCTSkip("no verification shot was asked for (VERIFICATION_SHOT_FRAME is unset)")
    }
    guard let make = frames[request.frame] else {
      throw Failure.unknownFrame(request.frame, known: frames.keys.sorted())
    }
    let frame = make()
    try capture(frame.view, width: request.width, height: request.height, dark: request.dark, to: request.file)
    try Data("\(frame.rows)\n".utf8).write(to: request.rowsFile, options: .atomic)
  }

  /// Hosts `view` in an offscreen window `width` points wide, at least `height` high, and writes what
  /// it drew as a PNG at the Mac's backing scale.
  static func capture(_ view: some View, width: Int, height: Int, dark: Bool, to url: URL) throws {
    if NSApp == nil {
      // A test process with no app of its own (swift test) gets one that never shows in the Dock and is
      // never activated. A hosted test keeps its host app's policy untouched.
      NSApplication.shared.setActivationPolicy(.accessory)
    }
    let framed = ZStack(alignment: .top) {
      Color(nsColor: .windowBackgroundColor)
      view
    }
    .frame(width: CGFloat(width))
    .frame(minHeight: CGFloat(height), alignment: .top)

    let host = NSHostingView(rootView: framed)
    let fitted = host.fittingSize
    let size = NSSize(width: CGFloat(width), height: max(CGFloat(height), fitted.height))
    let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                          styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    window.contentView = host
    window.setFrameOrigin(NSPoint(x: -30_000, y: -30_000))
    window.orderBack(nil)
    defer { window.close() }
    window.layoutIfNeeded()
    window.displayIfNeeded()
    // A fixed 0.2 second turn of the run loop, as Ovation's camera has, so a view that lays itself out
    // asynchronously on the main run loop gets the chance to. It waits on no condition: a view that
    // settles later than this is drawn unsettled, and the pixel checks are what would show it.
    RunLoop.current.run(until: Date().addingTimeInterval(0.2))

    guard let content = window.contentView,
          let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) else {
      throw Failure.nothingToDraw
    }
    content.cacheDisplay(in: content.bounds, to: bitmap)
    guard let data = bitmap.representation(using: .png, properties: [:]) else {
      throw Failure.couldNotEncode
    }
    try data.write(to: url, options: .atomic)
  }
}
