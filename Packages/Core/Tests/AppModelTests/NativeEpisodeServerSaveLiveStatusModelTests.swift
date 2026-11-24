import Foundation
import Persistence
import SyncEngine
import TestSupport
import Testing

@testable import AppModel

@Suite struct NativeEpisodeServerSaveLiveStatusModelTests {
  private static let resolver = StaticNativeEpisodeIDResolving(["9": 9])

  @MainActor
  @Test("removing from the show immediately re-enables Save on a visible episode card")
  func showRemovalReachesCard() async {
    let statuses = FakeNativeEpisodeServerSaveStatusReading(
      snapshot: .init(
        status: .saved, attemptID: 1,
        preflightPresence: .absentBeforeRequest))
    let saving = FakeNativeEpisodeServerSaving(
      removeOutcomes: [
        .inProgress(attemptID: 1, state: .removed, serverItemID: "server-show")
      ])
    let show = PodcastShowModel(
      itemID: "rss:7",
      reading: Self.makeReading(episodes: [Self.summary("9")]),
      nativeEpisodeIDResolving: Self.resolver,
      nativeEpisodeServerSaving: saving,
      nativeEpisodeServerSaveStatusReading: statuses)
    let card = PodcastEpisodeCardModel(
      itemID: "rss:7", episodeID: "9",
      reading: Self.makeReading(
        episodes: [Self.summary("9")], contexts: [Self.context(episodeID: "9")]),
      nativeEpisodeIDResolving: Self.resolver,
      nativeEpisodeServerSaveStatusReading: statuses)

    #expect(
      await waitUntil {
        show.serverSave.serverSaveStatus(for: "9") == .saved && card.serverSaveStatus == .saved
      })

    await show.serverSave.removeEpisodeFromServer(episodeID: "9")
    statuses.push(.init(status: .removed, attemptID: 1))

