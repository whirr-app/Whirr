import ABSApi
import AppModel
import CoreGraphics
import DesignSystem
import Foundation
import Persistence
import PlayerCore
import SwiftUI
import SyncEngine
import Testing

@testable import Whirr

/// Pure logic behind `ExpandedPlayerView`'s retained-projection and chapter-affordance decisions.
/// Exercised over `(displayedItem, activeItemID, chapterMap)` triples, with no view construction.
@Suite struct ExpandedPlayerPresentationTests {

  private static let noNetwork = ServerReachability.unreachable(
    .noNetworkPath, since: Date(timeIntervalSince1970: 123))
  private static let serverUnreachable = ServerReachability.unreachable(
    .serverUnreachable, since: Date(timeIntervalSince1970: 123))

  // MARK: - Artwork playback emphasis

  @Test("playing artwork grows and gains depth while paused artwork recedes")
  func artworkEmphasisCommunicatesPlaybackIntent() {
    let playing = ExpandedPlayerPresentation.artworkEmphasis(isPlaybackIntended: true)
    let paused = ExpandedPlayerPresentation.artworkEmphasis(isPlaybackIntended: false)

    #expect(playing.scale == 1)
    #expect(paused.scale < playing.scale)
    #expect(paused.scale >= 0.9)
    #expect(playing.shadowOpacity > paused.shadowOpacity)
    #expect(playing.shadowRadius > paused.shadowRadius)
    #expect(playing.shadowOffsetY > paused.shadowOffsetY)
  }

  // MARK: - Remote playback status

  @Test("a stalled stream uses the network-specific copy in both player surfaces")
  func stalledStreamUsesNoNetworkCopy() {
    let status = ExpandedPlayerPresentation.remotePlaybackPresentation(
      phase: .stalled, isStreamingSource: true, reachability: Self.noNetwork)

    #expect(status?.subtitle == PlaybackUnavailableCopy.subtitle(for: .noNetworkPath))
    #expect(status?.banner == ConnectivityStatusCopy.status(for: .noNetworkPath))
  }

  @Test("a stalled stream uses the server-specific copy when the server is unreachable")
  func stalledStreamUsesServerCopy() {
    let status = ExpandedPlayerPresentation.remotePlaybackPresentation(
      phase: .stalled, isStreamingSource: true, reachability: Self.serverUnreachable)

    #expect(status?.subtitle == PlaybackUnavailableCopy.subtitle(for: .serverUnreachable))
    #expect(status?.banner == ConnectivityStatusCopy.status(for: .serverUnreachable))
  }

  @Test("buffering becomes an immediate offline banner once the server is known unreachable")
  func bufferingWhileUnreachableUsesOfflineBannerBeforeTheDebounce() {
    let status = ExpandedPlayerPresentation.statusBanner(
      phase: .buffering, isStreamingSource: true, reachability: Self.serverUnreachable,
      isBufferingDebounced: false)

    guard case .some(.offline(let presentation)) = status else {
      Issue.record("Expected buffering with proven unreachability to use the offline banner")
      return
    }
    #expect(presentation.banner == ConnectivityStatusCopy.status(for: .serverUnreachable))
  }

  @Test("a confirmed stall is not held behind the buffering debounce")
  func stalledStreamUsesOfflineBannerImmediately() {
    let status = ExpandedPlayerPresentation.statusBanner(
      phase: .stalled, isStreamingSource: true, reachability: Self.serverUnreachable,
      isBufferingDebounced: false)

    guard case .some(.offline) = status else {
      Issue.record("Expected a stalled stream to use the offline banner immediately")
      return
    }
  }

