import Foundation
import Persistence
import TestSupport
import Testing

@testable import AppModel

@Suite struct PodcastEpisodeCardPresentationTests {
  @Test("the play button names the verb only, at every progress state")
  func playButtonCarriesNoRemainingTime() {
    let unstarted = Self.presentation(progressSeconds: 0, durationSeconds: 1_800)
    #expect(unstarted.playButtonLabel == PodcastCopy.play)

    let partPlayed = Self.presentation(progressSeconds: 1_080, durationSeconds: 1_800)
    #expect(partPlayed.playButtonLabel == PodcastCopy.resume)
    #expect(partPlayed.playButtonLabel == "Resume")

    let finished = Self.presentation(progressSeconds: 1_800, durationSeconds: 1_800)
    #expect(finished.playButtonLabel == PodcastCopy.play)
  }

  @Test("the card keeps the show's artwork and carries the episode's own beside it")
  func cardCarriesEpisodeArtworkBesideTheShows() {
    let episode = PodcastEpisodeSummary(
      id: "episode", title: "Episode", subtitle: nil, episodeDescription: nil,
      seasonNumber: nil, episodeNumber: nil, episodeType: nil,
      durationSeconds: 1_800, sizeBytes: nil, publishedAt: nil,
      progressSeconds: 0, isPlayed: false, isFinished: false,
      downloadStatus: .completed, isAvailableOnServer: true)
    let show = URL(string: "https://example.com/show.jpg")
    let own = URL(string: "https://example.com/episode.jpg")

    let withOwn = PodcastEpisodeCardPresentation(
      context: PodcastEpisodeContext(
        episode: episode, showTitle: "Show", showAuthor: nil, artworkURL: show,
        artworkFeedURL: nil, episodeArtworkURL: own))
    #expect(withOwn.artworkURL == show)
    #expect(withOwn.episodeArtworkURL == own)

    let without = PodcastEpisodeCardPresentation(
      context: PodcastEpisodeContext(
        episode: episode, showTitle: "Show", showAuthor: nil, artworkURL: show,
        artworkFeedURL: nil))
    #expect(without.episodeArtworkURL == nil)
    #expect(without.artworkURL == show)
  }

  @Test("the pause label is the verb alone, so a tap never reflows the row")
  func pauseButtonCarriesNoRemainingTime() {
    let partPlayed = Self.presentation(progressSeconds: 1_080, durationSeconds: 1_800)
    #expect(partPlayed.pauseButtonLabel == PodcastCopy.pause)
    #expect(partPlayed.pauseButtonLabel == "Pause")
  }

  @Test("remaining joins the metadata line, and only while the bar is drawn")
  func metadataLineCarriesRemainingWhenPartPlayed() {
    let partPlayed = Self.presentation(progressSeconds: 1_080, durationSeconds: 1_800)
    #expect(partPlayed.metadataLine == "\(partPlayed.metadataText) · 12 min left")

    let unstarted = Self.presentation(progressSeconds: 0, durationSeconds: 1_800)
    #expect(unstarted.metadataLine == unstarted.metadataText)

    let finished = Self.presentation(progressSeconds: 1_800, durationSeconds: 1_800)
    #expect(finished.metadataLine == finished.metadataText)

    let overrun = Self.presentation(progressSeconds: 2_000, durationSeconds: 1_800)
    #expect(overrun.metadataLine == overrun.metadataText)
  }

  @Test("part-played countdown uses listening time at the current playback rate")
  func partPlayedCountdownUsesPlaybackRate() {
    let normal = Self.presentation(
      progressSeconds: 1_080, durationSeconds: 1_800, playbackRate: 1.0)
    let faster = normal.adjusted(forPlaybackRate: 1.5)

    #expect(normal.metadataLine.hasSuffix("· 12 min left"))
    #expect(faster.metadataLine.hasSuffix("· 8 min left at 1.5×"))
    #expect(normal.remainingProgressFraction == faster.remainingProgressFraction)
    #expect(normal.playButtonLabel == faster.playButtonLabel)
  }

