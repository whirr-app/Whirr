import ABSApi
import AppModel
import DesignSystem
import Persistence
import SwiftUI

/// The two ways a `PodcastEpisodeCardView` leaves, decided by whoever presents it. Both drop the
/// card as part of the same call: the show line and the not-found fallback go through `openShow`,
/// the canonical menu's More From Creator through `search`, routed to the shared search entry
/// point the same way `PodcastShowView.perform` does for its own menu.
struct PodcastEpisodeCardHost {
  let openShow: (NavigationModel.Route) -> Void
  let search: (String) -> Void
}

/// The podcast episode's own sheet-presented card: artwork, title, a tappable show line,
/// date · duration · remaining, progress, a prominent Play/Resume button, the download control,
/// full show notes, and the canonical action menu. Composed from pieces the show screen's own
/// row/header already use.
///
/// Owns its content, not its presentation: the shell raises it as a `.sheet(item:)` on
/// `NavigationModel.presentedEpisode`, the player as a sheet over its page. Leaving differs (the
/// shell's card drops and pushes the show; the player's must also collapse), so the show line,
/// not-found fallback and More From Creator go through `PodcastEpisodeCardHost`.
struct PodcastEpisodeCardView: View {
  @State private var deferredModel = DeferredModel<PodcastEpisodeCardModel>()
  @State private var homeWashProvider: HomeWashProvider
  @State var isConfirmingRemove = false
  @State private var isShowingSupplementaryNotes = false
  @State var downloadFailureAlert: PodcastDownloadFailurePresentation.Alert?
  @State private var serverRemovalConfirmation: NativeEpisodeServerSaveRemovalConfirmation?
  @State private var transcript = PlayerTranscriptController()
  /// Owned here, not by the status line, so the status line and the progress lines share one
  /// answer: each reads only its own property, so neither redraws the card around them.
  @State private var adSkipStatusModel: AdSkipCardStatusModel
  @Environment(\.displayScale) private var displayScale
  @Environment(\.accessibilityReduceMotion) var reduceMotion
  @Environment(\.smartLists) private var smartLists
  @Environment(\.watchCopies) private var watchCopies

  let itemID: String
  /// The card's own identity, needed by `ListeningQueueActionPolicy`: the episode already playing
  /// offers no queue action for itself.
  let episodeID: String
  let coverClient: any ArtworkServing
  let paletteService: CoverPaletteService
  /// Read only, for the shell card's observation lifecycle (`presentedEpisode`); every navigation
  /// the card performs goes through `host`.
  let navigation: NavigationModel
  let playback: PlaybackModel
  let makeModel: () -> PodcastEpisodeCardModel
  let host: PodcastEpisodeCardHost
  /// Whether the card sits on the system's Liquid Glass, which decides its secondary ink. See
  /// `PodcastEpisodeCardViewPresentation.SecondaryInk`.
  let onSystemGlass: Bool
  /// The smart list the card was opened from. Its Play starts through that list's run, so the
  /// next episode is the list's, not the show's. Nil from every other surface.
  let listContext: NavigationModel.SmartListContext?
  /// Offers the transcript for a downloaded episode it can transcribe; nil (a harness) offers none.
  let transcriptCoordinator: EpisodeTranscriptCoordinator?

  typealias Metric = PodcastEpisodeCardViewPresentation.Metric

  init(
    itemID: String,
    episodeID: String,
    coverClient: any ArtworkServing,
    paletteService: CoverPaletteService,
    navigation: NavigationModel,
    playback: PlaybackModel,
    makeModel: @escaping () -> PodcastEpisodeCardModel,
    host: PodcastEpisodeCardHost,
    onSystemGlass: Bool = false,
    listContext: NavigationModel.SmartListContext? = nil,
    transcriptCoordinator: EpisodeTranscriptCoordinator? = nil
  ) {
    self.listContext = listContext
    self.transcriptCoordinator = transcriptCoordinator
    self.itemID = itemID
    self.episodeID = episodeID
    self.coverClient = coverClient
    self.paletteService = paletteService
    self.navigation = navigation
    self.playback = playback
    self.makeModel = makeModel
    self.host = host
    self.onSystemGlass = onSystemGlass
    _homeWashProvider = State(
      initialValue: HomeWashProvider(
        service: paletteService,
        displaySize: Metric.coverSize, displayScale: 1, artworkRole: .libraryThumbnail))
    _adSkipStatusModel = State(
      initialValue: AdSkipCardStatusModel(
        itemID: itemID, episodeID: episodeID, source: .live))
  }