  @Test("a followed-podcast stall uses source-neutral Retry copy")
  func nativePodcastStallUsesSourceNeutralRetry() throws {
    let itemID = try #require(PodcastSourceIdentity.rss(feedId: 42)).itemId
    let status = ExpandedPlayerPresentation.statusBanner(
      phase: .stalled,
      isStreamingSource: true,
      reachability: Self.serverUnreachable,
      isBufferingDebounced: false,
      itemID: itemID)

    #expect(
      status
        == .recoverableError(message: "Couldn't continue playing. Try again."))
  }

  @Test("the followed-podcast Retry banner requires a valid streaming identity")
  func nativePodcastRetryDoesNotLeakToLocalOrMalformedPlayback() throws {
    let itemID = try #require(PodcastSourceIdentity.rss(feedId: 42)).itemId
    let local = ExpandedPlayerPresentation.statusBanner(
      phase: .stalled,
      isStreamingSource: false,
      reachability: .unknown,
      isBufferingDebounced: false,
      itemID: itemID)
    let malformed = ExpandedPlayerPresentation.statusBanner(
      phase: .stalled,
      isStreamingSource: true,
      reachability: .unknown,
      isBufferingDebounced: false,
      itemID: "rss:not-a-feed")

    #expect(local == nil)
    #expect(malformed == nil)
  }

  @Test("ordinary buffering remains silent until its existing debounce fires")
  func ordinaryBufferingStillUsesTheDebounce() {
    let beforeDelay = ExpandedPlayerPresentation.statusBanner(
      phase: .buffering, isStreamingSource: true, reachability: .reachable,
      isBufferingDebounced: false)
    let afterDelay = ExpandedPlayerPresentation.statusBanner(
      phase: .buffering, isStreamingSource: true, reachability: .reachable,
      isBufferingDebounced: true)

    #expect(beforeDelay == nil)
    #expect(afterDelay == .some(.buffering))
  }

  @Test("a failed start keeps its own message in the recoverable player banner")
  func recoverableStartFailureUsesItsOwnMessage() {
    let message = "This title is unavailable right now."

    let status = ExpandedPlayerPresentation.statusBanner(
      phase: .recoverableError,
      isStreamingSource: false,
      reachability: .unknown,
      isBufferingDebounced: false,
      startFailureMessage: message
    )

    #expect(status == .recoverableError(message: message))
  }

  @Test("a failed start says so on the mini player, not just inside the expanded one")
  func recoverableStartFailureAnnotatesTheMiniPlayer() {
    let message = "This title is unavailable right now."

    let status = ExpandedPlayerPresentation.miniPlayerStatus(
      author: "An Author",
      phase: .recoverableError,
      isStreamingSource: false,
      reachability: .unknown,
      startFailureMessage: message
    )

    #expect(status.subtitle == message)
    #expect(status.systemImage != nil)
  }

  @Test("a complete local download stays unannotated while unreachable")
  func localPlaybackHasNoRemoteStatus() {
    let miniPlayerStatus = ExpandedPlayerPresentation.miniPlayerStatus(
      author: "Andy Weir", phase: .stalled, isStreamingSource: false,
      reachability: Self.serverUnreachable)
    let banner = ExpandedPlayerPresentation.statusBanner(
      phase: .stalled, isStreamingSource: false, reachability: Self.serverUnreachable,
      isBufferingDebounced: true)

    #expect(miniPlayerStatus.subtitle == "Andy Weir")
    #expect(miniPlayerStatus.systemImage == nil)
    #expect(banner == nil)
  }

  @Test("remote status outranks the author in the mini-player subtitle")
  func remoteStatusOutranksAuthor() {
    let status = ExpandedPlayerPresentation.miniPlayerStatus(
      author: "Andy Weir", phase: .buffering, isStreamingSource: true,
      reachability: Self.noNetwork)

    #expect(status.subtitle == "Offline")
    #expect(status.systemImage == "wifi.slash")
  }

  @Test("healthy playback keeps the existing author subtitle")
  func healthyPlaybackKeepsAuthorSubtitle() {
    let status = ExpandedPlayerPresentation.miniPlayerStatus(
      author: "Andy Weir", phase: .playing, isStreamingSource: true,
      reachability: .reachable)

    #expect(status.subtitle == "Andy Weir")
    #expect(status.systemImage == nil)
  }

  @Test("a regular-width chapter title leads the author in the mini-player subtitle")
  func chapterTitleLeadsAuthorSubtitle() {
    let withAuthor = ExpandedPlayerPresentation.miniPlayerStatus(
      author: "Andy Weir", phase: .playing, isStreamingSource: false,
      reachability: .reachable, chapterTitle: "Chapter 12")
    let withoutAuthor = ExpandedPlayerPresentation.miniPlayerStatus(
      author: nil, phase: .playing, isStreamingSource: false,
      reachability: .reachable, chapterTitle: "Chapter 12")

    #expect(withAuthor.subtitle == "Chapter 12 · Andy Weir")
    #expect(withoutAuthor.subtitle == "Chapter 12")
  }

  @Test("the regular-width mini-player subtitle carries the compact chapter name")
  func chapterTitleIsCompactedInMiniPlayerSubtitle() {
    let status = ExpandedPlayerPresentation.miniPlayerStatus(
      author: "Philip Pullman", phase: .playing, isStreamingSource: false,
      reachability: .reachable, chapterTitle: "Chapter Nineteen: The East India Docks")

    #expect(status.subtitle == "19: The East India Docks · Philip Pullman")
  }

  @Test("playback trouble still outranks a chapter title in the mini-player subtitle")
  func playbackTroubleOutranksChapterTitle() {
    let failed = ExpandedPlayerPresentation.miniPlayerStatus(
      author: "Andy Weir", phase: .recoverableError, isStreamingSource: false,
      reachability: .reachable, startFailureMessage: "Couldn't start", chapterTitle: "Chapter 12")
    let offline = ExpandedPlayerPresentation.miniPlayerStatus(
      author: "Andy Weir", phase: .buffering, isStreamingSource: true,
      reachability: Self.noNetwork, chapterTitle: "Chapter 12")

    #expect(failed.subtitle == "Couldn't start")
    #expect(offline.subtitle == "Offline")
  }

  /// The author-less fallback to the phase is the subtitle's whole behaviour. Inverting the
  /// precedence for an outage must not quietly delete it for items with no author.
  @Test("healthy playback without an author still falls back to the phase")
  func healthyPlaybackWithoutAuthorFallsBackToPhase() {
    let status = ExpandedPlayerPresentation.miniPlayerStatus(
      author: nil, phase: .playing, isStreamingSource: true, reachability: .reachable)

    #expect(status.subtitle == PlaybackModel.Phase.playing.copyText)
    #expect(status.systemImage == nil)
  }

  /// A stall is terminal evidence on its own, so it is actionable before the reachability probe it
  /// triggers has answered. The surfaces must still say something in that window, and nothing
  /// observed says the device lost its own network path.
  @Test("a stall with no reachability answer yet still explains itself as a server problem")
  func stalledStreamWithUnknownReachabilityUsesServerCopy() {
    let status = ExpandedPlayerPresentation.remotePlaybackPresentation(
      phase: .stalled, isStreamingSource: true, reachability: .unknown)

    #expect(status?.banner == ConnectivityStatusCopy.status(for: .serverUnreachable))
    #expect(status?.subtitle == PlaybackUnavailableCopy.subtitle(for: .serverUnreachable))
  }

  @Test("RSS playback ignores ABS reachability and shows no outage banner")
  func rssPlaybackNeverUsesABSOutageCopy() throws {
    let rssItemID = try #require(PodcastSourceIdentity.rss(feedId: 42)).itemId

    let stalled = ExpandedPlayerPresentation.remotePlaybackPresentation(
      phase: .stalled, isStreamingSource: true, reachability: Self.serverUnreachable,
      itemID: rssItemID)
    let buffering = ExpandedPlayerPresentation.statusBanner(
      phase: .buffering, isStreamingSource: true, reachability: Self.serverUnreachable,
      isBufferingDebounced: false, itemID: rssItemID)

    #expect(stalled == nil)
    #expect(buffering == nil)
  }

  // MARK: - Artwork-ambient contrast

  @Test func anUnresolvedAmbientPageUsesTheSelectedAppScheme() {
    #expect(CoverAmbientPalette.fallbackCanvas(for: .dark).mode == .dark)
    #expect(CoverAmbientPalette.fallbackCanvas(for: .light).mode == .light)
  }

  @Test func appAppearanceOwnsTheWindowOutsideTheReader() {
    #expect(CoverAmbientPresentation.windowColorScheme(appPreference: .light) == .light)
    #expect(CoverAmbientPresentation.windowColorScheme(appPreference: nil) == nil)
    #expect(CoverAmbientPresentation.windowColorScheme(appPreference: .dark) == .dark)
  }

  @Test func designSystemLightReaderThemeWinsWhileReaderIsPresented() {
    #expect(
      CoverAmbientPresentation.windowColorScheme(
        appPreference: .dark,
        presentedReaderTheme: DesignSystem.ReaderTheme.light)
        == .light)
  }

  @Test func designSystemDarkReaderThemeWinsWhileReaderIsPresented() {
    #expect(
      CoverAmbientPresentation.windowColorScheme(
        appPreference: .light,
        presentedReaderTheme: DesignSystem.ReaderTheme.dark)
        == .dark)
  }

  @Test func designSystemSepiaReaderThemeMapsToLightWindowSchemeWhileReaderIsPresented() {
    #expect(
      CoverAmbientPresentation.windowColorScheme(
        appPreference: .dark,
        presentedReaderTheme: DesignSystem.ReaderTheme.sepia)
        == .light)
  }

  @Test func windowSchemeRestoresThePriorResolutionExactlyWhenReaderIsDismissed() {
    let beforePresentation = CoverAmbientPresentation.windowColorScheme(appPreference: .light)
    let whilePresented = CoverAmbientPresentation.windowColorScheme(
      appPreference: .light,
      presentedReaderTheme: DesignSystem.ReaderTheme.dark)
    let afterDismissal = CoverAmbientPresentation.windowColorScheme(
      appPreference: .light,
      presentedReaderTheme: nil)

    #expect(whilePresented == .dark)
    #expect(afterDismissal == beforePresentation)
  }

  @Test func itemDetailContentSchemeDoesNotLeakIntoLightOrSepiaReaderThemes() {
    let lightReaderScheme = CoverAmbientPresentation.windowColorScheme(
      appPreference: .dark,
      presentedReaderTheme: DesignSystem.ReaderTheme.light)
    let sepiaReaderScheme = CoverAmbientPresentation.windowColorScheme(
      appPreference: .dark,
      presentedReaderTheme: DesignSystem.ReaderTheme.sepia)

    #expect(lightReaderScheme == .light)
    #expect(sepiaReaderScheme == .light)
  }

  /// Title and author are two SwiftUI elements but one spoken element. The overflow control shares
  /// the author's row, so combining the two `Text`s would swallow it.
  @Test func titleAndAuthorStayOneSpokenElement() {
    #expect(
      ExpandedPlayerPresentation.metadataAccessibilityLabel(
        title: "Mercy for Hire", author: "J.S. Morin") == "Mercy for Hire. J.S. Morin")
  }

  @Test func metadataLabelOmitsAMissingOrEmptyAuthor() {
    #expect(
      ExpandedPlayerPresentation.metadataAccessibilityLabel(title: "Mercy for Hire", author: nil)
        == "Mercy for Hire")
    #expect(
      ExpandedPlayerPresentation.metadataAccessibilityLabel(title: "Mercy for Hire", author: "")
        == "Mercy for Hire")
  }

  @Test func podcastBylineOpensItsShowWhileAudiobookBylineRequestsAnAuthor() {
    #expect(
      PlayerBylineNavigationPresentation.destination(
        itemID: "show-1", episodeID: "episode-1", byline: "The Show")
        == .podcastShow(itemID: "show-1"))
    #expect(
      PlayerBylineNavigationPresentation.destination(
        itemID: "book-1", episodeID: nil, byline: "Ursula K. Le Guin")
        == .author(named: "Ursula K. Le Guin"))
    #expect(
      PlayerBylineNavigationPresentation.destination(
        itemID: "book-1", episodeID: nil, byline: "  ") == nil)
  }

  @Test func audiobookBylineResolvesTheFirstDisplayedAuthorToItsLibraryEntity() {
    let pratchett = AuthorSeriesEntity(
      kind: .author, entityID: "author-pratchett", name: "Terry Pratchett", libraryID: "library-1")
    let gaiman = AuthorSeriesEntity(
      kind: .author, entityID: "author-gaiman", name: "Neil Gaiman", libraryID: "library-1")

    #expect(
      PlayerBylineNavigationPresentation.authorEntity(
        named: "Neil Gaiman, Terry Pratchett", among: [pratchett, gaiman]) == gaiman)
  }

  @Test func tappableBylineExplainsItsDestinationToVoiceOver() {
    #expect(
      PlayerBylineNavigationPresentation.accessibilityHint(for: .podcastShow(itemID: "show-1"))
        == "Opens this show in Library")
    #expect(
      PlayerBylineNavigationPresentation.accessibilityHint(for: .author(named: "N. K. Jemisin"))
        == "Opens this author in Library")
  }

  @Test func bylineDestinationsOpenInsideTheLibrarySection() {
    let author = AuthorSeriesEntity(
      kind: .author, entityID: "author-1", name: "N. K. Jemisin", libraryID: "library-1")

    #expect(
      PlayerBylineNavigationPresentation.libraryDestination(
        for: .podcastShow(itemID: "show-1"))
        == NavigationModel.Destination(
          section: .library, path: [.podcastShow(itemID: "show-1")]))
    #expect(
      PlayerBylineNavigationPresentation.libraryDestination(
        for: .author(named: author.name), authorEntity: author)
        == NavigationModel.Destination(
          section: .library,
          path: [.author(id: "author-1", libraryID: "library-1")]))
  }

  // MARK: - Metadata + saved position render from the retained projection

  @Test func expandedPlayerRendersTitleAndAuthorFromTheRetainedProjection() {
    let bookmark = Self.bookmark(id: "abc123", title: "Retained Title", author: "Retained Author", position: 812)

    let metadata = ExpandedPlayerPresentation.metadata(
      itemID: "abc123", displayedItem: bookmark, liveTitle: nil, liveAuthor: nil)
    #expect(
      metadata == ExpandedPlayerPresentation.DisplayedMetadata(title: "Retained Title", author: "Retained Author"))
  }

  @Test func metadataFallsBackToLoadingWhenNeitherLiveNorRetainedNamesTheItem() {
    let metadata = ExpandedPlayerPresentation.metadata(
      itemID: "other", episodeID: nil, displayedItem: Self.bookmark(id: "abc123"),
      liveTitle: nil, liveAuthor: nil)
    #expect(metadata == ExpandedPlayerPresentation.DisplayedMetadata(title: "Loading…", author: nil))
  }

  @Test func podcastMetadataUsesTheMatchingEpisodeTitleAndShowTitleInsteadOfItemMetadata() {
    let bookmark = Self.bookmark(
      id: "show", episodeID: "episode-a", episodeTitle: "Episode A", showTitle: "The Show",
      title: "Legacy Item Title", author: "Legacy Author")

    let metadata = ExpandedPlayerPresentation.metadata(
      itemID: "show", episodeID: "episode-a", displayedItem: bookmark,
      liveTitle: "The Show Item", liveAuthor: "Show Author")

    #expect(
      metadata
        == ExpandedPlayerPresentation.DisplayedMetadata(title: "Episode A", author: "The Show"))
  }

  @Test func preparingSiblingEpisodeDoesNotReuseRetainedEpisodeMetadata() {
    let bookmarkA = Self.bookmark(
      id: "show", episodeID: "episode-a", episodeTitle: "Episode A", showTitle: "The Show")

    let metadataForB = ExpandedPlayerPresentation.metadata(
      itemID: "show", episodeID: "episode-b", displayedItem: bookmarkA,
      liveTitle: "The Show", liveAuthor: "Show Author")

    #expect(
      metadataForB
        == ExpandedPlayerPresentation.DisplayedMetadata(title: "Loading…", author: nil))
  }

  @Test func queueMetadataSeedPreventsLoadingPlaceholder() throws {
    let identity = try #require(
      ListeningIdentity.podcastEpisode(itemID: "show", episodeID: "episode-b"))
    let seed = PlayerMetadataSeed(identity: identity, title: "Episode B", author: "The Show")

    let metadata = ExpandedPlayerPresentation.metadata(
      itemID: "show", episodeID: "episode-b", displayedItem: nil,
      liveTitle: nil, liveAuthor: nil, metadataSeed: seed)

    #expect(
      metadata
        == ExpandedPlayerPresentation.DisplayedMetadata(title: "Episode B", author: "The Show"))
  }

  // MARK: - Cover identity before the item loads

  /// The open morph measures the page's cover before the page's item has loaded. Without the
  /// seed's revision the page keys its cover `unversioned` while the bar keys the same cover by
  /// its real revision, so the two never match and the cover never flies.
  @Test func artworkSeedSuppliesTheCoverRevisionUntilTheItemLoads() throws {
    let identity = try #require(ListeningIdentity.audiobook(itemID: "book-1"))
    let source = ArtworkSource.audiobookshelf(ArtworkAccountScope("account-1"))
    let seed = PlayerMetadataSeed(
      identity: identity, title: "Book", author: nil, artworkSource: source,
      artworkRevision: ArtworkRevision("1791488708042"))

    let seeded = ExpandedPlayerPresentation.artworkIdentity(
      itemID: "book-1", episodeID: nil, live: nil, metadataSeed: seed)
    #expect(seeded == .init(source: source, revision: ArtworkRevision("1791488708042")))

    // The loaded item always wins: it is the library's current answer.
    let live = ExpandedPlayerPresentation.ArtworkIdentity(
      source: nil, revision: ArtworkRevision("1791488709999"))
    #expect(
      ExpandedPlayerPresentation.artworkIdentity(
        itemID: "book-1", episodeID: nil, live: live, metadataSeed: seed) == live)
  }

  @Test func artworkSeedForAnotherIdentityIsIgnored() throws {
    let other = try #require(ListeningIdentity.audiobook(itemID: "book-2"))
    let seed = PlayerMetadataSeed(
      identity: other, title: "Other", author: nil,
      artworkRevision: ArtworkRevision("1791488708042"))

    #expect(
      ExpandedPlayerPresentation.artworkIdentity(
        itemID: "book-1", episodeID: nil, live: nil, metadataSeed: seed)
        == .init(source: nil, revision: .unversioned))
    #expect(
      ExpandedPlayerPresentation.artworkIdentity(
        itemID: "book-1", episodeID: nil, live: nil, metadataSeed: nil)
        == .init(source: nil, revision: .unversioned))
  }

  // MARK: - Transport/scrubber enablement

  @Test func transportAndScrubberAreEnabledForARetainedInactiveItem() {
    let enabled = ExpandedPlayerPresentation.isTransportEnabled(
      itemID: "abc123", activeItemID: nil, loadedItemID: nil, displayedItem: Self.bookmark(id: "abc123"))
    #expect(enabled == true)
  }

  @Test func transportAndScrubberAreEnabledForAnActiveLiveSession() {
    let enabled = ExpandedPlayerPresentation.isTransportEnabled(
      itemID: "abc123", activeItemID: "abc123", loadedItemID: "abc123", displayedItem: nil)
    #expect(enabled == true)
  }

  @Test func transportAndScrubberAreDisabledWhenTheItemIsNeitherActiveNorRetained() {
    let enabled = ExpandedPlayerPresentation.isTransportEnabled(
      itemID: "abc123", activeItemID: "other", loadedItemID: "other",
      displayedItem: Self.bookmark(id: "another"))
    #expect(enabled == false)
  }

  // MARK: - Chapter affordances use the identity-safe live-or-retained map

  @Test func chapterAffordancesAreDisabledUntilAChapterMapExists() {
    #expect(ExpandedPlayerPresentation.isChapterAffordanceEnabled(chapterMap: nil) == false)
    #expect(
      ExpandedPlayerPresentation.isChapterAffordanceEnabled(chapterMap: PlaybackChapterMap(chapters: [])) == false)
  }

  @Test func chapterAffordancesAreEnabledOnceANonEmptyChapterMapExists() {
    let chapterMap = PlaybackChapterMap(chapters: [
      PlayerCore.PlaybackChapter(id: "1", title: "One", start: 0, end: 100)
    ])
    #expect(ExpandedPlayerPresentation.isChapterAffordanceEnabled(chapterMap: chapterMap) == true)
  }

  @Test func retainedChapterMapEnablesNavigationBeforePlaybackIsLoaded() {
    let retainedMap = PlaybackChapterMap(
      chapters: [PlayerCore.PlaybackChapter(id: "retained", title: "One", start: 0, end: 100)])
    let resolved = ExpandedPlayerPresentation.resolvedChapterMap(
      itemID: "book", loadedItemID: nil, playerItem: nil, fallbackChapterMap: retainedMap)

    #expect(ExpandedPlayerPresentation.isChapterAffordanceEnabled(chapterMap: resolved))
  }

  @Test func matchingLiveEmptyChapterMapOverridesANonEmptyRetainedMap() throws {
    let liveItem = PlayerItem(
      id: "book",
      timeline: try PlaybackTimeline(
        tracks: [PlaybackTrack(index: 0, startOffset: 0, duration: 100)]),
      chapters: PlaybackChapterMap(chapters: []))
    let retainedMap = PlaybackChapterMap(
      chapters: [PlayerCore.PlaybackChapter(id: "retained", title: "One", start: 0, end: 100)])

    let resolved = ExpandedPlayerPresentation.resolvedChapterMap(
      itemID: "book", loadedItemID: "book", playerItem: liveItem,
      fallbackChapterMap: retainedMap)

    #expect(resolved?.chapters.isEmpty == true)
    #expect(ExpandedPlayerPresentation.isChapterAffordanceEnabled(chapterMap: resolved) == false)
  }

  @Test func absentAndEmptyResolvedChapterMapsKeepNavigationDisabled() {
    #expect(
      ExpandedPlayerPresentation.isChapterAffordanceEnabled(
        chapterMap: ExpandedPlayerPresentation.resolvedChapterMap(
          itemID: "book", loadedItemID: nil, playerItem: nil, fallbackChapterMap: nil)) == false)
    #expect(
      ExpandedPlayerPresentation.isChapterAffordanceEnabled(
        chapterMap: ExpandedPlayerPresentation.resolvedChapterMap(
          itemID: "book", loadedItemID: nil, playerItem: nil,
          fallbackChapterMap: PlaybackChapterMap(chapters: []))) == false)
  }

  @Test func mismatchedLiveItemCannotLendItsChaptersToThisPlayer() throws {
    let liveItem = PlayerItem(
      id: "other",
      timeline: try PlaybackTimeline(
        tracks: [PlaybackTrack(index: 0, startOffset: 0, duration: 100)]),
      chapters: PlaybackChapterMap(
        chapters: [PlayerCore.PlaybackChapter(id: "other-1", title: "Other", start: 0, end: 100)]))

    let resolved = ExpandedPlayerPresentation.resolvedChapterMap(
      itemID: "book", loadedItemID: "other", playerItem: liveItem, fallbackChapterMap: nil)

    #expect(resolved == nil)
    #expect(ExpandedPlayerPresentation.isChapterAffordanceEnabled(chapterMap: resolved) == false)
  }

  @Test func siblingEpisodeCannotLendItsChaptersToThisEpisode() throws {
    let sibling = PlayerItem(
      id: "show", episodeID: "episode-a",
      timeline: try PlaybackTimeline(
        tracks: [PlaybackTrack(index: 0, startOffset: 0, duration: 100)]),
      chapters: PlaybackChapterMap(
        chapters: [PlayerCore.PlaybackChapter(id: "sibling-1", title: "Sibling", start: 0, end: 100)]))

    let resolved = ExpandedPlayerPresentation.resolvedChapterMap(
      itemID: "show", episodeID: "episode-b", loadedItemID: "show",
      loadedEpisodeID: "episode-a", playerItem: sibling, fallbackChapterMap: nil)

    #expect(resolved == nil)
    #expect(ExpandedPlayerPresentation.isChapterAffordanceEnabled(chapterMap: resolved) == false)
  }

  @Test func chapterTransportUsesTheMatchingQuietItemProjection() {
    let item = PlayerQuickActionsItem(
      id: "book", episodeID: nil, totalDuration: 3_600, hasChapters: true)

    #expect(
      ExpandedPlayerPresentation.hasLiveChapters(
        itemID: "book", loadedItemID: "book", quickActionsItem: item))
    #expect(
      ExpandedPlayerPresentation.hasLiveChapters(
        itemID: "other", loadedItemID: "book", quickActionsItem: item) == false)
    #expect(
      ExpandedPlayerPresentation.hasLiveChapters(
        itemID: "book", loadedItemID: "other", quickActionsItem: item) == false)
  }

  @Test func chapterTransportRejectsSiblingEpisodesAndChapterlessItems() {
    let episode = PlayerQuickActionsItem(
      id: "show", episodeID: "episode-a", totalDuration: 1_800, hasChapters: true)
    let chapterlessBook = PlayerQuickActionsItem(
      id: "book", episodeID: nil, totalDuration: 3_600, hasChapters: false)

    #expect(
      ExpandedPlayerPresentation.hasLiveChapters(
        itemID: "show", episodeID: "episode-b", loadedItemID: "show",
        loadedEpisodeID: "episode-a", quickActionsItem: episode) == false)
    #expect(
      ExpandedPlayerPresentation.hasLiveChapters(
        itemID: "book", loadedItemID: "book", quickActionsItem: chapterlessBook) == false)
  }

  @Test func chapteredEpisodeKeepsItsExistingChapterNavigationCapability() {
    let episode = PlayerQuickActionsItem(
      id: "rss:1", episodeID: "episode-1", totalDuration: 1_800, hasChapters: true)

    #expect(
      ExpandedPlayerPresentation.hasLiveChapters(
        itemID: "rss:1", episodeID: "episode-1", loadedItemID: "rss:1",
        loadedEpisodeID: "episode-1", quickActionsItem: episode))
  }

  @Test func retainedItemDetailChaptersBuildAChapterMapBeforePlaybackIsLoaded() {
    let extras = ItemDetailExtras(
      seriesName: nil,
      narrator: "Narrator",
      chapters: [
        ItemChapterInfo(title: "One", start: 0, end: 100),
        ItemChapterInfo(title: "Two", start: 100, end: 220),
      ])

    let chapterMap = ExpandedPlayerPresentation.playbackChapterMap(from: extras)

    #expect(chapterMap?.chapters.count == 2)
    #expect(chapterMap?.currentChapter(at: 150)?.title == "Two")
  }

  @Test func retainedBookmarkProvidesTimelineDurationBeforePlaybackIsLoaded() {
    let bookmark = Self.bookmark(id: "abc123", position: 812)

    #expect(
      ExpandedPlayerPresentation.timelineDurationSeconds(
        itemID: "abc123", displayedItem: bookmark, itemDetailDurationSeconds: nil) == 100)
  }

  @Test func podcastTimelineNeverUsesTheParentItemsDetailDuration() {
    let bookmark = Self.bookmark(id: "show", episodeID: "episode-a", position: 812)

    #expect(
      ExpandedPlayerPresentation.timelineDurationSeconds(
        itemID: "show", episodeID: "episode-a", displayedItem: bookmark,
        itemDetailDurationSeconds: 250_000) == 100)
  }

  @Test func finishedRetainedEpisodeFillsTheTimeline() {
    let bookmark = Self.bookmark(id: "rss:1", episodeID: "ep", position: 2_027, isFinished: true)

    #expect(
      ExpandedPlayerPresentation.timelinePositionSeconds(
        itemID: "rss:1", episodeID: "ep", savedPosition: 2_027, displayedItem: bookmark,
        isLoaded: false, totalDuration: 2_080) == 2_080)
  }

  @Test func unfinishedOrLiveTimelineKeepsItsPosition() {
    let unfinished = Self.bookmark(id: "rss:1", episodeID: "ep", position: 2_027)
    let finished = Self.bookmark(id: "rss:1", episodeID: "ep", position: 2_027, isFinished: true)

    #expect(
      ExpandedPlayerPresentation.timelinePositionSeconds(
        itemID: "rss:1", episodeID: "ep", savedPosition: 2_027, displayedItem: unfinished,
        isLoaded: false, totalDuration: 2_080) == 2_027)
    // A replay of a finished episode reads the live playhead, not the end.
    #expect(
      ExpandedPlayerPresentation.timelinePositionSeconds(
        itemID: "rss:1", episodeID: "ep", savedPosition: 12, displayedItem: finished,
        isLoaded: true, totalDuration: 2_080) == 12)
    // A sibling episode's finished bookmark lends nothing.
    #expect(
      ExpandedPlayerPresentation.timelinePositionSeconds(
        itemID: "rss:1", episodeID: "other", savedPosition: 300, displayedItem: finished,
        isLoaded: false, totalDuration: 2_080) == 300)
    // No known length leaves the saved position alone.
    #expect(
      ExpandedPlayerPresentation.timelinePositionSeconds(
        itemID: "rss:1", episodeID: "ep", savedPosition: 2_027, displayedItem: finished,
        isLoaded: false, totalDuration: nil) == 2_027)
  }

  // MARK: - Chapter row tri-state

  /// A podcast episode never grows the chapter row, in any state, not even the reserved
  /// placeholder, since an ABS episode never carries a chapter map.
  @Test func chapterRowIsHiddenOutrightForAPodcastEpisode() {
    #expect(
      ExpandedPlayerPresentation.chapterRowState(
        episodeID: "ep-1", chapterMap: nil, currentChapter: nil) == .hidden)
    #expect(
      ExpandedPlayerPresentation.chapterRowState(
        episodeID: "ep-1",
        chapterMap: PlaybackChapterMap(
          chapters: [PlayerCore.PlaybackChapter(id: "1", title: "One", start: 0, end: 100)]),
        currentChapter: nil) == .hidden)
  }

  /// No live session for this item yet: the row reserves its one-line slot (disabled, generic
  /// label) so title/scrubber placement doesn't jump once the chapter map arrives.
  @Test func chapterRowReservesItsSlotUntilTheChapterMapResolves() {
    #expect(
      ExpandedPlayerPresentation.chapterRowState(
        episodeID: nil, chapterMap: nil, currentChapter: nil) == .reserved)
  }

  /// A live, empty chapter map is a confirmed answer. The row is omitted rather than left as a
  /// permanently disabled control.
  @Test func chapterRowIsOmittedForAConfirmedChapterlessBook() {
    #expect(
      ExpandedPlayerPresentation.chapterRowState(
        episodeID: nil, chapterMap: PlaybackChapterMap(chapters: []), currentChapter: nil)
        == .chapterless)
  }

  /// A live, non-empty chapter map shows the current chapter, falling back to "Chapter N" when
  /// it carries no title of its own.
  @Test func chapterRowShowsTheCurrentChapterFallingBackToItsOrdinal() {
    let titled = PlayerCore.PlaybackChapter(id: "1", title: "The Crossing", start: 0, end: 100)
    let untitled = PlayerCore.PlaybackChapter(id: "2", start: 100, end: 200)
    let chapterMap = PlaybackChapterMap(chapters: [titled, untitled])

    #expect(
      ExpandedPlayerPresentation.chapterRowState(
        episodeID: nil, chapterMap: chapterMap, currentChapter: titled)
        == .current(label: "The Crossing", spokenLabel: "The Crossing"))
    #expect(
      ExpandedPlayerPresentation.chapterRowState(
        episodeID: nil, chapterMap: chapterMap, currentChapter: untitled)
        == .current(label: "Chapter 2", spokenLabel: "Chapter 2"))
  }

  /// The row is one line wide, so a numbering prefix like "Chapter Nineteen: " can take the
  /// whole of it. The label shows the compact form; VoiceOver still reads the title as published.
  @Test func chapterRowShowsTheCompactTitleButSpeaksTheFullOne() {
    let chapter = PlayerCore.PlaybackChapter(
      id: "19", title: "Chapter Nineteen: The East India Docks", start: 0, end: 100)
    let chapterMap = PlaybackChapterMap(chapters: [chapter])

    #expect(
      ExpandedPlayerPresentation.chapterRowState(
        episodeID: nil, chapterMap: chapterMap, currentChapter: chapter)
        == .current(
          label: "19: The East India Docks", spokenLabel: "Chapter Nineteen: The East India Docks"))
  }

  /// A non-empty map with the playhead in a gap no chapter covers must still enable the row, as
  /// the only entry point to the chapter sheet, with a generic label rather than stale chapter
  /// text.
  @Test func chapterRowStaysEnabledWithAGenericLabelWhenThePlayheadIsInAGap() {
    let chapterMap = PlaybackChapterMap(
      chapters: [PlayerCore.PlaybackChapter(id: "1", title: "One", start: 0, end: 100)])

    #expect(
      ExpandedPlayerPresentation.chapterRowState(
        episodeID: nil, chapterMap: chapterMap, currentChapter: nil)
        == .current(label: "Chapters", spokenLabel: "Chapters"))
  }

  /// Drawing the control and occupying the row are separate questions. Neither a podcast episode
  /// nor a chapterless book gets a control, but both keep the height. The block above the scrubber
  /// anchors the page's spacing, and a row that came and went put the transport in two places.
  @Test func onlyResolvedChapterStatesDrawAControlInTheReservedRow() {
    #expect(ExpandedPlayerPresentation.chapterRowDrawsControl(for: .hidden) == false)
    #expect(ExpandedPlayerPresentation.chapterRowDrawsControl(for: .chapterless) == false)
    #expect(ExpandedPlayerPresentation.chapterRowDrawsControl(for: .reserved))
    #expect(ExpandedPlayerPresentation.chapterRowDrawsControl(for: .current(label: "One", spokenLabel: "One")))
  }

  @Test func chapterNavigationDirectionsKeepTheirTransportSemantics() {
    let previous = ExpandedPlayerPresentation.ChapterNavigationDirection.previous
    let next = ExpandedPlayerPresentation.ChapterNavigationDirection.next

    #expect(previous.systemImage == "backward.end.fill")
    #expect(previous.accessibilityLabel == "Previous chapter")
    #expect(previous.accessibilityHint == "Restarts this chapter, or goes to the previous one.")
    #expect(next.systemImage == "forward.end.fill")
    #expect(next.accessibilityLabel == "Next chapter")
    #expect(next.accessibilityHint == "Goes to the start of the next chapter.")
  }

  @Test func preparingBDoesNotExposeLoadedAsTimelineOrEnableBTransport() {
    let itemA = PlayerItem(
      id: "item-a",
      timeline: try! PlaybackTimeline(
        tracks: [PlaybackTrack(index: 0, startOffset: 0, duration: 9_000)]),
      chapters: PlaybackChapterMap(
        chapters: [PlayerCore.PlaybackChapter(id: "a-1", title: "A chapter", start: 0, end: 9_000)])
    )
    let bookmarkA = Self.bookmark(id: "item-a", position: 812)

    let liveItemForB = ExpandedPlayerPresentation.livePlayerItem(
      itemID: "item-b", loadedItemID: "item-a", playerItem: itemA)
    let transportForB = ExpandedPlayerPresentation.isTransportEnabled(
      itemID: "item-b", activeItemID: "item-b", loadedItemID: "item-a", displayedItem: bookmarkA)

    #expect(liveItemForB == nil, "A's duration and chapters must not appear in B's timeline")
    #expect(transportForB == false, "B controls stay disabled until B is actually loaded")
  }

  @Test func preparingSiblingEpisodeDoesNotExposeRetainedOrLiveEpisodeState() {
    let loadedEpisodeA = PlayerItem(
      id: "show",
      episodeID: "episode-a",
      timeline: try! PlaybackTimeline(
        tracks: [PlaybackTrack(index: 0, startOffset: 0, duration: 9_000)])
    )
    let bookmarkA = Self.bookmark(
      id: "show", episodeID: "episode-a", episodeTitle: "Episode A", showTitle: "The Show",
      position: 812)

    let liveItemForB = ExpandedPlayerPresentation.livePlayerItem(
      itemID: "show", episodeID: "episode-b", loadedItemID: "show",
      loadedEpisodeID: "episode-a", playerItem: loadedEpisodeA)
    let transportForB = ExpandedPlayerPresentation.isTransportEnabled(
      itemID: "show", episodeID: "episode-b", activeItemID: "show",
      activeEpisodeID: "episode-b", loadedItemID: "show", loadedEpisodeID: "episode-a",
      displayedItem: bookmarkA)

    #expect(liveItemForB == nil)
    #expect(transportForB == false)
  }

  // MARK: - Finish duration

  /// The item-detail fetch behind an episode's player describes the show, so its duration would
  /// stamp a whole podcast's length onto one episode's progress row.
  @Test func episodeFinishDurationNeverComesFromTheShowsItemDetail() {
    let bookmark = Self.bookmark(
      id: "show", episodeID: "episode-a", episodeTitle: "Episode A", showTitle: "The Show")

    #expect(
      ExpandedPlayerPresentation.finishDurationSeconds(
        itemID: "show", episodeID: "episode-a", displayedItem: bookmark,
        itemDetailDurationSeconds: 250_000, liveTotalDuration: nil) == 100)
  }

  @Test func episodeFinishDurationPrefersTheLiveTimelineOverTheRetainedBookmark() {
    let bookmark = Self.bookmark(id: "show", episodeID: "episode-a")

    #expect(
      ExpandedPlayerPresentation.finishDurationSeconds(
        itemID: "show", episodeID: "episode-a", displayedItem: bookmark,
        itemDetailDurationSeconds: 250_000, liveTotalDuration: 3_050) == 3_050)
  }

  /// A bookmark for a sibling episode is not this episode's duration. Record none rather than
  /// finish an episode at another one's length.
  @Test func episodeFinishDurationIsUnknownWhenNeitherSourceMatches() {
    let bookmarkB = Self.bookmark(id: "show", episodeID: "episode-b")

    #expect(
      ExpandedPlayerPresentation.finishDurationSeconds(
        itemID: "show", episodeID: "episode-a", displayedItem: bookmarkB,
        itemDetailDurationSeconds: 250_000, liveTotalDuration: nil) == nil)
  }

  @Test func itemFinishDurationKeepsPreferringTheItemDetailFetch() {
    let bookmark = Self.bookmark(id: "abc123")

    #expect(
      ExpandedPlayerPresentation.finishDurationSeconds(
        itemID: "abc123", episodeID: nil, displayedItem: bookmark,
        itemDetailDurationSeconds: 42_000, liveTotalDuration: 41_000) == 42_000)
    #expect(
      ExpandedPlayerPresentation.finishDurationSeconds(
        itemID: "abc123", episodeID: nil, displayedItem: bookmark,
        itemDetailDurationSeconds: nil, liveTotalDuration: nil) == 100)
    #expect(
      ExpandedPlayerPresentation.finishDurationSeconds(
        itemID: "other", episodeID: nil, displayedItem: bookmark,
        itemDetailDurationSeconds: nil, liveTotalDuration: nil) == nil)
  }

  @Test("overflow progress state belongs to the exact displayed item or episode")
  func overflowProgressStateUsesExactIdentity() {
    #expect(
      ExpandedPlayerPresentation.playbackStatus(
        itemID: "book", episodeID: nil,
        displayedItem: Self.bookmark(id: "book", position: 0), retainedPositionSeconds: 42)
        == .inProgress)
    #expect(
      ExpandedPlayerPresentation.playbackStatus(
        itemID: "show", episodeID: "episode-a",
        displayedItem: Self.bookmark(
          id: "show", episodeID: "episode-a", position: 100, isFinished: true),
        retainedPositionSeconds: 100) == .finished)
    #expect(
      ExpandedPlayerPresentation.playbackStatus(
        itemID: "show", episodeID: "episode-a",
        displayedItem: Self.bookmark(id: "show", episodeID: "episode-b"),
        retainedPositionSeconds: 42) == nil)
  }

  private static func bookmark(
    id: String = "abc123",
    episodeID: String? = nil,
    episodeTitle: String? = nil,
    showTitle: String? = nil,
    title: String = "Title",
    author: String? = "Author",
    position: Double = 10,
    isFinished: Bool = false
  ) -> PlaybackBookmark {
    PlaybackBookmark(
      serverItemId: id, episodeID: episodeID, episodeTitle: episodeTitle, showTitle: showTitle,
      title: title, author: author, durationSeconds: 100, positionSeconds: position,
      isFinished: isFinished)
  }
}