  @Test("ads the player will skip are left out of the remainder, before the rate conversion")
  func skipsAheadReduceTheRemainderBeforeTheRate() {
    let breaks = AdSkipBreaks(
      breaks: (0..<4).map { index in
        let start = 400 + Double(index) * 100
        return AdSkipBreaks.Break(start: start, end: start + 90, endsItem: false)
      })
    let normal = Self.presentation(progressSeconds: 306, durationSeconds: 3_600)
    let slower = normal.adjusted(forPlaybackRate: 0.9)

    #expect(normal.metadataLine.hasSuffix("· 54 min left"))
    #expect(slower.metadataLine.hasSuffix("· 1 hr 1 min left at 0.9×"))
    #expect(normal.atPosition(306, skipping: breaks).metadataLine.hasSuffix("· 48 min left"))
    #expect(
      slower.atPosition(306, skipping: breaks).metadataLine
        == slower.metadataText + " · 54 min left at 0.9×")
  }

  @Test("the progress bar measures media, so ad data does not move it")
  func skippingAdsDoesNotMoveTheProgressFraction() {
    let breaks = AdSkipBreaks(breaks: [.init(start: 400, end: 500, endsItem: false)])
    let card = Self.presentation(progressSeconds: 306, durationSeconds: 3_600)

    #expect(
      card.atPosition(306, skipping: breaks).remainingProgressFraction
        == card.atPosition(306).remainingProgressFraction)
  }

  @Test("breaks behind or around the playhead are left in the remainder")
  func breaksThePlayerWillNotSkipStayInTheRemainder() {
    let card = Self.presentation(progressSeconds: 306, durationSeconds: 3_600)
    let behind = AdSkipBreaks(breaks: [.init(start: 100, end: 200, endsItem: false)])
    let around = AdSkipBreaks(breaks: [.init(start: 300, end: 400, endsItem: false)])

    #expect(card.atPosition(306, skipping: behind).metadataLine.hasSuffix("· 54 min left"))
    // A resume inside a break plays it, so the whole break stays.
    #expect(card.atPosition(306, skipping: around).metadataLine.hasSuffix("· 54 min left"))
  }

  @Test("a remainder never goes below zero when a break runs past the end")
  func remainderFloorsAtZero() {
    let card = Self.presentation(progressSeconds: 306, durationSeconds: 3_600)
    let toTheEnd = AdSkipBreaks(breaks: [.init(start: 306, end: 3_600, endsItem: true)])

    #expect(card.atPosition(306, skipping: toTheEnd).metadataLine.hasSuffix("· 0 min left"))
  }

  @Test("the metadata line's spoken form names the rate in words")
  func metadataAccessibilityLabelSpeaksTheRate() {
    let slower = Self.presentation(
      progressSeconds: 1_080, durationSeconds: 1_800, playbackRate: 0.9)

    #expect(slower.metadataAccessibilityLabel.hasSuffix(", 13 min left at 0.9 times speed"))
    #expect(slower.metadataAccessibilityLabel.contains("×") == false)
  }

  @Test("progress lines at a displayed position match a card loaded at that position")
  func progressLinesAtADisplayedPositionMatchACardLoadedThere() {
    let stored = Self.presentation(progressSeconds: 0, durationSeconds: 1_800)
    let loadedThere = Self.presentation(progressSeconds: 1_080, durationSeconds: 1_800)

    let live = stored.atPosition(1_080)

    #expect(live.remainingProgressFraction == loadedThere.remainingProgressFraction)
    #expect(live.metadataLine == loadedThere.metadataLine)
  }

  @Test("a finished card draws no progress at any displayed position")
  func finishedCardDrawsNoProgressAtAnyPosition() {
    let finished = Self.presentation(progressSeconds: 600, durationSeconds: 1_800, isFinished: true)

    #expect(finished.atPosition(900).remainingProgressFraction == nil)
    #expect(finished.atPosition(900).metadataLine == finished.metadataText)
  }

  @Test("invalid podcast playback rates use raw remaining audio time")
  func invalidPlaybackRatesUseRawRemainingAudioTime() {
    let expected = Self.presentation(
      progressSeconds: 1_080, durationSeconds: 1_800, playbackRate: 1.0)

    for rate in [0.0, -1.0, Double.nan, Double.infinity, -Double.infinity] {
      let actual = Self.presentation(
        progressSeconds: 1_080, durationSeconds: 1_800, playbackRate: rate)
      #expect(actual.metadataLine == expected.metadataLine)
    }
  }

  @Test("a zero-progress episode remains plain Play at every playback rate")
  func zeroProgressEpisodeIsUnchangedAtEveryPlaybackRate() {
    let normal = Self.presentation(progressSeconds: 0, durationSeconds: 1_800, playbackRate: 1.0)
    let faster = Self.presentation(progressSeconds: 0, durationSeconds: 1_800, playbackRate: 1.5)

    #expect(faster.playButtonLabel == normal.playButtonLabel)
    #expect(faster.remainingProgressFraction == normal.remainingProgressFraction)
    #expect(faster.metadataText == normal.metadataText)
    #expect(faster.metadataLine == normal.metadataLine)
  }

  @Test("podcast copy uses the shared listening-time remainder helper")
  func podcastCopyUsesSharedRemainderHelper() {
    let listeningSeconds =
      ItemDetailDurationPresentation.remainingSeconds(
        durationSeconds: 720, progressSeconds: 0, playbackRate: 1.5) ?? 0

    #expect(listeningSeconds == 480)
    #expect(
      PodcastCopy.remaining(seconds: 720, playbackRate: 1.5) == "8 min left at 1.5×")
  }

  @Test func progressBarAppearsOnlyWhenPartPlayed() {
    let unstarted = Self.presentation(progressSeconds: 0, durationSeconds: 1_800)
    #expect(unstarted.remainingProgressFraction == nil)

    let finished = Self.presentation(progressSeconds: 1_800, durationSeconds: 1_800)
    #expect(finished.remainingProgressFraction == nil)

    let overrun = Self.presentation(progressSeconds: 2_000, durationSeconds: 1_800)
    #expect(overrun.remainingProgressFraction == nil)

    let partPlayed = Self.presentation(progressSeconds: 1_080, durationSeconds: 1_800)
    #expect(partPlayed.remainingProgressFraction == 0.6)
  }

  /// Marking an episode done leaves whatever position it stopped at behind, so the fraction alone
  /// still says "part way through". Finished wins: no bar, and no remainder in the metadata line.
  @Test func markingPartPlayedEpisodeFinishedRemovesTheBar() {
    let markedDone = Self.presentation(
      progressSeconds: 120, durationSeconds: 1_800, isFinished: true)

    #expect(markedDone.remainingProgressFraction == nil)
    #expect(markedDone.metadataLine == markedDone.metadataText)
    #expect(markedDone.playButtonLabel == PodcastCopy.play)
  }

  @Test func notesPreferDescriptionOverSubtitle() {
    let withDescription = Self.presentation(
      subtitle: "Short subtitle", episodeDescription: "<p>Full show notes.</p>")
    #expect(withDescription.notes == "Full show notes.")

    let subtitleOnly = Self.presentation(subtitle: "Short subtitle", episodeDescription: nil)
    #expect(subtitleOnly.notes == "Short subtitle")

    let neither = Self.presentation(subtitle: nil, episodeDescription: nil)
    #expect(neither.notes == nil)

    // Description present but strips to nothing: falls back to subtitle, same as `??` would.
    let blankDescription = Self.presentation(subtitle: "Short subtitle", episodeDescription: "<p></p>")
    #expect(blankDescription.notes == "Short subtitle")
  }

  @Test func boilerplateAfterADividerFoldsIntoSupplementaryNotes() {
    let presentation = Self.presentation(
      subtitle: nil,
      episodeDescription: "The episode.\n\n__________\n\nJoin our newsletter.\n\nProducer: Someone")
    #expect(presentation.notes == "The episode.")
    #expect(presentation.supplementaryNotes == "Join our newsletter.\n\nProducer: Someone")

    let plain = Self.presentation(subtitle: nil, episodeDescription: "<p>Full show notes.</p>")
    #expect(plain.supplementaryNotes == nil)

    let plug = "Join our newsletter for weekly extras."
    let boilerplate = ShowNotesBoilerplate(
      descriptions: (0..<5).map { "<p>Episode \($0) stands alone.</p><p>\(plug)</p>" })
    let withHistory = Self.presentation(
      subtitle: nil, episodeDescription: "<p>The episode.</p><p>\(plug)</p>",
      boilerplate: boilerplate)
    #expect(withHistory.notes == "The episode.")
    #expect(withHistory.supplementaryNotes == plug)

    let dividersOnly = Self.presentation(subtitle: nil, episodeDescription: "__________")
    #expect(dividersOnly.notes == nil)
    #expect(dividersOnly.supplementaryNotes == nil)
  }

  @Test func cardActionsMatchCanonicalListForEveryDownloadState() {
    for status in Self.everyDownloadStatus {
      for isAvailableOnServer in [true, false] {
        let presentation = Self.presentation(
          status: status, isAvailableOnServer: isAvailableOnServer)
        let expectedActions = PodcastShowPresentation.episodeActions(
          status: status, isAvailableOnServer: isAvailableOnServer, surface: .episodeDetail)

        #expect(presentation.contextActions == expectedActions)
        #expect(
          presentation.primaryDeviceAction
            == PodcastShowPresentation.primaryDeviceAction(
              status: status, isAvailableOnServer: isAvailableOnServer))
      }
    }
  }

  /// The App-target card view draws its trailing download control from the raw status, with the
  /// same glyph vocabulary as the show row, not from `primaryDeviceAction` alone, which is `nil`
  /// for three of the ten states.
  @Test func deviceDownloadStatusCarriesTheRawStatus() {
    for status in Self.everyDownloadStatus {
      let presentation = Self.presentation(status: status)
      #expect(presentation.deviceDownloadStatus == status)
    }
  }

  @Test func unknownDownloadSizeUsesIndeterminateCopyWithoutChangingRawStatus() {
    let known = Self.presentation(
      status: .downloading(progressFraction: 0), isDownloadSizeKnown: true)
    let unknown = Self.presentation(
      status: .downloading(progressFraction: 0), isDownloadSizeKnown: false)

    #expect(known.isDownloadSizeKnown)
    #expect(known.deviceDownloadText == "Downloading… 0%")
    #expect(unknown.isDownloadSizeKnown == false)
    #expect(unknown.deviceDownloadText == "Downloading…")
    #expect(unknown.deviceDownloadStatus == .downloading(progressFraction: 0))
  }

  /// The canonical menu's `.moreFromCreator` entry needs the show's creator name, a per-episode
  /// fact the row/menu adapters carry from outside the episode.
  @Test func showAuthorCarriesTheShowsCreator() {
    let withCreator = Self.presentation()
    #expect(withCreator.showAuthor == "Goalhanger")
  }

  /// The card presents Play as a capsule, Save for Later as a bookmark, the download as its own
  /// control and the show as a tappable line, so its menu carries none of them; what is left is
  /// the two queue entries and the progress actions. The rule is on
  /// `PodcastShowPresentation.suppressedActions(on:)`: suppress what the surface presents as its
  /// own control, keep what it only mentions.
  @Test func episodeDetailSurfaceSuppressesWhatTheCardAlreadyPresents() {
    let suppressed = PodcastShowPresentation.suppressedActions(on: .episodeDetail)
    #expect(suppressed.contains(.playPause))
    #expect(suppressed.contains(.saveForLater))
    #expect(suppressed.contains(.removeFromSaved))
    #expect(suppressed.contains(.openShow))
    for deviceAction in [
      MediaItemAction.download, .removeDownload, .pauseDownload, .resumeDownload,
    ] {
      #expect(suppressed.contains(deviceAction))
    }

    // What survives is what the card has nowhere else to offer.
    #expect(suppressed.contains(.playNext) == false)
    #expect(suppressed.contains(.addToUpNext) == false)
    #expect(suppressed.contains(.markAsFinished) == false)
    #expect(suppressed.contains(.resetProgress) == false)
    #expect(suppressed.contains(.removeFromContinueListening) == false)

    // Whatever the device state, the menu never speaks about the device: that is the trailing
    // control's job, and it knows states this menu's coarse presence cannot name.
    for status in Self.everyDownloadStatus {
      let onCard = PodcastShowPresentation.episodeActions(
        status: status, isAvailableOnServer: true, surface: .episodeDetail)
      #expect(onCard.contains(.download) == false)
      #expect(onCard.contains(.removeDownload) == false)
      #expect(onCard.contains(.playPause) == false)
      #expect(onCard.contains(.openShow) == false)
      #expect(onCard.isEmpty == false)
    }
  }

  /// `DownloadOrigin` (`DownloadRecord.origin`) is a retention concept for the auto-download
  /// reaper, never joined onto `PodcastEpisodeSummary`/`PodcastEpisodeContext` (the card's read
  /// model), so the card cannot render an automatic download differently from a manual one. This
  /// pins both halves: identical presentation for every download state, and the structure, so it
  /// fails if origin is threaded into either read model.
  @Test func automaticallyDownloadedEpisodeIsVisuallyIdenticalToAManualOne() {
    for status in Self.everyDownloadStatus {
      // Two independently built presentations for the same episode/status, standing in for
      // "queued by the auto-download pass" and "tapped by hand". No origin parameter exists in
      // this call chain for the two to diverge on.
      let asIfAutomatic = Self.presentation(status: status)
      let asIfManual = Self.presentation(status: status)
      #expect(
        asIfAutomatic == asIfManual,
        "\(status) must render identically regardless of how the download was requested")
    }

    let episode = PodcastEpisodeSummary(
      id: "episode", title: "Episode", subtitle: nil, episodeDescription: nil,
      seasonNumber: nil, episodeNumber: nil, episodeType: nil,
      durationSeconds: 1_800, sizeBytes: nil, publishedAt: nil,
      progressSeconds: 0, isPlayed: false, isFinished: false,
      downloadStatus: .completed, isAvailableOnServer: true)
    let context = PodcastEpisodeContext(
      episode: episode, showTitle: "Show", showAuthor: nil, artworkURL: nil, artworkFeedURL: nil)

    // Structural pin: neither type the card reads from carries an `origin` field at all, so no
    // future presentation code could branch on one without this failing first.
    let episodeFields = Mirror(reflecting: episode).children.compactMap(\.label)
    let contextFields = Mirror(reflecting: context).children.compactMap(\.label)
    #expect(!episodeFields.contains { $0.localizedCaseInsensitiveContains("origin") })
    #expect(!contextFields.contains { $0.localizedCaseInsensitiveContains("origin") })
  }

  /// The card's delete control dispatches through
  /// `PodcastEpisodeIntents.removeDownload(itemID:episodeID:)`, which takes no origin.
  /// `PodcastEpisodeCardModel.removeDownload` forwards straight to it with no status/origin
  /// branch, so whatever confirmation the view wraps the tap in is the same whether the download
  /// was automatic or manual.
  @MainActor
  @Test func tappingDeleteOnAnAutomaticDownloadStillOffersTheSameConfirmation() async {
    let intents = FakePodcastEpisodeIntents()
    let model = PodcastEpisodeCardModel(
      itemID: "show-1", episodeID: "episode-1", reading: NoOpPodcastReading(),
      episodeIntents: intents)

    await model.performAction(.removeDownload)
    #expect(intents.calls == [.removeDownload("show-1", "episode-1")])

    // Same episode ref, same single call. Nothing about how it was downloaded is available for
    // the model to key a different action (or confirmation) off.
    intents.reset()
    await model.removeDownload()
    #expect(intents.calls == [.removeDownload("show-1", "episode-1")])
  }

  private static let everyDownloadStatus: [ItemDownloadStatus] = [
    .notDownloaded, .waitingForWiFi, .queued, .downloading(progressFraction: 0.42), .paused,
    .pausedAuth, .interrupted, .failed(category: .transport), .deleting, .completed,
  ]

  /// The card is the one episode surface with no playback glyph in a leading column, so the
  /// finished state has to be carried explicitly for it to show a badge at all. The menu it
  /// raises drops the entry that would do nothing.
  @Test func finishedEpisodeIsMarkedAndDropsMarkAsFinished() {
    let unfinished = Self.presentation(isFinished: false)
    #expect(unfinished.isFinished == false)
    #expect(unfinished.contextActions.contains(.markAsFinished))

    let finished = Self.presentation(isFinished: true)
    #expect(finished.isFinished)
    #expect(finished.contextActions.contains(.markAsFinished) == false)
    #expect(finished.contextActions.contains(.resetProgress))
  }

  private static func presentation(
    status: ItemDownloadStatus = .notDownloaded,
    isAvailableOnServer: Bool = true,
    subtitle: String? = "Subtitle",
    episodeDescription: String? = nil,
    progressSeconds: Double = 0,
    durationSeconds: Double? = 1_800,
    isFinished: Bool = false,
    playbackRate: Double = 1.0,
    isDownloadSizeKnown: Bool = true,
    boilerplate: ShowNotesBoilerplate = .none
  ) -> PodcastEpisodeCardPresentation {
    PodcastEpisodeCardPresentation(
      context: PodcastEpisodeContext(
        episode: PodcastEpisodeSummary(
          id: "episode", title: "Episode", subtitle: subtitle,
          episodeDescription: episodeDescription,
          seasonNumber: nil, episodeNumber: nil, episodeType: nil,
          durationSeconds: durationSeconds, sizeBytes: nil, publishedAt: nil,
          progressSeconds: progressSeconds, isPlayed: isFinished, isFinished: isFinished,
          downloadStatus: status, isAvailableOnServer: isAvailableOnServer,
          isDownloadSizeKnown: isDownloadSizeKnown),
        showTitle: "The Rest Is Politics: US", showAuthor: "Goalhanger",
        artworkURL: nil, artworkFeedURL: nil),
      playbackRate: playbackRate, boilerplate: boilerplate)
  }
}
