import Testing

@testable import Whirr

/// Both background wake routes resolve to one adapter. `WhirrApp.body`'s
/// `.backgroundTask(.urlSession(...))` and `BackgroundDownloadAppDelegate` both read the
/// `BackgroundDownloadHardware.adapter` static, so neither builds its own. Both routes are wired
/// because the SwiftUI-only wake route's reliability is uncertain.
@Suite("Background download composition")
struct BackgroundDownloadCompositionTests {

  @Test("both wake routes resolve to the one shared adapter instance")
  func bothWakeRoutesReachSameAdapterInstance() {
    let firstDelegate = BackgroundDownloadAppDelegate()
    let secondDelegate = BackgroundDownloadAppDelegate()

    #expect(ObjectIdentifier(firstDelegate.adapter) == ObjectIdentifier(BackgroundDownloadHardware.adapter))
    #expect(ObjectIdentifier(secondDelegate.adapter) == ObjectIdentifier(BackgroundDownloadHardware.adapter))
    #expect(firstDelegate.adapter.sessionIdentifier == BackgroundDownloadHardware.sessionIdentifier)
  }
}
