import Foundation
import Persistence
import Testing

@testable import AppModel

private func makeItem(
  id: String = "item-1",
  title: String = "A Parade of Horribles",
  author: String? = "Matt Dinniman",
  category: ItemMediaCategory = .audiobook,
  hasReadableEbook: Bool = false,
  durationSeconds: Double? = 3600 * 12,
  progressSeconds: Double = 3600 * 3,
  ebookProgress: Double = 0,
  isFinished: Bool = false,
  isDownloaded: Bool = false,
  audioDownloaded: Bool = false,
  ebookDownloaded: Bool = false,
  supplementDownloaded: Bool = false,
  episodeID: String? = nil,
  episodeTitle: String? = nil
) -> HomeItem {
  HomeItem(
    serverItemId: id,
    title: title,
    author: author,
    category: category,
    hasReadableEbook: hasReadableEbook,
    durationSeconds: durationSeconds,
    progressSeconds: progressSeconds,
    ebookProgress: ebookProgress,
    isFinished: isFinished,
    addedAt: nil,
    isDownloaded: isDownloaded,
    episodeID: episodeID,
    episodeTitle: episodeTitle,
    audioDownloaded: audioDownloaded,
    ebookDownloaded: ebookDownloaded,
    supplementDownloaded: supplementDownloaded)
}

@Suite struct HomeMoreItemRowPresentationTests {
  @Test func continueListeningRowNamesTitleAuthorAndRemainingTime() {
    let row = HomeMoreItemRowPresentation(item: makeItem(), section: .continueListening)

    #expect(row.title == "A Parade of Horribles")
    #expect(row.subtitle == "Matt Dinniman")
    #expect(row.metadataText == "Audiobook")
    #expect(row.progressText == "25% · 9h 0m left")
    #expect(row.progressFraction == 0.25)
  }

  @Test("a displayed position drives both the bar and the countdown")
  func displayedPositionDrivesBarAndCountdown() {
    let row = HomeMoreItemRowPresentation(
      item: makeItem(), section: .continueListening, progressSeconds: 3600 * 6)

    #expect(row.progressText == "50% · 6h 0m left")
    #expect(row.progressFraction == 0.5)
  }

  @Test("continue-listening countdown uses the current playback rate")
  func continueListeningRowAccountsForPlaybackRate() {
    let row = HomeMoreItemRowPresentation(
      item: makeItem(), section: .continueListening, playbackRate: 1.15)

    #expect(row.progressText == "25% · 7h 50m left")
  }

  @Test func podcastContinuationRowLeadsWithTheEpisodeAndNamesItsShow() {
    let row = HomeMoreItemRowPresentation(
      item: makeItem(
        title: "Empire", author: "Goalhanger", category: .podcast, durationSeconds: 45 * 60,
        progressSeconds: 9 * 60, episodeID: "ep-1", episodeTitle: "376. Algerian Revolution"),
      section: .continueListening)

    #expect(row.title == "376. Algerian Revolution")
    #expect(row.subtitle == "Empire")
    #expect(row.metadataText == "Podcast")
    #expect(row.progressText == "20% · 36m left")
  }

  @Test("Continue Reading uses the ebook badge and ebook progress for bundled audiobooks")
  func continueReadingRowUsesEbookPresentation() {
    let row = HomeMoreItemRowPresentation(
      item: makeItem(ebookProgress: 0.25), section: .continueReading)

    #expect(row.metadataText == "eBook")
    #expect(row.progressText == "25%")
    #expect(row.progressFraction == 0.25)
  }

  @Test func finishedRowReadsFinishedRatherThanACountdown() {
    let row = HomeMoreItemRowPresentation(
      item: makeItem(progressSeconds: 3600 * 12, isFinished: true), section: .continueListening)

    #expect(row.progressText == "Finished")
    #expect(row.isFinished)
  }

  @Test func unknownDurationDropsTheProgressLineAndTheBar() {
    let row = HomeMoreItemRowPresentation(
      item: makeItem(durationSeconds: nil), section: .continueListening)

    #expect(row.progressText == nil)
    #expect(row.progressFraction == nil)
    #expect(row.metadataText == "Audiobook")
  }

