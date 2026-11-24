import AdSkip
import Foundation
import Persistence
import Synchronization
import TestSupport
import Testing

@testable import AppModel

/// What an episode card is told about ad skipping before playback: a status for any downloaded
/// episode, which leaves the queue alone, and a signal for every change to it.
@Suite struct AdSkipCoordinatorEpisodeStatusTests {
  typealias Harness = AdSkipCoordinatorTests.Harness
  typealias Tests = AdSkipCoordinatorTests

  private func harness(wholeFiles: Bool = false) async throws -> Harness {
    let harness = try Harness(wholeFiles: wholeFiles)
    await harness.coordinator.setActivitySettle(.zero)
    return harness
  }

  /// Starts analysis of `episodes` without waiting for it to finish.
  private func start(_ harness: Harness, _ episodes: [AdSkipLocalEpisode], allowed: Bool = true) async {
    await harness.coordinator.setLocalEpisodes(episodes)
    await harness.coordinator.setAllowed(allowed)
    await harness.coordinator.setEnabled(true)
  }

  private func status(_ harness: Harness, _ episode: AdSkipLocalEpisode) async -> AdSkipEpisodeStatus {
    await status(harness, episode.identity)
  }

  private func status(_ harness: Harness, _ identity: AdSkipEpisodeIdentity) async -> AdSkipEpisodeStatus {
    await harness.coordinator.episodeStatus(itemID: identity.itemID, episodeID: identity.episodeID)
  }

  private func settle(_ harness: Harness) async {
    #expect(await waitUntil("settled") { await harness.coordinator.hasPendingSettle == false })
  }

  /// The number of breaks a ready status carries, or nil for any other status.
  private func readyBreakCount(_ status: AdSkipEpisodeStatus) -> Int? {
    if case .ready(let breaks) = status { return breaks.count }
    return nil
  }

  /// Set once `stream` yields.
  private func flag(for stream: AsyncStream<Void>) -> Mutex<Bool>.Shared {
    let shared = Mutex<Bool>.Shared()
    Task {
      for await _ in stream {
        shared.mutex.withLock { $0 = true }
        return
      }
    }
    return shared
  }

  private static func range(_ start: Double, _ end: Double, revision: Int = AdSkipRules.revision) -> AdSkipRange {
    AdSkipRange(
      startTime: start, endTime: end, meanAdProbability: 0.9, rulesRevision: revision,
      fromStore: false, endsItem: false)
  }

  // MARK: - Nothing to say

  @Test func anEpisodeThatIsNotDownloadedHasNoStatus() async throws {
    let harness = try await harness()
    let a = harness.episode("a", transcript: Tests.withAd("a"))
    await harness.run([a])
    #expect(await status(harness, Harness.identity("elsewhere")) == .none)
  }

  @Test func thereIsNoStatusWithTheSettingOff() async throws {
    let harness = try await harness()
    let a = harness.episode("a", transcript: Tests.withAd("a"))
    let b = harness.episode("b", transcript: Tests.withAd("b"))
    await harness.run([a, b])
    await settle(harness)
    #expect(readyBreakCount(await status(harness, a)) == 1)

    await harness.coordinator.setEnabled(false)
    #expect(await waitUntil("off") { await status(harness, a) == AdSkipEpisodeStatus.none })
  }

  @Test func thereIsNoStatusBeforeTheConditionsAreKnown() async throws {
    let harness = try await harness()
    let a = harness.episode("a", transcript: Tests.withAd("a"))
    await harness.coordinator.setLocalEpisodes([a])
    await harness.coordinator.setEnabled(true)
    await harness.coordinator.waitUntilIdle()
    await settle(harness)
    #expect(await status(harness, a) == .none)
  }

  @Test func aShowInALanguageAnalysisDoesNotCoverHasNoStatus() async throws {
    let harness = try await harness()
    let a = harness.episode("a", transcript: Tests.withAd("a"), language: "de")
    await harness.run([a])
    await settle(harness)
    #expect(await status(harness, a) == .none)
  }

