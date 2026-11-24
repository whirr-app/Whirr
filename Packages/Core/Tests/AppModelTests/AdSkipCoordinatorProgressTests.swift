import AdSkip
import Foundation
import TestSupport
import Testing

@testable import AppModel

/// What the Reduce Ads settings page shows of the backlog: how many downloaded episodes are
/// analysed, how many could not be, and whether the rest are being worked on or waiting.
@Suite struct AdSkipCoordinatorProgressTests {
  typealias Harness = AdSkipCoordinatorTests.Harness

  @Test func thereIsNoProgressWhileTheSettingIsOff() async throws {
    let harness = try Harness()
    await harness.run([harness.episode("a", transcript: AdSkipCoordinatorTests.withAd("a"))], enabled: false)
    #expect(await harness.coordinator.progress == nil)
  }

  @Test func analysedEpisodesAreCountedAgainstEveryAnalysableDownload() async throws {
    let harness = try Harness()
    await harness.run([
      harness.episode("a", transcript: AdSkipCoordinatorTests.withAd("a")),
      harness.episode("b", transcript: AdSkipCoordinatorTests.withAd("b")),
      // Another language is never analysed, so it is not part of the count.
      harness.episode("c", transcript: AdSkipCoordinatorTests.withAd("c"), language: "fr"),
    ])
    #expect(
      await harness.coordinator.progress
        == AdSkipProgress(analysed: 2, unanalysable: 0, total: 2, activity: .idle))
  }

  @Test func aFailedEpisodeIsCountedAsUnanalysable() async throws {
    let harness = try Harness()
    let a = harness.episode("a")
    harness.audio.fail(a.fileURL, AdSkipCoordinatorTests.Unexpected())
    await harness.run([a, harness.episode("b", transcript: AdSkipCoordinatorTests.withAd("b"))])
    #expect(
      await harness.coordinator.progress
        == AdSkipProgress(analysed: 1, unanalysable: 1, total: 2, activity: .idle))
  }

  @Test func episodesWaitingWhileAnalysisIsNotAllowedArePaused() async throws {
    let harness = try Harness()
    await harness.run(
      [harness.episode("a", transcript: AdSkipCoordinatorTests.withAd("a"))], allowed: false)
    let progress = try #require(await harness.coordinator.progress)
    #expect(progress == AdSkipProgress(analysed: 0, unanalysable: 0, total: 1, activity: .paused))
    #expect(progress.remaining == 1)
  }

  @Test func theEpisodeBeingTranscribedIsRemainingWhileAnalysing() async throws {
    let harness = try Harness(wholeFiles: true)
    let a = harness.episode("a", transcript: AdSkipCoordinatorTests.withAd("a"))
    harness.transcriber.hold(a.fileURL)
    await harness.coordinator.setLocalEpisodes([a])
    await harness.coordinator.setAllowed(true)
    await harness.coordinator.setEnabled(true)
    #expect(await waitUntil("transcription is held") { harness.transcriber.holding })

    #expect(
      await harness.coordinator.progress
        == AdSkipProgress(analysed: 0, unanalysable: 0, total: 1, activity: .analysing))

    harness.transcriber.release()
    await harness.coordinator.waitUntilIdle()
    #expect(
      await harness.coordinator.progress
        == AdSkipProgress(analysed: 1, unanalysable: 0, total: 1, activity: .idle))
  }

  /// A jingle with no speech, 20 s from `start`.
  private static func jingle(from start: Double) -> [TranscriptWord] {
    (0..<40).map {
      TranscriptWord(
        text: "jingle\($0)", start: start + Double($0) * 0.5, end: start + Double($0) * 0.5 + 0.4)
    }
  }

  /// Every episode counts as analysed, but a's windows have grown and its new stretch is held: c
  /// arrives carrying the jingle a ends with, and is analysed first as the player's episode.
  private func holdGrownWindows(_ harness: Harness) async throws {
    let spoken = AdSkipCoordinatorTests.long("a")
    let a = harness.episode("a", transcript: Transcript(words: spoken.words, duration: 280))
    harness.audio.unspoken.withLock { $0[a.fileURL] = Self.jingle(from: 240) }
    let b = harness.episode("b", transcript: AdSkipCoordinatorTests.long("b"))
    await harness.run([a, b])

    let c = harness.episode("c", transcript: Transcript(words: [], duration: 200))
    harness.audio.unspoken.withLock { $0[c.fileURL] = Self.jingle(from: 100) }
    harness.transcriber.hold(a.fileURL)
    await harness.coordinator.prioritize(c.identity)
    await harness.coordinator.setLocalEpisodes([a, b, c])
    #expect(await waitUntil("a's grown window is held") { harness.transcriber.holding })
  }

  @Test func windowsLeftOnAnalysedEpisodesAreStillAnalysing() async throws {
    let harness = try Harness()
    try await holdGrownWindows(harness)

    let held = await harness.coordinator.progress
    #expect(held == AdSkipProgress(analysed: 3, unanalysable: 0, total: 3, activity: .analysing))

    harness.transcriber.release()
    await harness.coordinator.waitUntilIdle()
    #expect(
      await harness.coordinator.progress
        == AdSkipProgress(analysed: 3, unanalysable: 0, total: 3, activity: .idle))
  }

  @Test func windowsLeftOnAnalysedEpisodesArePausedWhileAnalysisIsNotAllowed() async throws {
    let harness = try Harness()
    try await holdGrownWindows(harness)

    await harness.coordinator.setAllowed(false)
    harness.transcriber.release()
    await harness.coordinator.waitUntilIdle()
    #expect(
      await harness.coordinator.progress
        == AdSkipProgress(analysed: 3, unanalysable: 0, total: 3, activity: .paused))

    await harness.coordinator.setAllowed(true)
    await harness.coordinator.waitUntilIdle()
    #expect(
      await harness.coordinator.progress
        == AdSkipProgress(analysed: 3, unanalysable: 0, total: 3, activity: .idle))
  }

  @Test func aNewSubscriberIsToldTheCurrentProgressAtOnce() async throws {
    let harness = try Harness()
    await harness.run([harness.episode("a", transcript: AdSkipCoordinatorTests.withAd("a"))])
    var updates = harness.coordinator.progressUpdates().makeAsyncIterator()
    let first = await updates.next()
    #expect(first == AdSkipProgress(analysed: 1, unanalysable: 0, total: 1, activity: .idle))
  }

  @Test func turningTheSettingOffClearsTheProgress() async throws {
    let harness = try Harness()
    await harness.run([harness.episode("a", transcript: AdSkipCoordinatorTests.withAd("a"))])
    var updates = harness.coordinator.progressUpdates().makeAsyncIterator()
    _ = await updates.next()

    await harness.coordinator.setEnabled(false)
    await harness.coordinator.waitUntilIdle()
    #expect(await harness.coordinator.progress == nil)
    let cleared = await updates.next()
    #expect(cleared == .some(nil))
  }
}