  @Test func nonProgressSectionsSuppressProgressButKeepTheMetadataLine() {
    let recentlyAdded = HomeMoreItemRowPresentation(item: makeItem(), section: .recentlyAdded)
    #expect(recentlyAdded.progressText == nil)
    #expect(recentlyAdded.progressFraction == nil)
    #expect(recentlyAdded.metadataText == "Audiobook · 12 hr")

    let downloaded = HomeMoreItemRowPresentation(item: makeItem(), section: .downloaded)
    #expect(downloaded.progressText == nil)
    #expect(downloaded.progressFraction == nil)
    #expect(downloaded.metadataText == "Audiobook")
  }

  @Test("ebook-only rows print no duration, whether the server sends 0 or nothing")
  func ebookRowsSuppressTheUnknownDurationCaption() {
    let zero = HomeMoreItemRowPresentation(
      item: makeItem(category: .ebook, durationSeconds: 0), section: .continueSeries)
    #expect(zero.metadataText == "eBook")

    let absent = HomeMoreItemRowPresentation(
      item: makeItem(category: .ebook, durationSeconds: nil), section: .continueSeries)
    #expect(absent.metadataText == "eBook")
  }

  @Test("an audiobook whose duration the server never sent prints the badge alone")
  func audiobookWithZeroDurationSuppressesTheCaption() {
    let row = HomeMoreItemRowPresentation(
      item: makeItem(durationSeconds: 0), section: .continueSeries)

    #expect(row.metadataText == "Audiobook")
  }

  /// The bug this closes kept returning one section at a time: Continue Series printed
  /// "eBook · Duration unknown" long after Saved for Later and item detail had been taught not to.
  /// Sweeping every section against every category means a section added later inherits the rule
  /// instead of having to rediscover it.
  @Test("no section prints filler duration copy, for any category the server can send")
  func noSectionEverPrintsTheUnknownDurationCaption() {
    for section in HomeMoreSection.allCases {
      for category in [ItemMediaCategory.audiobook, .ebook, .podcast] {
        for durationSeconds in [nil, 0, -1, Double.infinity] as [Double?] {
          let row = HomeMoreItemRowPresentation(
            item: makeItem(category: category, durationSeconds: durationSeconds),
            section: section)

          #expect(
            row.metadataText.contains(PodcastCopy.unknownDuration) == false,
            "\(section) · \(category) · \(String(describing: durationSeconds))")
        }
      }
    }
  }

  @Test func downloadedPodcastUsesTheSameKindOnlyMetadataAsDownloadedAudiobook() {
    let row = HomeMoreItemRowPresentation(
      item: makeItem(category: .podcast, durationSeconds: 45 * 60), section: .downloaded)

    #expect(row.metadataText == "Podcast")
  }

  @Test("downloaded mixed rows name exactly the local formats")
  func downloadedRowsNameLocalFormats() {
    let both = HomeMoreItemRowPresentation(
      item: makeItem(
        hasReadableEbook: true, isDownloaded: true, audioDownloaded: true, ebookDownloaded: true),
      section: .downloaded)
    let ebookOnly = HomeMoreItemRowPresentation(
      item: makeItem(hasReadableEbook: true, isDownloaded: true, ebookDownloaded: true),
      section: .downloaded)
    let audioOnly = HomeMoreItemRowPresentation(
      item: makeItem(hasReadableEbook: true, isDownloaded: true, audioDownloaded: true),
      section: .downloaded)
    let pureAudiobook = HomeMoreItemRowPresentation(
      item: makeItem(isDownloaded: true, audioDownloaded: true), section: .downloaded)
    let pureEbook = HomeMoreItemRowPresentation(
      item: makeItem(category: .ebook, hasReadableEbook: true, isDownloaded: true, ebookDownloaded: true),
      section: .downloaded)
    let podcast = HomeMoreItemRowPresentation(
      item: makeItem(category: .podcast, isDownloaded: true, audioDownloaded: true),
      section: .downloaded)

    #expect(both.metadataText == "Audiobook + eBook")
    #expect(ebookOnly.metadataText == "eBook")
    #expect(audioOnly.metadataText == "Audiobook")
    #expect(pureAudiobook.metadataText == "Audiobook")
    #expect(pureEbook.metadataText == "eBook")
    #expect(podcast.metadataText == "Podcast")
  }

  @Test("a downloaded companion PDF is named beside the media it accompanies")
  func downloadedRowsNameTheirPDF() {
    let audiobook = HomeMoreItemRowPresentation(
      item: makeItem(isDownloaded: true, audioDownloaded: true, supplementDownloaded: true),
      section: .downloaded)
    let mixed = HomeMoreItemRowPresentation(
      item: makeItem(
        hasReadableEbook: true, isDownloaded: true, audioDownloaded: true, ebookDownloaded: true,
        supplementDownloaded: true),
      section: .downloaded)
    let elsewhere = HomeMoreItemRowPresentation(
      item: makeItem(isDownloaded: true, audioDownloaded: true, supplementDownloaded: true),
      section: .recentlyAdded)

    #expect(audiobook.metadataText == "Audiobook + PDF")
    #expect(mixed.metadataText == "Audiobook + eBook + PDF")
    #expect(elsewhere.metadataText.hasPrefix("Audiobook") && !elsewhere.metadataText.contains("PDF"))
  }

  @Test("format-aware downloaded wording does not leak into other sections")
  func downloadedWordingIsScopedToDownloadedSection() {
    let item = makeItem(
      hasReadableEbook: true, durationSeconds: nil, audioDownloaded: true, ebookDownloaded: true)

    #expect(
      HomeMoreItemRowPresentation(item: item, section: .recentlyAdded).metadataText == "Audiobook")
  }

  @Test func missingAuthorLeavesNoEmptySubtitleLine() {
    let row = HomeMoreItemRowPresentation(item: makeItem(author: nil), section: .downloaded)

    #expect(row.subtitle == nil)
  }

  @Test func accessibilityLabelSpeaksEveryVisibleLineOnce() {
    let row = HomeMoreItemRowPresentation(item: makeItem(), section: .continueListening)

    #expect(
      row.accessibilityLabel
        == "A Parade of Horribles, Matt Dinniman, Audiobook, 25% · 9h 0m left")
  }
}

