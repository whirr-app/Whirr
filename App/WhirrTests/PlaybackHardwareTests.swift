import SwiftUI
import Testing

@testable import Whirr

/// Covers the scene-phase to playback-cadence wiring `PlaybackHardware` owns. Constructing the real
/// type builds a real `AVQueuePlayer`, so these assert on the engine's declared cadence rather than
/// on an injected fake. The cadence is the observable contract. `AVAudioEngineAdapterTests` covers
/// what each cadence does to the time observer.
@MainActor
@Suite("PlaybackHardware scene-phase cadence")
struct PlaybackHardwareTests {

  private func makeSUT() -> PlaybackHardware {
    PlaybackHardware(remoteCommandCenter: FakeRemoteCommandRegistering())
  }

  @Test("a fresh hardware starts at the foreground cadence")
  func startsAtForegroundCadence() {
    #expect(makeSUT().engine.positionCadence == .foreground)
  }

  @Test("backgrounding drops the engine to the slower position cadence")
  func backgroundingSlowsCadence() {
    let hardware = makeSUT()
    hardware.handleScenePhase(.background)
    #expect(hardware.engine.positionCadence == .background)
  }

  @Test("returning to active restores the foreground cadence")
  func activeRestoresCadence() {
    let hardware = makeSUT()
    hardware.handleScenePhase(.background)
    hardware.handleScenePhase(.active)
    #expect(hardware.engine.positionCadence == .foreground)
  }

  @Test("a launch with no scene at all takes the backgrounded cadence")
  func headlessEntryTakesBackgroundCadence() {
    let hardware = makeSUT()
    hardware.noteHeadlessEntry()
    #expect(
      hardware.engine.positionCadence == .background,
      "a background App Intent can play a whole book without SwiftUI ever installing a window")
  }

  @Test("a scene that has already reported its phase outranks a later headless entry")
  func sceneOutranksHeadlessEntry() {
    let hardware = makeSUT()
    hardware.handleScenePhase(.active)
    hardware.noteHeadlessEntry()
    #expect(
      hardware.engine.positionCadence == .foreground,
      "the same intents are reachable with the app on screen; Siri must not slow a live scrubber")
  }

  @Test("a scene appearing after a headless entry restores the foreground cadence")
  func sceneAfterHeadlessEntryRestoresCadence() {
    let hardware = makeSUT()
    hardware.noteHeadlessEntry()
    hardware.handleScenePhase(.active)
    #expect(hardware.engine.positionCadence == .foreground)
  }

  @Test("inactive carries no cadence change")
  func inactiveIsNotATransition() {
    let hardware = makeSUT()
    hardware.handleScenePhase(.inactive)
    #expect(
      hardware.engine.positionCadence == .foreground,
      "an app-switcher peek or a Control Center pull is not backgrounding")

    hardware.handleScenePhase(.background)
    hardware.handleScenePhase(.inactive)
    #expect(
      hardware.engine.positionCadence == .background,
      "the .inactive iOS posts on the way back up must not pre-empt .active")
  }
}
