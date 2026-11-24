import ABSApi
import AppModel
import CoreSupport
import DesignSystem
import MediaPlayer
import Persistence
import PlayerCore
import SyncEngine
import UIKit

/// Returns the outcome, not just an image: only a completed fetch that proved the item has no
/// usable artwork may promote the lock screen to generated art. A bare `UIImage?` made a flaky
/// moment at item load look like a coverless item.
typealias NowPlayingArtworkImageLoader =
  @Sendable (_ key: ArtworkKey, _ client: any ArtworkServing) async -> ArtworkFetchOutcome

/// Publishes lock-screen/Control Center Now Playing metadata from `PlaybackControlling`
/// (ARCHITECTURE.md). The system extrapolates elapsed time from the published rate, so this
/// republishes only at semantic boundaries (item load, seek, pause/play, rate or chapter change),
/// found by diffing a snapshot (item id, episode id, phase, rate, chapter index, why a remote
/// stream is unavailable) against the last published, not on every `progressEvents` tick.
///
/// Title/author come from `NowPlayingItemInfoProviding` on the full `(item, episode)` identity, so
/// an episode names itself rather than its show; artwork comes from the bounded, coalesced
/// `any ArtworkServing` and stays item-scoped (a show has one cover, and the route is item-level).
@MainActor
final class NowPlayingMetadataAdapter {
  private let sink: any NowPlayingInfoSink
  private let controller: any PlaybackControlling
  private let itemInfoProvider: any NowPlayingItemInfoProviding
  private let coverImageClient: (any ArtworkServing)?
  private let artworkImageLoader: NowPlayingArtworkImageLoader
  private let playbackAvailability: (any PlaybackAvailabilityProviding)?
  /// Scales the expanded player's artwork request for this idiom into the pixel width this adapter
  /// requests, so it tracks denser screens like the other high-fidelity surfaces.
  /// Injected from SwiftUI's window environment through `RootView`/`PlaybackHardware`, so this
  /// adapter never reaches through UIKit's process-wide screen singleton.
  private let displayScale: CGFloat
  private let now: @Sendable () -> Date

  private var progressTask: Task<Void, Never>?
  private var artworkTask: Task<Void, Never>?
  private var artworkTaskID: UUID?
  private var lastPublished: PublishedSnapshot?
  /// What the system extrapolates from: the elapsed time last handed to it, when, and at what rate.
  private var publishedElapsed: (value: Double, at: Date, rate: Double)?

  /// How far the player may run from the system's extrapolation before elapsed time is republished.
  /// Trimmed pauses make the position outrun wall time x rate; untrimmed playback stays inside.
  static let elapsedDriftThreshold: TimeInterval = 1
  /// `provisionalSince` separates "this item has no cover" from "nobody has found one yet". A
  /// generated paperback published after an `.unavailable` fetch is a stand-in with a timestamp;
  /// real artwork is final and carries `nil`.
  private var retainedArtwork:
    (
      itemID: String,
      source: ArtworkSource?,
      revision: ArtworkRevision,
      artwork: MPMediaItemArtwork,
      provisionalSince: Date?
    )?
  /// Bounds the re-asking for the current `(itemID, source, revision)`; reset whenever that
  /// identity changes.
  private var provisionalArtworkAttempts = 0

  /// How long a provisional verdict stands before a semantic boundary may spend another request on
  /// it. A listener who pauses and resumes twice a minute must not become two 404s a minute, and a
  /// server still attaching a fresh cover needs well under a minute.
  static let provisionalArtworkRetryInterval: TimeInterval = 60
  /// Backstop for a coverless item, so it stops paying for requests over a long listen. The
  /// interval is the primary bound; a count alone would be spent in seconds by a pause/play burst.
  static let maximumProvisionalArtworkAttempts = 3

  private struct PublishedSnapshot: Equatable {
    let itemID: String
    /// Part of the boundary identity: an auto-advance between two episodes of the same show moves
    /// nothing else in this snapshot (same item, phase, rate, usually chapter index), so keying on
    /// the item alone leaves the lock screen, CarPlay and Control Center on the previous episode.
    let episodeID: String?
    let phase: PlayerPhase
    let rate: Double
    let chapterIndex: Int?
    let unavailableReason: ServerUnreachableReason?
    /// Part of the identity because `PlayerCore` may extend a declared duration that under-ran the
    /// real audio, and nothing else in this snapshot moves when it does. Without it the lock
    /// screen, Control Center and CarPlay keep the wrong length (and zero remaining time over
    /// still-playing audio) until the next play/pause, seek or chapter boundary.
    let totalDuration: Double
  }