  @Test func aFileThatCannotBeReadHasNoStatus() async throws {
    let harness = try await harness()
    let a = harness.episode("a", transcript: Tests.withAd("a"))
    harness.fingerprints.values.withLock { $0[a.fileURL] = nil }
    await harness.run([a])
    await settle(harness)
    #expect(await status(harness, a) == .none)
  }

  // MARK: - Settled rows

  @Test func anEpisodeAnalysisGaveUpOnHasFailed() async throws {
    let harness = try await harness()
    let a = harness.episode("a")
    harness.audio.fail(a.fileURL, Tests.Unexpected())
    await harness.run([a])
    await settle(harness)
    #expect(await status(harness, a) == .failed)
  }

  @Test func aFailureUnderAnOlderTranscriberIsStillToBeChecked() async throws {
    let first = try await harness()
    let a = first.episode("a")
    first.audio.fail(a.fileURL, Tests.Unexpected())
    await first.run([a])

    let upgraded = try Harness(transcriberRevision: "t2", reusing: first)
    await upgraded.coordinator.setActivitySettle(.zero)
    await upgraded.run([a], allowed: false)
    #expect(await waitUntil("waiting") { await status(upgraded, a) == .waiting(.conditions) })
  }

  @Test func anAnalysedEpisodeCountsItsAdBreaks() async throws {
    let harness = try await harness()
    let a = harness.episode("a", transcript: Tests.withAd("a"))
    let b = harness.episode("b", transcript: Tests.withAd("b"))
    await harness.run([a, b])
    await settle(harness)
    #expect(readyBreakCount(await status(harness, a)) == 1)
    #expect(readyBreakCount(await status(harness, b)) == 1)
  }

  @Test func anAnalysedEpisodeWithNoAdsIsReadyWithNone() async throws {
    let harness = try await harness()
    let a = harness.episode("a", transcript: Tests.transcript(Tests.programme("a")))
    let b = harness.episode("b", transcript: Tests.transcript(Tests.programme("b")))
    await harness.run([a, b])
    await settle(harness)
    #expect(try await harness.episodes.episode(for: a.identity)?.state == .analysed)
    #expect(readyBreakCount(await status(harness, a)) == 0)
  }

  @Test func aChangedFileIsNotReady() async throws {
    let harness = try await harness()
    let a = harness.episode("a", transcript: Tests.withAd("a"))
    let b = harness.episode("b", transcript: Tests.withAd("b"))
    await harness.run([a, b])
    await settle(harness)

    harness.fingerprints.set(b.fileURL, size: 77_777)
    #expect(await status(harness, b) == .queued)
  }

  // MARK: - In the queue

  @Test func theEpisodeUnderAnalysisIsCheckingAndTheRestAreQueued() async throws {
    let harness = try await harness(wholeFiles: true)
    let a = harness.episode("a", transcript: Tests.withAd("a"))
    let b = harness.episode("b", transcript: Tests.withAd("b"))
    harness.audio.hold(a.fileURL)
    await start(harness, [a, b])
    #expect(await waitUntil("a's decode is held") { harness.audio.holding })
    #expect(await waitUntil("a is checking") { await status(harness, a) == .checking })
    #expect(await status(harness, b) == .queued)

    harness.audio.release()
    await harness.coordinator.waitUntilIdle()
  }

  @Test func thePriorityEpisodeIsCheckingBeforeItsUnitStarts() async throws {
    let harness = try await harness()
    let a = harness.episode("a", transcript: Tests.withAd("a"))
    let b = harness.episode("b", transcript: Tests.withAd("b"))
    harness.audio.hold(a.fileURL)
    await start(harness, [a, b])
    #expect(await waitUntil("a's decode is held") { harness.audio.holding })
    #expect(await waitUntil("b is queued") { await status(harness, b) == .queued })

    // Loaded in the player while another episode's unit finishes: b is next.
    await harness.coordinator.prioritize(b.identity)
    #expect(await waitUntil("b is checking") { await status(harness, b) == .checking })

    harness.audio.release()
    await harness.coordinator.waitUntilIdle()
  }

