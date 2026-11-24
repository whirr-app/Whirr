import ABSApi
import AppModel
import DesignSystem
import MediaPlayer
import Persistence
import PlayerCore
import SyncEngine
import TestSupport
import Testing
import UIKit

@testable import Whirr

/// A valid 1x1 transparent PNG, small enough to inline. `UIImage(data:)` decodes it whatever
/// `Content-Type` `FakeCoverHTTPClient` sends.
let onePixelPNGData = Data(
  base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
)!

extension NowPlayingMetadataTests {

  static func chapters() -> PlaybackChapterMap {
    PlaybackChapterMap(chapters: [
      PlaybackChapter(id: "c0", title: "Chapter One", start: 0, end: 50),
      PlaybackChapter(id: "c1", title: "Chapter Two", start: 50, end: 100),
      PlaybackChapter(id: "c2", title: "Chapter Three", start: 100, end: 150),
    ])
  }

  static func item(id: String = "item-1", episodeID: String? = nil) -> PlayerItem {
    let timeline = try! PlaybackTimeline(tracks: [PlaybackTrack(index: 0, duration: 150)])
    return PlayerItem(id: id, episodeID: episodeID, timeline: timeline, chapters: chapters())
  }

  static func state(
    phase: PlayerPhase = .playing, position: Double = 10, rate: Double = 1.0,
    itemId: String = "item-1", episodeID: String? = nil
  ) -> PlayerState {
    PlayerState(
      phase: phase, item: item(id: itemId, episodeID: episodeID),
      currentTrackIndex: 0, globalPosition: position, rate: rate)
  }

  /// A state whose item carries an arbitrary chapter map, for the chapterless and blank-title
  /// books that the shared `chapters()` fixture cannot express.
  static func state(
    chapters chapterMap: PlaybackChapterMap, phase: PlayerPhase = .playing, position: Double = 10,
    rate: Double = 1.0
  ) -> PlayerState {
    let timeline = try! PlaybackTimeline(tracks: [PlaybackTrack(index: 0, duration: 150)])
    return PlayerState(
      phase: phase,
      item: PlayerItem(id: "item-1", episodeID: nil, timeline: timeline, chapters: chapterMap),
      currentTrackIndex: 0, globalPosition: position, rate: rate)
  }

  func progressEvent(itemId: String = "item-1", phase: PlayerPhase, currentTime: Double, sequence: Int = 1)
    -> PlaybackProgressEvent
  {
    PlaybackProgressEvent(sequence: sequence, itemId: itemId, phase: phase, currentTime: currentTime, listenedDelta: 0)
  }

  func makeAdapter(
    player: FakeAdapterPlaybackControlling, sink: FakeNowPlayingInfoSink,
    itemInfoProvider: any NowPlayingItemInfoProviding,
    playbackAvailability: (any PlaybackAvailabilityProviding)? = nil,
    now: @escaping @Sendable () -> Date = { Date() }
  ) -> NowPlayingMetadataAdapter {
    NowPlayingMetadataAdapter(
      sink: sink, controller: player, itemInfoProvider: itemInfoProvider, displayScale: 2,
      playbackAvailability: playbackAvailability, now: now)
  }

  static func episodeArtworkFixture() throws -> (
    episode: ArtworkSource, show: ArtworkSource, info: NowPlayingItemInfo
  ) {
    let feedURL = URL(string: "https://feed.test/show.xml")!
    let episode = ArtworkSource.rss(
      try #require(
        RSSArtworkSource(
          feedIdentity: "rss:1", artworkURL: URL(string: "https://img.test/episode.jpg")!,
          feedURL: feedURL)))
    let show = ArtworkSource.rss(
      try #require(
        RSSArtworkSource(
          feedIdentity: "rss:1", artworkURL: URL(string: "https://img.test/show.jpg")!,
          feedURL: feedURL)))
    return (
      episode, show,
      NowPlayingItemInfo(
        title: "Native Episode", author: "Native Show", artworkSource: episode,
        fallbackArtworkSource: show)
    )
  }

  static func requestedWidth(from request: HTTPRequest) -> Int? {
    guard let components = URLComponents(url: request.url, resolvingAgainstBaseURL: false) else { return nil }
    return components.queryItems?.first(where: { $0.name == "width" })?.value.flatMap(Int.init)
  }

  func makeCoverImageClient() throws -> CoverImageClient {
    let server = try ABSServerConfig(
      url: #require(URL(string: "https://books.example.test")))
    return CoverImageClient(
      server: server, httpClient: FakeCoverHTTPClient(imageData: onePixelPNGData),
      memoryCapacity: 0)
  }
}

actor NowPlayingArtworkKeyRecorder {
  private(set) var values: [ArtworkKey] = []

  func record(_ key: ArtworkKey) {
    values.append(key)
  }
}

