import AdSkip
import Foundation
import Persistence
import TestSupport
import Testing

@testable import AppModel

/// What the tiles and the player are told about analysis while it happens
/// Covers the episode under analysis, the loaded episode's status, the priority episode that
/// needs no transcription, and Check Now.
@Suite struct AdSkipCoordinatorActivityTests {
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

  private func activityIncludes(_ harness: Harness, _ episode: AdSkipLocalEpisode) async -> Bool {
    await harness.coordinator.analysisActivity?.includes(
      itemID: episode.identity.itemID, episodeID: episode.identity.episodeID) == true
  }

  private func status(_ harness: Harness, _ episode: AdSkipLocalEpisode) async -> PlaybackAdAnalysisStatus {
    await harness.coordinator.analysisStatus(for: Tests.request(episode))
  }

  // MARK: - The episode under analysis

  @Test func theEpisodeBeingTranscribedIsTheActivityUntilTheWorkerIsIdle() async throws {
    let harness = try await harness(wholeFiles: true)
    let a = harness.episode("a", transcript: Tests.withAd("a"))
    harness.transcriber.hold(a.fileURL)
    await start(harness, [a])
    #expect(await waitUntil("transcription is held") { harness.transcriber.holding })
    #expect(await waitUntil("a is under analysis") { await activityIncludes(harness, a) })

    harness.transcriber.release()
    await harness.coordinator.waitUntilIdle()
    #expect(await waitUntil("nothing is under analysis") { await harness.coordinator.analysisActivity == nil })
  }

