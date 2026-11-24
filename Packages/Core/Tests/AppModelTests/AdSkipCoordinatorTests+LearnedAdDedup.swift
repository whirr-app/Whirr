import AdSkip
import Foundation
import Persistence
import Testing

@testable import AppModel

/// Each learned ad is stored once (learned-ad dedup plan): what the coordinator's passes leave in
/// the store, and what Undo and a restore do to an ad more than one episode taught.
extension AdSkipCoordinatorTests {
  private static func key(_ id: String) -> String { Harness.identity(id).episodeKey.rawValue }

  @Test func aThirdEpisodeCarryingTheAdAddsATeacherAndNoAd() async throws {
    let harness = try Harness()
    let a = harness.episode("a", transcript: Self.withAd("a"))
    let b = harness.episode("b", transcript: Self.withAd("b"))
    await harness.run([a, b])
    let before = try await harness.signatures.allCreatives()
    #expect(before.map(\.teachers) == [[Self.key("a"), Self.key("b")]])

    let c = harness.episode("c", transcript: Self.withAd("c"))
    await harness.coordinator.setLocalEpisodes([a, b, c])
    await harness.coordinator.waitUntilIdle()
    let after = try await harness.signatures.allCreatives()
    #expect(after.map(\.id) == before.map(\.id))
    #expect(after.map(\.teachers) == [[Self.key("a"), Self.key("b"), Self.key("c")]])
    for id in ["a", "b", "c"] {
      #expect(try await harness.ranges(id).map(\.creativeId) == [before.first?.id])
    }

    await harness.coordinator.forceRecompute()
    await harness.coordinator.waitUntilIdle()
    #expect(try await harness.signatures.allCreatives() == after)
  }

  /// The case that made the first draft of the plan replace an ad on every pass. The two copies
  /// are 70 s apart, further than a gap between two skips is filled.
  @Test func anEpisodeCarryingTheAdTwiceLeavesOneAdAndLaterPassesChangeNothing() async throws {
    let measurement = RecordingMeasurement()
    let harness = try Harness(measurement: measurement)
    let twice = Self.transcript(
      Self.programme("a") + Self.ad + Self.programme("ax", count: 140) + Self.ad + Self.programme("ay"))
    await harness.run([
      harness.episode("a", transcript: twice), harness.episode("b", transcript: Self.withAd("b")),
    ])
    let settled = try await harness.signatures.allCreatives()
    #expect(settled.count == 1)
    #expect(try await harness.ranges("a").map(\.creativeId) == [settled.first?.id, settled.first?.id])

    measurement.reset()
    for _ in 0..<2 {
      await harness.coordinator.forceRecompute()
      await harness.coordinator.waitUntilIdle()
      #expect(try await harness.signatures.allCreatives().map(\.id) == settled.map(\.id))
    }
    // No id and no key changed, so the audio library was never dropped and nothing was replanned.
    #expect(measurement.queries == 0)
  }

  /// A store written before ads were merged, or a restore that added copies: the next pass leaves
  /// one ad, every range names it, and the pass after that changes nothing.
  @Test func storedCopiesOfOneAdCollapseOnTheNextPass() async throws {
    let harness = try Harness()
    let a = harness.episode("a", transcript: Self.withAd("a"))
    let b = harness.episode("b", transcript: Self.withAd("b"))
    await harness.run([a, b])
    let merged = try #require(try await harness.signatures.allCreatives().first)
    let print = try #require(try await harness.signatures.learnedAudioPrints().first?.audioPrint)
    // As the store was before: one copy for each teaching episode.
    _ = try await harness.signatures.apply(
      AdSignatureStoreChange(
        deletions: [merged.id],
        insertions: [Self.key("a"), Self.key("b")].map {
          NewAdSignatureCreative(
            kind: .learned, lastSeen: merged.lastSeen, startTime: merged.startTime, endTime: merged.endTime,
            teachers: [$0], hashes: merged.hashes, audioPrint: print)
        }))
    #expect(try await harness.signatures.allCreatives().count == 2)

    await harness.coordinator.learnedAdsRestored()
    await harness.coordinator.waitUntilIdle()
    let collapsed = try await harness.signatures.allCreatives()
    #expect(collapsed.count == 1)
    #expect(collapsed.first?.teachers == [Self.key("a"), Self.key("b")])
    #expect(collapsed.first?.hasAudioPrint == true)
    for id in ["a", "b"] {
      #expect(try await harness.ranges(id).map(\.creativeId) == [collapsed.first?.id])
    }

    await harness.coordinator.forceRecompute()
    await harness.coordinator.waitUntilIdle()
    #expect(try await harness.signatures.allCreatives() == collapsed)
  }