  var model: PodcastEpisodeCardModel {
    deferredModel.resolve(makeModel)
  }

  /// The show's title for the destination sheet, once the card has loaded. Display context only.
  private var loadedShowTitle: String? {
    guard case .loaded(let presentation) = model.state else { return nil }
    return presentation.showTitle
  }

  /// An RSS card already has the device-owned show projection in its episode context. Carry that
  /// projection with the route so `PodcastShowView` never asks the ABS library to resolve `rss:`.
  /// ABS routes stay unseeded.
  static func showRoute(
    itemID: String, presentation: PodcastEpisodeCardPresentation
  ) -> NavigationModel.Route {
    guard PodcastSourceIdentity(itemId: itemID)?.rssFeedId != nil else {
      return .podcastShow(itemID: itemID)
    }
    return .podcastShow(
      itemID: itemID,
      seed: ItemSummary(
        serverItemId: itemID,
        mediaKind: "podcast",
        title: presentation.showTitle,
        author: presentation.showAuthor,
        durationSeconds: nil,
        category: .podcast,
        artworkURL: presentation.artworkURL,
        artworkFeedURL: presentation.artworkFeedURL))
  }

  var body: some View {
    Group {
      switch model.state {
      case .loading:
        LoadingStateView(message: "Loading episode…")
      case .missing:
        // Not-found fallback: the tap degrades to the show push. `openShow()` leaves through the
        // host, which drops this card before it pushes the show.
        Color.clear
          .task { openShow() }
      case .loaded(let presentation):
        // The show's speed (one override per show, inherited by every episode), not whatever
        // happens to be playing.
        content(presentation.adjusted(forPlaybackRate: playback.effectiveRate(for: itemID)))
      }
    }
    .onAppear {
      model.startObserving()
      if case .loaded(let presentation) = model.state { requestWash(presentation) }
    }
    .onChange(of: model.state) { _, newState in
      guard case .loaded(let presentation) = newState else { return }
      requestWash(presentation)
    }
    .onChange(of: navigation.presentedEpisode) { _, newValue in
      guard let newValue else {
        model.stopObserving()
        return
      }
      guard newValue.itemID == itemID, newValue.episodeID == episodeID else {
        model.stopObserving()
        return
      }
      model.startObserving()
    }
    .nativeEpisodeServerSaveSheets(
      removalConfirmation: $serverRemovalConfirmation,
      choicePrompt: Binding(
        get: { model.pendingServerSaveChoice?.prompt },
        set: { if $0 == nil { model.dismissServerSaveFeedback() } }),
      podcastName: loadedShowTitle,
      onRemoveConfirmed: { _ in
        Task { await model.removeEpisodeFromServer() }
      },
      onChoice: { choice in
        Task { await model.chooseSaveDestination(choice) }
      },
      onChoiceCancelled: model.dismissServerSaveFeedback
    )
    .onChange(of: model.serverSavePresentationVersion) { _, _ in
      serverRemovalConfirmation = nil
    }
    .podcastDownloadFailureAlert($downloadFailureAlert) { _, action in
      Task { await model.performAction(action) }
    }
    .onDisappear {
      // Only the confirmation sheet is view-local state. The server-save presentation is not
      // cleared here: a card scrolling out of a lazy stack is not an account or subscription
      // lifecycle event, and clearing would mislabel the trigger and bump the presentation
      // generation, discarding the outcome of a save still in flight. The status is re-read from
      // the durable projection whenever the card loads again.
      serverRemovalConfirmation = nil
      model.stopObserving()
    }
  }

