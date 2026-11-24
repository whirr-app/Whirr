import ABSApi
import AppModel
import DesignSystem
import Foundation
import Persistence
import SwiftUI
import Testing

@testable import Whirr

/// Config constants for the App target, with no view rendering or model. Compact uses the
/// chapters-sheet detent idiom, widened to `.large` for full show notes. Regular uses the shared
/// page-sized host.
@Suite struct PodcastEpisodeCardViewPresentationTests {
  private typealias Metric = PodcastEpisodeCardViewPresentation.Metric

  /// The sheet draws its artwork larger than the row but requests the row's width. Cover bytes
  /// are cached per URL width, so a width unique to this sheet always misses. Offline, that miss
  /// puts generated art over a cover the device has already downloaded. The bulk cache pass warms
  /// the row width.
  @Test func theCardRequestsTheWarmedRowWidthWhileDrawingLarger() {
    #expect(Metric.artworkDisplaySize == PodcastEpisodeCardRowMetrics.coverSize)
    #expect(Metric.coverSize > Metric.artworkDisplaySize)
  }

  @Test func sheetWashUsesTheShowIDAndNeutralFallsBackToAppChrome() {
    #expect(PodcastEpisodeCardViewPresentation.washKey(for: "show-1") == "show-1")
    #expect(
      PodcastEpisodeCardViewPresentation.playAccentSource(for: .neutral) == .appChrome)
  }

  @Test func sheetPlayAccentUsesAResolvedWash() {
    let wash = CoverWash.from(hue: 0.4, saturation: 0.8, brightness: 0.6)
    #expect(PodcastEpisodeCardViewPresentation.playAccentSource(for: wash) == .wash)
  }

  @Test func controlMotionBecomesImmediateUnderReduceMotion() {
    #expect(PodcastEpisodeCardViewPresentation.motion(reduceMotion: false) == .animated)
    #expect(PodcastEpisodeCardViewPresentation.motion(reduceMotion: true) == .reduced)
  }

  @Test func detentsAreMediumAndLarge() {
    #expect(PodcastEpisodeCardViewPresentation.detents == [.medium, .large])
  }

  @Test("compact episode-card mode keeps the medium and large detents")
  func compactEpisodeCardModeKeepsMediumAndLargeDetents() {
    #expect(
      SheetViewPresentation.mode(for: .compact, role: .episodeCard) == .compactDetents)
    #expect(PodcastEpisodeCardViewPresentation.detents == [.medium, .large])
  }

  @Test("regular episode-card mode uses page sizing without detents")
  func regularEpisodeCardModeUsesPageSizingWithoutDetents() throws {
    #expect(
      SheetViewPresentation.mode(for: .regular, role: .episodeCard) == .regularPage)

    let source = try ViewSourceScan.source(declaring: "PodcastEpisodeCardSheet")
    let text = try ViewSourceScan.executableText(of: source)
    let regularStart = try #require(text.range(of: "case .regularPage:"))
    let regularEnd = try #require(
      text.range(
        of: "case .compactLarge, .regularForm, .regularFitted, .regularFullPage, .exempt:",
        range: regularStart.upperBound..<text.endIndex))
    let regularBranch = text[regularStart.lowerBound..<regularEnd.lowerBound]

    // Not `.fitted`. The card body is one `ScrollView` whose ideal height is its content's, and
    // that height is measured while the model is `.loading`. Fitting would size the sheet to the
    // spinner and it would never grow once the episode arrived. `.regularForm` avoids `.fitted`
    // for the same reason.
    #expect(regularBranch.contains(".presentationSizing(.page)"))
    #expect(regularBranch.contains(".fitted(") == false)
    #expect(regularBranch.contains(".presentationDetents(") == false)
  }

  @Test("regular episode-card metrics cap the card and reuse the shared reading measure")
  func regularEpisodeCardMetricsUseUpperBounds() {
    #expect(Metric.notesReadingMeasure == AdaptiveLayoutPresentation.readingMeasure)
  }

  @Test("episode-card notes keep vertical wrapping without an app truncation rule")
  func notesWrapWithoutAnAppTruncationRule() throws {
    let source = try ViewSourceScan.source(declaring: "PodcastEpisodeCardView")
    let text = try ViewSourceScan.executableText(of: source)
    let notesStart = try #require(text.range(of: "private func notesSection("))
    let notesEnd = try #require(
      text.range(of: "private func playRow(", range: notesStart.upperBound..<text.endIndex))
    let notesImplementation = text[notesStart.lowerBound..<notesEnd.lowerBound]

    #expect(notesImplementation.contains(".fixedSize(horizontal: false, vertical: true)"))
    #expect(notesImplementation.contains(".frame(maxWidth: Metric.notesReadingMeasure"))
    #expect(notesImplementation.contains(".lineLimit(") == false)
    #expect(notesImplementation.contains(".minimumScaleFactor(") == false)
    #expect(notesImplementation.contains(".frame(height:") == false)
    #expect(notesImplementation.contains(".frame(minHeight:") == false)
    #expect(notesImplementation.contains(".frame(maxHeight:") == false)
  }

  /// The tile is several times a row thumbnail's size, and the sheet's corners are far rounder
  /// than `WhirrSpacing.xxSmall`. At 72pt a 4pt clip reads as a hard square in a soft container,
  /// so the card sets its own radius.
  @Test func coverRadiusIsSoftenedForTheCardsLargerTile() {
    #expect(Metric.coverCornerRadius > WhirrSpacing.xxSmall)
    #expect(Metric.coverCornerRadius >= Metric.coverSize / 8)
  }

  /// The primary button and the three trailing controls share one height, so the row reads as one
  /// cluster. Each one clears the HIG minimum on its own.
  @Test func controlRowSharesOneHeightAboveTheMinimumTarget() {
    #expect(Metric.controlDiameter == Metric.playButtonMinHeight)
    #expect(Metric.controlDiameter >= WhirrMetric.minimumTouchTarget)
  }

  /// The sheet's grab indicator sits above this content, so uniform padding would pin the artwork
  /// under a bar. The top edge is the largest.
  @Test func topPaddingClearsTheGrabIndicator() {
    #expect(Metric.topPadding > Metric.bottomPadding)
    #expect(Metric.topPadding > Metric.horizontalPadding)
  }

  /// A completed download is the only device state where the trailing control destroys something
  /// the user waited for, so it asks first. Other states act immediately.
  @Test func onlyACompletedDownloadAsksBeforeRemoving() {
    #expect(PodcastEpisodeCardViewPresentation.requiresDeleteConfirmation(for: .completed))
    for kind in DownloadControlKind.allCases where kind != .completed {
      #expect(PodcastEpisodeCardViewPresentation.requiresDeleteConfirmation(for: kind) == false)
    }
  }

  /// Taken from the audiobook detail bubble's policy, so the two surfaces cannot disagree on which
  /// states destroy data.
  @Test func deleteConfirmationFollowsTheAudiobookBubblePolicy() {
    for kind in DownloadControlKind.allCases {
      #expect(
        PodcastEpisodeCardViewPresentation.requiresDeleteConfirmation(for: kind)
          == (ItemDetailDownloadBubblePresentation.tapBehavior(for: kind) == .confirm))
    }
  }

  /// The row answers `nil` here. Its only remaining action is destructive, so it stays behind the
  /// ellipsis. The card offers it, since the confirmation is itself a second gesture.
  @Test func aCompletedDownloadOffersTheRemoveTheRowWithholds() {
    #expect(
      PodcastEpisodeCardViewPresentation.primaryDeviceAction(
        kind: .completed, rowAction: nil, contextActions: [.removeDownload]) == .removeDownload)
  }

  /// Still drawn from the canonical menu, so the control never offers what the menu withholds.
  @Test func aCompletedDownloadWithNoRemoveInTheMenuAnswersNoTap() {
    #expect(
      PodcastEpisodeCardViewPresentation.primaryDeviceAction(
        kind: .completed, rowAction: nil, contextActions: []) == nil)
  }

  /// Covers what the two `primaryDeviceAction` cases above cannot, because they pass the action
  /// list by hand. In the app the list comes from `presentation.contextActions`. The
  /// `.episodeDetail` menu suppresses `.removeDownload` because this control carries it, so
  /// reading it there would draw a trash glyph with no action behind it.
  @Test func aDownloadedEpisodeSheetOffersATappableRemove() {
    let control = PodcastEpisodeCardViewPresentation.downloadControl(
      for: Self.cardPresentation(downloadStatus: .completed))
    #expect(control.episodeAction == .removeDownload)
    #expect(control.action != nil)
  }

  /// The download tap must keep working for an undownloaded episode.
  @Test func anUndownloadedEpisodeSheetOffersATappableDownload() {
    let control = PodcastEpisodeCardViewPresentation.downloadControl(
      for: Self.cardPresentation(downloadStatus: .notDownloaded))
    #expect(control.episodeAction == .download)
    #expect(control.action != nil)
  }

  /// The failed control is the row's explain-first control. The retry sits behind it as
  /// `episodeAction` for the alert's Try Again, never for the tap.
  @Test func aFailedDownloadSheetExplainsBeforeRetrying() {
    let control = PodcastEpisodeCardViewPresentation.downloadControl(
      for: Self.cardPresentation(downloadStatus: .failed(category: .transport)))
    #expect(control.action?.id == PodcastEpisodeViewAction.explainDownloadFailure.rawValue)
    #expect(control.episodeAction == .resumeDownload)
    #expect(PodcastEpisodeCardViewPresentation.requiresDeleteConfirmation(for: .failed) == false)
  }

  @Test func knownZeroUsesRingAndUnknownZeroUsesSpinnerState() {
    let known = PodcastEpisodeCardViewPresentation.downloadControl(
      for: Self.cardPresentation(
        downloadStatus: .downloading(progressFraction: 0), isDownloadSizeKnown: true))
    let unknown = PodcastEpisodeCardViewPresentation.downloadControl(
      for: Self.cardPresentation(
        downloadStatus: .downloading(progressFraction: 0), isDownloadSizeKnown: false))

    #expect(known.deviceStatus.isIndeterminate == false)
    #expect(known.deviceStatus.clampedProgressFraction == 0)
    #expect(unknown.deviceStatus.isIndeterminate)
    #expect(unknown.deviceStatus.clampedProgressFraction == nil)
  }

  /// The control reads the unsuppressed device set, not the sheet's own menu. The two
  /// disagree on the entries this control presents.
  @Test func theControlReadsTheUnsuppressedDeviceActions() {
    let presentation = Self.cardPresentation(downloadStatus: .completed)
    #expect(presentation.contextActions.contains(.removeDownload) == false)
    #expect(
      PodcastEpisodeCardViewPresentation.deviceActions(for: presentation)
        .contains(.removeDownload))
  }

  /// The sheet already draws a circle around the glyph. The row's enclosed symbols would add a
  /// second ring, so every state uses the bare symbols from the audiobook detail's toolbar control.
  @Test func everySheetDownloadGlyphIsBareInsideItsControl() {
    for kind in DownloadControlKind.allCases {
      let systemImage = PodcastEpisodeCardViewPresentation.systemImage(for: kind)
      #expect(systemImage == ItemDetailDownloadBubblePresentation.systemImage(for: kind))
      #expect(ItemDetailDownloadBubblePresentation.isEnclosed(systemImage) == false)
    }
    #expect(PodcastEpisodeCardViewPresentation.systemImage(for: .notDownloaded) == "arrow.down")
  }

  /// Only `.completed` diverges. `.deleting` and `.pausedAuth` still answer no tap, and every
  /// other actionable state keeps the row's answer rather than a second mapping.
  @Test func everyOtherStateKeepsTheRowsAnswer() {
    for kind in DownloadControlKind.allCases where kind != .completed {
      #expect(
        PodcastEpisodeCardViewPresentation.primaryDeviceAction(
          kind: kind, rowAction: .pauseDownload, contextActions: [.removeDownload])
          == .pauseDownload)
      #expect(
        PodcastEpisodeCardViewPresentation.primaryDeviceAction(
          kind: kind, rowAction: nil, contextActions: [.removeDownload]) == nil)
    }
  }

  /// The card's menu carries neither membership state, because it has no saved row. The bookmark
  /// beside the ellipsis is the control, and `.episodeDetail` suppresses the duplicate row.
  /// The resolved/unresolved distinction matters for the view's bookmark, which waits for a real
  /// answer rather than flickering. That is asserted where the control lives.
  @Test func cardMenuDrawsNoSavedRowWhateverTheMembership() {
    let presentation = Self.cardPresentation()
    for isSaved in [nil, false, true] as [Bool?] {
      let rows = PodcastEpisodeCardViewPresentation.actionRows(
        for: presentation, queueAvailability: .both, isSaved: isSaved)
      #expect(rows.contains { $0.action == .saveForLater || $0.action == .removeFromSaved } == false)
      // Play, the download and the show line are the card's own controls too.
      #expect(rows.contains { $0.action == .playPause } == false)
      #expect(rows.contains { $0.action == .download } == false)
      #expect(rows.contains { $0.action == .openShow } == false)
      // What is left is what the card has nowhere else to offer.
      #expect(rows.map(\.action) == [.playNext, .addToUpNext, .markAsFinished])
    }
  }

  @Test("episode detail carries server actions while the card surface keeps them hidden")
  func serverActionsFollowTheTwoSurfacePolicy() {
    let presentation = Self.cardPresentation()
    let detailRows = PodcastEpisodeCardViewPresentation.actionRows(
      for: presentation,
      queueAvailability: .both,
      serverSave: .enabled,
      serverRemove: .enabled)
    #expect(detailRows.contains { $0.action == .saveToServer })
    #expect(detailRows.contains { $0.action == .removeFromServer })

    let cardActions = PodcastEpisodeCardViewPresentation.deviceActions(for: presentation)
    #expect(cardActions.contains(.saveToServer) == false)
    #expect(cardActions.contains(.removeFromServer) == false)
  }

  /// A downloaded episode the coordinator can transcribe offers Transcript in its own group, with
  /// the player's copy and glyph; one that is not downloaded offers none.
  @Test func cardMenuOffersTranscriptForADownloadedEpisode() {
    let sections = PodcastEpisodeCardViewPresentation.actionSections(
      for: Self.cardPresentation(downloadStatus: .completed, isFinished: true),
      queueAvailability: .none, isSaved: true, offersTranscript: true)
    #expect(sections.map { $0.map(\.action) } == [[.transcript], [.resetProgress]])
    let row = sections.first?.first
    #expect(row?.display.label == "Transcript")
    #expect(row?.display.systemImage == "quote.bubble")

    let notDownloaded = PodcastEpisodeCardViewPresentation.actionSections(
      for: Self.cardPresentation(downloadStatus: .notDownloaded, isFinished: true),
      queueAvailability: .none, isSaved: true, offersTranscript: true)
    #expect(notDownloaded.joined().contains { $0.action == .transcript } == false)
  }

  /// The episode-detail card passes canonical sections to both its ellipsis and long-press menus.
  /// Flattening them would give one unbroken list, where every other episode menu shows separators.
  @Test func cardMenuPreservesCanonicalSections() {
    let sections = PodcastEpisodeCardViewPresentation.actionSections(
      for: Self.cardPresentation(downloadStatus: .completed, isFinished: true),
      queueAvailability: .none,
      isSaved: true)

    // A finished, downloaded episode with nothing queueable left. Every section except progress is
    // suppressed or empty, so the separators collapse with them.
    #expect(sections.map { $0.map(\.action) } == [[.resetProgress]])
    #expect(
      PodcastEpisodeCardViewPresentation.actionRows(
        for: Self.cardPresentation(downloadStatus: .completed, isFinished: true),
        queueAvailability: .none,
        isSaved: true
      )
      .map(\.action) == sections.flatMap { $0 }.map(\.action))
  }

  /// The card folds the progress entries as every item menu does, and still dispatches a
  /// submenu's choice by the flat row it came from.
  @Test func cardMenuFoldsProgressIntoOneSubmenu() {
    let actions: [AppModel.MediaItemAction] = [.markAsFinished, .resetProgress]
    let sections = [
      actions.compactMap { action in
        PodcastShowViewPresentation.contextAction(action, creator: nil).map {
          PodcastEpisodeCardViewPresentation.ActionRow(action: action, display: $0)
        }
      }
    ]
    #expect(sections[0].count == 2)
    let drawn = PodcastEpisodeCardViewPresentation.menuRows(sections)
    #expect(drawn.map { $0.map(\.label) } == [[MediaActionCopy.progress.title]])
    #expect(drawn[0][0].children.map(\.id) == sections[0].map(\.id))
  }

  /// The card's captions show the playhead, so its body re-runs each time the position is saved
  /// (every fifteen seconds). Rebuilding a presented `Menu`'s source pulses its glass, as the
  /// ellipsis did after starting an episode from the card. `PodcastEpisodeCardActionMenu` is
  /// compared on its rows, so a moved position changes what the card draws and nothing in the menu.
  @Test("a position tick moves the card's captions but not its menu rows")
  func aPositionTickLeavesTheMenuRowsUnchanged() {
    let started = Self.cardPresentation(progressSeconds: 10)
    let later = Self.cardPresentation(progressSeconds: 90)

    #expect(started != later)
    #expect(started.remainingProgressFraction != later.remainingProgressFraction)
    #expect(Self.menuRows(started) == Self.menuRows(later))
  }

  /// The same rule applies to the transfer fraction, which moves the download ring and must not
  /// reach the menu.
  @Test("download progress moves the ring but not the menu rows")
  func downloadProgressLeavesTheMenuRowsUnchanged() {
    #expect(
      Self.menuRows(Self.cardPresentation(downloadStatus: .downloading(progressFraction: 0.1)))
        == Self.menuRows(Self.cardPresentation(downloadStatus: .downloading(progressFraction: 0.9))))
  }

  /// The rows a menu is compared on, built the way the card builds them.
  private static func menuRows(
    _ presentation: PodcastEpisodeCardPresentation
  ) -> [[PodcastEpisodeCardViewPresentation.ActionRow]] {
    PodcastEpisodeCardViewPresentation.actionSections(
      for: presentation, queueAvailability: .none, isSaved: false)
  }

  @Test("the episode card source keeps the canonical RSS feed identity")
  func episodeCardSourceKeepsCanonicalRSSIdentity() throws {
    let artworkURL = URL(string: "https://images.example.com/show.jpg")!
    let feedURL = URL(string: "https://example.com/show.xml")!
    let presentation = Self.cardPresentation(
      artworkURL: artworkURL, artworkFeedURL: feedURL)
    let itemID = try #require(PodcastSourceIdentity.rss(feedId: 7)).itemId
    let source = try #require(presentation.providerArtworkSource(for: itemID))

    guard case .rss(let rssSource) = source else {
      Issue.record("expected the episode card to resolve an RSS artwork source")
      return
    }
    #expect(rssSource.feedIdentity == itemID)
    #expect(rssSource.artworkURL == artworkURL)
    #expect(rssSource.feedURL == feedURL)
  }

  @Test("a loaded RSS episode card seeds its show route")
  func loadedRSSCardSeedsItsShowRoute() {
    let route = PodcastEpisodeCardView.showRoute(
      itemID: "rss:7", presentation: Self.cardPresentation())
    let seed = ItemSummary(
      serverItemId: "rss:7", mediaKind: "podcast", title: "Show", author: "Creator",
      durationSeconds: nil, category: .podcast)

    #expect(route == .podcastShow(itemID: "rss:7", seed: seed))
  }

  @Test("an ABS episode card keeps its existing unseeded show route")
  func absCardKeepsItsExistingUnseededShowRoute() {
    #expect(
      PodcastEpisodeCardView.showRoute(itemID: "abs-show", presentation: Self.cardPresentation())
        == .podcastShow(itemID: "abs-show"))
  }

  @Test("the card speaks the Watch mark as its own phrase after the metadata, as the row does")
  func cardMetadataSpeaksTheWatchMark() {
    let metadata = "November 19, 2026, 34 minutes"
    #expect(
      PodcastEpisodeCardViewPresentation.metadataAccessibilityLabel(metadata, watchMark: nil)
        == metadata)
    #expect(
      PodcastEpisodeCardViewPresentation.metadataAccessibilityLabel(metadata, watchMark: .onWatch)
        == "\(metadata). On Apple Watch")
    #expect(
      PodcastEpisodeCardViewPresentation.metadataAccessibilityLabel(metadata, watchMark: .sending)
        == "\(metadata). Sending to Apple Watch")
  }

  static func cardPresentation(
    downloadStatus: ItemDownloadStatus = .notDownloaded,
    isFinished: Bool = false,
    artworkURL: URL? = nil,
    artworkFeedURL: URL? = nil,
    isDownloadSizeKnown: Bool = true,
    progressSeconds: Double? = nil
  ) -> PodcastEpisodeCardPresentation {
    PodcastEpisodeCardPresentation(
      context: PodcastEpisodeContext(
        episode: PodcastEpisodeSummary(
          id: "episode-1", title: "Episode", subtitle: nil, episodeDescription: nil,
          seasonNumber: nil, episodeNumber: nil, episodeType: nil, durationSeconds: 120,
          sizeBytes: nil, publishedAt: nil,
          progressSeconds: progressSeconds ?? (isFinished ? 120 : 0),
          isPlayed: isFinished,
          isFinished: isFinished, downloadStatus: downloadStatus, isAvailableOnServer: true,
          isDownloadSizeKnown: isDownloadSizeKnown),
        showTitle: "Show", showAuthor: "Creator", artworkURL: artworkURL,
        artworkFeedURL: artworkFeedURL))
  }
}

/// The compact half sheet uses the system's Liquid Glass at `.medium`. Its secondary copy uses
/// the hierarchical `.primary` rather than the fixed grey token, so the system can render it
/// against the glass. Not `.secondary`, which tops out near 3.4:1 on white. The same sheet is
/// opaque at `.large`. Other hosts keep the token.
@Suite struct PodcastEpisodeCardGlassInkTests {
  private typealias Presentation = PodcastEpisodeCardViewPresentation

  @Test func onlyTheHalfSheetDrawsSecondaryCopyInHierarchicalInk() {
    #expect(Presentation.secondaryInk(onSystemGlass: true) == .hierarchicalPrimary)
    #expect(Presentation.secondaryInk(onSystemGlass: false) == .token)
  }

}
