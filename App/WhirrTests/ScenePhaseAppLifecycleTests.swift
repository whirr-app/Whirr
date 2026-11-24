import SwiftUI
import SyncEngine
import Testing

@testable import Whirr

/// `RootView` seeds the scene phase into every freshly composed environment, since
/// `.onChange(of: scenePhase)` never fires for the initial value. Pins the two properties seeding
/// relies on: one `.active` reports foreground, and re-seeding a held phase emits nothing, so it
/// cannot reset a subscriber's per-foreground-session state. Background-task override, multicast
/// and no-replay are in `ScenePhaseAppLifecycleBackgroundTaskTests`.
@Suite("ScenePhaseAppLifecycle foreground seeding")
struct ScenePhaseAppLifecycleTests {

  @Test("a single active phase reports foreground and emits one transition")
  func firstActivePhaseReportsForegroundAndEmitsOneTransition() async {
    let lifecycle = ScenePhaseAppLifecycle(
      backgroundTaskProviding: FakeBackgroundTaskProviding())
    var iterator = lifecycle.transitions.makeAsyncIterator()

    lifecycle.handle(scenePhase: .active)

    #expect(lifecycle.isForeground)
    #expect(await iterator.next() == .foreground)
  }

  @Test("a repeated active phase emits no second foreground transition")
  func repeatedActivePhaseEmitsNoDuplicateForegroundTransition() async {
    let lifecycle = ScenePhaseAppLifecycle(
      backgroundTaskProviding: FakeBackgroundTaskProviding())
    var iterator = lifecycle.transitions.makeAsyncIterator()

    lifecycle.handle(scenePhase: .active)
    #expect(await iterator.next() == .foreground)

    // Seeding a phase the adapter already holds must not re-emit `.foreground`. A duplicate would
    // reset per-foreground-session budgets in downstream subscribers mid-session. Asserting that
    // the next value is the new edge shows nothing was interleaved, without racing a timeout for
    // an event that should never arrive.
    lifecycle.handle(scenePhase: .active)
    lifecycle.handle(scenePhase: .background)

    #expect(await iterator.next() == .background)
  }

  @Test("seeding an inactive phase never claims foreground")
  func inactivePhaseNeverClaimsForeground() {
    let lifecycle = ScenePhaseAppLifecycle(
      backgroundTaskProviding: FakeBackgroundTaskProviding())

    lifecycle.handle(scenePhase: .inactive)

    #expect(lifecycle.isForeground == false)
  }
}