    #expect(
      await waitUntil {
        show.serverSave.serverSaveStatus(for: "9") == .removed && card.serverSaveStatus == .removed
      })
    #expect(
      NativeEpisodeServerSaveStatus.saveAvailability(
        capability: .init(canSave: true, canRemove: true), isNativeFeed: true,
        isCredentialedFeed: false, status: card.serverSaveStatus) == .enabled)
  }

  @MainActor
  @Test("removing from the card immediately re-enables Save on the show row")
  func cardRemovalReachesShow() async {
    let statuses = FakeNativeEpisodeServerSaveStatusReading(
      snapshot: .init(
        status: .saved, attemptID: 1,
        preflightPresence: .absentBeforeRequest))
    let saving = FakeNativeEpisodeServerSaving(
      removeOutcomes: [
        .inProgress(attemptID: 1, state: .removed, serverItemID: "server-show")
      ])
    let show = PodcastShowModel(
      itemID: "rss:7",
      reading: Self.makeReading(episodes: [Self.summary("9")]),
      nativeEpisodeIDResolving: Self.resolver,
      nativeEpisodeServerSaveStatusReading: statuses)
    let card = PodcastEpisodeCardModel(
      itemID: "rss:7", episodeID: "9",
      reading: Self.makeReading(
        episodes: [Self.summary("9")], contexts: [Self.context(episodeID: "9")]),
      nativeEpisodeIDResolving: Self.resolver,
      nativeEpisodeServerSaving: saving,
      nativeEpisodeServerSaveStatusReading: statuses)

    #expect(
      await waitUntil {
        show.serverSave.serverSaveStatus(for: "9") == .saved && card.serverSaveStatus == .saved
      })

    await card.removeEpisodeFromServer()
    statuses.push(.init(status: .removed, attemptID: 1))

    #expect(
      await waitUntil {
        card.serverSaveStatus == .removed && show.serverSave.serverSaveStatus(for: "9") == .removed
      })
  }

  @MainActor
  @Test("a queued pre-removal snapshot cannot overwrite the durable removed state")
  func staleProjectionDoesNotResurrectSaved() async {
    let statuses = FakeNativeEpisodeServerSaveStatusReading(
      snapshot: .init(
        status: .saved, attemptID: 1,
        preflightPresence: .absentBeforeRequest))
    let saving = FakeNativeEpisodeServerSaving(
      removeOutcomes: [
        .inProgress(attemptID: 1, state: .removed, serverItemID: "server-show")
      ])
    let card = PodcastEpisodeCardModel(
      itemID: "rss:7", episodeID: "9",
      reading: Self.makeReading(
        episodes: [Self.summary("9")], contexts: [Self.context(episodeID: "9")]),
      nativeEpisodeIDResolving: Self.resolver,
      nativeEpisodeServerSaving: saving,
      nativeEpisodeServerSaveStatusReading: statuses)

    #expect(await waitUntil { card.serverSaveStatus == .saved })
    await card.removeEpisodeFromServer()
    #expect(card.serverSaveStatus == .removed)

    statuses.push(
      .init(status: .saved, attemptID: 1, preflightPresence: .absentBeforeRequest))
    let settled = await awaitQuiescence("the stale status event", recordingIssue: false) {
      "\(card.serverSaveStatus)"
    }
    #expect(settled.isObserved)
    #expect(card.serverSaveStatus == .removed)
  }

  @MainActor
  @Test("a fresh save after removal clears Removed feedback and starts a new attempt")
  func freshSaveAfterRemovalStartsNewAttempt() async {
    let statuses = FakeNativeEpisodeServerSaveStatusReading(
      snapshot: .init(status: .removed, attemptID: 1))
    let saving = FakeNativeEpisodeServerSaving(
      saveOutcomes: [.accepted(attemptID: 2, serverItemID: "server-show")])
    let card = PodcastEpisodeCardModel(
      itemID: "rss:7", episodeID: "9",
      reading: Self.makeReading(
        episodes: [Self.summary("9")], contexts: [Self.context(episodeID: "9")]),
      nativeEpisodeIDResolving: Self.resolver,
      nativeEpisodeServerSaving: saving,
      nativeEpisodeServerSaveStatusReading: statuses)

    #expect(await waitUntil { card.serverSaveStatus == .removed })
    await card.saveEpisodeToServer()

    #expect(card.serverSaveStatus == .requested)
    #expect(card.serverSaveFeedbackMessage == NativeEpisodeServerSaveCopy.requested)
    #expect(card.serverSaveFeedbackMessage != NativeEpisodeServerSaveCopy.removed)

    // A late event for the previous terminal attempt must not undo the fresh save.
    statuses.push(.init(status: .removed, attemptID: 1))
    let settled = await awaitQuiescence(
      "the stale removed status event", recordingIssue: false
    ) {
      "\(card.serverSaveStatus)"
    }
    #expect(settled.isObserved)
    #expect(card.serverSaveStatus == .requested)
  }

  @MainActor
  @Test("a queued pre-removal snapshot cannot overwrite the show row's removed state")
  func staleProjectionDoesNotResurrectSavedOnTheShow() async {
    let statuses = FakeNativeEpisodeServerSaveStatusReading(
      snapshot: .init(
        status: .saved, attemptID: 1,
        preflightPresence: .absentBeforeRequest))
    let saving = FakeNativeEpisodeServerSaving(
      removeOutcomes: [
        .inProgress(attemptID: 1, state: .removed, serverItemID: "server-show")
      ])
    let show = PodcastShowModel(
      itemID: "rss:7",
      reading: Self.makeReading(episodes: [Self.summary("9")]),
      nativeEpisodeIDResolving: Self.resolver,
      nativeEpisodeServerSaving: saving,
      nativeEpisodeServerSaveStatusReading: statuses)

    #expect(await waitUntil { show.serverSave.serverSaveStatus(for: "9") == .saved })
    await show.serverSave.removeEpisodeFromServer(episodeID: "9")
    #expect(show.serverSave.serverSaveStatus(for: "9") == .removed)

    statuses.push(
      .init(status: .saved, attemptID: 1, preflightPresence: .absentBeforeRequest))
    let settled = await awaitQuiescence("the stale status event", recordingIssue: false) {
      "\(show.serverSave.serverSaveStatus(for: "9"))"
    }
    #expect(settled.isObserved)
    #expect(show.serverSave.serverSaveStatus(for: "9") == .removed)
  }

  @MainActor
  @Test("a late removal of the previous attempt cannot undo a fresh save on the show row")
  func freshSaveAfterRemovalOutlivesTheLateRemovalOnTheShow() async {
    let statuses = FakeNativeEpisodeServerSaveStatusReading(
      snapshot: .init(status: .removed, attemptID: 1))
    let saving = FakeNativeEpisodeServerSaving(
      saveOutcomes: [.accepted(attemptID: 2, serverItemID: "server-show")])
    let show = PodcastShowModel(
      itemID: "rss:7",
      reading: Self.makeReading(episodes: [Self.summary("9")]),
      nativeEpisodeIDResolving: Self.resolver,
      nativeEpisodeServerSaving: saving,
      nativeEpisodeServerSaveStatusReading: statuses)

    #expect(await waitUntil { show.serverSave.serverSaveStatus(for: "9") == .removed })
    await show.serverSave.saveEpisodeToServer(episodeID: "9")
    #expect(show.serverSave.serverSaveStatus(for: "9") == .requested)

    statuses.push(.init(status: .removed, attemptID: 1))
    let settled = await awaitQuiescence(
      "the stale removed status event", recordingIssue: false
    ) {
      "\(show.serverSave.serverSaveStatus(for: "9"))"
    }
    #expect(settled.isObserved)
    #expect(show.serverSave.serverSaveStatus(for: "9") == .requested)
  }

  @MainActor
  @Test("stopping a card cancels its status stream and restarting reads the durable state")
  func cardStatusObservationFollowsLifecycle() async {
    let statuses = FakeNativeEpisodeServerSaveStatusReading(
      snapshot: .init(
        status: .saved, attemptID: 1,
        preflightPresence: .absentBeforeRequest))
    let reading = Self.makeReading(
      episodes: [Self.summary("9")], contexts: [Self.context(episodeID: "9")])
    let card = PodcastEpisodeCardModel(
      itemID: "rss:7", episodeID: "9", reading: reading,
      nativeEpisodeIDResolving: Self.resolver,
      nativeEpisodeServerSaveStatusReading: statuses)

    #expect(await waitUntil { card.serverSaveStatus == .saved })
    card.stopObserving()
    statuses.push(.init(status: .removed, attemptID: 1))
    let settled = await awaitQuiescence(
      "the stopped card status stream", recordingIssue: false
    ) {
      "\(card.serverSaveStatus)"
    }
    #expect(settled.isObserved)
    #expect(card.serverSaveStatus == .saved)

    card.startObserving()
    #expect(await waitUntil { card.serverSaveStatus == .removed })
  }

  @MainActor
  @Test("a show uses one aggregate status observation for all visible rows")
  func showUsesOneBoundedAggregateObservation() async {
    let statuses = FakeNativeEpisodeServerSaveStatusReading(snapshot: .init(status: .none))
    let episodes = [Self.summary("a"), Self.summary("b"), Self.summary("c")]
    let model = PodcastShowModel(
      itemID: "rss:7", reading: Self.makeReading(episodes: episodes),
      nativeEpisodeIDResolving: StaticNativeEpisodeIDResolving(["a": 1, "b": 2, "c": 3]),
      nativeEpisodeServerSaveStatusReading: statuses)

    #expect(await waitUntil { model.episodes.count == 3 })
    #expect(await waitUntil { statuses.aggregateRowIDs.count == 1 })
    #expect(statuses.aggregateRowIDs == [[1, 2, 3]])
  }

  /// Every attempt-table write re-emits the show's whole status map. When the values for a row
  /// have not moved, the show must not touch its observable maps: those maps are read by every
  /// visible row, so a no-op write would rebuild the list for nothing on each write of a batch.
  @MainActor
  @Test("an unchanged status snapshot is not an observable mutation on the show")
  func unchangedSnapshotDoesNotMutateTheShow() async {
    let snapshot = NativeEpisodeServerSaveStatusSnapshot(
      status: .saved, attemptID: 1, preflightPresence: .absentBeforeRequest)
    let statuses = FakeNativeEpisodeServerSaveStatusReading(snapshot: snapshot)
    let show = PodcastShowModel(
      itemID: "rss:7",
      reading: Self.makeReading(episodes: [Self.summary("9")]),
      nativeEpisodeIDResolving: Self.resolver,
      nativeEpisodeServerSaveStatusReading: statuses)
    #expect(await waitUntil { show.serverSave.serverSaveStatus(for: "9") == .saved })

    let observed = MutationFlag()
    withObservationTracking {
      _ = show.serverSave.serverSaveStatus(for: "9")
      _ = show.serverSave.serverSavePreflightPresence(for: "9")
      _ = show.serverSave.serverSaveAttemptID(for: "9")
      _ = show.serverSave.serverMutationCapability
    } onChange: {
      observed.mark()
    }

    statuses.push(snapshot)
    let settled = await awaitQuiescence("the repeated snapshot", recordingIssue: false) {
      "\(observed.isMarked)"
    }
    #expect(settled.isObserved)
    #expect(observed.isMarked == false)

    statuses.push(.init(status: .removed, attemptID: 1, preflightPresence: .absentBeforeRequest))
    #expect(await waitUntil { show.serverSave.serverSaveStatus(for: "9") == .removed })
    #expect(observed.isMarked)
  }

  private static func makeReading(
    episodes: [PodcastEpisodeSummary], contexts: [PodcastEpisodeContext] = []
  ) -> FakePodcastReading {
    let reading = FakePodcastReading(episodes: episodes)
    for context in contexts { reading.stubEpisode(context) }
    return reading
  }

  private static func summary(_ id: String) -> PodcastEpisodeSummary {
    PodcastEpisodeSummary(
      id: id, title: id, subtitle: nil, episodeDescription: nil, seasonNumber: nil,
      episodeNumber: nil, episodeType: nil, durationSeconds: 120, sizeBytes: nil,
      publishedAt: Date(timeIntervalSince1970: 1_700_000_000), progressSeconds: 0,
      isPlayed: false, isFinished: false, downloadStatus: .notDownloaded,
      isAvailableOnServer: true)
  }

  private static func context(episodeID: String) -> PodcastEpisodeContext {
    PodcastEpisodeContext(
      episode: summary(episodeID), showTitle: "Show", showAuthor: "Author",
      artworkURL: nil, artworkFeedURL: nil)
  }
}

private final class MutationFlag: @unchecked Sendable {
  private let lock = NSLock()
  private var marked = false
  func mark() { lock.withLock { marked = true } }
  var isMarked: Bool { lock.withLock { marked } }
}

extension FakeNativeEpisodeServerSaveStatusReading {
  /// The row ids of every aggregate read, whether by `statuses` or by an observation opening.
  fileprivate var aggregateRowIDs: [[Int64]] {
    calls.compactMap { call -> [Int64]? in
      switch call {
      case .statuses(_, let episodeIDs), .observeStatuses(_, let episodeIDs): episodeIDs
      default: nil
      }
    }
  }
}