/// The disclosure page answers the same provenance question its shelf does, in the place a list row
/// has for it: the metadata line, rather than a mark on a 56-point thumbnail.
@Suite struct HomeMoreItemRowSourceTests {
  @Test func aMixedPageNamesTheServerOnItsServerPodcastRows() throws {
    let server = HomeMoreItemRowPresentation(
      item: makeItem(id: "li_empire", category: .podcast), section: .downloaded,
      surfaceMixesSources: true)
    #expect(server.metadataText == "Podcast · On your server")
    #expect(server.accessibilityLabel.contains("On your server"))

    let feedID = try #require(PodcastSourceIdentity.rss(feedId: 17)).itemId
    let feed = HomeMoreItemRowPresentation(
      item: makeItem(id: feedID, category: .podcast), section: .downloaded,
      surfaceMixesSources: true)
    #expect(feed.metadataText == "Podcast")
  }

  @Test func anUnmixedPageSaysNothingAboutSource() {
    let row = HomeMoreItemRowPresentation(
      item: makeItem(id: "li_empire", category: .podcast), section: .downloaded)
    #expect(row.metadataText == "Podcast")
  }

  /// The suffix joins the line the same way on a progress-bearing page, where the metadata is the
  /// badge alone.
  @Test func theSourceJoinsAProgressPagesMetadataToo() {
    let row = HomeMoreItemRowPresentation(
      item: makeItem(id: "li_empire", category: .podcast), section: .continueListening,
      surfaceMixesSources: true)
    #expect(row.metadataText == "Podcast · On your server")
  }

  @Test func anAudiobookIsNeverMarked() {
    let row = HomeMoreItemRowPresentation(
      item: makeItem(id: "li_book", category: .audiobook, durationSeconds: nil),
      section: .downloaded, surfaceMixesSources: true)
    #expect(row.metadataText == "Audiobook")
  }
}