  private func content(_ presentation: PodcastEpisodeCardPresentation) -> some View {
    // Derived once per body pass and handed to both menus. Deriving it inside a menu's content
    // closure would put the rows inside a scope that a position tick re-runs; see
    // `PodcastEpisodeCardActionMenu`.
    let sections = actionSections(presentation)
    return ScrollView {
      VStack(alignment: .leading, spacing: WhirrSpacing.medium) {
        header(presentation, sections: sections)
        playRow(presentation, sections: sections)

        notesSection(presentation.notes, supplementary: presentation.supplementaryNotes)

        if let actionErrorMessage = model.actionErrorMessage {
          Text(actionErrorMessage)
            .font(WhirrTypeToken.caption.font)
            .foregroundStyle(.red)
        }

        if model.serverSaveStatus != .none,
          let serverSaveStatusText = model.serverSaveFeedbackMessage
        {
          Text(serverSaveStatusText)
            .font(WhirrTypeToken.caption.font)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel(
              NativeEpisodeServerSaveCopy.accessibilityLabel(for: model.serverSaveStatus))
        }
      }
      .padding(.top, Metric.topPadding)
      .padding(.horizontal, Metric.horizontalPadding)
      .padding(.bottom, Metric.bottomPadding)
    }
    .queueFeedbackBanner(
      message: model.queueFeedbackMessage, onDismiss: model.dismissQueueFeedback
    )
    .queueFeedbackBanner(
      message: model.savedFeedbackMessage, onDismiss: model.dismissSavedFeedback
    )
    .queueFeedbackBanner(
      message: model.continueListeningFeedbackMessage,
      onDismiss: model.dismissContinueListeningFeedback
    )
    .queueFeedbackBanner(
      message: model.serverSaveBannerMessage, onDismiss: model.dismissServerSaveBanner
    )
    .sensoryFeedback(trigger: model.actionErrorMessage) { _, newMessage in
      newMessage == nil ? nil : ItemActionHaptics.failure
    }
    // The player's transcript sheet, raised over the card in the Play capsule's colours. The card
    // has no chapter list until the episode loads in the player, so its transcript has no headings.
    .playerTranscriptSheet(
      transcript, coordinator: transcriptCoordinator, playback: playback, itemID: itemID,
      episodeID: episodeID,
      accent: .show(playAccent(presentation)),
      chapters: { [] })
  }

  private var secondaryInk: AnyShapeStyle {
    PodcastEpisodeCardViewPresentation.secondaryInk(onSystemGlass: onSystemGlass).style
  }

  /// The sheet is keyed by its show. A seedless route learns the show's RSS source, and an ABS
  /// show its cover revision, only once the episode loads, so nothing is requested before then:
  /// an earlier request would colour the show from an unversioned palette row and then re-key it.
  private func washSubject(_ presentation: PodcastEpisodeCardPresentation) -> EditorialWashSubject {
    EditorialWashSubject(
      itemID: PodcastEpisodeCardViewPresentation.washKey(for: itemID),
      artworkSource: presentation.providerArtworkSource(for: itemID),
      artworkRevision: presentation.artworkRevision)
  }

  private func requestWash(_ presentation: PodcastEpisodeCardPresentation) {
    homeWashProvider.request(
      [washSubject(presentation)], intent: .visible,
      displaySize: Metric.coverSize, displayScale: displayScale, artworkRole: .libraryThumbnail)
  }