  init(
    sink: any NowPlayingInfoSink,
    controller: any PlaybackControlling,
    itemInfoProvider: any NowPlayingItemInfoProviding,
    coverImageClient: (any ArtworkServing)? = nil,
    displayScale: CGFloat,
    playbackAvailability: (any PlaybackAvailabilityProviding)? = nil,
    artworkImageLoader: @escaping NowPlayingArtworkImageLoader = { key, client in
      await ArtworkImagePipeline.shared.outcome(
        for: key, priority: .playbackCritical, client: client)
    },
    now: @escaping @Sendable () -> Date = { Date() }
  ) {
    self.sink = sink
    self.controller = controller
    self.itemInfoProvider = itemInfoProvider
    self.coverImageClient = coverImageClient
    self.displayScale = displayScale
    self.playbackAvailability = playbackAvailability
    self.artworkImageLoader = artworkImageLoader
    self.now = now
    playbackAvailability?.setChangeHandler { [weak self] in
      self?.publish(force: false)
    }

    // Whatever is already loaded at construction (adapter wired mid-session) is published
    // immediately rather than waiting for the next boundary event.
    publish(force: true)

    let events = controller.progressEvents
    progressTask = Task { [weak self] in
      for await _ in events {
        self?.publish(force: false)
      }
    }
  }

  deinit {
    progressTask?.cancel()
    artworkTask?.cancel()
  }

  /// Clears Now Playing info regardless of controller state. Logout is the one boundary
  /// `PlayerCore` has no signal for. Idempotent.
  func clear() {
    cancelArtworkTask()
    retainedArtwork = nil
    provisionalArtworkAttempts = 0
    sink.nowPlayingInfo = nil
    lastPublished = nil
    publishedElapsed = nil
  }

  /// Rechecks the account-scoped availability after the process-lifetime hardware is rebound to a
  /// newly built environment. This is a semantic boundary, not a position-tick callback.
  func refreshPlaybackAvailability() {
    publish(force: false)
  }

