import Foundation
import Persistence
import Testing

@testable import AppModel

@Suite struct PodcastShowPresentationTests {
  @Test func diagnosticLineRendersBothKnownServerFields() {
    let now = Date(timeIntervalSince1970: 1_769_904_000)
    let checkedAt = now.addingTimeInterval(-21 * 86_400)

    #expect(
      PodcastShowPresentation.diagnosticText(
        diagnostics: PodcastShowDiagnostics(
          autoDownloadEpisodes: false, lastEpisodeCheck: checkedAt),
        now: now)
        == "Server auto-download off. Last checked 3 weeks ago")
    #expect(
      PodcastShowPresentation.diagnosticText(
        diagnostics: PodcastShowDiagnostics(
          autoDownloadEpisodes: true, lastEpisodeCheck: checkedAt),
        now: now)
        == "Server auto-download on. Last checked 3 weeks ago")
  }

  /// The two facts are independent. A show imported but never scheduled-checked reports
  /// `autoDownloadEpisodes: false, lastEpisodeCheck: null`, the "why isn't this updating?" case,
  /// so the known half must still render. Nothing is fabricated for the unknown half.
  @Test func diagnosticLineRendersKnownHalvesAndOmitsUnknownOnes() {
    let now = Date(timeIntervalSince1970: 1_769_904_000)
    let checkedAt = now.addingTimeInterval(-21 * 86_400)

    #expect(
      PodcastShowPresentation.diagnosticText(
        diagnostics: PodcastShowDiagnostics(
          autoDownloadEpisodes: false, lastEpisodeCheck: nil),
        now: now) == "Server auto-download off")
    #expect(
      PodcastShowPresentation.diagnosticText(
        diagnostics: PodcastShowDiagnostics(
          autoDownloadEpisodes: true, lastEpisodeCheck: nil),
        now: now) == "Server auto-download on")
    #expect(
      PodcastShowPresentation.diagnosticText(
        diagnostics: PodcastShowDiagnostics(
          autoDownloadEpisodes: nil, lastEpisodeCheck: checkedAt),
        now: now) == "Last checked 3 weeks ago")
  }

  /// `autoDownloadEpisodes` is the server's own RSS auto-download flag (read-only). The rendered
  /// diagnostic must name the server as the actor so it cannot be mistaken for the device-side
  /// download feature.
  @Test func diagnosticTextNamesTheServerAsTheActor() {
    let now = Date(timeIntervalSince1970: 1_769_904_000)

    #expect(
      PodcastShowPresentation.diagnosticText(
        diagnostics: PodcastShowDiagnostics(autoDownloadEpisodes: true, lastEpisodeCheck: nil),
        now: now)?.contains("Server auto-download") == true)
    #expect(
      PodcastShowPresentation.diagnosticText(
        diagnostics: PodcastShowDiagnostics(autoDownloadEpisodes: false, lastEpisodeCheck: nil),
        now: now)?.contains("Server auto-download") == true)
  }

  /// Feed blurbs arrive as HTML. The header renders plain `Text`, so the markup is stripped
  /// rather than escaped-and-shown, block-level tags become the spaces that keep words apart,
  /// the handful of entities feeds use are decoded, and a blurb that was only markup reports
  /// absent instead of blank.
  @Test("a stored synopsis line is drawn verbatim and a missing one falls back to stripping")
  func storedSynopsisLineIsDrawnVerbatim() {
    let stored = PodcastShowPresentation.episode(
      Self.episode(
        status: .notDownloaded, isAvailableOnServer: true, subtitle: "Subtitle",
        episodeDescription: "<p>Description</p>", synopsisLine: "Stored &lt;line&gt;"), surface: .show
    ).synopsis
    // Already plain text: an entity the feed wrote as `&amp;lt;` must not decode a second time.
    #expect(stored == "Stored &lt;line&gt;")
    #expect(Self.synopsis(subtitle: nil, description: "<p>Fallback</p>") == "Fallback")
  }

  @Test func showSynopsisStripsHTML() {
    #expect(
      PodcastShowPresentation.synopsis(from: "<p>A show about <b>shows</b>.</p>")
        == "A show about shows.")
    #expect(PodcastShowPresentation.synopsis(from: "One<br/>Two") == "One Two")
    #expect(
      PodcastShowPresentation.synopsis(from: "<ul><li>First</li><li>Second</li></ul>")
        == "First Second")
    #expect(
      PodcastShowPresentation.synopsis(from: "Tom &amp; Jerry &lt;3 &quot;quotes&quot;&nbsp;here")
        == "Tom & Jerry <3 \"quotes\" here")
    #expect(PodcastShowPresentation.synopsis(from: "  spaced   \n\n out  ") == "spaced out")
    #expect(PodcastShowPresentation.synopsis(from: "<a href=\"https://x\">Link</a>") == "Link")

    #expect(PodcastShowPresentation.synopsis(from: "<p></p>") == nil)
    #expect(PodcastShowPresentation.synopsis(from: "   ") == nil)
    #expect(PodcastShowPresentation.synopsis(from: "") == nil)
    #expect(PodcastShowPresentation.synopsis(from: nil) == nil)
  }

  @Test func diagnosticLineIsOmittedOnlyWhenNeitherFieldIsKnown() {
    let now = Date(timeIntervalSince1970: 1_769_904_000)

    #expect(
      PodcastShowPresentation.diagnosticText(
        diagnostics: PodcastShowDiagnostics(autoDownloadEpisodes: nil, lastEpisodeCheck: nil),
        now: now) == nil)
    #expect(PodcastShowPresentation.diagnosticText(diagnostics: nil, now: now) == nil)
  }

  @Test func mediaItemMenuSectionsKeepSavedInCanonicalOrder() {
    #expect(
      MediaItemMenuSection.allCases
        == [.primary, .saved, .navigation, .download, .progress, .server, .destructive])
  }

  /// Once a show resolves effectively on, the show screen's diagnostic slot gains the
  /// device-side state hint alongside the server's own diagnostic line. It never replaces it, and
  /// is gone once the show is effectively off.
  @Test func stateHintAppearsBesideTheServerDiagnosticLine() {
    let now = Date(timeIntervalSince1970: 1_769_904_000)
    let enabled = PodcastEffectiveSettings(
      isEnabled: true, keepLatestCount: 3, deleteAfterPlayed: false, floor: .distantPast)
    let disabled = PodcastEffectiveSettings(
      isEnabled: false, keepLatestCount: 3, deleteAfterPlayed: false, floor: .distantPast)
    let keepAll = PodcastEffectiveSettings(
      isEnabled: true, keepLatestCount: 0, deleteAfterPlayed: false, floor: .distantPast)

    #expect(
      PodcastShowPresentation.diagnosticText(
        diagnostics: PodcastShowDiagnostics(autoDownloadEpisodes: false, lastEpisodeCheck: nil),
        effective: enabled, now: now)
        == "Server auto-download off. Keeping 3 newest on this device")

    // Effectively off: the server line survives, the hint does not.
    #expect(
      PodcastShowPresentation.diagnosticText(
        diagnostics: PodcastShowDiagnostics(autoDownloadEpisodes: false, lastEpisodeCheck: nil),
        effective: disabled, now: now)
        == "Server auto-download off")

    // Keep-all resolves to the "new episodes" phrasing (never "0"), and the hint can carry the
    // line alone when the server payload knows neither field.
    #expect(
      PodcastShowPresentation.diagnosticText(diagnostics: nil, effective: keepAll, now: now)
        == "Keeping new episodes on this device")

    // Omitting `effective` never adds the hint.
    #expect(
      PodcastShowPresentation.diagnosticText(
        diagnostics: PodcastShowDiagnostics(autoDownloadEpisodes: true, lastEpisodeCheck: nil),
        now: now)
        == "Server auto-download on")
  }

  @Test func availableEpisodeOffersDownloadAndUsesExistingDownloadCopy() {
    let presentation = PodcastShowPresentation.episode(
      Self.episode(status: .notDownloaded, isAvailableOnServer: true), surface: .show)

    #expect(presentation.serverAvailability == .available)
    #expect(presentation.serverAvailabilityText == PodcastCopy.availableOnServer)
    #expect(presentation.deviceDownloadText == ItemDownloadCopy.notDownloaded)
    #expect(
      presentation.contextActions == [
        .playPause, .playNext, .addToUpNext, .download, .markAsFinished,
      ])
  }

  @Test func downloadingCopyDistinguishesKnownAndUnknownSize() {
    let known = PodcastShowPresentation.episode(
      Self.episode(
        status: .downloading(progressFraction: 0), isAvailableOnServer: true,
        isDownloadSizeKnown: true), surface: .show)
    let unknown = PodcastShowPresentation.episode(
      Self.episode(
        status: .downloading(progressFraction: 0), isAvailableOnServer: true,
        isDownloadSizeKnown: false), surface: .show)

    #expect(known.isDownloadSizeKnown)
    #expect(known.deviceDownloadText == "Downloading… 0%")
    #expect(unknown.isDownloadSizeKnown == false)
    #expect(unknown.deviceDownloadText == "Downloading…")
  }

  @Test("show row episode presentation matches the summary presentation")
  func showRowEpisodePresentationMatchesSummaryPresentation() {
    let summary = PodcastEpisodeSummary(
      id: "fixture-episode", title: "Fixture episode", subtitle: "A subtitle",
      episodeDescription: "<p>An <strong>HTML</strong> synopsis.</p>", seasonNumber: "2",
      episodeNumber: "3", episodeType: "full", durationSeconds: 3_661, sizeBytes: 10,
      publishedAt: Date(timeIntervalSince1970: 1_704_067_200), progressSeconds: 1_800,
      isPlayed: true, isFinished: false, downloadStatus: .notDownloaded,
      isAvailableOnServer: true)

    #expect(
      PodcastShowPresentation.episode(summary, surface: .show).episode
        == PodcastEpisodePresentation(episode: summary))
  }

  @Test func unavailableEpisodeNeverOffersDownload() {
    let presentation = PodcastShowPresentation.episode(
      Self.episode(status: .notDownloaded, isAvailableOnServer: false), surface: .show)

    #expect(presentation.serverAvailability == .unavailable)
    #expect(presentation.serverAvailabilityText == PodcastCopy.unavailableOnServer)
    #expect(
      presentation.contextActions == [
        .playPause, .playNext, .addToUpNext, .markAsFinished,
      ])
    #expect(presentation.contextActions.contains(.download) == false)
  }

  @Test(
    arguments: [
      (ItemDownloadStatus.waitingForWiFi, [MediaItemAction.removeDownload]),
      (ItemDownloadStatus.queued, [.removeDownload]),
      (ItemDownloadStatus.downloading(progressFraction: 0.42), [.pauseDownload, .removeDownload]),
      (ItemDownloadStatus.paused, [.resumeDownload, .removeDownload]),
      (ItemDownloadStatus.pausedAuth, [.removeDownload]),
      (ItemDownloadStatus.interrupted, [.resumeDownload, .removeDownload]),
      (ItemDownloadStatus.failed(category: .transport), [.resumeDownload, .removeDownload]),
      (ItemDownloadStatus.completed, [.removeDownload]),
      (ItemDownloadStatus.deleting, []),
    ])
  func deviceStateMapsToOneActionSet(
    status: ItemDownloadStatus, expectedDeviceActions: [MediaItemAction]
  ) {
    let presentation = PodcastShowPresentation.episode(
      Self.episode(status: status, isAvailableOnServer: true), surface: .show)

    #expect(presentation.deviceDownloadText == ItemDownloadCopy.text(for: status))
    // Progress state is untouched, so only Mark as Finished is relevant. Download state cannot
    // alter that guard. `.openShow` is absent because this is the show's own screen. The removal
    // is the last section, after progress.
    let removal = expectedDeviceActions.filter { $0 == .removeDownload }
    #expect(
      presentation.contextActions
        == [.playPause, .playNext, .addToUpNext]
        + expectedDeviceActions.filter { $0 != .removeDownload } + [.markAsFinished] + removal)
  }

  /// The row's trailing download control is a button, so one action per state is what a tap does.
  /// `nil` states render a glyph and answer no tap.
  @Test(
    arguments: [
      (ItemDownloadStatus.notDownloaded, MediaItemAction.download),
      (ItemDownloadStatus.waitingForWiFi, .removeDownload),
      (ItemDownloadStatus.queued, .removeDownload),
      (ItemDownloadStatus.downloading(progressFraction: 0.42), .pauseDownload),
      (ItemDownloadStatus.paused, .resumeDownload),
      (ItemDownloadStatus.interrupted, .resumeDownload),
      (ItemDownloadStatus.failed(category: .transport), .resumeDownload),
    ])
  func downloadControlPrimaryActionPerState(
    status: ItemDownloadStatus, expected: MediaItemAction
  ) {
    let presentation = PodcastShowPresentation.episode(
      Self.episode(status: status, isAvailableOnServer: true), surface: .show)
    #expect(presentation.primaryDeviceAction == expected)
  }

  /// A tap has no sensible answer here: `.deleting` is already mid-purge, `.completed`'s only
  /// remaining action is destructive and belongs behind the ellipsis, and `.pausedAuth` is fixed by
  /// signing in, not by poking the row.
  @Test(
    arguments: [ItemDownloadStatus.deleting, .completed, .pausedAuth])
  func downloadControlIsInertWhenDeleting(status: ItemDownloadStatus) {
    let presentation = PodcastShowPresentation.episode(
      Self.episode(status: status, isAvailableOnServer: true), surface: .show)
    #expect(presentation.primaryDeviceAction == nil)
  }

  @Test func downloadControlOffersNothingForAnEpisodeTheServerCannotSupply() {
    let presentation = PodcastShowPresentation.episode(
      Self.episode(status: .notDownloaded, isAvailableOnServer: false), surface: .show)
    #expect(presentation.primaryDeviceAction == nil)
  }

  /// The button can never offer something the menu does not: one tap and one long press have to
  /// agree about what this episode can do.
  @Test(
    arguments: [
      ItemDownloadStatus.notDownloaded, .waitingForWiFi, .queued,
      .downloading(progressFraction: 0.42), .paused, .pausedAuth, .interrupted,
      .failed(category: .transport), .deleting, .completed,
    ])
  func primaryDeviceActionIsAlwaysOfferedInTheMenu(status: ItemDownloadStatus) {
    for isAvailable in [true, false] {
      let presentation = PodcastShowPresentation.episode(
        Self.episode(status: status, isAvailableOnServer: isAvailable), surface: .show)
      guard let primary = presentation.primaryDeviceAction else { continue }
      #expect(presentation.contextActions.contains(primary))
    }
  }

  /// The row shows one synopsis line. `subtitle` is the server's own short form and wins
  /// whenever it exists; the feed's description is the fallback and arrives as raw HTML.
  @Test func synopsisPrefersSubtitle() {
    #expect(
      Self.synopsis(subtitle: "A Decoder Ring investigation", description: "<p>Long blurb</p>")
        == "A Decoder Ring investigation")
    #expect(
      Self.synopsis(subtitle: nil, description: "<p>Long blurb</p>") == "Long blurb")
    #expect(Self.synopsis(subtitle: "   ", description: "<p>Long blurb</p>") == "Long blurb")
  }

  @Test func synopsisStripsHTMLTags() {
    #expect(
      Self.synopsis(
        subtitle: nil,
        description: "<p>As Yugoslavia <em>fractures</em>, Tito clings to <b>power</b>.</p>")
        == "As Yugoslavia fractures, Tito clings to power.")
    #expect(
      Self.synopsis(subtitle: nil, description: "<a href=\"https://example.com\">Show notes</a>")
        == "Show notes")
    #expect(
      Self.synopsis(subtitle: nil, description: "One<br>Two<br/>Three") == "One Two Three")
  }

  @Test func synopsisCollapsesWhitespaceAndEntities() {
    #expect(
      Self.synopsis(subtitle: nil, description: "Tito   &amp;   the\n\n  Partisans")
        == "Tito & the Partisans")
    #expect(
      Self.synopsis(subtitle: nil, description: "&lt;not a tag&gt; &quot;quoted&quot;")
        == "<not a tag> \"quoted\"")
    #expect(Self.synopsis(subtitle: nil, description: "Non&nbsp;breaking") == "Non breaking")
    #expect(Self.synopsis(subtitle: nil, description: "It&#39;s &#x2014; fine") == "It's — fine")
  }

  @Test func synopsisIsNilWhenBothEmpty() {
    #expect(Self.synopsis(subtitle: nil, description: nil) == nil)
    #expect(Self.synopsis(subtitle: "", description: "") == nil)
    #expect(Self.synopsis(subtitle: "  ", description: " \n ") == nil)
    // Markup that strips down to nothing is nothing, not an empty line under the title.
    #expect(Self.synopsis(subtitle: nil, description: "<p></p><br/>&nbsp;") == nil)
  }

  // MARK: - One canonical episode menu

  @Test func episodeMenuSectionsShareBookOrderAndDropEmptyGroups() {
    let complete = PodcastShowPresentation.episodeActionSections(
      status: .notDownloaded, isAvailableOnServer: true, surface: .episodeList)
    #expect(complete.map(\.kind) == [.primary, .navigation, .download, .progress])
    #expect(complete.contains { $0.kind == .saved } == false)
    #expect(
      PodcastShowPresentation.episodeActions(
        status: .notDownloaded, isAvailableOnServer: true, surface: .episodeList
      ) == complete.flatMap(\.actions))

    let withoutDownload = PodcastShowPresentation.episodeActionSections(
      status: .notDownloaded, isAvailableOnServer: false, surface: .episodeList)
    #expect(withoutDownload.map(\.kind) == [.primary, .navigation, .progress])
    #expect(withoutDownload.allSatisfy { $0.actions.isEmpty == false })
  }

  @Test func episodeMenuSavedSectionFollowsResolvedMembership() {
    let cases: [(Bool?, [MediaItemAction]?)] = [
      (nil, nil),
      (false, [.saveForLater]),
      (true, [.removeFromSaved]),
    ]

    for (isSaved, expectedActions) in cases {
      let sections = PodcastShowPresentation.episodeActionSections(
        status: .notDownloaded,
        isAvailableOnServer: true,
        surface: .episodeList,
        isSaved: isSaved)
      let savedSection = sections.first { $0.kind == .saved }

      if let expectedActions {
        #expect(savedSection?.actions == expectedActions)
        #expect(sections.map(\.kind) == [.primary, .saved, .navigation, .download, .progress])
      } else {
        #expect(savedSection == nil)
        #expect(sections.map(\.kind) == [.primary, .navigation, .download, .progress])
      }

      #expect(
        PodcastShowPresentation.episodeActions(
          status: .notDownloaded,
          isAvailableOnServer: true,
          surface: .episodeList,
          isSaved: isSaved
        ) == sections.flatMap(\.actions))
    }
  }

  @Test func savedMembershipDoesNotChangeSurfaceSuppression() {
    let expected: [(PodcastMenuSurface, Set<MediaItemAction>)] = [
      (.show, [.openShow]),
      (.episodeList, [.saveToServer, .removeFromServer]),
      (.card, [.saveToServer, .removeFromServer]),
      (
        .episodeDetail,
        [
          .playPause, .saveForLater, .removeFromSaved, .download, .removeDownload, .pauseDownload,
          .resumeDownload, .openShow,
        ]
      ),
    ]

    for (surface, suppressed) in expected {
      for isSaved in [nil, false, true] as [Bool?] {
        _ = PodcastShowPresentation.episodeActions(
          status: .notDownloaded,
          isAvailableOnServer: true,
          surface: surface,
          isSaved: isSaved)
        #expect(PodcastShowPresentation.suppressedActions(on: surface) == suppressed)
      }
    }
  }

  /// The anti-drift test. Every surface derives from one list, and the only permitted differences
  /// are the two documented suppressions below. A third divergence fails here rather than being
  /// discovered on a device.
  @Test func episodeMenuIsIdenticalAcrossSurfacesExceptSuppressedEntries() {
    for status in Self.everyDownloadStatus {
      let canonical = PodcastShowPresentation.episodeActions(
        status: status, isAvailableOnServer: true, surface: .episodeList)

      for surface in PodcastMenuSurface.allCases {
        let actions = PodcastShowPresentation.episodeActions(
          status: status, isAvailableOnServer: true, surface: surface)
        let suppressed = PodcastShowPresentation.suppressedActions(on: surface)

        #expect(
          actions == canonical.filter { suppressed.contains($0) == false },
          "\(surface) differs from the canonical list by something other than its suppressions")
        // Order is part of the contract: a menu whose rows move between screens is as confusing
        // as one whose rows differ.
        #expect(actions == actions.sorted { canonical.firstIndex(of: $0)! < canonical.firstIndex(of: $1)! })
      }
    }
  }

  @Test func transcriptIsOfferedOnlyForADownloadedEpisodeTheCallerCanTranscribe() {
    func sections(_ status: ItemDownloadStatus, offersTranscript: Bool)
      -> [MediaItemActionSection]
    {
      PodcastShowPresentation.episodeActionSections(
        status: status, isAvailableOnServer: true, surface: .episodeDetail,
        offersTranscript: offersTranscript)
    }

    // It joins the navigation group: something to read, as View Details is in the player's menu.
    let navigation = sections(.completed, offersTranscript: true).first { $0.kind == .navigation }
    #expect(navigation?.actions == [.transcript])

    for status in Self.everyDownloadStatus where status != .completed {
      #expect(
        sections(status, offersTranscript: true).flatMap(\.actions).contains(.transcript) == false,
        "transcription reads the downloaded file, so \(status) offers no transcript")
    }
    // The caller says no for a show in an unsupported language or with no transcriber.
    #expect(
      sections(.completed, offersTranscript: false).flatMap(\.actions).contains(.transcript)
        == false)
    // Every surface that does not ask for it is unchanged.
    #expect(
      PodcastShowPresentation.episodeActions(
        status: .completed, isAvailableOnServer: true, surface: .episodeDetail
      ).contains(.transcript) == false)
  }

  /// The Watch pair is per-episode, not part of the download control's set: it joins the end of
  /// the device section, no surface suppresses it, and no projection hides it. A `nil` projection
  /// (no Watch app, not a native-RSS episode, or an identity the wire cannot carry) hides both.
  @Test func watchActionsTrailTheDeviceSectionOnEverySurface() {
    for surface in PodcastMenuSurface.allCases {
      let hidden = PodcastShowPresentation.episodeActionSections(
        status: .completed, isAvailableOnServer: true, surface: surface, watchCopy: nil)
      #expect(hidden.flatMap(\.actions).contains(.sendToWatch) == false)
      #expect(hidden.flatMap(\.actions).contains(.removeFromWatch) == false)

      let sendable = PodcastShowPresentation.episodeActionSections(
        status: .completed, isAvailableOnServer: true, surface: surface,
        watchCopy: .notOnWatch)
      #expect(sendable.first { $0.kind == .download }?.actions.last == .sendToWatch)

      let onWatch = PodcastShowPresentation.episodeActionSections(
        status: .completed, isAvailableOnServer: true, surface: surface, watchCopy: .onWatch)
      let removeDownload = onWatch.first { $0.kind == .download }
      #expect(removeDownload?.actions.last == .removeFromWatch)
      #expect(removeDownload?.actions.contains(.sendToWatch) == false)
    }
  }

  /// `.episodeDetail` suppresses the download control's own entries but never the Watch pair: the
  /// card's download control does not carry them.
  @Test func theEpisodeCardKeepsTheWatchPairInItsMenu() {
    let actions = PodcastShowPresentation.episodeActions(
      status: .completed, isAvailableOnServer: true, surface: .episodeDetail,
      watchCopy: .onWatch)
    #expect(actions.contains(.removeDownload) == false)
    #expect(actions.contains(.removeFromWatch))
  }

  @Test func showSurfaceSuppressesOpenShow() {
    let onShow = PodcastShowPresentation.episodeActions(
      status: .completed, isAvailableOnServer: true, surface: .show)
    #expect(onShow.contains(.openShow) == false, "you are already looking at the show")
    #expect(onShow.contains(.playNext))

    for surface in [PodcastMenuSurface.episodeList, .card] {
      #expect(
        PodcastShowPresentation.episodeActions(
          status: .completed, isAvailableOnServer: true, surface: surface
        ).contains(.openShow))
    }

    // The episode card suppresses it for a different reason than the show screen does: the show
    // line under its artwork is a link rather than a caption, so a menu row for a destination one
    // tap away is wasted.
    #expect(
      PodcastShowPresentation.episodeActions(
        status: .completed, isAvailableOnServer: true, surface: .episodeDetail
      ).contains(.openShow) == false)
  }

  /// There is no `.queue` surface. The player's queue sheet builds its rows' menu from
  /// `ListeningQueueViewPresentation.contextActions` (Play Now and Open, never a queue mutation),
  /// so "a queue row does not offer Play Next" is that type's contract, not a suppression here.
  @Test func noSurfaceReachesTheEpisodeMenuFromInsideUpNext() {
    #expect(PodcastMenuSurface.allCases.count == 4)
    #expect(
      PodcastMenuSurface.allCases.allSatisfy { surface in
        PodcastShowPresentation.suppressedActions(on: surface)
          .isDisjoint(with: [.playNext, .addToUpNext])
      })
  }

  /// Every device state resolves to a device action set, and between them they use every action the
  /// download coordinator can accept, so a stalled download can be resumed from any surface.
  @Test func episodeMenuCoversAllEightDownloadStates() {
    var seen: Set<MediaItemAction> = []
    for status in Self.everyDownloadStatus {
      let actions = PodcastShowPresentation.episodeActions(
        status: status, isAvailableOnServer: true, surface: .episodeList,
        playbackStatus: .inProgress)
      seen.formUnion(actions)

      // Playback and progress are unconditional: they describe what has been listened to, not what
      // is on this device, so no download state withdraws them.
      #expect(actions.contains(.playPause))
      #expect(actions.contains(.markAsFinished))
      #expect(actions.contains(.resetProgress))
    }

    #expect(seen.isSuperset(of: [.download, .pauseDownload, .resumeDownload, .removeDownload]))
  }

  @Test func episodeProgressActionsMatchSharedPolicy() {
    func progressActions(_ status: ItemPlaybackStatus?) -> [MediaItemAction] {
      PodcastShowPresentation.episodeActions(
        status: .notDownloaded, isAvailableOnServer: true, surface: .episodeList,
        playbackStatus: status
      ).filter {
        $0 == .markAsFinished || $0 == .resetProgress || $0 == .removeFromContinueListening
      }
    }

    #expect(progressActions(nil) == [.markAsFinished])
    #expect(
      progressActions(.inProgress)
        == [.markAsFinished, .resetProgress, .removeFromContinueListening])
    #expect(progressActions(.finished) == [.resetProgress])
  }

  /// Both sources record a Continue Listening dismissal durably (the account-owned progress row
  /// for ABS, `rssEpisodeState.hideFromContinueListening` for a device-owned episode), so the menu
  /// takes no view on which one it is drawing for.
  @Test func continueListeningRemovalIsOfferedWithoutRegardToSource() {
    #expect(
      PodcastShowPresentation.episodeActions(
        status: .notDownloaded, isAvailableOnServer: true, surface: .episodeList,
        playbackStatus: .inProgress
      ).contains(.removeFromContinueListening))
  }

  /// An episode already marked finished has nothing left for `Mark as Finished` to do: it writes
  /// the same progress row again and the surface does not visibly change, which reads as a broken
  /// menu entry. Every other entry stays, since replaying, re-queueing and resetting a finished
  /// episode are all real things to want.
  @Test func finishedEpisodeMenuOmitsMarkAsFinished() {
    for status in Self.everyDownloadStatus {
      for surface in PodcastMenuSurface.allCases {
        let unfinished = PodcastShowPresentation.episodeActions(
          status: status, isAvailableOnServer: true, surface: surface,
          playbackStatus: .inProgress)
        let finished = PodcastShowPresentation.episodeActions(
          status: status, isAvailableOnServer: true, surface: surface,
          playbackStatus: .finished)

        #expect(unfinished.contains(.markAsFinished))
        #expect(finished.contains(.markAsFinished) == false)
        #expect(finished.contains(.resetProgress), "un-finishing it is the remaining move")
        // The suppression is the only difference: order and every other entry are unchanged.
        #expect(
          finished
            == unfinished.filter {
              $0 != .markAsFinished && $0 != .removeFromContinueListening
            })
      }
    }
  }

  private static let everyDownloadStatus: [ItemDownloadStatus] = [
    .notDownloaded, .waitingForWiFi, .queued, .downloading(progressFraction: 0.42), .paused,
    .pausedAuth, .interrupted, .failed(category: .transport), .deleting, .completed,
  ]

  private static func synopsis(subtitle: String?, description: String?) -> String? {
    PodcastShowPresentation.episode(
      episode(
        status: .notDownloaded, isAvailableOnServer: true,
        subtitle: subtitle, episodeDescription: description), surface: .show
    ).synopsis
  }

  private static func episode(
    status: ItemDownloadStatus,
    isAvailableOnServer: Bool,
    subtitle: String? = "Subtitle",
    episodeDescription: String? = nil,
    isDownloadSizeKnown: Bool = true,
    synopsisLine: String? = nil
  ) -> PodcastEpisodeSummary {
    PodcastEpisodeSummary(
      id: "episode", title: "Episode", subtitle: subtitle,
      episodeDescription: episodeDescription,
      seasonNumber: nil, episodeNumber: nil, episodeType: nil, durationSeconds: 1_800,
      sizeBytes: nil, publishedAt: nil, progressSeconds: 0, isPlayed: false,
      isFinished: false, downloadStatus: status, isAvailableOnServer: isAvailableOnServer,
      isDownloadSizeKnown: isDownloadSizeKnown, synopsisLine: synopsisLine)
  }
}
