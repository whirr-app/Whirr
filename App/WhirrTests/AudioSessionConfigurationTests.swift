import AVFoundation
import Testing

@testable import Whirr

/// Covers `AudioSessionConfigurator` over an injected `AudioSessionControlling` fake. It never
/// touches the real, process-wide shared `AVAudioSession`.
@MainActor
@Suite("AudioSessionConfigurator")
struct AudioSessionConfigurationTests {

  @Test("activating for playback sets .playback category with .spokenAudio mode, then activates")
  func activationConfiguresPlaybackSpokenAudioThenActivates() {
    let fake = FakeAudioSessionControlling()
    let configurator = AudioSessionConfigurator(session: fake)
    var outcome: AudioSessionActivationOutcome?

    configurator.activateForPlayback { outcome = $0 }

    #expect(fake.setCategoryCalls.count == 1)
    #expect(fake.setCategoryCalls[0].category == .playback)
    #expect(fake.setCategoryCalls[0].mode == .spokenAudio)
    #expect(fake.setActiveCalls.count == 1)
    #expect(fake.setActiveCalls[0].active == true)
    #expect(outcome != nil)
    #expect(outcome?.configureError == nil)
    #expect(outcome?.activateError == nil)
  }

  @Test("activation never selects a recording-capable category - no recording permission is ever requested")
  func activationNeverRequestsRecordingCategory() {
    let fake = FakeAudioSessionControlling()
    let configurator = AudioSessionConfigurator(session: fake)

    configurator.activateForPlayback { _ in }

    #expect(fake.setCategoryCalls[0].category != .record)
    #expect(fake.setCategoryCalls[0].category != .playAndRecord)
  }

  @Test("deactivate sets the session inactive and notifies other audio")
  func deactivateSetsInactiveAndNotifiesOthers() {
    let fake = FakeAudioSessionControlling()
    let configurator = AudioSessionConfigurator(session: fake)
    var completed = false

    configurator.deactivate { error in
      completed = true
      #expect(error == nil)
    }

    #expect(completed)
    #expect(fake.setActiveCalls.count == 1)
    #expect(fake.setActiveCalls[0].active == false)
    #expect(fake.setActiveCalls[0].options == .notifyOthersOnDeactivation)
  }

  @Test("a session error is reported per stage rather than being swallowed")
  func sessionErrorsAreReported() {
    let fake = FakeAudioSessionControlling()
    fake.shouldThrow = true
    let configurator = AudioSessionConfigurator(session: fake)
    var outcome: AudioSessionActivationOutcome?
    var deactivationError: (any Error)?

    configurator.activateForPlayback { outcome = $0 }
    configurator.deactivate { deactivationError = $0 }

    #expect(outcome?.configureError != nil)
    #expect(outcome?.activateError != nil)
    #expect(deactivationError != nil)
  }

  @Test("the production runner keeps the session's blocking calls off the main thread")
  func backgroundWorkRunsOffMainAndCompletesOnMain() async {
    let fake = FakeAudioSessionControlling()
    let configurator = AudioSessionConfigurator(session: fake, work: BackgroundAudioSessionWork())

    await withCheckedContinuation { continuation in
      configurator.activateForPlayback { _ in
        #expect(Thread.isMainThread)
        continuation.resume()
      }
    }

    #expect(fake.setActiveCalls.count == 1)
    #expect(fake.mainThreadCallCount == 0)
  }

  @Test("the production runner applies a deactivation after the activation requested before it")
  func backgroundWorkKeepsRequestOrder() async {
    let fake = FakeAudioSessionControlling()
    let configurator = AudioSessionConfigurator(session: fake, work: BackgroundAudioSessionWork())

    await withCheckedContinuation { continuation in
      configurator.activateForPlayback { _ in }
      configurator.deactivate { _ in continuation.resume() }
    }

    #expect(fake.setActiveCalls.map(\.active) == [true, false])
  }
}
