import AppModel
import Foundation
import Persistence
import Testing

@testable import Whirr

/// The Audiobookshelf half of On Apple Watch (ADR 0021) and the two sections
/// both halves share.
@Suite("On Apple Watch: Audiobookshelf rows")
struct OnAppleWatchAudiobookshelfPresentationTests {
  private static let book = ABSWatchCopyKey(itemId: "book-1", episodeId: nil)
  private static let otherBook = ABSWatchCopyKey(itemId: "book-2", episodeId: nil)
  private static let watchBook = ABSWatchCopyKey(itemId: "book-3", episodeId: nil)
  private static let episode = ABSWatchCopyKey(itemId: "show-1", episodeId: "episode-1")

  @Test("a stored state reads as the screen's sentence, with the Watch's reason")
  func storedStates() {
    #expect(status(.delivered) == .onWatch)
    #expect(status(.declined(.storageFull)) == .watchStorageFull)
    #expect(status(.declined(.signedOut)) == .setUpWatch)
    #expect(status(.declined(.invalid)) == .couldNotDownload)
    #expect(status(.failed(.notOnServer)) == .notOnServer)
    #expect(status(.failed(.noAudio)) == .noAudioToDownload)
    #expect(status(.failed(.network)) == .waitingForWiFiOnWatch, "the Watch retries by itself")
    for reason: WatchCopyState.FailureReason? in [.server, .tooLarge, .couldNotDownload, nil] {
      #expect(status(.failed(reason)) == .couldNotDownload, "\(String(describing: reason))")
    }
    #expect(status(.removed(.watch)) == .removedOnWatch)
  }

  @Test("before the Watch acknowledges a request, the row reads the Watch's readiness")
  func unacknowledgedRequestsReadReadiness() {
    for state: WatchCopyState in [.wanted, .waitingForWatch, .sending] {
      #expect(status(state, readiness: .unknown) == .openWhirrOnWatch)
      #expect(status(state, readiness: .ready) == .waitingForWatch)
      #expect(status(state, readiness: .needsUpdate) == .updateWhirrOnWatch)
      #expect(status(state, readiness: .setUpWatch) == .setUpWatch)
    }
  }

  @Test("a missing Watch app overrides every live state and keeps a Watch removal")
  func missingWatchApp() {
    for state: WatchCopyState in [.wanted, .sending, .delivered, .failed(nil), .declined(.storageFull)] {
      #expect(status(state, readiness: .notInstalled) == .watchAppNotInstalled)
    }
    #expect(status(.removed(.watch), readiness: .notInstalled) == .removedOnWatch)
  }

