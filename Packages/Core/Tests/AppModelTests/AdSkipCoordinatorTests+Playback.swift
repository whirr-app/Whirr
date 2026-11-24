import AdSkip
import Foundation
import Persistence
import PlayerCore
import TestSupport
import Testing

@testable import AppModel

/// The coordinator as the player's range source: ranges only for an analysed file that still
/// matches, a change signal, and Undo.
extension AdSkipCoordinatorTests {

  static func request(_ episode: AdSkipLocalEpisode) -> PlaybackSkipRangeRequest {
    PlaybackSkipRangeRequest(
      itemID: episode.identity.itemID, episodeID: episode.identity.episodeID,
      fileURL: episode.fileURL)
  }

  @Test func anAnalysedEpisodeServesItsStoredRanges() async throws {
    let harness = try Harness()
    let a = harness.episode("a", transcript: Self.withAd("a"))
    let b = harness.episode("b", transcript: Self.withAd("b"))
    await harness.run([a, b])

    let served = await harness.coordinator.skipRanges(for: Self.request(b))
    let stored = try await harness.ranges("b").map {
      PlayerSkipRange(start: $0.startTime, end: $0.endTime, endsItem: $0.endsItem)
    }
    #expect(served.count == 1)
    #expect(served == stored)
  }

  @Test func aRangeStartingNearTheFileStartIsServedFromZero() async throws {
    let harness = try Harness()
    // Each copy opens with 3 s of words of its own, as a pre-roll's garbled opening would.
    let a = harness.episode(
      "a", transcript: Self.transcript(Self.programme("a", count: 6) + Self.ad + Self.programme("ax")))
    let b = harness.episode(
      "b", transcript: Self.transcript(Self.programme("b", count: 6) + Self.ad + Self.programme("bx")))
    await harness.run([a, b])

    let stored = try #require(try await harness.ranges("b").first)
    #expect(stored.startTime > 0)
    let served = await harness.coordinator.skipRanges(for: Self.request(b))
    #expect(served == [PlayerSkipRange(start: 0, end: stored.endTime, endsItem: stored.endsItem)])
  }

  @Test func aRangeStartingLaterIsServedAsStored() async throws {
    let harness = try Harness()
    let a = harness.episode(
      "a", transcript: Self.transcript(Self.programme("a", count: 12) + Self.ad + Self.programme("ax")))
    let b = harness.episode(
      "b", transcript: Self.transcript(Self.programme("b", count: 12) + Self.ad + Self.programme("bx")))
    await harness.run([a, b])

    let stored = try #require(try await harness.ranges("b").first)
    let served = await harness.coordinator.skipRanges(for: Self.request(b))
    #expect(served == [PlayerSkipRange(start: stored.startTime, end: stored.endTime, endsItem: stored.endsItem)])
  }

  @Test func aChangedFileServesNothing() async throws {
    let harness = try Harness()
    let a = harness.episode("a", transcript: Self.withAd("a"))
    let b = harness.episode("b", transcript: Self.withAd("b"))
    await harness.run([a, b])

    harness.fingerprints.set(b.fileURL, size: 77_777)
    #expect(await harness.coordinator.skipRanges(for: Self.request(b)).isEmpty)
  }

  @Test func nothingIsServedWithTheSettingOff() async throws {
    let harness = try Harness()
    let a = harness.episode("a", transcript: Self.withAd("a"))
    let b = harness.episode("b", transcript: Self.withAd("b"))
    await harness.run([a, b])

    await harness.coordinator.setEnabled(false)
    #expect(await harness.coordinator.skipRanges(for: Self.request(b)).isEmpty)

    await harness.coordinator.setEnabled(true)
    #expect(await harness.coordinator.skipRanges(for: Self.request(b)).count == 1)
  }

  @Test func turningTheSettingOffOrOnSignalsTheRanges() async throws {
    let harness = try Harness()
    let a = harness.episode("a", transcript: Self.withAd("a"))
    let b = harness.episode("b", transcript: Self.withAd("b"))
    await harness.run([a, b])

    var changes = harness.coordinator.skipRangeChanges().makeAsyncIterator()
    await harness.coordinator.setEnabled(false)
    #expect(await changes.next() != nil)

    changes = harness.coordinator.skipRangeChanges().makeAsyncIterator()
    await harness.coordinator.setEnabled(true)
    #expect(await changes.next() != nil)
  }

