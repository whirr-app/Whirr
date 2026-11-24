import Foundation
import PlayerCore
import SyncEngine
import TestSupport
import Testing

@testable import AppModel

/// The phone shows "Playing on Apple Watch" for the title the Watch last reported playing,
/// until the report expires 3 minutes after the Watch made it.
@Suite struct CompanionDevicePlaybackTests {
  private let observed = Date(timeIntervalSince1970: 1_000_000)

  @Test func aReportIsCurrentForThreeMinutes() {
    let report = CompanionDevicePlayback(itemID: "book-1", episodeID: nil, observedAt: observed)
    #expect(report.isCurrent(at: observed))
    #expect(report.isCurrent(at: observed.addingTimeInterval(179)))
    #expect(!report.isCurrent(at: observed.addingTimeInterval(180)))
    #expect(report.expiresAt == observed.addingTimeInterval(180))
  }

  /// The Watch's clock may run a little ahead of the phone's; a report from further ahead than
  /// the command skew allowance is not believed.
  @Test func aReportFromTooFarAheadIsNotCurrent() {
    let report = CompanionDevicePlayback(itemID: "book-1", episodeID: nil, observedAt: observed)
    #expect(report.isCurrent(at: observed.addingTimeInterval(-30)))
    #expect(!report.isCurrent(at: observed.addingTimeInterval(-31)))
  }

  @Test func itNamesOnlyItsOwnTitle() {
    let book = CompanionDevicePlayback(itemID: "book-1", episodeID: nil, observedAt: observed)
    #expect(book.isPlaying(itemID: "book-1", episodeID: nil))
    #expect(!book.isPlaying(itemID: "book-2", episodeID: nil))
    #expect(!book.isPlaying(itemID: "book-1", episodeID: "episode"))
    let episode = CompanionDevicePlayback(itemID: "show", episodeID: "episode-1", observedAt: observed)
    #expect(episode.isPlaying(itemID: "show", episodeID: "episode-1"))
    #expect(!episode.isPlaying(itemID: "show", episodeID: "episode-2"))
  }
}

/// The model holds the report, drops a stale one at once, and clears a held one at its expiry so
/// the views re-render without a timer of their own.
@MainActor
@Suite(.timeLimit(.minutes(1))) struct CompanionDevicePlaybackModelTests {
  private let now = Date(timeIntervalSince1970: 1_000_000)

  @Test func aCurrentReportIsHeldAndAStaleOneIsNot() {
    let (model, _) = makeModel()
    let report = CompanionDevicePlayback(itemID: "book-1", episodeID: nil, observedAt: now)
    model.setCompanionDevicePlayback(report, now: now)
    #expect(model.companionDevicePlayback == report)
    #expect(model.isPlayingOnCompanion(itemID: "book-1", episodeID: nil))
    #expect(!model.isPlayingOnCompanion(itemID: "book-2", episodeID: nil))

    let stale = CompanionDevicePlayback(itemID: "book-1", episodeID: nil, observedAt: now.addingTimeInterval(-180))
    model.setCompanionDevicePlayback(stale, now: now)
    #expect(model.companionDevicePlayback == nil)

    model.setCompanionDevicePlayback(report, now: now)
    model.setCompanionDevicePlayback(nil, now: now)
    #expect(model.companionDevicePlayback == nil)
  }

  @Test func aHeldReportIsClearedAtItsExpiry() async {
    let (model, waits) = makeModel()
    let report = CompanionDevicePlayback(itemID: "book-1", episodeID: nil, observedAt: now.addingTimeInterval(-60))
    model.setCompanionDevicePlayback(report, now: now)
    let wait = await waits.next()
    #expect(wait.seconds == 120)
    wait.finish()
    await model.companionExpiryTask?.value
    #expect(model.companionDevicePlayback == nil)
  }

  /// A newer report replaces the held one; the replaced report's expiry must not clear it.
  @Test func aReplacedReportsExpiryLeavesTheNewerOne() async {
    let (model, waits) = makeModel()
    let first = CompanionDevicePlayback(itemID: "book-1", episodeID: nil, observedAt: now)
    model.setCompanionDevicePlayback(first, now: now)
    let firstWait = await waits.next()
    let firstTask = model.companionExpiryTask

    let second = CompanionDevicePlayback(itemID: "book-2", episodeID: nil, observedAt: now.addingTimeInterval(10))
    model.setCompanionDevicePlayback(second, now: now.addingTimeInterval(10))
    let secondWait = await waits.next()
    firstWait.finish()
    await firstTask?.value
    #expect(model.companionDevicePlayback == second)
    secondWait.finish()
  }

  private func makeModel() -> (PlaybackModel, ExpiryWaits) {
    let model = PlaybackModelHarness().model
    let waits = ExpiryWaits()
    model.companionExpiryWait = { seconds in await waits.park(seconds) }
    return (model, waits)
  }
}

/// Parks each expiry wait until the test releases it, so expiry needs no real time.
@MainActor
private final class ExpiryWaits {
  struct Wait: Sendable {
    let seconds: TimeInterval
    let finish: @Sendable () -> Void
  }

  private let started = CallRecorder<Wait>(label: "ExpiryWaits expiry waits")
  private var taken = 0

  func park(_ seconds: TimeInterval) async {
    // An expiry wait runs to completion regardless of cancellation, so a cancelled one stays
    // parked until the test finishes it.
    let gate = TestGate<Void>(label: "ExpiryWaits expiry wait", ignoresCancellation: true)
    gate.hold()
    started.record(Wait(seconds: seconds, finish: { gate.release() }))
    await gate.pass()
  }

  func next() async -> Wait {
    let index = taken
    taken += 1
    await started.waitUntil(count: index + 1)
    let waits = started.calls
    return waits.indices.contains(index) ? waits[index] : Wait(seconds: 0, finish: {})
  }
}
