import TestSupport
import Testing

@testable import SyncEngine

/// The pure half of the `ScenePhase` to `AppLifecycle` adapter (ARCHITECTURE.md). The concrete
/// adapter that owns the `AsyncStream` continuation and imports SwiftUI lives in the App target.
/// This is only the decision table, kept here so it stays testable on the macOS host without
/// SwiftUI.
@Suite("ScenePhase → AppLifecycleTransition mapping", .timeLimit(.minutes(1)))
struct ScenePhaseLifecycleMappingTests {

  @Test("entering active from nil (launch) or from background/inactive emits foreground")
  func enteringActiveEmitsForeground() {
    #expect(ScenePhaseLifecycleMapper.transition(from: nil, to: .active) == .foreground)
    #expect(ScenePhaseLifecycleMapper.transition(from: .background, to: .active) == .foreground)
    #expect(ScenePhaseLifecycleMapper.transition(from: .inactive, to: .active) == .foreground)
  }

  @Test("entering background from active or inactive emits background")
  func enteringBackgroundEmitsBackground() {
    #expect(ScenePhaseLifecycleMapper.transition(from: .active, to: .background) == .background)
    #expect(ScenePhaseLifecycleMapper.transition(from: .inactive, to: .background) == .background)
    #expect(ScenePhaseLifecycleMapper.transition(from: nil, to: .background) == .background)
  }

  @Test("inactive never itself emits a transition")
  func inactiveNeverEmits() {
    #expect(ScenePhaseLifecycleMapper.transition(from: .active, to: .inactive) == nil)
    #expect(ScenePhaseLifecycleMapper.transition(from: .background, to: .inactive) == nil)
    #expect(ScenePhaseLifecycleMapper.transition(from: nil, to: .inactive) == nil)
  }

  @Test("a repeated identical phase never repeats the same transition")
  func repeatedPhaseIsANoOp() {
    #expect(ScenePhaseLifecycleMapper.transition(from: .active, to: .active) == nil)
    #expect(ScenePhaseLifecycleMapper.transition(from: .background, to: .background) == nil)
  }

  @Test("the shared lifecycle fake delivers each edge to every subscriber")
  func fakeLifecycleMulticasts() async {
    let lifecycle = FakeAppLifecycle()
    var first = lifecycle.transitions.makeAsyncIterator()
    var second = lifecycle.transitions.makeAsyncIterator()

    lifecycle.simulateForeground()
    lifecycle.simulateBackground()

    #expect(await first.next() == .foreground)
    #expect(await second.next() == .foreground)
  }
}
