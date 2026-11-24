import ABSApi
import Foundation
import Persistence
import Testing

@testable import SyncEngine

@Suite struct SyncEngineItemMappingTests {
  @Test func absentInvalidAndNegativePodcastCountsPreserveExistingValue() {
    let existing = preservedMetadata(podcastEpisodeCount: 7)
    for count in [Int?(nil), -1, -42] {
      let summary = summary(podcastEpisodeCount: count)
      let mapped = SyncEngine.mapItem(
        summary, library: podcastLibrary, accountId: 1, libraryId: 2, existingMetadata: existing)
      #expect(mapped?.podcastServerEpisodeCount == 7)
    }
  }

  @Test func explicitNonnegativePodcastCountIsAuthoritative() {
    let existing = preservedMetadata(podcastEpisodeCount: 7)
    for count in [0, 3] {
      let summary = summary(podcastEpisodeCount: count)
      let mapped = SyncEngine.mapItem(
        summary, library: podcastLibrary, accountId: 1, libraryId: 2, existingMetadata: existing)
      #expect(mapped?.podcastServerEpisodeCount == count)
    }
  }

  @Test func podcastCountIsRetainedAcrossBookMapping() {
    let summary = LibraryItemSummary(
      id: "book", libraryID: "library", mediaType: "book", title: "Book", authorName: nil,
      seriesName: nil, podcastEpisodeCount: nil)
    let mapped = SyncEngine.mapItem(
      summary, library: bookLibrary, accountId: 1, libraryId: 2,
      existingMetadata: preservedMetadata(podcastEpisodeCount: 7))
    #expect(mapped?.podcastServerEpisodeCount == 7)
  }

  @Test func podcastFeedFingerprintPreservesReplacesAndClearsByFieldState() {
    let existingFingerprint = PodcastFeedIdentity.fingerprint("https://example.com/old")!
    let existing = preservedMetadata(
      podcastEpisodeCount: 7, podcastFeedFingerprint: existingFingerprint)

    let absent = SyncEngine.mapItem(
      summary(feedURLState: .absent), library: podcastLibrary, accountId: 1, libraryId: 2,
      existingMetadata: existing)
    #expect(absent?.podcastFeedFingerprint == existingFingerprint)

    let replacementURL = "HTTPS://EXAMPLE.COM:443/New/"
    let replacement = SyncEngine.mapItem(
      summary(feedURLState: .value(replacementURL)), library: podcastLibrary, accountId: 1,
      libraryId: 2, existingMetadata: existing)
    #expect(
      replacement?.podcastFeedFingerprint
        == PodcastFeedIdentity.fingerprint(
          "https://example.com/New"))

    for state in [
      PodcastFeedURLState.invalid,
      .value("not a feed URL"),
      .value("https://user:password@example.com/feed"),
    ] {
      let cleared = SyncEngine.mapItem(
        summary(feedURLState: state), library: podcastLibrary, accountId: 1, libraryId: 2,
        existingMetadata: existing)
      #expect(cleared?.podcastFeedFingerprint == nil)
    }
  }

  @Test func malformedPersistedPodcastFeedFingerprintFailsOpen() {
    let mapped = SyncEngine.mapItem(
      summary(feedURLState: .absent), library: podcastLibrary, accountId: 1, libraryId: 2,
      existingMetadata: preservedMetadata(
        podcastEpisodeCount: nil, podcastFeedFingerprint: "not-a-fingerprint"))
    #expect(mapped?.podcastFeedFingerprint == nil)
  }

  @Test func booksAlwaysKeepPodcastFeedFingerprintNil() {
    let summary = LibraryItemSummary(
      id: "book", libraryID: "library", mediaType: "book", title: "Book", authorName: nil,
      seriesName: nil, feedURLState: .value("https://example.com/feed"))
    let mapped = SyncEngine.mapItem(
      summary, library: bookLibrary, accountId: 1, libraryId: 2,
      existingMetadata: preservedMetadata(
        podcastEpisodeCount: 4,
        podcastFeedFingerprint: PodcastFeedIdentity.fingerprint("https://example.com/feed")))
    #expect(mapped?.podcastFeedFingerprint == nil)
  }

  @Test func podcastLanguagePreservesReplacesAndClearsByFieldState() {
    let existing = preservedMetadata(podcastEpisodeCount: nil, podcastLanguage: "en")

    func mapped(_ state: PodcastLanguageState) -> String? {
      SyncEngine.mapItem(
        summary(podcastLanguageState: state), library: podcastLibrary, accountId: 1, libraryId: 2,
        existingMetadata: existing)?.podcastLanguage
    }
    #expect(mapped(.absent) == "en")
    #expect(mapped(.value("fr")) == "fr")
    #expect(mapped(.cleared) == nil)
    #expect(
      SyncEngine.mapItem(
        summary(podcastLanguageState: .absent), library: podcastLibrary, accountId: 1, libraryId: 2
      )?.podcastLanguage == nil)
  }

  @Test func booksAlwaysKeepPodcastLanguageNil() {
    let summary = LibraryItemSummary(
      id: "book", libraryID: "library", mediaType: "book", title: "Book", authorName: nil,
      seriesName: nil, podcastLanguageState: .value("en"))
    let mapped = SyncEngine.mapItem(
      summary, library: bookLibrary, accountId: 1, libraryId: 2,
      existingMetadata: preservedMetadata(podcastEpisodeCount: nil, podcastLanguage: "en"))
    #expect(mapped?.podcastLanguage == nil)
  }

  private var podcastLibrary: Library {
    Library(
      id: "library", name: "Podcasts", mediaType: "podcast",
      onlyShowLaterBooksInContinueSeries: false)
  }

  private var bookLibrary: Library {
    Library(
      id: "library", name: "Books", mediaType: "book",
      onlyShowLaterBooksInContinueSeries: false)
  }

  private func summary(
    podcastEpisodeCount: Int? = nil,
    feedURLState: PodcastFeedURLState = .absent,
    podcastLanguageState: PodcastLanguageState = .absent
  ) -> LibraryItemSummary {
    LibraryItemSummary(
      id: "show", libraryID: "library", mediaType: "podcast", title: "Show", authorName: nil,
      seriesName: nil, podcastEpisodeCount: podcastEpisodeCount, feedURLState: feedURLState,
      podcastLanguageState: podcastLanguageState)
  }

  private func preservedMetadata(
    podcastEpisodeCount: Int?, podcastFeedFingerprint: String? = nil, podcastLanguage: String? = nil
  ) -> ItemDAO.PreservedMetadata {
    ItemDAO.PreservedMetadata(
      addedAt: nil, seriesName: nil, narratorName: nil, expandedMetadataFetchedAt: nil,
      itemDescription: nil, ebookFileIno: nil, ebookFileExt: nil,
      audioDownloadExpectedBytes: nil, ebookDownloadExpectedBytes: nil,
      hasServerArtwork: nil, podcastServerEpisodeCount: podcastEpisodeCount,
      podcastFeedFingerprint: podcastFeedFingerprint, podcastLanguage: podcastLanguage)
  }
}
