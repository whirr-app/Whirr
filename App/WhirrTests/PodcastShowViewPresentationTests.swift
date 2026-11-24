import ABSApi
import AppModel
import DesignSystem
import Foundation
import Observation
import Persistence
import TestSupport
import Testing

@testable import Whirr

@Suite("Podcast show presentation")
struct PodcastShowViewPresentationTests {
  /// The navigation title names the show from the first frame and never swaps while scrolling: it
  /// is what the back button and its history menu read. Every change of it relays out the bar, so
  /// what the bar *shows* is a principal item whose opacity alone follows the header.
  @Test func navigationTitleIsTheShow() {
    #expect(
      PodcastShowViewPresentation.navigationTitle(showTitle: "The Rest Is History")
        == "The Rest Is History")
  }

  @Test func navigationTitleFallsBackWithoutAShowTitle() {
    #expect(PodcastShowViewPresentation.navigationTitle(showTitle: nil) == "Podcast")
    #expect(PodcastShowViewPresentation.navigationTitle(showTitle: "  ") == "Podcast")
  }

  /// The header already names the show, so the bar stays empty on arrival. A title drawn there
  /// during the push lays out against the toolbar group mid-morph and is clipped, then reflows.
  @Test func theBarShowsNoTitleWhileTheHeaderNamesTheShow() {
    #expect(
      PodcastShowViewPresentation.showsBarTitle(screenPlaceholder: nil, isHeaderTitleVisible: true)
        == false)
  }

  @Test func theBarNamesTheShowOnceTheHeaderTitleHasScrolledAway() {
    #expect(
      PodcastShowViewPresentation.showsBarTitle(screenPlaceholder: nil, isHeaderTitleVisible: false))
  }

  /// A show still loading is about to draw its header; naming it in the bar first would fade the
  /// title out again a frame later, which is the flicker this rule exists to remove.
  @Test func theBarStaysEmptyWhileTheHeaderIsStillToCome() {
    #expect(
      PodcastShowViewPresentation.showsBarTitle(
        screenPlaceholder: .loading, isHeaderTitleVisible: true) == false)
  }

  /// No header will be drawn for a show that is not found, so the bar is the only name it gets.
  @Test func theBarNamesTheScreenWhenNoHeaderWillBeDrawn() {
    #expect(
      PodcastShowViewPresentation.showsBarTitle(
        screenPlaceholder: .notFound, isHeaderTitleVisible: true))
  }

  @Test func downloadingDeviceStatusKeepsKnownZeroDeterminateAndUnknownIndeterminate() {
    let known = PodcastShowViewPresentation.deviceStatus(
      for: .downloading(progressFraction: 0), isDownloadSizeKnown: true)
    let unknown = PodcastShowViewPresentation.deviceStatus(
      for: .downloading(progressFraction: 0), isDownloadSizeKnown: false)

    #expect(known.isIndeterminate == false)
    #expect(known.clampedProgressFraction == 0)
    #expect(unknown.isIndeterminate)
    #expect(unknown.clampedProgressFraction == nil)
  }

  @Test func notFoundCopyDistinguishesDeviceSubscriptionsFromABS() {
    let rssMessage = PodcastShowViewPresentation.notFoundMessage(for: "rss:7")
    let absMessage = PodcastShowViewPresentation.notFoundMessage(for: "abs-show")

    #expect(rssMessage != absMessage)
    #expect(rssMessage == "This podcast is not subscribed on this device.")
    #expect(absMessage == "This podcast is no longer in your synced library.")
  }

  @Test("the header captions a followed feed with the source presentation's own copy")
  func theHeaderCaptionsAFeedFromTheSharedSourceCopy() {
    #expect(PodcastShowSourcePresentation.showCaption(itemID: "rss:7") == "Followed on this device")
    #expect(
      PodcastShowSourcePresentation.showCaption(itemID: "abs-show")
        == "On your Audiobookshelf server")
    #expect(
      PodcastShowViewPresentation.sourceCaptionSymbolName(for: "rss:7")
        == "iphone")
    #expect(
      PodcastShowViewPresentation.sourceCaptionSymbolName(for: "abs-show")
        == "server.rack")
  }

  @Test func theShowIDIsTheWashKeyForHeaderAndRows() {
    #expect(PodcastShowViewPresentation.washKey(for: "show-1") == "show-1")
  }

  @Test("page artwork source prefers seed, then resolver, then loaded item")
  func pageArtworkSourceUsesSeedResolverAndLoadedItemInOrder() {
    let seed = ItemSummary(
      serverItemId: "rss:7", mediaKind: "podcast", title: "Seed", author: nil,
      durationSeconds: nil, category: .podcast,
      artworkURL: URL(string: "https://example.com/seed.jpg"),
      artworkFeedURL: URL(string: "https://example.com/feed.xml"))
    let loaded = ItemSummary(
      serverItemId: "rss:7", mediaKind: "podcast", title: "Loaded", author: nil,
      durationSeconds: nil, category: .podcast,
      artworkURL: URL(string: "https://example.com/loaded.jpg"),
      artworkFeedURL: URL(string: "https://example.com/feed.xml"))
    let resolverSource = ArtworkSource.audiobookshelf(ArtworkAccountScope("resolver"))

    #expect(
      PodcastShowViewPresentation.pageArtworkSource(
        seed: seed, resolverSource: resolverSource, loadedItem: loaded) == seed.providerArtworkSource)
    #expect(
      PodcastShowViewPresentation.pageArtworkSource(
        seed: nil, resolverSource: resolverSource, loadedItem: loaded) == resolverSource)
    #expect(
      PodcastShowViewPresentation.pageArtworkSource(
        seed: nil, resolverSource: nil, loadedItem: loaded) == loaded.providerArtworkSource)
    #expect(
      PodcastShowViewPresentation.pageArtworkSource(
        seed: nil, resolverSource: nil, loadedItem: nil) == nil)
  }

  /// Restraint: two full-width fills, the header card and every episode row, would put the cover's
  /// colour under most of the screen. The palette spends it on marks instead. No surface takes a
  /// fill, and the accent goes to the row's glyph and bar and to the selected filter chip.
  @Test func theShowPageSpendsItsWashOnMarksAndNotOnSurfaces() {
    let wash = CoverWash.from(hue: 0.97, saturation: 0.6, brightness: 0.5)
    let palette = PodcastShowViewPresentation.palette(for: wash)

    #expect(palette.headerFill == nil)
    #expect(palette.episodeRowFill == nil)
    #expect(palette.separatesEpisodeRows)
    #expect(palette.usesWashAccent)
    #expect(palette.accent != nil)
  }

  /// A cover too grey to yield an accent leaves the marks on the shared tint, as
  /// `PodcastEpisodeCardRow` does.
  @Test func aNeutralWashLeavesTheMarksOnTheirDefaultInk() {
    let palette = PodcastShowViewPresentation.palette(for: .neutral)

    #expect(palette.headerFill == nil)
    #expect(palette.episodeRowFill == nil)
    #expect(palette.usesWashAccent == false)
    #expect(palette.accent == nil)
  }

  /// The page's one surface use of the wash: a region painted behind the top of the page, not a
  /// fill handed to a card. That is why the two fills above stay nil.
  @Test func aTintedShowPaintsItsTopRegionWithTheCoversOwnWash() {
    let wash = CoverWash.from(hue: 0.97, saturation: 0.6, brightness: 0.5)
    let palette = PodcastShowViewPresentation.palette(for: wash)

    #expect(palette.headerWash == wash)
  }

  /// A grey cover has no colour worth spending. A gradient between two near-identical greys is a
  /// smudge, so no wash is rendered.
  @Test func aNeutralWashPaintsNoRegionAtAll() {
    #expect(PodcastShowViewPresentation.palette(for: .neutral).headerWash == nil)
  }

  /// The pin that stops the top-region wash undoing that restraint. The wash may reach this page as
  /// a region, but never as the header or episode-row fills, which would put a cover's hue under
  /// most of the screen. If a change hands `headerWash`'s value to a card, this fails.
  @Test func theTopRegionsWashNeverBecomesACardFill() {
    let wash = CoverWash.from(hue: 0.55, saturation: 0.8, brightness: 0.7)
    let palette = PodcastShowViewPresentation.palette(for: wash)

    #expect(palette.headerWash != nil)
    #expect(palette.headerFill == nil)
    #expect(palette.episodeRowFill == nil)
    #expect(palette.separatesEpisodeRows)
  }

  /// The fade must finish inside its region, or the first episode row sits on colour.
  @Test func theWashFadesOutWithinItsOwnRegion() {
    #expect(PodcastShowViewPresentation.headerWashHeight > 0)
    #expect(PodcastShowViewPresentation.headerWashSolidFraction > 0)
    #expect(PodcastShowViewPresentation.headerWashSolidFraction < 1)
  }

  /// At rest the wash sits against the physical top edge, behind the navigation bar.
  /// `contentInsets.top` is what the bar costs the content, so a resting list reports a content
  /// offset of exactly its negation.
  @Test func aRestingListLeavesTheWashAgainstTheTopEdge() {
    #expect(PodcastShowViewPresentation.washOffset(contentOffsetY: -96, topInset: 96) == 0)
  }

  /// Scrolled, the wash moves exactly as far as the content does, so it belongs to the header
  /// rather than the screen.
  @Test func theWashTravelsWithTheContent() {
    #expect(PodcastShowViewPresentation.washOffset(contentOffsetY: 4, topInset: 96) == 100)
  }

  /// Rubber-banding at the top must not peel the wash off the top edge. Following a negative offset
  /// would expose plain page above it, and fire on every frame of a pull-to-refresh.
  @Test func overscrollingAtTheTopDoesNotDetachTheWash() {
    #expect(PodcastShowViewPresentation.washOffset(contentOffsetY: -260, topInset: 96) == 0)
  }

  /// The bound that keeps observation cheap. Once the region has left the screen, every larger
  /// offset draws the same frame, so the value stops changing and the action stops firing. A long
  /// episode list then scrolls at no cost for the rest of its travel.
  @Test func theWashStopsProducingValuesOnceItHasLeftTheScreen() {
    let height = PodcastShowViewPresentation.headerWashHeight

    #expect(PodcastShowViewPresentation.washOffset(contentOffsetY: height, topInset: 0) == height)
    #expect(
      PodcastShowViewPresentation.washOffset(contentOffsetY: height * 40, topInset: 0) == height)
  }

  /// `scrollContentBackground(.hidden)` leaves each cell on `systemBackground` (see
  /// `LibraryBrowseView.editorialListRow`), so every row declares a background: cleared, or carded
  /// by `editorialCardListRow`. Source-level, as a cell's resolved fill is unreadable here; the
  /// separator count is the row count the fills are checked against.
  @Test("every row of the show list declares the fill its cell takes")
  func everyShowListRowDeclaresItsOwnCellFill() throws {
    let text = try Self.showContentSource()

    let rows = ViewSourceScan.occurrences(of: [".listRowSeparator("], in: text)
    let cleared = ViewSourceScan.occurrences(of: [".listRowBackground(Color.clear)"], in: text)
    let carded = ViewSourceScan.occurrences(of: [".editorialCardListRow("], in: text)

    #expect(rows > 0)
    #expect(
      cleared + carded == rows,
      "\(rows) row(s) declared, but only \(cleared) clear and \(carded) carded fills were explicit"
    )
  }

  /// A cell takes the innermost background, and `editorialCardListRow` already declares one, so a
  /// second at the call site is silently discarded while the scan above still counts it.
  @Test("no episode row declares a fill outside editorialCardListRow")
  func anEpisodeRowsFillIsDeclaredExactlyOnce() throws {
    let text = try Self.showContentSource()

    let episodeStart = try #require(text.range(of: "ForEach(filteredEpisodes)"))
    let episodeTail = text[episodeStart.lowerBound...]
    // The next sibling row ends the episode region.
    let episodeEnd = try #require(
      episodeTail.range(of: "if let actionErrorMessage = model.actionErrorMessage"))

    #expect(
      episodeTail[..<episodeEnd.lowerBound].contains(".listRowBackground(") == false,
      "an episode row's fill is `editorialCardListRow`'s to declare; a second one is discarded")
  }

  /// Performance guardrail: the offset is clamped by `washOffset(contentOffsetY:topInset:)` and
  /// held in a reference type this screen's `body` never reads. A `@State private var washOffset:
  /// CGFloat` would rebuild the whole `List` on every scroll frame.
  @Test("the wash's scroll offset never invalidates the show list")
  func theWashOffsetIsHeldOutsideTheScreensOwnState() throws {
    let text = try Self.showViewSource()

    #expect(text.contains("@State private var washOffset = PodcastShowWashOffset()"))
    #expect(
      ViewSourceScan.occurrences(of: ["onScrollGeometryChange"], in: text) == 1,
      "the wash is the one scroll observer; the bar title stays fixed for the whole visit")
    #expect(
      ViewSourceScan.occurrences(of: ["washOffset.value"], in: text) == 1,
      "the only write is the scroll action; the read belongs to PodcastShowWashBackground")
    #expect(
      text.contains("PodcastShowViewPresentation.washOffset("),
      "the scroll transform has to clamp, or scrolling past the wash keeps firing")

    // The cheaper mechanisms stay banned: neither can express this, and both cost a layout pass.
    for forbidden in ["GeometryReader", "PreferenceKey"] {
      #expect(text.contains(forbidden) == false, "PodcastShowView must not use \(forbidden)")
    }
  }

  /// Performance guardrail, as for the wash: whether the header's title is on screen flips mid
  /// scroll, so it lives in a reference type only the bar title view reads. A `@State Bool` on the
  /// screen rebuilt the whole `List` at each crossing, which showed as a jolt as the title arrived.
  @Test("the header title's visibility never invalidates the show list")
  func theHeaderTitleVisibilityIsHeldOutsideTheScreensOwnState() throws {
    let text = try Self.showViewSource()

    #expect(text.contains("@State private var barTitleState = PodcastShowBarTitleState()"))
    #expect(text.contains("@State private var isHeaderTitleVisible") == false)
    #expect(
      ViewSourceScan.occurrences(of: ["barTitleState.isHeaderTitleVisible"], in: text) == 0,
      "the read belongs to PodcastShowBarTitle, never the screen's body")
    #expect(
      ViewSourceScan.occurrences(of: ["barTitleState.setHeaderTitleVisible("], in: text) == 1,
      "the only write is the header's visibility callback")
  }

  /// The arrival flash came back once already. The bar's title must be one principal item, always
  /// present outside selection, that fades by opacity: inserting it, or putting the show in
  /// `navigationTitle` alone, lays it out against the toolbar group mid-push, clipped, then
  /// reflowed.
  @Test("the bar title is a principal item that only fades")
  func theBarTitleIsAnAlwaysPresentPrincipalItemThatFades() throws {
    let text = try Self.showViewSource()

    #expect(ViewSourceScan.occurrences(of: [".toolbar { barTitle }"], in: text) == 1)
    #expect(ViewSourceScan.occurrences(of: ["ToolbarItem(placement: .principal)"], in: text) == 1)
    #expect(text.contains(".opacity(isShown ? 1 : 0)"))
    #expect(
      ViewSourceScan.occurrences(of: ["if isShown", "if state.isHeaderTitleVisible"], in: text)
        == 0,
      "the title view stays in the bar; only its opacity follows the header")
  }

  /// Visibility is reported again as rows are reused; an unchanged value must not notify.
  @Test func repeatingTheSameHeaderTitleVisibilityDoesNotNotify() {
    let state = PodcastShowBarTitleState()
    let didNotify = Locked(false)
    withObservationTracking {
      _ = state.isHeaderTitleVisible
    } onChange: {
      didNotify.value = true
    }

    state.setHeaderTitleVisible(true)
    #expect(didNotify.value == false)
    state.setHeaderTitleVisible(false)
    #expect(didNotify.value)
  }

  // Keep the screen and its extracted content separate, so source-level checks follow the code that
  // owns the policy they describe.
  private static func showViewSource() throws -> String {
    try ViewSourceScan.executableText(ofViewNamed: "PodcastShowView")
  }

  private static func showContentSource() throws -> String {
    let source = try ViewSourceScan.source(declaring: "PodcastShowContentView")
    return try ViewSourceScan.executableText(of: source)
  }

  @Test("the outer screen keeps a scroll host for item loading and not-found states")
  func screenPlaceholdersAreNonInterceptingOverlays() {
    for state in [ItemDetailModel.State.loading, .notFound] {
      let placeholder = PodcastShowViewPresentation.screenPlaceholder(for: state)

      #expect(placeholder != nil)
      #expect(placeholder?.allowsHitTesting == false)
    }

    let item = ItemSummary(
      serverItemId: "show-1", mediaKind: "podcast", title: "Show", author: "Publisher",
      durationSeconds: nil, category: .podcast)
    #expect(PodcastShowViewPresentation.screenPlaceholder(for: .loaded(item)) == nil)
  }

  @Test func cachedRowsStayVisibleAcrossNonTerminalStates() {
    let episode = Self.episode()
    for state in [
      PodcastShowModel.State.refreshing, .staleOffline, .partiallyDecoded,
    ] {
      let content = PodcastShowViewPresentation.content(state: state, episodes: [episode])
      #expect(content.episodeIDs == ["episode"])
      #expect(content.stateText == state.copyText)
    }
  }

  @Test func episodeRowMapsStatusesAndAClosedActionSet() {
    let row = PodcastShowViewPresentation.episode(Self.episode(), queueAvailability: .both)
    #expect(row.title == "Episode")
    #expect(row.playbackStatus == .inProgress)
    #expect(row.serverAvailability == .available)
    #expect(row.deviceStatus.text == ItemDownloadCopy.shortText(for: .downloading(progressFraction: 0.4)))
    #expect(
      row.actions.map(\.id) == [
        "play-pause", "play-next", "add-up-next", "pause-download",
        "mark-as-finished", "reset-progress", "remove-from-continue-listening", "remove-download",
      ])
    // One device-download label per episode. Server availability is a separate fact, not a second
    // copy of the device-transfer state.
    #expect(row.serverAvailabilityText == PodcastCopy.availableOnServer)
    #expect(row.serverAvailabilityText != row.deviceStatus.text)
  }

  /// The drift guard between the show row and the cross-show card rows. Both read
  /// `PodcastEpisodeListeningState`, so for the same episode they show the same words and bar, and
  /// agree on whether it is started or finished.
  @Test func episodeRowListeningStateMatchesTheCrossShowRows() {
    let inputs: [(progress: Double, isFinished: Bool, duration: Double?)] = [
      (0, false, 1_800), (600, false, 1_800), (1_800, false, 1_800), (600, true, 1_800),
      (600, false, nil), (0, true, nil),
    ]

    for input in inputs {
      let summary = PodcastEpisodeSummary(
        id: "episode", title: "Episode", subtitle: nil, episodeDescription: nil,
        seasonNumber: nil, episodeNumber: nil, episodeType: nil,
        durationSeconds: input.duration, sizeBytes: nil,
        publishedAt: Date(timeIntervalSince1970: 0), progressSeconds: input.progress,
        isPlayed: input.progress > 0, isFinished: input.isFinished,
        downloadStatus: .notDownloaded, isAvailableOnServer: true)
      let row = PodcastShowViewPresentation.episode(summary, queueAvailability: .both)
      let listening = HomePodcastEpisodePresentation(
        episode: HomePodcastEpisode(
          itemID: "show", showTitle: "Show", showAuthor: nil, episodeID: "episode",
          title: "Episode", subtitle: nil, publishedAt: Date(timeIntervalSince1970: 0),
          durationSeconds: input.duration, progressSeconds: input.progress,
          isFinished: input.isFinished)
      ).listening

      #expect(row.progressText == listening.progressText)
      #expect(row.playbackProgressFraction == listening.progressFraction)
      #expect(
        row.playbackStatus
          == PodcastShowViewPresentation.playbackStatus(for: listening.playbackStatus))
    }
  }

  /// The show row passes this policy to `PodcastEpisodeRowView` unflattened, so its native menu
  /// keeps the separators the Home and Podcasts cards show. This pins the canonical boundaries and
  /// the fact that the `actions` projection is only their flattened form.
  @Test func episodeRowPreservesCanonicalMenuSections() {
    let row = PodcastShowViewPresentation.episode(
      Self.episode(downloadStatus: .completed),
      creator: "Goalhanger",
      isSaved: true,
      queueAvailability: .none)

    #expect(
      row.actionSections.map { $0.map(\.id) } == [
        ["play-pause"],
        ["remove-from-saved"],
        [MediaItemMenuLayout.Submenu.progress.id],
        ["remove-download"],
      ])
    #expect(
      row.actionSections[2].first?.children.map(\.id) == [
        "mark-as-finished", "reset-progress", "remove-from-continue-listening",
      ])
    #expect(row.actions.map(\.id).last == "remove-download")
  }

  /// Tapping a show row presents the episode card rather than playing. `PodcastShowView` wires
  /// `onSelect` to this pure ref-builder, so the tap's target is pinned without rendering the view.
  @Test func episodeRowSelectPresentsCard() {
    let ref = PodcastShowViewPresentation.episodeRowSelection(
      itemID: "show-1", episodeID: Self.episode().id)

    #expect(ref == NavigationModel.PodcastEpisodeRef(itemID: "show-1", episodeID: "episode"))
  }

  /// The row's primary tap opens the card, but quick play stays two cheap paths away: long-press
  /// to Play, or the card's own button. `.playPause` staying first in the canonical `.show` list
  /// keeps it in the row's long-press menu and ellipsis.
  @Test func episodeRowMenuStillOffersPlayPause() {
    let row = PodcastShowViewPresentation.episode(Self.episode(), queueAvailability: .both)

    #expect(row.actions.map(\.id).contains(PodcastEpisodeViewAction.playPause.rawValue))
  }

  @Test func resolvedSavedMembershipAddsExactlyOneStatefulRowAction() {
    let unsaved = PodcastShowViewPresentation.episode(
      Self.episode(), isSaved: false, queueAvailability: .both)
    let saved = PodcastShowViewPresentation.episode(
      Self.episode(), isSaved: true, queueAvailability: .both)

    #expect(
      unsaved.actions.filter { $0.id == PodcastEpisodeViewAction.saveForLater.rawValue }.count
        == 1)
    #expect(
      unsaved.actions.first { $0.id == PodcastEpisodeViewAction.saveForLater.rawValue }?.label
        == "Save for Later")
    #expect(
      saved.actions.filter { $0.id == PodcastEpisodeViewAction.removeFromSaved.rawValue }.count
        == 1)
    #expect(
      saved.actions.first { $0.id == PodcastEpisodeViewAction.removeFromSaved.rawValue }?.label
        == "Remove from Saved")
    #expect(
      unsaved.actions.first?.id == PodcastEpisodeViewAction.playPause.rawValue)
    let saveAction = unsaved.actions.first {
      $0.id == PodcastEpisodeViewAction.saveForLater.rawValue
    }
    let removeAction = saved.actions.first {
      $0.id == PodcastEpisodeViewAction.removeFromSaved.rawValue
    }
    #expect(
      saveAction?.systemImage == "bookmark")
    #expect(
      removeAction?.systemImage == "bookmark.fill")
  }

  /// A failed download's trailing control explains rather than retries. It is
  /// `PodcastDownloadFailurePresentation`'s control, not the Resume the menu still lists.
  @Test func aFailedRowsControlExplainsFirst() throws {
    let row = PodcastShowViewPresentation.episode(
      Self.episode(downloadStatus: .failed(category: .validation)), queueAvailability: .both)

    #expect(row.deviceStatus.kind == .failed)
    #expect(row.downloadAction?.id == PodcastEpisodeViewAction.explainDownloadFailure.rawValue)
    #expect(row.actions.map(\.id).contains(row.downloadAction?.id ?? "") == false)
    #expect(row.actions.map(\.id).contains(PodcastEpisodeViewAction.resumeDownload.rawValue))

    // Other actionable states keep their status-derived tap.
    let paused = PodcastShowViewPresentation.episode(
      Self.episode(downloadStatus: .paused), queueAvailability: .both)
    #expect(paused.downloadAction?.id == PodcastEpisodeViewAction.resumeDownload.rawValue)
  }

  @Test func rowDeviceStatusUsesShortRowCopyNotTheDetailScreenSentence() {
    let row = PodcastShowViewPresentation.episode(
      Self.episode(downloadStatus: .waitingForWiFi), queueAvailability: .both)
    #expect(row.deviceStatus.text == ItemDownloadCopy.shortText(for: .waitingForWiFi))
    #expect(row.deviceStatus.text != ItemDownloadCopy.waitingForWiFi)
    #expect(row.deviceStatus.text.count <= 30)

    let statuses: [ItemDownloadStatus] = [
      .notDownloaded, .waitingForWiFi, .queued, .paused, .pausedAuth, .interrupted,
      .deleting, .completed, .failed(category: .transport), .failed(category: .auth),
      .failed(category: .validation), .failed(category: .storage),
      .failed(category: .lowDisk), .failed(category: .unknown),
    ]
    let shortForms = statuses.map { ItemDownloadCopy.shortText(for: $0) }
    #expect(Set(shortForms).count == statuses.count, "every status keeps a distinct short form")
    #expect(shortForms.allSatisfy { $0.count <= 30 })
  }

  @Test func aFilteredEmptyListNeverClaimsTheCacheIsEmpty() {
    let placeholder = PodcastShowViewPresentation.placeholder(
      state: .loaded, episodeCount: 20, filteredEpisodeCount: 0, filter: .downloaded)

    #expect(
      placeholder
        == .empty(
          title: PodcastShowListCopy.noMatchingEpisodesTitle,
          message: PodcastShowListCopy.noMatches(.downloaded),
          systemImage: PodcastShowListCopy.noMatchingEpisodesSystemImage))
    #expect(placeholder?.message != PodcastShowModel.State.empty.copyText)
  }

  @Test func filterEmptyCopyOutranksNonTerminalStateCopy() {
    for state in [PodcastShowModel.State.staleOffline, .partiallyDecoded, .refreshing] {
      let placeholder = PodcastShowViewPresentation.placeholder(
        state: state, episodeCount: 3, filteredEpisodeCount: 0, filter: .played)
      #expect(placeholder?.message == PodcastShowListCopy.noMatches(.played))
    }
  }

  @Test func queryEmptyCopyNamesTheSearchAndTheStatusFilter() {
    let placeholder = PodcastShowViewPresentation.placeholder(
      state: .loaded, episodeCount: 20, filteredEpisodeCount: 0, filter: .unplayed,
      query: " Islam ")

    #expect(
      placeholder
        == .empty(
          title: PodcastShowListCopy.noMatchingEpisodesTitle,
          message: "No unplayed episodes match “Islam”. Try another search or choose a different filter.",
          systemImage: PodcastShowListCopy.noMatchingEpisodesSystemImage))
  }

  @Test func anEmptyCacheKeepsItsLoadingAndEmptyPlaceholders() {
    #expect(
      PodcastShowViewPresentation.placeholder(
        state: .refreshing, episodeCount: 0, filteredEpisodeCount: 0, filter: .all)
        == .loading(message: PodcastShowModel.State.refreshing.copyText))
    #expect(
      PodcastShowViewPresentation.placeholder(
        state: .loaded, episodeCount: 0, filteredEpisodeCount: 0, filter: .all)
        == .empty(
          title: PodcastShowListCopy.noEpisodesTitle,
          message: PodcastShowModel.State.empty.copyText,
          systemImage: PodcastShowListCopy.noEpisodesSystemImage))
    #expect(
      PodcastShowViewPresentation.placeholder(
        state: .loaded, episodeCount: 2, filteredEpisodeCount: 2, filter: .all) == nil)
  }

  /// Until the cache has answered, an empty episode array means "not read yet", not "nothing
  /// cached". The appear refresh flips the state to `.refreshing` before that first read lands, so
  /// keying the spinner off state alone flashed it on every visit to a show with rows.
  @Test func anUnreadCacheRendersNoPlaceholderInAnyState() {
    for state in PodcastShowModel.State.allCases {
      #expect(
        PodcastShowViewPresentation.placeholder(
          state: state, hasReadEpisodeCache: false, episodeCount: 0, filteredEpisodeCount: 0,
          filter: .all) == nil)
    }
  }

  /// No state copy above the list in any state: loading, refreshing, then settled runs on every
  /// visit, and text appearing and vanishing within a tenth of a second reflows the rows. Only an
  /// empty result set has anything to explain. States worth knowing about get a toolbar glyph
  /// (outside the list's layout flow); transient states get nothing.
  @Test func onlyTheStatesWorthKnowingAboutEarnAToolbarGlyph() {
    let silent: [PodcastShowModel.State] = [.loading, .refreshing, .loaded, .empty]
    for state in silent {
      #expect(PodcastShowViewPresentation.stateIndicator(for: state) == nil)
    }

    let speaking: [PodcastShowModel.State] = [.staleOffline, .recoverableError, .partiallyDecoded]
    let indicators = speaking.compactMap(PodcastShowViewPresentation.stateIndicator)
    #expect(indicators.count == speaking.count)
    // Distinguishable at a glance: "we can't reach the server" and "some of this didn't decode"
    // are different problems, so they need different glyphs.
    #expect(Set(indicators.map(\.systemImage)).count == speaking.count)
    #expect(indicators.allSatisfy { $0.title.isEmpty == false })
    // The explanation is the state's own sentence, so there is no second wording to drift.
    #expect(zip(speaking, indicators).allSatisfy { $0.copyText == $1.message })
  }

  @Test func aShowWithRowsRendersNothingButItsRows() {
    for state in PodcastShowModel.State.allCases {
      #expect(
        PodcastShowViewPresentation.placeholder(
          state: state, episodeCount: 3, filteredEpisodeCount: 3, filter: .all) == nil)
    }
  }

  @Test func everyFilterHasItsOwnLabelAndNoMatchesCopy() {
    let filters = PodcastEpisodeFilter.allCases
    #expect(Set(filters.map(PodcastShowListCopy.filterLabel)).count == filters.count)
    #expect(Set(filters.map(PodcastShowListCopy.noMatches)).count == filters.count)
    #expect(filters.allSatisfy { PodcastShowListCopy.noMatches($0).isEmpty == false })
    #expect(PodcastShowListCopy.filterLabel(.downloaded) == "Downloads")
  }

  @Test func unavailableEpisodeOffersNoDownloadAction() {
    let row = PodcastShowViewPresentation.episode(
      Self.episode(isAvailableOnServer: false, downloadStatus: .notDownloaded),
      queueAvailability: .both)
    #expect(row.serverAvailability == .unavailable)
    // The progress actions survive. They concern what has been listened to, not what is
    // downloadable, so a server-unavailable episode can still be marked finished.
    #expect(
      row.actions.map(\.id) == [
        "play-pause", "play-next", "add-up-next", "mark-as-finished", "reset-progress",
        "remove-from-continue-listening",
      ])
  }

  /// The queue has two ends, and the row offers one action for each: `insertNext` and append.
  @Test func playNextAndAddToQueueAreSeparateRowsInThatOrder() {
    let row = PodcastShowViewPresentation.episode(Self.episode(), queueAvailability: .both)
    let queueRows = row.actions.filter { ["play-next", "add-up-next"].contains($0.id) }

    #expect(queueRows.map(\.id) == ["play-next", "add-up-next"])
    #expect(queueRows.map(\.label) == ["Play Next", "Add to Up Next"])
    #expect(Set(queueRows.map(\.systemImage)).count == 2, "two ends of the queue, two symbols")
    #expect(queueRows.allSatisfy { $0.role == .standard })
    #expect(row.actions.prefix(3).map(\.id) == ["play-pause", "play-next", "add-up-next"])
  }

  /// The show's rows lead with Play/Pause, as every other surface's menu does. `.openShow` is the
  /// one entry this surface drops. Publisher discovery is absent, since the show itself is the
  /// meaningful podcast destination.
  @Test func episodeRowActionsMatchCanonicalList() {
    let withCreator = PodcastShowViewPresentation.episode(
      Self.episode(), creator: "Slate", queueAvailability: .both)
    #expect(withCreator.actions.first?.id == "play-pause")
    #expect(withCreator.actions.map(\.id).contains("open-show") == false)
    #expect(withCreator.actions.map(\.id).contains("more-from-creator") == false)
    #expect(
      withCreator.actions.suffix(4).map(\.id) == [
        "mark-as-finished", "reset-progress", "remove-from-continue-listening", "remove-download",
      ])

    // Publisher metadata never changes the action set.
    let anonymous = PodcastShowViewPresentation.episode(
      Self.episode(), creator: nil, queueAvailability: .both)
    #expect(anonymous.actions.map(\.id).contains("more-from-creator") == false)
    #expect(
      PodcastShowViewPresentation.episode(
        Self.episode(), creator: "   ", queueAvailability: .both
      ).actions
        .map(\.id).contains("more-from-creator") == false)
  }

  /// The two conditions `MediaProgressActionPolicy` withholds removal for. Pinned here as well as
  /// in the shared policy, since the show row takes both as parameters.
  @Test func episodeRowWithholdsRemovalWhenHiddenOrPlaying() {
    let hidden = PodcastShowViewPresentation.episode(
      Self.episode(), queueAvailability: .both, isHidden: true)
    let playing = PodcastShowViewPresentation.episode(
      Self.episode(), queueAvailability: .both, isCurrentlyPlaying: true)

    #expect(hidden.actions.map(\.id).contains("remove-from-continue-listening") == false)
    #expect(playing.actions.map(\.id).contains("remove-from-continue-listening") == false)
    #expect(
      hidden.actions.suffix(3).map(\.id) == ["mark-as-finished", "reset-progress", "remove-download"])
  }

  /// Viewing the queue is the player's job, so podcast browsing offers no route to it. Nothing in
  /// this menu, by id, label or hint, may lead to a queue, and the closed action list has no case
  /// that could.
  @Test func showMenuOffersNoQueueDestination() {
    let items = Self.showMenu()

    #expect(items.isEmpty == false)
    for item in items {
      #expect(item.id.contains("up-next") == false)
      #expect(item.label.localizedCaseInsensitiveContains("up next") == false)
      #expect(item.hint.localizedCaseInsensitiveContains("queue") == false)
    }
    #expect(PodcastShowMenuAction.allCases.contains { $0.rawValue.contains("up-next") } == false)
  }

  @Test func showMenuExcludesServerDiagnostics() {
    let items = Self.showMenu()

    #expect(PodcastShowMenuAction.allCases.allSatisfy { $0.rawValue != "diagnostics" })
    #expect(items.allSatisfy { $0.label.localizedCaseInsensitiveContains("server") == false })
    #expect(items.allSatisfy { $0.label.localizedCaseInsensitiveContains("last checked") == false })
  }

  /// Mark-all is bounded by the visible filter, so the label has to say so. "Mark All as Played"
  /// under the Unplayed filter would read as the whole show, and be wrong.
  @Test func markAllLabelNamesTheFilteredScope() {
    #expect(
      PodcastShowViewPresentation.markAllLabel(filter: .all, isFinished: true)
        == "Mark All as Played")
    #expect(
      PodcastShowViewPresentation.markAllLabel(filter: .unplayed, isFinished: true)
        == "Mark All Unplayed as Played")
    #expect(
      PodcastShowViewPresentation.markAllLabel(filter: .downloaded, isFinished: false)
        == "Mark All Downloaded as Unplayed")
    #expect(
      PodcastShowViewPresentation.markAllLabel(filter: .all, isFinished: false)
        == "Mark All as Unplayed")
  }

  @Test func activeSearchNamesTheVisibleBulkActionScope() {
    let items = PodcastShowViewPresentation.showMenu(
      filter: .unplayed, unplayedCount: 3, playedCount: 2, downloadableCount: 2,
      removableCount: 1, isSearchActive: true)

    #expect(
      items.first { $0.id == PodcastShowMenuAction.markAllPlayed.rawValue }?.label
        == "Mark Shown as Played")
    #expect(
      items.first { $0.id == PodcastShowMenuAction.downloadAll.rawValue }?.label
        == "Download All Shown")
    #expect(
      items.first { $0.id == PodcastShowMenuAction.removeAllDownloads.rawValue }?.label
        == "Remove Shown Downloads")
  }

  /// A mark-all that would change one row needs no ceremony. One that would change forty is worth
  /// a question, because nothing on this screen undoes it in one gesture.
  @Test func markAllConfirmsOnlyAboveTheBulkThreshold() {
    #expect(PodcastShowViewPresentation.markAllConfirmation(count: 0, isFinished: true) == nil)
    #expect(PodcastShowViewPresentation.markAllConfirmation(count: 20, isFinished: true) == nil)

    let confirmation = PodcastShowViewPresentation.markAllConfirmation(count: 42, isFinished: true)
    #expect(confirmation?.contains("42") == true)
    #expect(
      PodcastShowViewPresentation.markAllConfirmation(count: 42, isFinished: false)
        != confirmation,
      "played and unplayed ask different questions")
  }

  /// The rows exist whatever the filter, but disable themselves when the filtered list holds
  /// nothing they would change. An enabled row that does nothing reads as a broken one.
  @Test func markAllRowsDisableWhenThereIsNothingToChange() {
    let live = Self.showMenu(unplayedCount: 3, playedCount: 1)
    #expect(
      live.first { $0.id == PodcastShowMenuAction.markAllPlayed.rawValue }?.isEnabled == true)
    #expect(
      live.first { $0.id == PodcastShowMenuAction.markAllUnplayed.rawValue }?.isEnabled == true)

    let allPlayed = Self.showMenu(filter: .played, unplayedCount: 0, playedCount: 9)
    #expect(
      allPlayed.first { $0.id == PodcastShowMenuAction.markAllPlayed.rawValue }?.isEnabled
        == false)
    #expect(
      allPlayed.first { $0.id == PodcastShowMenuAction.markAllUnplayed.rawValue }?.isEnabled
        == true)
  }

  /// Deleting files off the device is destructive and irreversible in one gesture, so it always
  /// asks. Unlike mark-all, which asks only past a bulk threshold. The copy names what goes and
  /// says it can come back, following the existing purge convention.
  @Test func removeAllDownloadsRequiresConfirmation() {
    #expect(PodcastShowViewPresentation.removeAllConfirmation(count: 1) != nil)
    #expect(PodcastShowViewPresentation.removeAllConfirmation(count: 40)?.contains("40") == true)
    #expect(
      PodcastShowViewPresentation.removeAllConfirmation(count: 1)?
        .contains("download them again") == true)

    // Nothing to delete asks nothing. The row is disabled in that state anyway.
    #expect(PodcastShowViewPresentation.removeAllConfirmation(count: 0) == nil)

    // Downloading is not destructive and needs no question.
    #expect(PodcastShowViewPresentation.downloadAllConfirmation(count: 40) == nil)
  }

  @Test func bulkDownloadRowsDisableWhenThereIsNothingToTransfer() {
    let live = Self.showMenu(downloadableCount: 4, removableCount: 2)
    #expect(
      live.first { $0.id == PodcastShowMenuAction.downloadAll.rawValue }?.isEnabled == true)
    #expect(
      live.first { $0.id == PodcastShowMenuAction.removeAllDownloads.rawValue }?.isEnabled
        == true)

    let nothing = Self.showMenu(downloadableCount: 0, removableCount: 0)
    #expect(
      nothing.first { $0.id == PodcastShowMenuAction.downloadAll.rawValue }?.isEnabled == false)
    #expect(
      nothing.first { $0.id == PodcastShowMenuAction.removeAllDownloads.rawValue }?.isEnabled
        == false)
  }

  /// The destructive row sits last, so a mis-tap never lands on it by muscle memory.
  @Test func removeAllDownloadsIsTheLastActionAndIsDestructive() {
    let items = Self.showMenu()
    let actionIDs = items.filter { $0.isEnabled }.map(\.id)

    #expect(actionIDs.last == PodcastShowMenuAction.removeAllDownloads.rawValue)
    #expect(
      items.first { $0.id == PodcastShowMenuAction.removeAllDownloads.rawValue }?.isDestructive
        == true)
    #expect(items.last?.id == PodcastShowMenuAction.removeAllDownloads.rawValue)
  }

  /// A device-owned feed replaces the bulk download group with Unfollow alone. A copy-feed-address
  /// row would copy a string with no destination inside the app, so "copy-feed-url" is asserted
  /// absent here, not only missing from the enum.
  /// Unfollow stays last and alone in its group, whether or not Save Show to Audiobookshelf… (group
  /// 2, beside Show Settings) is offered.
  @Test func nativeShowMenuOffersUnfollowOnly() {
    let items = PodcastShowViewPresentation.showMenu(
      filter: .all, unplayedCount: 1, playedCount: 1, downloadableCount: 4,
      removableCount: 2, isNativeFeed: true)
    let ids = Set(items.map(\.id))

    #expect(ids.contains(PodcastShowMenuAction.unsubscribe.rawValue))
    #expect(ids.contains("copy-feed-url") == false)
    #expect(ids.contains(PodcastShowMenuAction.downloadAll.rawValue) == false)
    #expect(ids.contains(PodcastShowMenuAction.removeAllDownloads.rawValue) == false)
    #expect(items.last?.id == PodcastShowMenuAction.unsubscribe.rawValue)
    #expect(items.last?.isDestructive == true)
  }

  /// Admin-only server routes (API-CONVENTIONS rule 26) stay out of the show menu, as does the
  /// action that destroys the show for every user of the server, so neither can be quietly added.
  /// The one server-facing row, Save Show to Audiobookshelf…, is not such a route. It only opens
  /// the existing multi-select save, which any account allowed to save can use, and it is absent
  /// from the default menu this test builds.
  @Test func showMenuHasNoAdminActions() {
    let ids = Set(Self.showMenu().map(\.id))

    #expect(ids.isSubset(of: Set(PodcastShowMenuAction.allCases.map(\.rawValue))))
    for forbidden in [
      "manage-auto-downloads", "manage-notifications", "remove-from-library", "share-podcast",
      "follow", "unfollow", "delete-podcast", "edit-podcast",
    ] {
      #expect(ids.contains(forbidden) == false)
    }
  }

  /// The show overflow's Show Settings entry is navigation, not server management, so it sits above
  /// the destructive download group. This matches the show screen, which leads with informational
  /// rows before anything irreversible.
  @Test func showMenuOffersShowSettingsBeforeDestructiveGroup() {
    let items = Self.showMenu(downloadableCount: 1, removableCount: 1)
    let settingsIndex = items.firstIndex { $0.id == PodcastShowMenuAction.openSettings.rawValue }
    let downloadIndex = items.firstIndex { $0.id == PodcastShowMenuAction.downloadAll.rawValue }
    let removeIndex = items.firstIndex {
      $0.id == PodcastShowMenuAction.removeAllDownloads.rawValue
    }

    #expect(settingsIndex != nil)
    #expect(downloadIndex != nil)
    #expect(removeIndex != nil)
    #expect(settingsIndex! < downloadIndex!)
    #expect(settingsIndex! < removeIndex!)
  }

  @Test func showSettingsActionIsNonDestructive() {
    let item = Self.showMenu().first { $0.id == PodcastShowMenuAction.openSettings.rawValue }

    #expect(item != nil)
    #expect(item?.isDestructive == false)
    #expect(item?.isEnabled == true)
  }

  /// This re-checks the closed set against the navigation case, so a later edit cannot quietly turn
  /// "Show Settings" into an admin route by widening its hint or label. Save Show to
  /// Audiobookshelf… is offered only through its own parameter, so this default menu stays free of
  /// server-facing rows.
  @Test func showMenuStillRejectsAdminActions() {
    let ids = Set(Self.showMenu().map(\.id))

    #expect(ids.isSubset(of: Set(PodcastShowMenuAction.allCases.map(\.rawValue))))
    #expect(ids.contains(PodcastShowMenuAction.openSettings.rawValue))
    for forbidden in [
      "manage-auto-downloads", "manage-notifications", "remove-from-library", "share-podcast",
      "follow", "unfollow", "delete-podcast", "edit-podcast",
    ] {
      #expect(ids.contains(forbidden) == false)
    }
  }

  /// The overflow's "Show Settings" installs `[.podcastSettings, .podcastShowSettings(itemID:)]` on
  /// the `.settings` stack via `NavigationModel.navigate(to:)`. That raises the settings sheet over
  /// whatever section or route the user is on, rather than moving them off it. Done therefore
  /// returns to the show the overflow was opened from, with no special case in `NavigationModel`.
  @MainActor
  @Test func showSettingsDestinationReturnsToOriginatingShowOnDone() {
    let destination = PodcastShowViewPresentation.showSettingsDestination(itemID: "show-1")
    #expect(destination.section == .settings)
    #expect(destination.path == [.podcastSettings, .podcastShowSettings(itemID: "show-1")])

    let model = NavigationModel(presentation: .shell, section: .podcasts)
    model.navigate(to: .podcastShow(itemID: "show-1"))
    model.navigate(to: destination)

    #expect(model.section == .podcasts)
    #expect(model[pathFor: .podcasts] == [.podcastShow(itemID: "show-1")])
    #expect(model[pathFor: .settings] == destination.path)
    #expect(model.settingsPresentation == .presented)

    model.dismissSettings()

    #expect(model.settingsPresentation == .dismissed)
    #expect(model.section == .podcasts)
    #expect(model[pathFor: .podcasts] == [.podcastShow(itemID: "show-1")])
  }

  @Test func everySwipeActionMapsToAVisibleSharedButton() {
    let cases: [(ItemContextMenuDownloadAction, Bool, Bool, ListeningIdentity?, ListeningIdentity?)] = [
      (.download, true, false, nil, nil),
      (.remove, true, false, Self.episodeIdentity, Self.otherIdentity),
      (.unavailable, true, true, Self.episodeIdentity, Self.episodeIdentity),
      (.download, false, true, Self.episodeIdentity, Self.otherIdentity),
    ]

    for (deviceAction, isAvailableOnServer, isFinished, identity, nowPlaying) in cases {
      let policy = PodcastEpisodeSwipeActions.actions(
        deviceAction: deviceAction,
        isAvailableOnServer: isAvailableOnServer,
        playbackStatus: isFinished ? .finished : nil,
        identity: identity,
        nowPlaying: nowPlaying, isPlaybackIntended: false)

      let buttons = PodcastShowViewPresentation.swipeButtons(for: policy)
      #expect(buttons != nil)
      #expect(buttons?.leading.count == policy.leading.count)
      #expect(buttons?.trailing.count == policy.trailing.count)
    }

    #expect(PodcastShowViewPresentation.contextAction(.openShow, creator: nil) == nil)
    #expect(PodcastShowViewPresentation.contextAction(.moreFromCreator, creator: nil) == nil)
  }

  @Test func swipeButtonRolesMatchTheSharedMenuActions() {
    let policy = PodcastEpisodeSwipeActions.actions(
      deviceAction: .remove,
      isAvailableOnServer: true,
      playbackStatus: nil,
      identity: Self.episodeIdentity,
      nowPlaying: Self.otherIdentity, isPlaybackIntended: false)
    let buttons = PodcastShowViewPresentation.swipeButtons(for: policy)

    #expect(
      buttons?.leading.map(\.role)
        == policy.leading.compactMap { Self.menuAction($0)?.role })
    #expect(
      buttons?.trailing.map(\.role)
        == policy.trailing.compactMap { Self.menuAction($0)?.role })
    // Remove Download and Mark as Finished, in that order. Only the first deletes bytes off the
    // device, so only it has a destructive role. `swipeTint` sets each capsule's colour explicitly,
    // so the role does not change the colour.
    #expect(buttons?.trailing.map(\.id) == ["remove-download", "mark-as-finished"])
    #expect(buttons?.trailing.map(\.role) == [.destructive, .standard])
  }

  /// The playing row's leading edge names the tap: Pause while playing, Play once paused. An empty
  /// edge would let the row slide open onto nothing.
  @Test func nowPlayingRowLeadingCapsuleNamesTheTap() {
    func leading(isPlaybackIntended: Bool) -> [PodcastEpisodeSwipeButton]? {
      PodcastShowViewPresentation.swipeButtons(
        for: PodcastEpisodeSwipeActions.actions(
          deviceAction: .remove, isAvailableOnServer: true, playbackStatus: .inProgress,
          identity: Self.episodeIdentity, nowPlaying: Self.episodeIdentity,
          isPlaybackIntended: isPlaybackIntended))?.leading
    }

    let playing = leading(isPlaybackIntended: true)
    #expect(playing == [PodcastShowViewPresentation.pauseSwipeButton])
    #expect(playing?.map(\.id) == [PodcastEpisodeViewAction.playPause.rawValue])

    let paused = leading(isPlaybackIntended: false)
    #expect(paused?.map(\.label) == ["Play"])
    #expect(paused?.map(\.systemImage) == ["play.fill"])
  }

  @Test func swipeButtonOrderMatchesPolicyOrderOnBothEdges() {
    let policy = PodcastEpisodeSwipeActions.actions(
      deviceAction: .download,
      isAvailableOnServer: true,
      playbackStatus: nil,
      identity: Self.episodeIdentity,
      nowPlaying: Self.otherIdentity, isPlaybackIntended: false)
    let buttons = PodcastShowViewPresentation.swipeButtons(for: policy)

    #expect(buttons?.leading.map(\.id) == ["play-next"])
    #expect(buttons?.trailing.map(\.id) == ["download", "mark-as-finished"])
    #expect(
      buttons?.leading.map(\.id)
        == policy.leading.compactMap { Self.menuAction($0)?.id })
    #expect(
      buttons?.trailing.map(\.id)
        == policy.trailing.compactMap { Self.menuAction($0)?.id })
  }

  @Test("every swipe button names its own fill rather than inheriting the app tint")
  func swipeButtonsNameTheirOwnFill() {
    for (action, tint) in Self.swipeVocabulary.map({ ($0.0, $0.2) }) {
      #expect(PodcastShowViewPresentation.swipeButton(for: action)?.tint == tint)
    }

    // Red marks deleting bytes only. Both progress edits share the trailing edge with Remove
    // Download, so red on either would make a progress change read as a deletion.
    #expect(Self.swipeVocabulary.filter { $0.2 == .remove }.map(\.0) == [.removeDownload])
  }

  @Test("swipe labels shorten the menu's phrasing rather than repeating it")
  func swipeLabelsShortenTheMenuVocabulary() {
    for (action, label, _) in Self.swipeVocabulary {
      let button = PodcastShowViewPresentation.swipeButton(for: action)
      #expect(button?.label == label)
      // iOS grows a swipe capsule past its minimum width to fit the title, so a longer label is a
      // physically wider target. The menu's "Remove Download" made a downloaded row's trailing edge
      // wider than an undownloaded row's in the same list.
      #expect(button?.label.count ?? .max <= Self.menuAction(action)?.label.count ?? 0)
    }
  }

  @Test("swipe buttons take their id, glyph, hint and role from the one menu table")
  func swipeButtonsReuseTheMenuPresentation() {
    for (action, _, _) in Self.swipeVocabulary {
      guard let button = PodcastShowViewPresentation.swipeButton(for: action),
        let menu = Self.menuAction(action)
      else {
        Issue.record("no swipe button for \(action)")
        continue
      }

      #expect(button.id == menu.id)
      #expect(button.systemImage == menu.systemImage)
      #expect(button.hint == menu.hint)
      #expect(button.role == menu.role)
    }
  }

  @Test("an action the menu cannot draw has no swipe button either")
  func swipeButtonsFailClosedWithTheMenu() {
    #expect(PodcastShowViewPresentation.swipeButton(for: .openShow) == nil)
    #expect(PodcastShowViewPresentation.swipeButton(for: .moreFromCreator) == nil)
  }

  private static func showMenu(
    filter: PodcastEpisodeFilter = .all,
    unplayedCount: Int = 1,
    playedCount: Int = 1,
    downloadableCount: Int = 1,
    removableCount: Int = 1
  ) -> [PodcastShowViewPresentation.ShowMenuItem] {
    PodcastShowViewPresentation.showMenu(
      filter: filter, unplayedCount: unplayedCount,
      playedCount: playedCount, downloadableCount: downloadableCount,
      removableCount: removableCount)
  }

  static func episode(
    isAvailableOnServer: Bool = true,
    downloadStatus: ItemDownloadStatus = .downloading(progressFraction: 0.4)
  ) -> PodcastEpisodeSummary {
    PodcastEpisodeSummary(
      id: "episode", title: "Episode", subtitle: "Subtitle", episodeDescription: nil,
      seasonNumber: nil, episodeNumber: nil, episodeType: nil, durationSeconds: 100,
      sizeBytes: 10, publishedAt: Date(timeIntervalSince1970: 0), progressSeconds: 40,
      isPlayed: true, isFinished: false, downloadStatus: downloadStatus,
      isAvailableOnServer: isAvailableOnServer)
  }

  private static let episodeIdentity = ListeningIdentity.podcastEpisode(
    itemID: "show-1", episodeID: "episode")
  private static let otherIdentity = ListeningIdentity.podcastEpisode(
    itemID: "show-2", episodeID: "other-episode")

  private static func menuAction(_ action: MediaItemAction) -> MediaContextAction? {
    PodcastShowViewPresentation.contextAction(action, creator: nil)
  }

  /// Every action `PodcastEpisodeSwipeActions` can put on an edge, with the label and fill it
  /// draws. Declared once, so the label, tint and menu-reuse tests walk the same list. A new action
  /// cannot be added to the policy without appearing here.
  private static let swipeVocabulary: [(MediaItemAction, String, PodcastEpisodeSwipeTint)] = [
    (.playPause, "Play", .playback),
    (.playNext, "Play Next", .playback),
    (.download, "Download", .download),
    (.removeDownload, "Remove", .remove),
    (.markAsFinished, "Finished", .finished),
    (.resetProgress, "Reset", .reset),
  ]
}