  /// Artwork, the tappable show line, title, `date · duration · remaining`, and a thin progress bar
  /// (only when part-played). The remainder rides the metadata line, so the Resume button names
  /// only its tap. Long-press raises the same menu as the ellipsis. The show line leads: as the
  /// last child of a variable-height stack beside a fixed-height cover it would move with the
  /// title's line count.
  private func header(
    _ presentation: PodcastEpisodeCardPresentation,
    sections: [[PodcastEpisodeCardViewPresentation.ActionRow]]
  ) -> some View {
    let finishedBadgeMotion = ItemDetailViewPresentation.finishedBadgeMotion(
      reduceMotion: reduceMotion)
    return HStack(alignment: .top, spacing: WhirrSpacing.small) {
      CoverImageView(
        itemID: itemID, title: presentation.title, displaySize: Metric.artworkDisplaySize,
        client: coverClient, source: presentation.episodeArtworkSource(for: itemID),
        fallbackSource: presentation.providerArtworkSource(for: itemID),
        cornerRadius: Metric.coverCornerRadius, revision: presentation.artworkRevision
      )
      .frame(width: Metric.coverSize, height: Metric.coverSize)
      .accessibilityHidden(true)
      // The finished mark sits on the artwork, as item detail's hero draws it, so marking an
      // episode finished does not push the controls and notes down under the user's thumb.
      // Attached after `.accessibilityHidden(true)` so "Finished" keeps its own VoiceOver element
      // while the artwork stays silent.
      .coverArtworkOverlay(alignment: .bottomTrailing) {
        if presentation.isFinished {
          FinishedCoverBadge(size: Metric.finishedBadgeSize)
            .padding(Metric.finishedBadgeInset)
            .transition(finishedBadgeMotion.transition)
        }
      }
      .animation(finishedBadgeMotion.animation, value: presentation.isFinished)

      VStack(alignment: .leading, spacing: WhirrSpacing.xxSmall) {
        showLineButton(presentation)

        VStack(alignment: .leading, spacing: WhirrSpacing.xxSmall) {
          Text(presentation.title)
            .font(.title3.weight(.bold))
            .fixedSize(horizontal: false, vertical: true)

          PodcastEpisodeCardProgressLines(
            presentation: presentation, playback: playback, itemID: itemID,
            episodeID: episodeID, adSkip: adSkipStatusModel, secondaryInk: secondaryInk,
            watchMark: PodcastShowViewPresentation.watchMark(
              for: watchCopies?.watchCopyState(itemID: itemID, episodeID: episodeID)))
        }
        .accessibilityElement(children: .combine)
      }
    }
    .contentShape(Rectangle())
    .contextMenu {
      PodcastEpisodeCardActionMenuItems(sections: sections, perform: perform)
        .equatable()
    }
  }

  /// Full contrast, not `.secondary`: a chevron alone does not carry affordance at the same weight
  /// as the date sitting two lines below it.
  private func showLineButton(_ presentation: PodcastEpisodeCardPresentation) -> some View {
    Button(action: openShow) {
      HStack(spacing: WhirrSpacing.xxSmall) {
        Text(presentation.showTitle)
          .lineLimit(1)
        Image(systemName: "chevron.right")
          .font(.caption2.weight(.semibold))
      }
      .font(WhirrTypeToken.caption.font.weight(.semibold))
      // Caption type is 18.9 points tall. The sheet's header stacks show name, title and date on
      // tight leading, so this claims its remaining target from the margins rather than the stack.
      .whirrMinimumHitTarget()
    }
    .buttonStyle(.plain)
    .accessibilityLabel(presentation.showTitle)
    .accessibilityHint("Opens the podcast show.")
  }