  @Test func theActivityNamesTheIdentitiesLinkedToTheEpisode() async throws {
    let harness = try await harness(wholeFiles: true)
    let server = Harness.identity("x", source: .abs)
    let a = harness.episode("a", transcript: Tests.withAd("a"), linked: [server])
    harness.transcriber.hold(a.fileURL)
    await start(harness, [a])
    #expect(
      await waitUntil("the server copy is named") {
        await harness.coordinator.analysisActivity?.includes(itemID: server.itemID, episodeID: server.episodeID)
          == true
      })
    harness.transcriber.release()
    await harness.coordinator.waitUntilIdle()
  }

  @Test func holdingAnalysisClearsTheActivity() async throws {
    let harness = try await harness(wholeFiles: true)
    let a = harness.episode("a", transcript: Tests.withAd("a"))
    harness.transcriber.hold(a.fileURL)
    await start(harness, [a])
    #expect(await waitUntil("a is under analysis") { await activityIncludes(harness, a) })

    await harness.coordinator.setAllowed(false)
    harness.transcriber.release()
    #expect(await waitUntil("cleared") { await harness.coordinator.analysisActivity == nil })
    await harness.coordinator.waitUntilIdle()
  }

  @Test func turningTheSettingOffClearsTheActivity() async throws {
    let harness = try await harness(wholeFiles: true)
    let a = harness.episode("a", transcript: Tests.withAd("a"))
    harness.transcriber.hold(a.fileURL)
    await start(harness, [a])
    #expect(await waitUntil("a is under analysis") { await activityIncludes(harness, a) })

    await harness.coordinator.setEnabled(false)
    harness.transcriber.release()
    #expect(await waitUntil("cleared") { await harness.coordinator.analysisActivity == nil })
    await harness.coordinator.waitUntilIdle()
  }

  @Test func anEpisodeLeavingTheSetIsNoLongerTheActivity() async throws {
    let harness = try await harness(wholeFiles: true)
    let a = harness.episode("a", transcript: Tests.withAd("a"))
    harness.transcriber.hold(a.fileURL)
    await start(harness, [a])
    #expect(await waitUntil("a is under analysis") { await activityIncludes(harness, a) })

    await harness.coordinator.setLocalEpisodes([])
    #expect(await waitUntil("cleared") { await harness.coordinator.analysisActivity == nil })
    harness.transcriber.release()
    await harness.coordinator.waitUntilIdle()
  }

  @Test func aUnitIsPublishedOnlyOnceItHasHeldForTheSettle() async throws {
    let harness = try Harness(wholeFiles: true)
    await harness.coordinator.setActivitySettle(.seconds(60))
    let a = harness.episode("a", transcript: Tests.withAd("a"))
    harness.transcriber.hold(a.fileURL)
    await start(harness, [a])
    #expect(await waitUntil("transcription is held") { harness.transcriber.holding })

    #expect(await harness.coordinator.hasPendingSettle)
    #expect(await harness.coordinator.analysisActivity == nil)
    harness.transcriber.release()
    await harness.coordinator.waitUntilIdle()
  }

  @Test func aDeferralOnEveryActivationNeverReachesTheTilesOrThePlayer() async throws {
    let harness = try await harness(wholeFiles: true)
    let a = harness.episode("a")
    harness.transcriber.set(a.fileURL, .failure(AdSkipAnalysisDeferred()))
    await harness.run([a])
    #expect(await waitUntil("settled waiting for the model") { await status(harness, a) == .waiting(.speechModel) })
    #expect(await waitUntil("no pending publish") { await harness.coordinator.hasPendingSettle == false })

    // An activation re-emits allowed: the hold lifts, a's unit runs and defers again at once.
    await harness.coordinator.setActivitySettle(.seconds(60))
    await harness.coordinator.setAllowed(true)
    await harness.coordinator.waitUntilIdle()
    #expect(harness.transcriber.calls.withLock { $0.count } == 2)
    #expect(await harness.coordinator.hasPendingSettle == false)
    #expect(await harness.coordinator.analysisActivity == nil)
    #expect(await status(harness, a) == .waiting(.speechModel))
  }

  // MARK: - The loaded episode's status

  @Test func theLoadedEpisodeIsCheckingWhileItIsAnalysed() async throws {
    let harness = try await harness(wholeFiles: true)
    let a = harness.episode("a", transcript: Tests.withAd("a"))
    let b = harness.episode("b", transcript: Tests.withAd("b"))
    harness.transcriber.hold(a.fileURL)
    await harness.coordinator.prioritize(a.identity)
    await start(harness, [a, b])
    #expect(await waitUntil("a is held") { harness.transcriber.holding })
    #expect(await waitUntil("checking") { await status(harness, a) == .checking })

    harness.transcriber.release()
    await harness.coordinator.waitUntilIdle()
    #expect(await waitUntil("ready") { await status(harness, a) == .none })
  }

  @Test func theLoadedEpisodeWaitsWhileAnalysisIsHeld() async throws {
    let harness = try await harness()
    let a = harness.episode("a", transcript: Tests.withAd("a"))
    await harness.run([a], allowed: false)
    #expect(await waitUntil("waiting") { await status(harness, a) == .waiting(.conditions) })
  }

  @Test func theLoadedEpisodeWaitsForTheSpeechModel() async throws {
    let harness = try await harness(wholeFiles: true)
    let a = harness.episode("a")
    harness.transcriber.set(a.fileURL, .failure(AdSkipAnalysisDeferred()))
    await harness.run([a])
    #expect(await waitUntil("waiting") { await status(harness, a) == .waiting(.speechModel) })
  }

  @Test func anAnalysedEpisodeHasNothingToSay() async throws {
    let harness = try await harness()
    let a = harness.episode("a", transcript: Tests.withAd("a"))
    let b = harness.episode("b", transcript: Tests.withAd("b"))
    await harness.run([a, b])
    #expect(try await harness.episodes.allEpisodes().map(\.state) == [.analysed, .analysed])
    #expect(await status(harness, a) == .none)
  }

  @Test func thereIsNothingToSayBeforeTheConditionsAreKnown() async throws {
    let harness = try await harness()
    let a = harness.episode("a", transcript: Tests.withAd("a"))
    await harness.coordinator.setLocalEpisodes([a])
    await harness.coordinator.setEnabled(true)
    await harness.coordinator.waitUntilIdle()
    #expect(await status(harness, a) == .none)
  }

  // MARK: - Off, for a file analysis would cover

  @Test func anEpisodeAnalysisWouldCoverSaysTheSettingIsOff() async throws {
    let harness = try await harness()
    let a = harness.episode("a", transcript: Tests.withAd("a"))
    await harness.run([a], enabled: false, allowed: false)
    #expect(await status(harness, a) == .notEnabled)
  }

  @Test func thereIsNothingToSayBeforeTheSettingIsKnown() async throws {
    let harness = try await harness()
    let a = harness.episode("a", transcript: Tests.withAd("a"))
    await harness.coordinator.setLocalEpisodes([a])
    #expect(await status(harness, a) == .none)
  }

  @Test func aShowAnalysisDoesNotCoverIsNotOffered() async throws {
    let harness = try await harness()
    let a = harness.episode("a", transcript: Tests.withAd("a"), language: "de")
    await harness.run([a], enabled: false, allowed: false)
    #expect(await status(harness, a) == .none)
  }

  @Test func anAudiobookIsNotOffered() async throws {
    let harness = try await harness()
    let a = harness.episode("a", transcript: Tests.withAd("a"))
    await harness.run([a], enabled: false, allowed: false)
    let audiobook = PlaybackSkipRangeRequest(
      itemID: a.identity.itemID, episodeID: nil, fileURL: a.fileURL)
    #expect(await harness.coordinator.analysisStatus(for: audiobook) == .none)
  }

  @Test func anAnalysedEpisodeStillSaysTheSettingIsOff() async throws {
    let harness = try await harness()
    let a = harness.episode("a", transcript: Tests.withAd("a"))
    await harness.run([a])
    #expect(await status(harness, a) == .none)

    await harness.coordinator.setEnabled(false)
    #expect(await status(harness, a) == .notEnabled)
  }

  /// The live setting, not the settled one: the settled state lags a change by the settle, and
  /// reads as off for the first second of every launch.
  @Test func turningTheSettingOnStopsSayingItIsOffBeforeTheSettle() async throws {
    let harness = try Harness()
    await harness.coordinator.setActivitySettle(.seconds(60))
    let a = harness.episode("a", transcript: Tests.withAd("a"))
    await harness.coordinator.setLocalEpisodes([a])
    await harness.coordinator.setEnabled(false)
    #expect(await status(harness, a) == .notEnabled)

    await harness.coordinator.setEnabled(true)
    #expect(await status(harness, a) != .notEnabled)
  }

  @Test func aHoldSignalsTheStatusOnceSettled() async throws {
    let harness = try await harness()
    let a = harness.episode("a", transcript: Tests.withAd("a"))
    let b = harness.episode("b", transcript: Tests.withAd("b"))
    await harness.run([a, b])
    #expect(await waitUntil("settled") { await harness.coordinator.hasPendingSettle == false })
    var changes = harness.coordinator.analysisStatusChanges().makeAsyncIterator()

    await harness.coordinator.setAllowed(false)
    #expect(await changes.next() != nil)
  }

  // MARK: - A priority episode with no windows

  @Test func aPriorityEpisodeWithNoWindowsSettlesBeforeTheBacklogIsDecoded() async throws {
    let harness = try await harness()
    let a = harness.episode("a", transcript: Tests.transcript(Tests.programme("a")))
    let b = harness.episode("b", transcript: Tests.transcript(Tests.programme("b")))
    let c = harness.episode("c", transcript: Tests.transcript(Tests.programme("c")))
    harness.audio.hold(b.fileURL)
    await harness.coordinator.prioritize(a.identity)
    await start(harness, [a, b, c])
    #expect(await waitUntil("b's decode is held") { harness.audio.holding })

    let row = try #require(try await harness.episodes.episode(for: a.identity))
    #expect(row.state == .analysed)
    #expect(harness.transcriber.calls.withLock { $0 }.contains(a.fileURL) == false)

    harness.audio.release()
    await harness.coordinator.waitUntilIdle()
  }

  // MARK: - Check Now

  @Test func theConditionsAloneNeverAnalyseOnBattery() async throws {
    let harness = try await harness()
    let a = harness.episode("a", transcript: Tests.withAd("a"))
    await harness.coordinator.setPriorityConditionsAllowed(true)
    await harness.run([a], allowed: false)
    _ = await harness.coordinator.skipRanges(for: Tests.request(a))
    await harness.coordinator.waitUntilIdle()
    #expect(harness.audio.calls.withLock { $0 }.isEmpty)
  }

  @Test func checkNowAnalysesTheLoadedEpisodeAndNothingElse() async throws {
    let harness = try await harness()
    let a = harness.episode("a", transcript: Tests.withAd("a"))
    let b = harness.episode("b", transcript: Tests.withAd("b"))
    await harness.coordinator.setPriorityConditionsAllowed(true)
    await harness.run([a, b], allowed: false)
    #expect(await waitUntil("waiting") { await status(harness, a) == .waiting(.conditions) })

    await harness.coordinator.checkNow(for: Tests.request(a))
    await harness.coordinator.waitUntilIdle()
    #expect(try await harness.episodes.episode(for: a.identity)?.state == .analysed)
    #expect(harness.audio.calls.withLock { $0 }.contains(b.fileURL) == false)
    // Analysed, so the grant is spent: the backlog still waits for power.
    #expect(await harness.coordinator.grantedPriority == nil)
  }

  @Test func checkNowShowsCheckingWhileItRuns() async throws {
    let harness = try await harness(wholeFiles: true)
    let a = harness.episode("a", transcript: Tests.withAd("a"))
    await harness.coordinator.setPriorityConditionsAllowed(true)
    await harness.run([a], allowed: false)
    harness.transcriber.hold(a.fileURL)

    await harness.coordinator.checkNow(for: Tests.request(a))
    #expect(await waitUntil("a is held") { harness.transcriber.holding })
    #expect(await waitUntil("checking") { await status(harness, a) == .checking })
    harness.transcriber.release()
    await harness.coordinator.waitUntilIdle()
  }

  @Test func checkNowWaitsWhileLowPowerModeOrHeatHold() async throws {
    let harness = try await harness()
    let a = harness.episode("a", transcript: Tests.withAd("a"))
    await harness.run([a], allowed: false)

    await harness.coordinator.checkNow(for: Tests.request(a))
    await harness.coordinator.waitUntilIdle()
    #expect(harness.audio.calls.withLock { $0 }.isEmpty)
    #expect(await status(harness, a) == .waiting(.conditions))
  }

  @Test func anotherEpisodeLoadedEndsCheckNow() async throws {
    let harness = try await harness()
    let a = harness.episode("a", transcript: Tests.withAd("a"))
    let b = harness.episode("b", transcript: Tests.withAd("b"))
    await harness.run([a, b], allowed: false)
    await harness.coordinator.checkNow(for: Tests.request(a))
    #expect(await harness.coordinator.grantedPriority == a.identity)

    await harness.coordinator.prioritize(b.identity)
    #expect(await harness.coordinator.grantedPriority == nil)
  }

  @Test func aMoveToBatteryDoesNotStopCheckNow() async throws {
    let harness = try await harness(wholeFiles: true)
    let a = harness.episode("a", transcript: Tests.withAd("a"))
    await harness.coordinator.setPriorityConditionsAllowed(true)
    harness.transcriber.hold(a.fileURL)
    await harness.coordinator.prioritize(a.identity)
    await start(harness, [a])
    await harness.coordinator.checkNow(for: Tests.request(a))
    #expect(await waitUntil("a is held") { harness.transcriber.holding })

    await harness.coordinator.setAllowed(false)
    harness.transcriber.release()
    await harness.coordinator.waitUntilIdle()
    #expect(try await harness.episodes.episode(for: a.identity)?.state == .analysed)
  }

  @Test func lowPowerModeStopsCheckNow() async throws {
    let harness = try await harness(wholeFiles: true)
    let a = harness.episode("a", transcript: Tests.withAd("a"))
    await harness.coordinator.setPriorityConditionsAllowed(true)
    await harness.run([a], allowed: false)
    harness.transcriber.hold(a.fileURL)
    await harness.coordinator.checkNow(for: Tests.request(a))
    #expect(await waitUntil("a is held") { harness.transcriber.holding })

    await harness.coordinator.setPriorityConditionsAllowed(false)
    harness.transcriber.release()
    await harness.coordinator.waitUntilIdle()
    #expect(try await harness.episodes.episode(for: a.identity)?.state == .decoded)
  }

  @Test func theOvernightExpiryStopsCheckNowToo() async throws {
    let harness = try await harness(wholeFiles: true)
    let a = harness.episode("a", transcript: Tests.withAd("a"))
    await harness.coordinator.setPriorityConditionsAllowed(true)
    harness.transcriber.hold(a.fileURL)
    await harness.coordinator.prioritize(a.identity)
    await start(harness, [a])
    await harness.coordinator.checkNow(for: Tests.request(a))
    #expect(await waitUntil("a is held") { harness.transcriber.holding })

    await harness.coordinator.suspendForExpiry()
    harness.transcriber.release()
    await harness.coordinator.waitUntilIdle()
    #expect(try await harness.episodes.episode(for: a.identity)?.state == .decoded)
    #expect(await harness.coordinator.grantedPriority == nil)
  }
}