  @Test func everyEpisodeWaitsWhileAnalysisIsHeld() async throws {
    let harness = try await harness()
    let a = harness.episode("a", transcript: Tests.withAd("a"))
    await harness.run([a], allowed: false)
    #expect(await waitUntil("waiting") { await status(harness, a) == .waiting(.conditions) })
  }

  @Test func everyEpisodeWaitsForTheSpeechModel() async throws {
    let harness = try await harness(wholeFiles: true)
    let a = harness.episode("a")
    harness.transcriber.set(a.fileURL, .failure(AdSkipAnalysisDeferred()))
    await harness.run([a])
    #expect(await waitUntil("waiting") { await status(harness, a) == .waiting(.speechModel) })
  }

  @Test func checkNowShowsOnlyItsEpisodeAsChecking() async throws {
    let harness = try await harness(wholeFiles: true)
    let a = harness.episode("a", transcript: Tests.withAd("a"))
    let b = harness.episode("b", transcript: Tests.withAd("b"))
    await harness.coordinator.setPriorityConditionsAllowed(true)
    await harness.run([a, b], allowed: false)
    harness.audio.hold(a.fileURL)

    await harness.coordinator.checkNow(for: Tests.request(a))
    #expect(await waitUntil("a's decode is held") { harness.audio.holding })
    #expect(await waitUntil("a is checking") { await status(harness, a) == .checking })
    #expect(await status(harness, b) == .waiting(.conditions))
    harness.audio.release()
    await harness.coordinator.waitUntilIdle()
  }

  // MARK: - Which episode

  @Test func askingNeverChangesThePriority() async throws {
    let harness = try await harness()
    let a = harness.episode("a", transcript: Tests.withAd("a"))
    let b = harness.episode("b", transcript: Tests.withAd("b"))
    await harness.coordinator.prioritize(a.identity)
    await harness.run([a, b], allowed: false)

    _ = await status(harness, b)
    #expect(await harness.coordinator.priority == a.identity)
    await harness.coordinator.waitUntilIdle()
    #expect(harness.audio.calls.withLock { $0 }.isEmpty)
  }

  @Test func anRSSDownloadAnswersForItsServerCopy() async throws {
    let harness = try await harness()
    let server = Harness.identity("x", source: .abs)
    let a = harness.episode("a", transcript: Tests.withAd("a"), linked: [server])
    let b = harness.episode("b", transcript: Tests.withAd("b"))
    await harness.run([a, b])
    await settle(harness)
    #expect(readyBreakCount(await status(harness, server)) == 1)
  }

  @Test func ofTwoAccountsCopiesTheLessSettledAnswers() async throws {
    let harness = try await harness()
    let mine = harness.episode("a", transcript: Tests.withAd("a"), source: .abs)
    let b = harness.episode("b", transcript: Tests.withAd("b"), source: .abs)
    // Another account's download of the same server episode: its own file and its own row.
    var identity = mine.identity
    identity.accountId = 8
    let theirs = AdSkipLocalEpisode(
      identity: identity, fileURL: harness.root.appendingPathComponent("audio/other-a.mp3"),
      languageTag: nil, showTitle: nil, linkedIdentities: [])
    harness.fingerprints.set(theirs.fileURL, size: 4_242)
    harness.audio.fail(theirs.fileURL, Tests.Unexpected())
    await harness.run([mine, b, theirs])
    await settle(harness)

    #expect(try await harness.episodes.episode(for: mine.identity)?.state == .analysed)
    #expect(try await harness.episodes.episode(for: theirs.identity)?.state == .failed)
    #expect(await status(harness, mine) == .failed)
  }

  // MARK: - The break count