  private func publish(force: Bool) {
    let state = controller.state
    guard let item = state.item, state.phase != .idle else {
      clear()
      return
    }

    let chapterIndex = chapterIndex(for: item, at: state.globalPosition)
    let unavailableReason = playbackAvailability?.unavailableReason
    let snapshot = PublishedSnapshot(
      itemID: item.id, episodeID: item.episodeID, phase: state.phase, rate: state.rate,
      chapterIndex: chapterIndex, unavailableReason: unavailableReason,
      totalDuration: item.timeline.totalDuration)
    let chapterWindow = NowPlayingChapterWindow.chapter(for: state)
    let elapsed =
      chapterWindow.map { min(max(state.globalPosition - $0.start, 0), $0.end - $0.start) }
      ?? state.globalPosition
    // Skipped (trimmed) audio advances the position faster than the published rate predicts, and
    // nothing else in the snapshot moves, so the lock-screen clock would fall behind unboundedly.
    let drifted =
      state.phase == .playing
      && (publishedElapsed.map {
        let extrapolated = $0.value + now().timeIntervalSince($0.at) * $0.rate
        return abs(elapsed - extrapolated) > Self.elapsedDriftThreshold
      } ?? false)
    guard force || drifted || snapshot != lastPublished else { return }
    lastPublished = snapshot

    var info: [String: Any] = [:]
    let itemInfo = itemInfoProvider.nowPlayingItemInfo(
      forItemID: item.id, episodeID: item.episodeID)
    // A chaptered audiobook names the chapter in the title slot and moves the book to the album
    // slot, so a listener can tell where they are without unlocking; no chapters or a blank
    // chapter title keeps the book title and no album. Audiobooks only: an episode's name stays in
    // the title slot. The slot never scrolls, so the chapter goes out compact
    // ("20: The Clock-Tower").
    let bookTitle = itemInfo?.title
    let chapterTitle =
      item.episodeID == nil
      ? item.chapters.currentChapterTitle(at: state.globalPosition).map(ChapterTitleFormatting.compact)
      : nil
    if let chapterTitle, let bookTitle {
      info[MPMediaItemPropertyTitle] = chapterTitle
      info[MPMediaItemPropertyAlbumTitle] = bookTitle
    } else if let title = chapterTitle ?? bookTitle {
      info[MPMediaItemPropertyTitle] = title
    }
    // The lock screen, Control Center and CarPlay take their transport look from the audio session
    // and the published rate, so a dead stream already draws a Play button. None can show why
    // pressing it does nothing. The subtitle slot is rendered verbatim and the mini-player already
    // gives it to the status. Title and album keep naming the title, so identity is unaffected.
    if let unavailableReason {
      info[MPMediaItemPropertyArtist] = PlaybackUnavailableCopy.subtitle(for: unavailableReason)
    } else if let author = itemInfo?.author {
      info[MPMediaItemPropertyArtist] = author
    }
    // Chapter-scoped timeline for a chaptered audiobook (see `NowPlayingChapterWindow`), since a
    // 20-hour span makes the scrubber unusable. `RemoteCommandAdapter` maps an incoming scrub back
    // through the same window.
    if let chapter = chapterWindow {
      info[MPMediaItemPropertyPlaybackDuration] = chapter.end - chapter.start
    } else {
      info[MPMediaItemPropertyPlaybackDuration] = item.timeline.totalDuration
    }
    info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = elapsed
    // Actual rate is 0 while not playing, so the system does not extrapolate elapsed time from a
    // rate that is not advancing. DefaultPlaybackRate always reflects the set rate, so a remote
    // "play" resumes at the rate the user chose.
    let publishedRate = state.phase == .playing ? state.rate : 0.0
    info[MPNowPlayingInfoPropertyPlaybackRate] = publishedRate
    publishedElapsed = (elapsed, now(), publishedRate)
    info[MPNowPlayingInfoPropertyDefaultPlaybackRate] = state.rate
    info[MPNowPlayingInfoPropertyMediaType] = MPNowPlayingInfoMediaType.audio.rawValue
    if let chapterIndex {
      // Zero-based: the first chapter is number 0.
      info[MPNowPlayingInfoPropertyChapterNumber] = chapterIndex
      info[MPNowPlayingInfoPropertyChapterCount] = item.chapters.chapters.count
    }
    let source = resolvedArtworkSource(forItemID: item.id, itemInfo: itemInfo)
    if retains(itemID: item.id, source: source, revision: Self.revision(of: itemInfo)) {
      info[MPMediaItemPropertyArtwork] = retainedArtwork?.artwork
    }

    sink.nowPlayingInfo = info
    loadArtworkIfNeeded(forItemID: item.id, itemInfo: itemInfo)
  }

  private func chapterIndex(for item: PlayerItem, at position: Double) -> Int? {
    guard let current = item.chapters.currentChapter(at: position) else { return nil }
    return item.chapters.chapters.firstIndex(of: current)
  }