  @Test("the Watch's report on the row's revision gives progress, parts and the Wi-Fi hold")
  func groupReport() {
    func sending(_ group: ABSWatchGroup) -> OnAppleWatchStatus {
      status(.sending, group: group)
    }
    #expect(sending(Self.group(.queued)) == .waitingForWatch)
    #expect(
      sending(Self.group(.downloading, progress: 0.4, tracks: 12, completed: 3))
        == .downloadingOnWatch(progress: 0.4, parts: OnAppleWatchParts(completed: 3, total: 12)))
    #expect(
      sending(Self.group(.downloading, key: Self.episode, progress: 0.4))
        == .downloadingOnWatch(progress: 0.4, parts: nil), "an episode is one file")
    #expect(
      sending(Self.group(.downloading, progress: nil, tracks: 1, completed: 0))
        == .downloadingOnWatch(progress: nil, parts: nil), "a one-file book names no parts")
    #expect(sending(Self.group(.waitingForNetwork)) == .waitingForWiFiOnWatch)
    #expect(sending(Self.group(.ready)) == .onWatch)
    #expect(sending(Self.group(.failed)) == .couldNotDownload)
    #expect(sending(Self.group(.declined, declineReason: .storageFull)) == .watchStorageFull)
    #expect(sending(Self.group(.removed)) == .removedOnWatch)
  }

  @Test("a phone removal is left out; a Watch download offers Remove and no recovery")
  func rows() {
    let rows = OnAppleWatchPresentation.rows(
      [
        Self.row(.delivered, key: Self.book, requestedAt: 30),
        Self.row(.removed(.phone), key: Self.otherBook, requestedAt: 20),
        Self.row(.removed(.watch), key: Self.episode, subtitle: "The Show", requestedAt: 10),
        Self.row(.failed(nil), key: Self.watchBook, requestedAt: nil),
      ],
      readiness: .ready)

    #expect(rows.map(\.id) == ["abs:book-1/", "abs:show-1/episode-1", "abs:book-3/"])
    #expect(rows.map(\.kind) == [.book, .episode, .book])
    #expect(
      rows.map(\.target)
        == [.audiobookshelf(Self.book), .audiobookshelf(Self.episode), .audiobookshelf(Self.watchBook)])
    #expect(rows.map(\.status) == [.onWatch, .removedOnWatch, .couldNotDownload])
    #expect(rows.map(\.action) == [nil, .sendAgain, nil], "no Try Again for the Watch's own")
    #expect(rows.map(\.canRemove) == [true, false, true])
    #expect(rows.map(\.subtitle) == ["", "The Show", ""])
    #expect(rows.map(\.artworkItemID) == ["book-1", "show-1", "book-3"])
  }

  @Test("sections split books from episodes, newest request first, the Watch's own last")
  func sections() {
    let sections = OnAppleWatchPresentation.sections(
      rss: [Self.screenRow("rss:1", .episode, 10), Self.screenRow("rss:2", .episode, 40)],
      audiobookshelf: [
        Self.screenRow("abs:b1", .book, 20), Self.screenRow("abs:b2", .book, nil),
        Self.screenRow("abs:b3", .book, 30), Self.screenRow("abs:e1", .episode, 30),
        Self.screenRow("abs:e2", .episode, nil),
      ])

    #expect(sections.audiobooks.map(\.id) == ["abs:b3", "abs:b1", "abs:b2"])
    #expect(sections.episodes.map(\.id) == ["rss:2", "abs:e1", "rss:1", "abs:e2"])
    #expect(sections.isEmpty == false)
    #expect(OnAppleWatchPresentation.sections(rss: [], audiobookshelf: []).isEmpty)
  }

  // MARK: - Builders

  private func status(
    _ state: WatchCopyState, readiness: WatchABSReadiness = .ready, group: ABSWatchGroup? = nil
  ) -> OnAppleWatchStatus {
    OnAppleWatchPresentation.status(
      for: Self.row(state, key: Self.book, group: group, requestedAt: 10), readiness: readiness)
  }

  private static func row(
    _ state: WatchCopyState, key: ABSWatchCopyKey, subtitle: String? = nil,
    group: ABSWatchGroup? = nil, requestedAt: TimeInterval?
  ) -> ABSWatchCopyRow {
    ABSWatchCopyRow(
      key: key, title: "Title of \(key.itemId)", subtitle: subtitle, state: state,
      revision: requestedAt == nil ? nil : 1, group: group,
      requestedAt: requestedAt.map { Date(timeIntervalSince1970: $0) })
  }

  private static func group(
    _ state: ABSWatchGroup.State, key: ABSWatchCopyKey = book, progress: Double? = nil,
    tracks: Int = 1, completed: Int = 0, declineReason: RSSWatchDeclineReason? = nil
  ) -> ABSWatchGroup {
    ABSWatchGroup(
      itemID: key.itemId, episodeID: key.episodeId, revision: 1, state: state, progress: progress,
      trackCount: tracks, completedTracks: completed, committedBytes: nil,
      declineReason: declineReason, failureReason: nil, title: "", subtitle: nil)
  }

  private static func screenRow(
    _ id: String, _ kind: OnAppleWatchRow.Kind, _ requestedAt: TimeInterval?
  ) -> OnAppleWatchRow {
    OnAppleWatchRow(
      id: id, kind: kind, target: .rss(episodeId: 1), title: id, subtitle: "", artworkItemID: id,
      artworkSource: nil, artworkFallbackSource: nil, artworkRevision: .unversioned,
      status: .onWatch, action: nil, canRemove: true,
      requestedAt: requestedAt.map { Date(timeIntervalSince1970: $0) })
  }
}