  @Test func rangesThePlayerJoinsAreOneBreak() {
    #expect(AdSkipCoordinator.breakCount(of: []) == 0)
    #expect(AdSkipCoordinator.breakCount(of: [Self.range(30, 50)]) == 1)
    #expect(AdSkipCoordinator.breakCount(of: [Self.range(30, 50), Self.range(59, 80)]) == 1)
    #expect(AdSkipCoordinator.breakCount(of: [Self.range(30, 50), Self.range(59.5, 80)]) == 2)
    // An ad, the fill after it and the next ad meet end to start.
    #expect(
      AdSkipCoordinator.breakCount(of: [Self.range(90, 120), Self.range(30, 50), Self.range(50, 90)]) == 1)
    // A long range holding a short one still reaches as far as its own end.
    #expect(
      AdSkipCoordinator.breakCount(of: [Self.range(0, 100), Self.range(10, 20), Self.range(105, 130)]) == 1)
  }

  @Test func rangesPlaybackIsNotServedAreNotCounted() {
    let unserved = (0...AdSkipRules.revision).first { AdSkipRules.servedRevisions.contains($0) == false }
    guard let unserved else { return }
    #expect(
      AdSkipCoordinator.breakCount(of: [Self.range(30, 50), Self.range(200, 230, revision: unserved)]) == 1)
  }

  @Test func twoAdsAndTheFillBetweenThemAreOneBreak() async throws {
    let harness = try await harness()
    let library = Tests().breakLibrary(harness)
    await harness.run(library)
    await settle(harness)
    #expect(try await harness.ranges("a").count == 3)
    #expect(readyBreakCount(await status(harness, library[0])) == 1)
  }

  // MARK: - Signals

  @Test func aFinishedDownloadSignals() async throws {
    let harness = try await harness()
    let a = harness.episode("a", transcript: Tests.withAd("a"))
    await harness.run([a], allowed: false)
    await settle(harness)
    // Nothing settles from here on, so only the local set's own signal can arrive.
    await harness.coordinator.setActivitySettle(.seconds(60))
    let signalled = flag(for: harness.coordinator.episodeStatusChanges())

    await harness.coordinator.setLocalEpisodes([a, harness.episode("b", transcript: Tests.withAd("b"))])
    #expect(await waitUntil("signalled") { signalled.value })
  }

  @Test func aHoldSignals() async throws {
    let harness = try await harness()
    let a = harness.episode("a", transcript: Tests.withAd("a"))
    let b = harness.episode("b", transcript: Tests.withAd("b"))
    await harness.run([a, b])
    await settle(harness)
    let signalled = flag(for: harness.coordinator.episodeStatusChanges())

    await harness.coordinator.setAllowed(false)
    #expect(await waitUntil("signalled") { signalled.value })
  }

  @Test func aFailureSignalsThoughNothingSettles() async throws {
    let harness = try await harness()
    let a = harness.episode("a")
    harness.audio.fail(a.fileURL, Tests.Unexpected())
    await harness.run([a], allowed: false)
    await settle(harness)
    // A unit shorter than the settle changes no settled state, as a quick failure does not.
    await harness.coordinator.setActivitySettle(.seconds(60))
    let signalled = flag(for: harness.coordinator.episodeStatusChanges())

    await harness.coordinator.setAllowed(true)
    await harness.coordinator.waitUntilIdle()
    #expect(await status(harness, a) == .failed)
    #expect(await waitUntil("signalled") { signalled.value })
  }

  @Test func anUnreadableFileSignalsThoughNothingSettles() async throws {
    let harness = try await harness()
    let a = harness.episode("a", transcript: Tests.withAd("a"))
    await harness.run([a], allowed: false)
    await settle(harness)
    await harness.coordinator.setActivitySettle(.seconds(60))
    let signalled = flag(for: harness.coordinator.episodeStatusChanges())

    harness.fingerprints.values.withLock { $0[a.fileURL] = nil }
    await harness.coordinator.setAllowed(true)
    await harness.coordinator.waitUntilIdle()
    #expect(await status(harness, a) == .none)
    #expect(await waitUntil("signalled") { signalled.value })
  }
}

extension Mutex where Value == Bool {
  /// A flag a detached task can set and a test can read.
  final class Shared: Sendable {
    let mutex = Mutex<Bool>(false)
    var value: Bool { mutex.withLock { $0 } }
  }
}