  /// The rule and label give the notes a visible start, so a paragraph cut off at the `.medium`
  /// detent reads as continuing, not clipped; body weight at full contrast would outrank the
  /// title. Publisher boilerplate is folded under the notes. The rule and heading row are always
  /// laid out: the heading's trailing half is the ad-skip status, which needs a permanent slot.
  private func notesSection(_ notes: String?, supplementary: String?) -> some View {
    VStack(alignment: .leading, spacing: WhirrSpacing.xSmall) {
      Divider()

      PodcastEpisodeCardNotesHeading(showsLabel: notes != nil, secondaryInk: secondaryInk) {
        AdSkipCardStatusLine(model: adSkipStatusModel, secondaryInk: secondaryInk)
      }

      if let notes {
        Text(notes)
          .font(.callout)
          .foregroundStyle(secondaryInk)
          .fixedSize(horizontal: false, vertical: true)
      }

      if notes != nil, let supplementary {
        DisclosureGroup(isExpanded: $isShowingSupplementaryNotes) {
          Text(supplementary)
            .font(.footnote)
            .foregroundStyle(secondaryInk)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, WhirrSpacing.xSmall)
        } label: {
          Text("Links, sponsors & credits")
            .font(.footnote.weight(.semibold))
            .foregroundStyle(secondaryInk)
        }
        .padding(.top, WhirrSpacing.xSmall)
      }
    }
    .frame(maxWidth: Metric.notesReadingMeasure, alignment: .leading)
  }

  /// The Play capsule's fill: the show's wash once it resolves, else nil for the app tint.
  private func playAccent(_ presentation: PodcastEpisodeCardPresentation) -> Color? {
    let wash = homeWashProvider.wash(for: washSubject(presentation))
    return PodcastEpisodeCardViewPresentation.playAccentSource(for: wash) == .wash
      ? wash.accentColor
      : nil
  }

  /// The prominent Play/Resume button, saved control, download control and ellipsis, one height so
  /// the row reads as a cluster; the capsule sizes to its label, not the full width. Saved
  /// membership and the local copy are different facts: the bookmark tracks the shelf only, and
  /// deleting a download never disturbs it. The button morphs in place rather than dismissing the
  /// card, as the mini-player confirming playback is behind the sheet; only verb and glyph change
  /// ("Resume · 12 min left" → "Pause · 12 min left"), with no material swap.
  private func playRow(
    _ presentation: PodcastEpisodeCardPresentation,
    sections: [[PodcastEpisodeCardViewPresentation.ActionRow]]
  ) -> some View {
    let motion = PodcastEpisodeCardViewPresentation.motion(reduceMotion: reduceMotion)
    let accent = playAccent(presentation)
    let control = PodcastEpisodeCardPlayControl.resolve(
      isCurrentEpisode: playback.isLoaded(itemID: itemID, episodeID: episodeID),
      isPlaybackIntended: playback.isPlaybackIntended(for: itemID, episodeID: episodeID))

    return HStack(spacing: WhirrSpacing.small) {
      Button {
        if control.startsNewSession, let listContext, let smartLists {
          Task {
            _ = await smartLists.startFromList(
              listID: listContext.listID, itemID: itemID, episodeID: episodeID)
          }
        } else if control.startsNewSession {
          Task { await model.play() }
        } else {
          playback.togglePlayPause(itemID: itemID, episodeID: episodeID)
        }
      } label: {
        Label {
          Text(control.label(for: presentation))
            .contentTransition(motion.textTransition)
        } icon: {
          playGlyph(control, motion: motion)
        }
        .playCapsuleLabel()
        // Named explicitly: `.borderedProminent` paints its label white whatever the tint is, and
        // `AppChrome.tint` is near-white in dark mode (see `AppChrome.onTint`).
        .foregroundStyle(AppChrome.onTint)
      }
      .buttonStyle(.borderedProminent)
      .buttonBorderShape(.capsule)
      .tint(accent ?? AppChrome.tint)
      .animation(motion.controlAnimation, value: control)
      .accessibilityHint(
        SmartListsPresentation.playHint(
          listName: listContext?.name, startsRun: control.startsNewSession && smartLists != nil)
          ?? "")

      Spacer(minLength: WhirrSpacing.xSmall)

      savedControl()
      downloadControl(presentation)
      PodcastEpisodeCardActionMenu(sections: sections, perform: perform)
        .equatable()
    }
  }

  /// The canonical menu's rows for this episode as the card currently knows it. Membership and
  /// server-save facts are read from the model here rather than inside a menu's content closure so
  /// a mutation cannot leave a stale menu behind.
  private func actionSections(
    _ presentation: PodcastEpisodeCardPresentation
  ) -> [[PodcastEpisodeCardViewPresentation.ActionRow]] {
    let isSaved = model.isSaved
    return PodcastEpisodeCardViewPresentation.actionSections(
      for: presentation,
      queueAvailability: ListeningQueueActionPolicy.availability(
        itemID: itemID, episodeID: episodeID, category: .podcast,
        nowPlaying: playback.nowPlayingIdentity),
      isSaved: isSaved,
      isCurrentlyPlaying: playback.isPlaybackIntended(
        for: itemID, episodeID: episodeID),
      isHidden: model.isHiddenFromContinueListening,
      serverSave: NativeEpisodeServerSaveStatus.saveAvailability(
        capability: model.serverMutationCapability,
        isNativeFeed: model.isNativeFeed,
        isCredentialedFeed: model.isCredentialedNativeFeed,
        status: model.serverSaveStatus),
      serverRemove: NativeEpisodeServerSaveStatus.removeAvailability(
        capability: model.serverMutationCapability,
        isNativeFeed: model.hostsServerSaveRemoval,
        status: model.serverSaveStatus,
        preflightPresence: model.serverSavePreflightPresence),
      offersTranscript: transcript.onShow != nil,
      watchCopy: watchCopies?.watchCopy(itemID: itemID, episodeID: episodeID))
  }

  /// `.openShow` and `.moreFromCreator` are navigation/search concerns this view owns, as in
  /// `PodcastShowView.perform`. Everything else forwards straight to the model.
  private func perform(_ action: AppModel.MediaItemAction) {
    switch action {
    case .openShow:
      openShow()
    case .moreFromCreator:
      guard case .loaded(let presentation) = model.state,
        let creator = presentation.showAuthor,
        creator.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
      else { return }
      host.search(creator)
    case .saveToServer:
      Task { await model.saveEpisodeToServer() }
    case .removeFromServer:
      serverRemovalConfirmation = .init(episodeID: episodeID)
    case .transcript:
      transcript.show()
    case .sendToWatch:
      Task { await watchCopies?.send(itemID: itemID, episodeID: episodeID) }
    case .removeFromWatch:
      Task { await watchCopies?.remove(itemID: itemID, episodeID: episodeID) }
    default:
      Task { await model.performAction(action) }
    }
  }

  /// Leaves for the show through the host, which drops this card first. A loaded RSS card carries
  /// its device-owned show seed; ABS and unresolved-card routes are unseeded.
  private func openShow() {
    let route: NavigationModel.Route
    if case .loaded(let presentation) = model.state {
      route = Self.showRoute(itemID: itemID, presentation: presentation)
    } else {
      route = .podcastShow(itemID: itemID)
    }
    host.openShow(route)
  }
}