  /// At launch the setting can arrive before the downloads, so the player's first ask finds no
  /// episode. Without a signal when they arrive it never asks again and plays every ad.
  @Test func theLocalEpisodesArrivingSignalsTheRanges() async throws {
    let first = try Harness()
    let a = first.episode("a", transcript: Self.withAd("a"))
    let b = first.episode("b", transcript: Self.withAd("b"))
    await first.run([a, b])

    let harness = try Harness(reusing: first)
    await harness.coordinator.setEnabled(true)
    #expect(await harness.coordinator.skipRanges(for: Self.request(b)).isEmpty)

    let signalled = Locked(false)
    let changes = harness.coordinator.skipRangeChanges()
    let listener = Task {
      for await _ in changes { signalled.value = true }
    }
    defer { listener.cancel() }
    await harness.coordinator.setLocalEpisodes([a, b])
    #expect(await waitUntil("the ranges to be signalled") { signalled.value })
    #expect(await harness.coordinator.skipRanges(for: Self.request(b)).count == 1)
  }

  @Test func anotherEpisodesFileServesNothing() async throws {
    let harness = try Harness()
    let a = harness.episode("a", transcript: Self.withAd("a"))
    let b = harness.episode("b", transcript: Self.withAd("b"))
    await harness.run([a, b])

    let mismatched = PlaybackSkipRangeRequest(
      itemID: b.identity.itemID, episodeID: "unknown", fileURL: b.fileURL)
    #expect(await harness.coordinator.skipRanges(for: mismatched).isEmpty)
  }

  @Test func askingForAnEpisodesRangesAnalysesItFirst() async throws {
    let harness = try Harness()
    let a = harness.episode("a", transcript: Self.withAd("a"))
    let z = harness.episode("z", transcript: Self.withAd("z"))
    await harness.coordinator.setLocalEpisodes([a, z])
    _ = await harness.coordinator.skipRanges(for: Self.request(z))
    await harness.run([a, z])
    #expect(harness.audio.calls.withLock { $0 } == [z.fileURL, a.fileURL])
    #expect(harness.transcriber.calls.withLock { $0.prefix(2) } == [z.fileURL, a.fileURL])
  }

  @Test func rangeChangesAreSignalled() async throws {
    let harness = try Harness()
    var changes = harness.coordinator.skipRangeChanges().makeAsyncIterator()
    let a = harness.episode("a", transcript: Self.withAd("a"))
    let b = harness.episode("b", transcript: Self.withAd("b"))
    await harness.run([a, b])
    #expect(await changes.next() != nil)
  }

  /// The ad two episodes taught stays in the store; the tombstone is what stops it.
  @Test func undoingASkipStopsThatAdEverywhere() async throws {
    let harness = try Harness()
    let a = harness.episode("a", transcript: Self.withAd("a"))
    let b = harness.episode("b", transcript: Self.withAd("b"))
    await harness.run([a, b])
    let skipped = try #require(await harness.coordinator.skipRanges(for: Self.request(b)).first)

    await harness.coordinator.undoSkip(skipped, for: Self.request(b))
    await harness.coordinator.waitUntilIdle()

    #expect(try await harness.ranges("a").isEmpty)
    #expect(try await harness.ranges("b").isEmpty)
    let creatives = try await harness.signatures.allCreatives()
    #expect(creatives.contains { $0.kind == .tombstone })
    #expect(creatives.filter { $0.kind == .learned }.map(\.teachers.count) == [2])

    // A new episode carrying the same ad is not skipped either.
    let c = harness.episode("c", transcript: Self.withAd("c"))
    await harness.coordinator.setLocalEpisodes([a, b, c])
    await harness.coordinator.waitUntilIdle()
    #expect(try await harness.ranges("c").isEmpty)
  }

  @Test func anUndoWhoseTranscriptIsLostWaitsForTheEpisodeToBeAnalysedAgain() async throws {
    let harness = try Harness()
    let a = harness.episode("a", transcript: Self.withAd("a"))
    let b = harness.episode("b", transcript: Self.withAd("b"))
    await harness.run([a, b])
    let skipped = try #require(await harness.coordinator.skipRanges(for: Self.request(b)).first)
    let name = try #require(try await harness.episodes.episode(for: b.identity)?.transcriptFileName)
    try FileManager.default.removeItem(at: harness.transcripts.rootURL.appendingPathComponent(name))

    await harness.coordinator.undoSkip(skipped, for: Self.request(b))
    await harness.coordinator.waitUntilIdle()

    #expect(try await harness.ranges("a").isEmpty)
    #expect(try await harness.ranges("b").isEmpty)
    let creatives = try await harness.signatures.allCreatives()
    #expect(creatives.contains { $0.kind == .tombstone })
  }

  @Test func anUndoSignalsTheTrimmedRanges() async throws {
    let harness = try Harness()
    let a = harness.episode("a", transcript: Self.withAd("a"))
    let b = harness.episode("b", transcript: Self.withAd("b"))
    await harness.run([a, b])
    let skipped = try #require(await harness.coordinator.skipRanges(for: Self.request(b)).first)
    var changes = harness.coordinator.skipRangeChanges().makeAsyncIterator()

    await harness.coordinator.undoSkip(skipped, for: Self.request(b))
    await harness.coordinator.waitUntilIdle()

    #expect(await changes.next() != nil)
  }
}