  private func loadArtworkIfNeeded(forItemID itemID: String, itemInfo: NowPlayingItemInfo?) {
    guard let coverImageClient else { return }
    let source = resolvedArtworkSource(forItemID: itemID, itemInfo: itemInfo)
    // A native feed with no declared show artwork has no network route. Retain the generated
    // fallback used for a completed provider miss without ever falling through to ABS.
    if isRSSItemWithoutArtwork(forItemID: itemID, itemInfo: itemInfo) {
      cancelArtworkTask()
      publishGeneratedArtworkIfNeeded(forItemID: itemID, itemInfo: itemInfo, source: source)
      return
    }
    guard let source else { return }
    let revision = Self.revision(of: itemInfo)
    if let retained = retainedArtwork, retains(itemID: itemID, source: source, revision: revision) {
      // Final artwork ends the question. A provisional retention only postpones it: once the
      // interval has elapsed and attempts remain, the next boundary asks again.
      guard let provisionalSince = retained.provisionalSince,
        provisionalArtworkAttempts < Self.maximumProvisionalArtworkAttempts,
        now().timeIntervalSince(provisionalSince) >= Self.provisionalArtworkRetryInterval
      else { return }
      #if DEBUG
        DeviceTraceLog.emit(
          "WHIRRART nowplaying.retry item=\(itemID) attempt=\(provisionalArtworkAttempts + 1)")
      #endif
      // `retainedArtwork` is kept: the generated cover stays on the lock screen while the retry
      // is in flight, so re-asking causes no flicker.
      cancelArtworkTask()
    } else {
      cancelArtworkTask()
      retainedArtwork = nil
      provisionalArtworkAttempts = 0
    }
    // `CoverRequest.init` quantises internally, so the raw pixel width is passed, as
    // `CoverImageView`'s callers do. The expanded player keys its high-fidelity request on the same
    // `artworkRequestSize`, so one cache entry serves both; this runs at item load, often with no
    // player on screen, and an unwarmed rung is a cold fetch a flaky connection would fail.
    let variant = ArtworkVariant.highFidelity(
      displaySize: Double(ExpandedPlayerView.artworkRequestSize),
      displayScale: Double(displayScale))
    let resolvedWidth = variant.pixelWidth
    let key = ArtworkKey(
      source: source,
      itemID: itemID,
      variant: variant,
      revision: revision)

    // The show's cover under the same geometry, for an episode image that cannot be had.
    let fallbackKey = key.fallingBack(to: itemInfo?.fallbackArtworkSource)
    let artworkImageLoader = self.artworkImageLoader
    let taskID = UUID()
    artworkTaskID = taskID
    artworkTask = Task { [weak self] in
      guard let self else { return }
      defer {
        if self.artworkTaskID == taskID {
          self.artworkTask = nil
          self.artworkTaskID = nil
        }
      }
      let outcome = await artworkImageLoader(key, coverImageClient)
      guard
        Task.isCancelled == false,
        self.controller.state.item?.id == itemID,
        self.resolvedArtworkSource(
          forItemID: itemID,
          itemInfo: self.itemInfoProvider.nowPlayingItemInfo(
            forItemID: itemID, episodeID: self.controller.state.item?.episodeID)) == source
      else { return }
      // The show's cover stands in for an episode image that is gone (final) or could not be reached
      // this attempt (provisional, so a later boundary asks for the episode's again).
      let fallback =
        outcome.image == nil
        ? await Self.fallbackImage(fallbackKey, coverImageClient, artworkImageLoader) : nil
      guard Task.isCancelled == false else { return }
      let resolved: UIImage?
      let provisional: Bool
      switch outcome {
      case .image(let fetched):
        resolved = fetched
        provisional = false
      case .unavailable where fallback != nil:
        resolved = fallback
        provisional = false
      case .failed where fallback != nil:
        resolved = fallback
        provisional = true
      case .unavailable:
        // A completed fetch proved there is no usable artwork, so the lock screen draws the
        // generated paperback the in-app surfaces use (`CoverPlaceholder`, rasterised once per
        // item, bounded by the `retainedArtwork` guard). Not final: a book added minutes ago can
        // 404 for a cover it is still attaching, so the fallback is published and the slot stays
        // open (see `provisionalSince` and the interval check in `loadArtworkIfNeeded`).
        resolved = Self.generatedArtwork(
          title: itemInfo?.title, author: itemInfo?.author, pixelWidth: resolvedWidth)
        provisional = true
      case .failed:
        // Offline, a timeout, a 5xx, a cancellation: evidence about this attempt, not the item.
        // Retain nothing, so the next semantic boundary fetches again (retained generated art would
        // pin a placeholder all session). A failed provisional retry keeps the generated cover and
        // spends the attempt, so a failing route is not re-asked at every boundary.
        self.noteProvisionalRetryEnded(itemID: itemID, source: source, revision: revision)
        return
      }
      guard let image = resolved else {
        self.noteProvisionalRetryEnded(itemID: itemID, source: source, revision: revision)
        return
      }
      let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
      #if DEBUG
        DeviceTraceLog.emit(
          "WHIRRART nowplaying.resolved item=\(itemID) provisional=\(provisional)")
      #endif
      self.retainedArtwork = (itemID, source, revision, artwork, provisional ? self.now() : nil)
      self.provisionalArtworkAttempts = provisional ? self.provisionalArtworkAttempts + 1 : 0
      self.sink.nowPlayingInfo?[MPMediaItemPropertyArtwork] = artwork
    }
  }

  private static func fallbackImage(
    _ key: ArtworkKey?, _ client: any ArtworkServing, _ loader: NowPlayingArtworkImageLoader
  ) async -> UIImage? {
    guard let key else { return nil }
    return await loader(key, client).image
  }