actor ControllableNowPlayingArtworkLoader {
  private struct PendingFetch {
    let id: UUID
    let continuation: CheckedContinuation<ArtworkFetchOutcome, Never>
  }

  private var started: Set<String> = []
  private var cancelled: Set<String> = []
  private var continuations: [String: PendingFetch] = [:]

  func load(_ key: ArtworkKey) async -> ArtworkFetchOutcome {
    let requestID = UUID()
    return await withTaskCancellationHandler {
      guard Task.isCancelled == false else { return ArtworkFetchOutcome.failed }
      return await withCheckedContinuation {
        (continuation: CheckedContinuation<ArtworkFetchOutcome, Never>) in
        started.insert(key.itemID)
        continuations[key.itemID] = PendingFetch(id: requestID, continuation: continuation)
      }
    } onCancel: {
      Task { await self.cancel(itemID: key.itemID, requestID: requestID) }
    }
  }

  func hasStarted(itemID: String) -> Bool {
    started.contains(itemID)
  }

  /// `nil` means the fetch completed and proved the item has no usable artwork (`.unavailable`).
  /// Only that ending may promote generated art. Transport failures call `finish(itemID:outcome:)`
  /// with `.failed`.
  func finish(itemID: String, image: UIImage?) {
    finish(itemID: itemID, outcome: image.map(ArtworkFetchOutcome.image) ?? .unavailable)
  }

  func finish(itemID: String, outcome: ArtworkFetchOutcome) {
    continuations.removeValue(forKey: itemID)?.continuation.resume(returning: outcome)
  }

  /// Lets a test arrange the next load for an item before the adapter starts it, so a retry can
  /// be answered without racing `waitUntilStarted`.
  func clearStarted(itemID: String) {
    started.remove(itemID)
  }

  /// Bounded by progress, not a yield budget: the artwork task hops off this actor, so a budget
  /// bounds only this task's reschedules and can expire under load before the request starts.
  /// `awaitCondition` counts serviced waiting and unwinds on cancellation; the suite's
  /// `.timeLimit` is the backstop. Polls run on the caller's isolation: the load starts from the
  /// main actor, so only polls queued there stretch the budget when it is busy.
  func waitUntilStarted(
    itemID: String,
    isolation: isolated (any Actor)? = #isolation,
    sourceLocation: SourceLocation = #_sourceLocation
  ) async {
    _ = await awaitCondition(
      "artwork load started for \(itemID)",
      isolation: isolation,
      sourceLocation: sourceLocation,
      observing: { "started=\(await self.started.sorted())" },
      until: { await self.started.contains(itemID) })
  }

  func waitUntilCancelled(
    itemID: String,
    isolation: isolated (any Actor)? = #isolation,
    sourceLocation: SourceLocation = #_sourceLocation
  ) async {
    _ = await awaitCondition(
      "artwork load cancelled for \(itemID)",
      isolation: isolation,
      sourceLocation: sourceLocation,
      observing: { "cancelled=\(await self.cancelled.sorted())" },
      until: { await self.cancelled.contains(itemID) })
  }

  private func cancel(itemID: String, requestID: UUID) {
    cancelled.insert(itemID)
    guard let pending = continuations[itemID], pending.id == requestID else { return }
    continuations[itemID] = nil
    pending.continuation.resume(returning: .failed)
  }
}

/// Episode-aware `NowPlayingItemInfoProviding` double. Resolves on the full `(item, episode)`
/// identity, as `LibraryBackedNowPlayingItemInfoProvider` does, so these tests can prove Now
/// Playing names the episode. `FakeNowPlayingItemInfoProviding` stays
/// item-only, which keeps the audiobook path pinned through the protocol's item-only default.
@MainActor
final class FakeEpisodeAwareNowPlayingItemInfoProviding: NowPlayingItemInfoProviding {
  var infoByItemID: [String: NowPlayingItemInfo] = [:]
  var infoByEpisodeID: [String: NowPlayingItemInfo] = [:]
  /// Every episode id the adapter asked about, in order. `nil` marks an item-level (audiobook) ask.
  private(set) var requestedEpisodeIDs: [String?] = []

  func nowPlayingItemInfo(forItemID itemID: String) -> NowPlayingItemInfo? {
    nowPlayingItemInfo(forItemID: itemID, episodeID: nil)
  }

  func nowPlayingItemInfo(forItemID itemID: String, episodeID: String?) -> NowPlayingItemInfo? {
    requestedEpisodeIDs.append(episodeID)
    guard let episodeID else { return infoByItemID[itemID] }
    return infoByEpisodeID[episodeID] ?? infoByItemID[itemID]
  }
}

/// A hand-wound clock, so the adapter's provisional-artwork interval is exercised by arithmetic
/// rather than by a test that sleeps for a minute. `Sendable` because the adapter stores the
/// closure and reads it from its artwork task.
nonisolated final class MutableClock: @unchecked Sendable {
  private let lock = NSLock()
  private var current = Date(timeIntervalSinceReferenceDate: 0)

  var now: @Sendable () -> Date {
    { [self] in
      lock.lock()
      defer { lock.unlock() }
      return current
    }
  }

  func advance(by seconds: TimeInterval) {
    lock.lock()
    defer { lock.unlock() }
    current = current.addingTimeInterval(seconds)
  }
}
