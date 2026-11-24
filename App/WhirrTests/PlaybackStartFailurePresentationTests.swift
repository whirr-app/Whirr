import AppModel
import Testing

@testable import Whirr

@Suite("Playback start failure presentation")
struct PlaybackStartFailurePresentationTests {
  @Test("no start failure presents no surface")
  func noStartFailurePresentsNoSurface() {
    #expect(PlaybackStartFailurePresentation.surfaces(for: nil).isEmpty)
  }

  @Test("one refused start presents exactly one shared alert")
  func oneRefusedStartPresentsExactlyOneSharedAlert() {
    let surfaces = PlaybackStartFailurePresentation.surfaces(
      for: PlaybackStartFailure(message: PlaybackCopy.genericStartFailure, origin: .requested))

    #expect(surfaces == [.sharedAlert])
    #expect(surfaces.count == 1)
  }

  /// The automatic continuation after a title finishes runs with nobody necessarily looking. Its
  /// `.recoverableError` phase already explains itself on the player; a modal on top of that would
  /// interrupt a listener who asked for nothing.
  @Test("a failed queue advance presents no modal")
  func failedQueueAdvancePresentsNoModal() {
    let failure = PlaybackStartFailure(
      message: PlaybackCopy.genericStartFailure, origin: .queueAdvance)

    #expect(PlaybackStartFailurePresentation.surfaces(for: failure).isEmpty)
    #expect(PlaybackStartFailurePresentation.isAlertPresented(for: failure) == false)
  }

  /// A smart list's automatic advance is as unattended as a queue advance (ADR 0016).
  @Test("a failed list advance presents no modal")
  func failedListAdvancePresentsNoModal() {
    let failure = PlaybackStartFailure(
      message: PlaybackCopy.genericStartFailure, origin: .listAdvance)

    #expect(PlaybackStartFailurePresentation.surfaces(for: failure).isEmpty)
    #expect(PlaybackStartFailurePresentation.isAlertPresented(for: failure) == false)
    #expect(PlaybackStartFailurePresentation.message(for: failure) == "")
  }

  /// The alert's message is read whether or not it is presented, so a suppressed failure must not
  /// leave its words behind for the next presentation to inherit.
  @Test("a suppressed failure contributes no alert message")
  func suppressedFailureContributesNoMessage() {
    let queueAdvance = PlaybackStartFailure(message: "Queue advance failed", origin: .queueAdvance)
    let requested = PlaybackStartFailure(message: "Requested start failed", origin: .requested)

    #expect(PlaybackStartFailurePresentation.message(for: queueAdvance) == "")
    #expect(PlaybackStartFailurePresentation.message(for: requested) == "Requested start failed")
  }
}
