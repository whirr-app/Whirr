import SwiftUI
import Testing

@testable import DesignSystem

/// Component semantics. These assert the values the views derive (combined VoiceOver
/// label/value, per-state textual and symbolic signals, clamped fractions, touch-target metrics)
/// rather than snapshotting the `View` structs. A `.dump` snapshot of a SwiftUI value type
/// reflects stored properties only. It never evaluates `body` or records a computed accessibility
/// string, so it cannot fail when these semantics regress.
@Suite("Podcast and queue components")
@MainActor
struct PodcastComponentTests {
  @Test("podcast episode summary row renders its episode metadata and forwards selection once")
  func podcastEpisodeSummaryRowRendersMetadataAndSelectsOnce() {
    var selectionCount = 0
    let row = PodcastEpisodeSummaryRow(
      title: "The Mystery of the Missing Hit",
      showTitle: "Decoder Ring",
      dateText: "12 July 2026",
      durationText: "42 minutes",
      accessibilityLabel:
        "The Mystery of the Missing Hit, Decoder Ring, 12 July 2026, 42 minutes",
      coverSize: 44,
      cover: { Color.clear },
      onSelect: { selectionCount += 1 }
    )

    #expect(
      row.visibleText == [
        "The Mystery of the Missing Hit", "Decoder Ring", "12 July 2026", "42 minutes",
      ])
    #expect(row.metadataText == "12 July 2026 · 42 minutes")
    #expect(
      row.accessibilityLabel
        == "The Mystery of the Missing Hit, Decoder Ring, 12 July 2026, 42 minutes")
    row.onSelect()
    #expect(selectionCount == 1)
  }

  @Test("podcast episode summary row honours the caller-supplied cover size")
  func podcastEpisodeSummaryRowHonoursCallerSuppliedCoverSize() {
    let row = PodcastEpisodeSummaryRow(
      title: "Episode",
      showTitle: "Show",
      dateText: "Date",
      durationText: "Duration",
      accessibilityLabel: "Episode, Show, Date, Duration",
      coverSize: 72,
      cover: { Color.clear },
      onSelect: {}
    )

    #expect(row.coverSize == 72)
  }

  @Test func showHeaderCombinesCallerSuppliedSemantics() {
    let full = makeHeader()
    #expect(full.accessibilityLabel == "Decoder Ring. Slate")
    #expect(full.isAccessibilityHeader)

    let minimal = PodcastShowHeaderView(
      title: "Decoder Ring", subtitle: nil,
      badgeLabel: "Podcast", cover: { Color.clear })
    #expect(minimal.accessibilityLabel == "Decoder Ring")
  }

  @Test("an absent subtitle is omitted from the header's combined label, never voiced blank")
  func showHeaderOmitsAbsentSubtitleFromItsLabel() {
    let noSubtitle = PodcastShowHeaderView(
      title: "Decoder Ring", subtitle: nil,
      badgeLabel: "Podcast", cover: { Color.clear })
    #expect(noSubtitle.accessibilityLabel == "Decoder Ring")
    #expect(noSubtitle.isAccessibilityHeader)
  }

  @Test("a source caption is voiced after the subtitle and absent when there is none")
  func showHeaderVoicesItsSourceCaptionOnlyWhenPresent() {
    let captioned = PodcastShowHeaderView(
      title: "Decoder Ring", subtitle: "Slate", sourceCaption: "Followed on this device",
      badgeLabel: "Podcast", cover: { Color.clear })
    #expect(captioned.accessibilityLabel == "Decoder Ring. Slate. Followed on this device")

    let blank = PodcastShowHeaderView(
      title: "Decoder Ring", subtitle: nil, sourceCaption: "",
      badgeLabel: "Podcast", cover: { Color.clear })
    #expect(blank.accessibilityLabel == "Decoder Ring")
    #expect(makeHeader().accessibilityLabel == "Decoder Ring. Slate")

    let served = PodcastShowHeaderView(
      title: "Decoder Ring", subtitle: "Slate", sourceCaption: "On your Audiobookshelf server",
      sourceCaptionSymbolName: PodcastShowHeaderView<Color>.serverCaptionSymbolName,
      badgeLabel: "Podcast", cover: { Color.clear })
    #expect(served.sourceCaptionSymbolName == "server.rack")
    #expect(captioned.sourceCaptionSymbolName == "iphone")
  }

  @Test("the source caption's glyph names where the show lives, apart from the podcast badge")
  func showHeaderSourceGlyphsAreDistinctFromThePodcastBadge() {
    let badge = MediaKindBadgeView(kind: .podcast, label: "Podcast").systemImage
    #expect(PodcastShowHeaderView<Color>.feedCaptionSymbolName != badge)
    #expect(PodcastShowHeaderView<Color>.serverCaptionSymbolName != badge)
    #expect(PodcastShowHeaderView<Color>.sourceCaptionGlyphSpacing == WhirrSpacing.xxSmall)
  }

  @Test("the title counts as visible from the scroll view's bounds, not a visibility event")
  func showHeaderTitleVisibilityFollowsGeometry() {
    let title = CGRect(x: 0, y: 0, width: 200, height: 40)
    // Fully inside the scroll view.
    #expect(
      PodcastShowHeaderView<Color>.isTitleVisible(
        titleFrame: title, scrollBounds: CGRect(x: 0, y: -100, width: 400, height: 800)))
    // A quarter still showing clears the 20% threshold.
    #expect(
      PodcastShowHeaderView<Color>.isTitleVisible(
        titleFrame: title, scrollBounds: CGRect(x: 0, y: 30, width: 400, height: 800)))
    // A tenth showing does not.
    #expect(
      PodcastShowHeaderView<Color>.isTitleVisible(
        titleFrame: title, scrollBounds: CGRect(x: 0, y: 36, width: 400, height: 800)) == false)
    // Scrolled entirely past.
    #expect(
      PodcastShowHeaderView<Color>.isTitleVisible(
        titleFrame: title, scrollBounds: CGRect(x: 0, y: 300, width: 400, height: 800)) == false)
    // Outside any scroll view, or before layout, the header names the show itself.
    #expect(PodcastShowHeaderView<Color>.isTitleVisible(titleFrame: title, scrollBounds: nil))
    #expect(
      PodcastShowHeaderView<Color>.isTitleVisible(titleFrame: .zero, scrollBounds: .zero))
  }

  /// The header shows the first three lines of one full layout and the continuation row the rest,
  /// so the two meet exactly and the header never changes height.
  @Test("the synopsis splits into a three-line head and a tail that continues from it")
  func showHeaderSynopsisWindows() {
    typealias Window = PodcastShowSynopsisWindow
    #expect(PodcastShowHeaderView<Color>.collapsedSynopsisLineLimit == 3)

    #expect(Window.head.height(collapsedHeight: 60, fullHeight: 300) == 60)
    #expect(Window.head.offset(collapsedHeight: 60, fullHeight: 300) == 0)
    #expect(Window.tail.height(collapsedHeight: 60, fullHeight: 300) == 240)
    #expect(Window.tail.offset(collapsedHeight: 60, fullHeight: 300) == -60)
    // A blurb shorter than three lines is all head.
    #expect(Window.head.height(collapsedHeight: 60, fullHeight: 40) == 40)
    #expect(Window.tail.height(collapsedHeight: 60, fullHeight: 40) == 0)

    #expect(Window.isTruncated(collapsedHeight: 60, fullHeight: 300))
    #expect(Window.isTruncated(collapsedHeight: 60, fullHeight: 60.4) == false)
    #expect(PodcastShowHeaderView<Color>.synopsisAnimation == .snappy(duration: 0.3))
  }

  /// A feed blurb runs to thousands of characters, so folding it into the header's combined label
  /// would make VoiceOver read the whole synopsis before reaching anything actionable. It stays
  /// its own element with its own label and an expansion hint instead.
  @Test("the synopsis stays a separate element rather than joining the header's combined label")
  func showHeaderKeepsSynopsisOutOfItsCombinedLabel() {
    let header = makeHeader(synopsis: "A show about shows.")
    #expect(header.accessibilityLabel == "Decoder Ring. Slate")
    #expect(header.synopsisAccessibilityLabel == "A show about shows.")
    #expect(header.synopsisAccessibilityHint(isExpanded: false) == "Shows the full description")
    #expect(header.synopsisAccessibilityHint(isExpanded: true) == "Shows less")

    let withoutSynopsis = makeHeader()
    #expect(withoutSynopsis.synopsisAccessibilityLabel == nil)
    #expect(withoutSynopsis.synopsisAccessibilityHint(isExpanded: false) == nil)
    #expect(makeHeader(synopsis: "").synopsisAccessibilityLabel == nil)
  }

  @Test func episodeRowCombinesLabelValueAndTraits() {
    let row = makeEpisodeRow()
    #expect(row.accessibilityLabel == "The Mystery of the Missing Hit. A Decoder Ring investigation")
    #expect(
      row.accessibilityValue
        == "12 July 2026. 42 minutes. 18 minutes remaining. In progress. Stored on server. Downloading, 58%")
    #expect(row.deviceStatus.kind == .downloading)
    #expect(row.updatesFrequently)
    #expect(row.contextMenuAccessibilityLabel == "Episode actions")
    #expect(row.contextMenuAccessibilityHint == "Shows actions for this episode")
  }

  @Test("an in-progress downloading row surfaces every semantic signal the row is given")
  func episodeRowInProgressDownloadingSurfacesEverySemanticSignal() {
    let row = makeEpisodeRow()

    #expect(row.metadataTexts == ["12 July 2026", "42 minutes"])
    #expect(row.clampedPlaybackProgressFraction == 0.58)
    #expect(row.deviceStatus.clampedProgressFraction == 0.58)
    #expect(row.playbackStatus == .inProgress)
    #expect(row.serverAvailability == .available)

    // Every context action reaches the row intact (label, hint, symbol and role), so the menu
    // can render named, hinted, role-carrying entries rather than icons alone.
    #expect(row.contextActions.map(\.id) == ["up-next", "download", "remove"])
    #expect(row.contextActions.map(\.label) == ["Add to Up Next", "Download", "Remove Download"])
    #expect(
      row.contextActions.map(\.hint) == [
        "Adds this episode to the queue", "Downloads this episode",
        "Removes this episode from this device",
      ])
    #expect(row.contextActions.allSatisfy { $0.systemImage.isEmpty == false })
    #expect(row.contextActions.map(\.role) == [.standard, .standard, .destructive])
    #expect(row.contextActions.allSatisfy { $0.isEnabled })
    #expect(row.contextActionSections.map { $0.map(\.id) } == [["up-next"], ["download", "remove"]])
    #expect(row.contextActions == row.contextActionSections.flatMap { $0 })
  }

  @Test("the Watch mark has one glyph and is spoken as its own phrase, apart from the download label")
  func watchMarkSpeaksItsOwnState() {
    #expect(
      PodcastEpisodeWatchMark.allCases.allSatisfy { $0.systemImage == "applewatch" },
      "pending and delivered differ in ink, not in glyph")
    #expect(PodcastEpisodeWatchMark.sending.accessibilityText == "Sending to Apple Watch")
    #expect(PodcastEpisodeWatchMark.onWatch.accessibilityText == "On Apple Watch")

    let row = makeEpisodeRow(
      deviceStatus: PodcastEpisodeDeviceDownloadStatus(
        kind: .completed, text: "Downloaded", systemImage: "arrow.down.circle.fill"),
      watchMark: .onWatch)
    #expect(row.watchMark == .onWatch)
    #expect(row.deviceStatusText == "Downloaded", "never folded into the download status")
    #expect(
      row.accessibilityValue.hasSuffix(". Downloaded. On Apple Watch"),
      "the Watch mark is its own phrase after the download status")
  }

  @Test("playback and server states carry distinct production symbols, never colour alone")
  func playbackAndServerSymbolsAreDistinctPerState() {
    let playbackSymbols = PodcastEpisodePlaybackStatus.allCases.map(\.systemImage)
    #expect(playbackSymbols.allSatisfy { $0.isEmpty == false })
    #expect(
      Set(playbackSymbols).count == PodcastEpisodePlaybackStatus.allCases.count,
      "two playback states sharing a symbol would leave colour as the only difference")

    let serverSymbols = PodcastServerAudioAvailability.allCases.map(\.systemImage)
    #expect(serverSymbols.allSatisfy { $0.isEmpty == false })
    #expect(
      Set(serverSymbols).count == PodcastServerAudioAvailability.allCases.count,
      "two availability states sharing a symbol would leave colour as the only difference")
  }

  @Test(
    "episode row status indicators reach VoiceOver as words, not colour",
    arguments: [
      (
        PodcastEpisodePlaybackStatus.unplayed, "Unplayed",
        PodcastServerAudioAvailability.available, "Stored on server",
        DownloadControlKind.notDownloaded, "Not downloaded"
      ),
      (
        PodcastEpisodePlaybackStatus.inProgress, "In progress",
        PodcastServerAudioAvailability.unavailable, "Unavailable for download",
        DownloadControlKind.downloading, "Downloading"
      ),
      (
        PodcastEpisodePlaybackStatus.played, "Played",
        PodcastServerAudioAvailability.available, "Stored on server",
        DownloadControlKind.completed, "Downloaded"
      ),
    ])
  func episodeRowStatusIndicatorsAreNotColorOnly(
    playback: PodcastEpisodePlaybackStatus,
    playbackText: String,
    server: PodcastServerAudioAvailability,
    serverText: String,
    deviceKind: DownloadControlKind,
    deviceText: String
  ) {
    let row = makeEpisodeRow(
      playbackStatus: playback,
      playbackStatusText: playbackText,
      serverAvailability: server,
      serverAvailabilityText: serverText,
      deviceStatus: PodcastEpisodeDeviceDownloadStatus(
        kind: deviceKind, text: deviceText, systemImage: "circle.dashed"))

    // The row's own combined value is what VoiceOver reads: all three state words must survive it.
    #expect(row.accessibilityValue.contains(playbackText))
    #expect(row.accessibilityValue.contains(serverText))
    #expect(row.accessibilityValue.contains(deviceText))
    #expect(row.accessibilityValue.contains(playback.systemImage) == false, "symbols are not spoken")
    #expect(row.updatesFrequently == (deviceKind == .downloading))
  }

  @Test("the three representative episode states are mutually distinguishable without colour")
  func episodeRowStatesProduceDistinctAccessibilityValues() {
    let values = [
      makeEpisodeRow(
        progressText: nil, playbackProgressFraction: nil, playbackStatus: .unplayed,
        playbackStatusText: "Unplayed", serverAvailabilityText: "Stored on server",
        deviceStatus: PodcastEpisodeDeviceDownloadStatus(
          kind: .notDownloaded, text: "Not downloaded", systemImage: "arrow.down.circle")),
      makeEpisodeRow(),
      makeEpisodeRow(
        progressText: nil, playbackProgressFraction: nil, playbackStatus: .played,
        playbackStatusText: "Played", serverAvailability: .unavailable,
        serverAvailabilityText: "Unavailable for download",
        deviceStatus: PodcastEpisodeDeviceDownloadStatus(
          kind: .completed, text: "Downloaded", systemImage: "checkmark.circle.fill")),
    ].map(\.accessibilityValue)

    #expect(Set(values).count == values.count)
  }

  @Test("a downloaded episode being checked for ads says so after its downloaded state")
  func episodeRowCheckingForAds() {
    let downloaded = PodcastEpisodeDeviceDownloadStatus(
      kind: .completed, text: "Downloaded", systemImage: "checkmark.circle.fill")
    let row = makeEpisodeRow(deviceStatus: downloaded, isCheckingForAds: true)

    #expect(row.showsCheckingForAds)
    #expect(row.deviceStatusText == "Downloaded, checking for ads")
    #expect(row.accessibilityValue.hasSuffix("Downloaded, checking for ads"))
    #expect(makeEpisodeRow(deviceStatus: downloaded).showsCheckingForAds == false)
  }

  @Test("only a downloaded episode can show the ad check")
  func episodeRowCheckingForAdsNeedsTheFile() {
    let row = makeEpisodeRow(isCheckingForAds: true)

    #expect(row.deviceStatus.kind == .downloading)
    #expect(row.showsCheckingForAds == false)
    #expect(row.deviceStatusText == "Downloading, 58%")
  }

  @Test func episodeRowPreservesUnknownDateAndDurationCopy() {
    let row = makeEpisodeRow(
      dateText: "Date unknown", durationText: "Duration unknown",
      progressText: nil)
    #expect(row.metadataTexts == ["Date unknown", "Duration unknown"])
    #expect(
      row.accessibilityValue
        == "Date unknown. Duration unknown. In progress. Stored on server. Downloading, 58%",
      "unknown metadata is voiced verbatim and no empty segment is joined in")
  }

  @Test("a played, unavailable, undownloaded row voices no numeric progress and no fraction")
  func episodeRowPlayedUnavailableUndownloadedCarriesNoNumericProgress() {
    let row = makeEpisodeRow(
      dateText: "Date unknown", durationText: "Duration unknown",
      progressText: nil, playbackProgressFraction: nil,
      playbackStatus: .played, playbackStatusText: "Played",
      serverAvailability: .unavailable,
      serverAvailabilityText: "Unavailable for download",
      deviceStatus: PodcastEpisodeDeviceDownloadStatus(
        kind: .notDownloaded, text: "Not available",
        systemImage: "arrow.down.circle.dotted"))

    #expect(row.metadataTexts == ["Date unknown", "Duration unknown"])
    #expect(
      row.accessibilityValue
        == "Date unknown. Duration unknown. Played. Unavailable for download. Not available")
    #expect(row.clampedPlaybackProgressFraction == nil)
    #expect(row.deviceStatus.clampedProgressFraction == nil)
    #expect(row.updatesFrequently == false)
  }

  @Test(
    "episode progress clamps to a valid fraction",
    arguments: [(-0.2, 0.0), (0.0, 0.0), (0.42, 0.42), (1.0, 1.0), (1.3, 1.0)]
  )
  func episodeRowClampsProgressFraction(input: Double, expected: Double) {
    #expect(makeEpisodeRow(playbackProgressFraction: input).clampedPlaybackProgressFraction == expected)
  }

  @Test func playbackAndDeviceProgressRemainIndependent() {
    let row = makeEpisodeRow(
      playbackProgressFraction: 0.25,
      deviceStatus: PodcastEpisodeDeviceDownloadStatus(
        kind: .downloading, text: "Downloading, 75%",
        systemImage: "arrow.down.circle.fill", progressFraction: 0.75))

    #expect(row.clampedPlaybackProgressFraction == 0.25)
    #expect(row.deviceStatus.clampedProgressFraction == 0.75)
  }

  @Test func unknownSizeDownloadingRowUsesIndeterminateProgress() {
    let row = makeEpisodeRow(
      deviceStatus: PodcastEpisodeDeviceDownloadStatus(
        kind: .downloading, text: "Downloading…", systemImage: "arrow.down.circle.fill",
        isIndeterminate: true))

    #expect(row.deviceStatus.isIndeterminate)
    #expect(row.deviceStatus.clampedProgressFraction == nil)
    #expect(row.downloadProgressFraction == nil)
    #expect(row.updatesFrequently)
  }

  /// Every episode the screen can show is on the server (an Audiobookshelf client has no other
  /// source), so the sentence is noise. It survives in `accessibilityValue`.
  @Test func episodeRowOmitsServerAvailabilityLabel() {
    let row = makeEpisodeRow()
    #expect(row.visibleStatusTexts.contains("Stored on server") == false)

    let unavailable = makeEpisodeRow(
      serverAvailability: .unavailable, serverAvailabilityText: "Unavailable for download")
    #expect(unavailable.visibleStatusTexts.contains("Unavailable for download") == false)
  }

  /// A bar is for a thing in motion. `.completed` must not carry `progressFraction: 1`, which
  /// would pin a full-width bar under every downloaded episode.
  @Test(
    "the device progress bar exists only while a download is actually moving",
    arguments: DownloadControlKind.allCases)
  func episodeRowDrawsDeviceProgressOnlyWhileDownloading(kind: DownloadControlKind) {
    let row = makeEpisodeRow(
      deviceStatus: PodcastEpisodeDeviceDownloadStatus(
        kind: kind, text: "Status", systemImage: "circle", progressFraction: 0.58))
    #expect(row.downloadProgressFraction == (kind == .downloading ? 0.58 : nil))
  }

  @Test func episodeRowDrawsNoDeviceProgressForACompletedDownload() {
    let row = makeEpisodeRow(
      deviceStatus: PodcastEpisodeDeviceDownloadStatus(
        kind: .completed, text: "Downloaded", systemImage: "checkmark.circle.fill",
        progressFraction: 1))
    #expect(row.downloadProgressFraction == nil)
  }

  /// Visible prose can be dropped only because VoiceOver still hears every word of it.
  @Test func episodeRowAccessibilityValueRetainsServerAvailability() {
    #expect(makeEpisodeRow().accessibilityValue.contains("Stored on server"))
    #expect(
      makeEpisodeRow(
        serverAvailability: .unavailable, serverAvailabilityText: "Unavailable for download"
      ).accessibilityValue.contains("Unavailable for download"))
  }

  /// The playback state is one leading glyph. Its sentence is not printed; the glyph's
  /// accessibility label and the row's value carry it.
  @Test(
    "the leading glyph names the playback state and the sentence stops being printed",
    arguments: PodcastEpisodePlaybackStatus.allCases)
  func episodeRowLeadingGlyphMatchesPlaybackState(status: PodcastEpisodePlaybackStatus) {
    let row = makeEpisodeRow(playbackStatus: status, playbackStatusText: "State \(status)")
    #expect(row.playbackGlyphSystemImage == status.systemImage)
    #expect(row.visibleStatusTexts.contains("State \(status)") == false)
    #expect(row.accessibilityValue.contains("State \(status)"))
  }

  /// A glyph carrying state must differ in shape, not only in colour, so a monochrome or
  /// colour-blind reading of the row still distinguishes played from unplayed.
  @Test func episodeRowGlyphsAreShapeDistinct() {
    let glyphs = PodcastEpisodePlaybackStatus.allCases.map {
      makeEpisodeRow(playbackStatus: $0).playbackGlyphSystemImage
    }
    #expect(glyphs.allSatisfy { $0.isEmpty == false })
    #expect(
      Set(glyphs).count == glyphs.count,
      "two playback states sharing a symbol would leave colour as the only difference")
  }

  /// The trailing download control is a button when the caller names an action for the current
  /// state, and an inert glyph when it does not.
  @Test func episodeRowDownloadControlIsInteractiveOnlyWhenGivenAnAction() {
    var performed: [String] = []
    let interactive = makeEpisodeRow(
      downloadAction: MediaContextAction(
        id: "pause-download", label: "Pause Download",
        hint: "Pauses this device download.", systemImage: "pause.circle"),
      onSelectAction: { performed.append($0.id) })
    #expect(interactive.isDownloadControlInteractive)
    interactive.onSelectAction(interactive.downloadAction!)
    #expect(performed == ["pause-download"])

    let inert = makeEpisodeRow(downloadAction: nil)
    #expect(inert.isDownloadControlInteractive == false)
    #expect(inert.deviceStatus.systemImage.isEmpty == false, "an inert control is still a glyph")
  }

  /// Every piece of row state is a glyph or a bar. The words survive only in
  /// `accessibilityValue`.
  @Test func episodeRowPrintsNoStateProse() {
    let row = makeEpisodeRow()
    #expect(row.visibleStatusTexts.isEmpty)
    #expect(row.accessibilityValue.contains("In progress"))
    #expect(row.accessibilityValue.contains("Downloading, 58%"))
  }

  /// The row reads title, when, what, how far, and the bar is last. `contentLines` is what `body`
  /// iterates, so this cannot drift from what is drawn.
  @Test func episodeRowOrdersSynopsisAboveProgress() {
    #expect(
      makeEpisodeRow().contentLines == [
        .title, .metadata, .synopsis, .progressCaption, .progressBar,
      ])

    let noSynopsis = makeEpisodeRow(synopsis: nil)
    #expect(noSynopsis.contentLines == [.title, .metadata, .progressCaption, .progressBar])
    #expect(makeEpisodeRow(synopsis: "  ").contentLines.contains(.synopsis) == false)

    // The caption is the bar's label; neither appears without the other.
    let noCaption = makeEpisodeRow(progressText: nil)
    #expect(noCaption.contentLines == [.title, .metadata, .synopsis, .progressBar])
    #expect(makeEpisodeRow().synopsisLineLimit == 2)
  }

  /// A bar means "part way through". Nothing started and nothing finished both draw none, so an
  /// unplayed episode has no empty bar and a finished one no full bar.
  @Test(
    "the playback bar exists only between the two ends",
    arguments: [(nil, false), (0.0, false), (0.001, true), (0.58, true), (1.0, false), (1.4, false)]
      as [(Double?, Bool)])
  func episodeRowHidesProgressWhenUnstartedOrFinished(fraction: Double?, isVisible: Bool) {
    let row = makeEpisodeRow(playbackProgressFraction: fraction)
    #expect((row.visiblePlaybackProgressFraction != nil) == isVisible)
    #expect(row.contentLines.contains(.progressBar) == isVisible)
    #expect(row.contentLines.contains(.progressCaption) == isVisible)
  }

  /// A row marked played keeps whatever partial position the listener stopped at, so the fraction
  /// alone still reads as "part way through". The finished state overrides it: no bar and no
  /// caption, as for a row listened to the end.
  @Test(
    "a played row draws no bar whatever position it stopped at",
    arguments: [nil, 0.0, 0.05, 0.58, 1.0] as [Double?])
  func episodeRowHidesProgressWhenPlayed(fraction: Double?) {
    let row = makeEpisodeRow(
      progressText: "Played", playbackProgressFraction: fraction,
      playbackStatus: .played, playbackStatusText: "Played")

    #expect(row.visiblePlaybackProgressFraction == nil)
    #expect(row.contentLines.contains(.progressBar) == false)
    #expect(row.contentLines.contains(.progressCaption) == false)
  }

  /// The bar is not the screen tint. A blue bar was rejected in the mockup.
  @Test func episodeRowProgressTintIsNotAccent() {
    #expect(PodcastEpisodeRowView.progressTint != Color.accentColor)
    #expect(PodcastEpisodeRowView.progressTint != WhirrColorToken.accent.color)
    #expect(PodcastEpisodeRowView.progressTint == WhirrColorToken.textPrimary.color)
  }

  /// An accented row spends the cover hue on its two marks, the leading playback glyph and the
  /// progress bar, and nowhere else. Without an accent both fall back to neutral ink, so the rest
  /// of the app's rows are unchanged.
  @Test func episodeRowSpendsTheCoverAccentOnMarksOnly() {
    let accent = Color(red: 0.55, green: 0.09, blue: 0.13)
    let accented = makeEpisodeRow(accent: accent)
    #expect(accented.usesAccentMarks)
    #expect(accented.progressBarTint == accent)
    #expect(accented.playbackGlyphTint == accent)

    let plain = makeEpisodeRow()
    #expect(plain.usesAccentMarks == false)
    #expect(plain.progressBarTint == PodcastEpisodeRowView.progressTint)
    #expect(plain.playbackGlyphTint == nil)
  }

  /// A finished episode keeps the accent off: its glyph is the receding one, and tinting it would
  /// put the loudest colour on the row that matters least.
  @Test func episodeRowLeavesThePlayedGlyphUnaccented() {
    let accent = Color(red: 0.55, green: 0.09, blue: 0.13)
    let played = makeEpisodeRow(playbackStatus: .played, accent: accent)
    #expect(played.playbackGlyphTint == nil)
    #expect(played.usesAccentMarks)
  }

  @Test("episode row exposes the shared download ring's reduced-motion contract")
  func episodeRowUsesSharedDownloadRing() {
    #expect(DownloadProgressRing.respectsReducedMotion)
    #expect(DownloadProgressRing.progressAnimation(reduceMotion: true) == nil)
    #expect(
      DownloadProgressRing.progressAnimation(reduceMotion: false)
        == .linear(duration: 0.2))
  }

  @Test("download progress never sends non-finite or out-of-range values to Shape.trim")
  func downloadProgressIsRenderSafe() {
    #expect(DownloadProgressRing.resolvedProgress(.nan) == 0)
    #expect(DownloadProgressRing.resolvedProgress(.infinity) == 0)
    #expect(DownloadProgressRing.resolvedProgress(-.infinity) == 0)
    #expect(DownloadProgressRing.resolvedProgress(-0.1) == 0)
    #expect(DownloadProgressRing.resolvedProgress(1.1) == 1)
    #expect(DownloadProgressRing.resolvedProgress(0.4) == 0.4)
  }

  @Test func episodeRowActionsForwardExactlyOnceAndIndependently() {
    var selected = 0
    var selectedActionIDs: [String] = []
    let row = makeEpisodeRow(
      onSelect: { selected += 1 },
      onSelectAction: { selectedActionIDs.append($0.id) })

    row.onSelect()
    for action in row.contextActions {
      row.onSelectAction(action)
    }

    #expect(selected == 1)
    #expect(selectedActionIDs == ["up-next", "download", "remove"])
    #expect(row.contextActions.last?.role == .destructive)
  }

  /// The ellipsis button is not the only way in: a long press on the row itself raises the same
  /// actions, which is the gesture the rest of the app's item surfaces already answer to.
  @Test func episodeRowOffersItsActionsOnLongPressAsWellAsTheEllipsis() {
    let row = makeEpisodeRow()
    #expect(row.presentsActionsOnLongPress)
    #expect(row.contextActions.isEmpty == false)
  }

  @Test func episodeRowActionTargetsMeet44PointMinimum() {
    let row = makeEpisodeRow()
    #expect(row.selectionMinimumHeight == 44)
    #expect(row.contextActionMinimumWidth == 44)
    #expect(row.contextActionMinimumHeight == 44)
    #expect(MediaRowLayoutValues.resolve(isAccessibilitySize: true).minimumActionDimension == 44)
  }

  @Test func mediaRowLayoutValuesAdaptAtAccessibilitySizes() {
    let standard = MediaRowLayoutValues.resolve(isAccessibilitySize: false)
    let accessibility = MediaRowLayoutValues.resolve(isAccessibilitySize: true)

    #expect(standard.axis == .horizontal)
    #expect(accessibility.axis == .vertical)
    #expect(standard.essentialTextLineLimit == nil)
    #expect(accessibility.essentialTextLineLimit == nil)
    #expect(accessibility.minimumActionDimension >= WhirrMetric.minimumTouchTarget)
  }

  /// The row prints no status labels, so a long-copy squeeze cannot happen there: the sentence
  /// never reaches a pixel. What matters is that no length of it truncates what VoiceOver hears.
  @Test func longStatusCopyStacksInsteadOfBeingSqueezedOntoOneLine() {
    let standard = MediaRowLayoutValues.resolve(isAccessibilitySize: false)
    let accessibility = MediaRowLayoutValues.resolve(isAccessibilitySize: true)

    #expect(standard.statusLayout == .singleLineOrStacked)
    #expect(accessibility.statusLayout == .stacked)
    #expect(standard.essentialTextLineLimit == nil)

    let row = makeEpisodeRow(
      deviceStatus: PodcastEpisodeDeviceDownloadStatus(
        kind: .waitingForWiFi,
        text: "Waiting for Wi-Fi. Downloads only use Wi-Fi unless you turn on cellular downloads in Settings.",
        systemImage: "wifi.exclamationmark"))
    #expect(row.visibleStatusTexts.isEmpty)
    #expect(row.essentialTextLineLimit == nil)
    #expect(row.accessibilityValue.contains(row.deviceStatus.text))
  }

  @Test func podcastContentSurfacesDoNotUseGlass() {
    #expect(PodcastShowHeaderView<Color>.surface == .ordinaryContent)
    #expect(PodcastEpisodeRowView.surface == .ordinaryContent)
  }

  private func makeHeader(synopsis: String? = nil) -> PodcastShowHeaderView<Color> {
    PodcastShowHeaderView(
      title: "Decoder Ring", subtitle: "Slate",
      synopsis: synopsis, badgeLabel: "Podcast",
      cover: { Color.clear })
  }

  private func makeEpisodeRow(
    synopsis: String? = "A Decoder Ring investigation",
    dateText: String = "12 July 2026",
    durationText: String = "42 minutes",
    progressText: String? = "18 minutes remaining",
    playbackProgressFraction: Double? = 0.58,
    playbackStatus: PodcastEpisodePlaybackStatus = .inProgress,
    playbackStatusText: String = "In progress",
    serverAvailability: PodcastServerAudioAvailability = .available,
    serverAvailabilityText: String = "Stored on server",
    deviceStatus: PodcastEpisodeDeviceDownloadStatus = PodcastEpisodeDeviceDownloadStatus(
      kind: .downloading, text: "Downloading, 58%",
      systemImage: "arrow.down.circle.fill", progressFraction: 0.58),
    downloadAction: MediaContextAction? = nil,
    watchMark: PodcastEpisodeWatchMark? = nil,
    accent: Color? = nil,
    isCheckingForAds: Bool = false,
    onSelect: @escaping () -> Void = {},
    onSelectAction: @escaping (MediaContextAction) -> Void = { _ in }
  ) -> PodcastEpisodeRowView {
    PodcastEpisodeRowView(
      title: "The Mystery of the Missing Hit",
      synopsis: synopsis,
      dateText: dateText,
      durationText: durationText,
      progressText: progressText,
      playbackProgressFraction: playbackProgressFraction,
      playbackStatus: playbackStatus,
      playbackStatusText: playbackStatusText,
      serverAvailability: serverAvailability,
      serverAvailabilityText: serverAvailabilityText,
      deviceStatus: deviceStatus,
      downloadAction: downloadAction,
      watchMark: watchMark,
      accent: accent,
      isCheckingForAds: isCheckingForAds,
      selectionAccessibilityHint: "Opens the episode.",
      contextMenuAccessibilityLabel: "Episode actions",
      contextMenuAccessibilityHint: "Shows actions for this episode",
      contextActionSections: [
        [
          MediaContextAction(
            id: "up-next", label: "Add to Up Next",
            hint: "Adds this episode to the queue", systemImage: "text.line.last.and.arrowtriangle.forward")
        ],
        [
          MediaContextAction(
            id: "download", label: "Download",
            hint: "Downloads this episode", systemImage: "arrow.down.circle"),
          MediaContextAction(
            id: "remove", label: "Remove Download",
            hint: "Removes this episode from this device", systemImage: "trash",
            role: .destructive),
        ],
      ],
      onSelect: onSelect,
      onSelectAction: onSelectAction)
  }
}