  /// An ad one episode taught carries that episode's key in the audio library. When a second
  /// group teaches it, it keeps its id and loses its keys, so the loaded library must go.
  @Test func anAdMergedInPlaceIsReKeyedInTheAudioLibrary() async throws {
    let harness = try Harness()
    let a = harness.episode("a", transcript: Self.withAd("a"))
    let b = harness.episode("b", transcript: Self.withAd("b"))
    await harness.run([a, b])
    let merged = try #require(try await harness.signatures.allCreatives().first)
    let print = try #require(try await harness.signatures.learnedAudioPrints().first?.audioPrint)
    await harness.coordinator.setEnabled(false)
    await harness.coordinator.waitUntilIdle()
    let ids = try await harness.signatures.apply(
      AdSignatureStoreChange(
        deletions: [merged.id],
        insertions: [
          NewAdSignatureCreative(
            kind: .learned, lastSeen: merged.lastSeen, startTime: merged.startTime, endTime: merged.endTime,
            teachers: [Self.key("a")], hashes: merged.hashes, audioPrint: print)
        ]))
    await harness.coordinator.learnedAdsRestored()
    await harness.coordinator.setEnabled(true)
    await harness.coordinator.waitUntilIdle()

    let after = try await harness.signatures.allCreatives()
    #expect(after.map(\.id) == ids)
    #expect(after.first?.teachers == [Self.key("a"), Self.key("b")])
    let library = try await harness.coordinator.loadedAudioLibrary()
    #expect(library.creativeKeys == [ids[0]: []])
  }

  @Test func undoingAnAdOneEpisodeTaughtDeletesIt() async throws {
    let harness = try Harness()
    let a = harness.episode("a", transcript: Self.withAd("a"))
    let b = harness.episode("b", transcript: Self.withAd("b"))
    await harness.run([a, b])
    let merged = try #require(try await harness.signatures.allCreatives().first)
    let print = try #require(try await harness.signatures.learnedAudioPrints().first?.audioPrint)
    // A restored ad whose teachers the backup could not name, and one episode left to hear it.
    await harness.coordinator.setLocalEpisodes([b])
    await harness.coordinator.waitUntilIdle()
    _ = try await harness.signatures.apply(
      AdSignatureStoreChange(
        deletions: [merged.id],
        insertions: [
          NewAdSignatureCreative(
            kind: .learned, lastSeen: merged.lastSeen, startTime: merged.startTime, endTime: merged.endTime,
            teachers: [], hashes: merged.hashes, audioPrint: print)
        ]))
    await harness.coordinator.learnedAdsRestored()
    await harness.coordinator.waitUntilIdle()
    let skipped = try #require(await harness.coordinator.skipRanges(for: Self.request(b)).first)
    #expect(try await harness.signatures.allCreatives().map(\.teachers.count) == [1])

    await harness.coordinator.undoSkip(skipped, for: Self.request(b))
    await harness.coordinator.waitUntilIdle()
    #expect(try await harness.ranges("b").isEmpty)
    #expect(try await harness.signatures.allCreatives().map(\.kind) == [.tombstone])
  }
}