/// The card's metadata line and progress bar, which are the only parts of the card
/// that follow the playhead. They resolve the displayed position here, so while this episode plays
/// only these lines redraw, not the card around them.
private struct PodcastEpisodeCardProgressLines: View {
  let presentation: PodcastEpisodeCardPresentation
  let playback: PlaybackModel
  let itemID: String
  let episodeID: String
  let adSkip: AdSkipCardStatusModel
  let secondaryInk: AnyShapeStyle
  /// The show row's Watch mark, leading the metadata line as it does there.
  let watchMark: PodcastEpisodeWatchMark?

  var body: some View {
    let lines = presentation.atPosition(
      playback.listPositionSeconds(
        itemID: itemID, episodeID: episodeID, persisted: presentation.progressSeconds),
      skipping: adSkip.breaks)
    Group {
      (watchMark?.leading(lines.metadataLine) ?? Text(lines.metadataLine))
        .font(WhirrTypeToken.caption.font)
        .foregroundStyle(secondaryInk)
        .accessibilityLabel(
          PodcastEpisodeCardViewPresentation.metadataAccessibilityLabel(
            lines.metadataAccessibilityLabel, watchMark: watchMark))

      // The bar's slot is always laid out, hidden when there is nothing to show (unstarted or
      // finished), so starting or finishing playback never shifts the card's layout.
      let fraction = lines.remainingProgressFraction
      PlaybackProgressBar(fraction: fraction ?? 0)
        .opacity(fraction == nil ? 0 : 1)
        .accessibilityHidden(true)
    }
  }
}