  /// Restarts the clock on a provisional retention whose retry ended without an image, and spends
  /// one of its attempts. Without this a retry that fails leaves an already-elapsed timestamp
  /// behind and every subsequent boundary re-fetches.
  private func noteProvisionalRetryEnded(
    itemID: String, source: ArtworkSource?, revision: ArtworkRevision
  ) {
    guard retains(itemID: itemID, source: source, revision: revision),
      var retained = retainedArtwork, retained.provisionalSince != nil
    else { return }
    retained.provisionalSince = now()
    retainedArtwork = retained
    provisionalArtworkAttempts += 1
  }

  private func cancelArtworkTask() {
    artworkTask?.cancel()
    artworkTask = nil
    artworkTaskID = nil
  }

  private func publishGeneratedArtworkIfNeeded(
    forItemID itemID: String, itemInfo: NowPlayingItemInfo?, source: ArtworkSource?
  ) {
    guard retains(itemID: itemID, source: source, revision: .unversioned) == false else { return }
    let pixelWidth = Int((ExpandedPlayerView.artworkRequestSize * displayScale).rounded())
    guard
      let image = Self.generatedArtwork(
        title: itemInfo?.title, author: itemInfo?.author, pixelWidth: pixelWidth)
    else { return }
    let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
    // Final, not provisional: a native feed with no declared show artwork has no route to re-ask.
    retainedArtwork = (itemID, source, .unversioned, artwork, nil)
    provisionalArtworkAttempts = 0
    sink.nowPlayingInfo?[MPMediaItemPropertyArtwork] = artwork
  }

  private func retains(
    itemID: String, source: ArtworkSource?, revision: ArtworkRevision
  ) -> Bool {
    guard let retainedArtwork else { return false }
    return retainedArtwork.itemID == itemID && retainedArtwork.source == source
      && retainedArtwork.revision == revision
  }

  private static func revision(of itemInfo: NowPlayingItemInfo?) -> ArtworkRevision {
    itemInfo?.artworkRevision ?? .unversioned
  }

  private func resolvedArtworkSource(
    forItemID itemID: String, itemInfo: NowPlayingItemInfo?
  ) -> ArtworkSource? {
    // A native feed with no declared artwork has no resolved network source. Keeping this as nil
    // marks the generated fallback and lets a later declared URL invalidate it.
    if isRSSItemWithoutArtwork(forItemID: itemID, itemInfo: itemInfo) {
      return nil
    }
    return itemInfo?.artworkSource ?? coverImageClient?.defaultSource
  }

  private func isRSSItemWithoutArtwork(
    forItemID itemID: String, itemInfo: NowPlayingItemInfo?
  ) -> Bool {
    PodcastSourceIdentity(itemId: itemID)?.rssFeedId != nil && itemInfo?.artworkSource == nil
  }

  /// The bitmap form of the generated paperback cover `CoverPlaceholder` draws in-app, so the lock
  /// screen agrees with the app about what an item with no server-side artwork looks like.
  /// Nil when there is no title to set, the same condition `CoverPlaceholder` applies before
  /// promoting its blank tile to generated art.
  private static func generatedArtwork(title: String?, author: String?, pixelWidth: Int) -> UIImage? {
    guard
      let cgImage = GeneratedCoverArtRasterizer.cgImage(
        title: title, author: author, pixelWidth: pixelWidth)
    else {
      return nil
    }
    return UIImage(cgImage: cgImage)
  }

  /// Test seam only: awaits any in-flight artwork fetch so `NowPlayingMetadataTests` can assert on
  /// `MPMediaItemPropertyArtwork` deterministically instead of polling (no sleeps in tests).
  func waitForPendingArtworkForTesting() async {
    let currentTask = artworkTask
    await currentTask?.value
  }

  var retainedArtworkItemIDForTesting: String? { retainedArtwork?.itemID }
  var retainedArtworkCountForTesting: Int { retainedArtwork == nil ? 0 : 1 }
  var hasPendingArtworkForTesting: Bool { artworkTask != nil }
  var provisionalArtworkAttemptsForTesting: Int { provisionalArtworkAttempts }
  var retainedArtworkIsProvisionalForTesting: Bool { retainedArtwork?.provisionalSince != nil }
}
