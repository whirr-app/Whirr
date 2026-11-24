import ABSApi
import AppModel
import DesignSystem
import Persistence
import SwiftUI

/// The universal Up Next queue, raised from the player's Up Next quick action. A mixed ordered list
/// of future items only (Now Playing is never a row), with tap-to-play-now, reorder, swipe remove,
/// a per-row context menu, and an overflow Clear with its transient Undo.
///
/// Presentation is a plain `.sheet` styled by `ListeningQueuePresentation`; a custom overlay or
/// second drag-dismiss would compete with the player's pull-down and `ScrollView`. The expanded
/// player owns `ListeningQueueModel` and hands it in, since its post-Clear restore token must
/// outlive this view's identity.
struct ListeningQueueSheet: View {
  let model: ListeningQueueModel
  let coverClient: any ArtworkServing
  let playback: PlaybackModel
  /// Opening the book/show behind a queued row. Navigation is the caller's to perform; this view
  /// never touches `NavigationModel` itself.
  let onOpen: (ListeningIdentity, ItemMediaCategory) -> Void
  let onDismiss: () -> Void
  /// Supplies display-only row metadata to the expanded player before the asynchronous start
  /// resolves. The seed is keyed to the row identity and is reconciled against live playback by
  /// the shell after this sheet's native dismissal completes.
  var onPlayNowCommitted: (PlayerMetadataSeed) -> Void = { _ in }
  /// `.sheet` brings its own navigation bar and Close. `.inline` is the queue drawn in the expanded
  /// player's upper region, on the ambient canvas, where the Up Next quick action closes it.
  var style: Style = .sheet

  enum Style: Equatable {
    case sheet
    case inline
  }

  /// Scopes the transient Undo to the presentation that cleared: the offer is invalidated on
  /// dismissal, and `ListeningQueueModel.canUndoClear` (which must survive this view's identity)
  /// has no dismissal signal of its own.
  @State private var didClear = false
  /// Bumped once per edit the listener completed here, so the sheet can tap for it. A counter
  /// rather than `model.items`: the queue also changes when playback consumes the head or a sync
  /// lands, and neither is the listener's edit to confirm. Two identical edits in a row are still
  /// two distinct values, so the second one taps.
  @State private var editTick = 0
  @AccessibilityFocusState private var isUndoFocused: Bool
  /// The active smart list run. Optional because the harness mounts the sheet without a shell.
  @Environment(SmartListRunModel.self) private var smartListRun: SmartListRunModel?

  private var content: ListeningQueueSheetPresentation.Content {
    ListeningQueueSheetPresentation.content(
      state: model.state, offersUndo: didClear && model.canUndoClear)
  }

  var body: some View {
    container
      .alert(
        ListeningQueueSheetPresentation.errorAlertTitle,
        isPresented: Binding(
          get: { model.actionErrorMessage != nil },
          set: { if $0 == false { model.dismissActionError() } })
      ) {
        Button("OK", role: .cancel) { model.dismissActionError() }
      } message: {
        Text(model.actionErrorMessage ?? "")
      }
      .sensoryFeedback(ItemActionHaptics.mutation, trigger: editTick)
      .sensoryFeedback(trigger: model.actionErrorMessage) { _, newMessage in
        newMessage == nil ? nil : ItemActionHaptics.failure
      }
  }

  @ViewBuilder private var container: some View {
    switch style {
    case .sheet:
      NavigationStack {
        contentBody
          .navigationTitle(ListeningQueueSheetPresentation.title)
          .navigationBarTitleDisplayMode(.inline)
          .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
              overflowMenu
            }
            ToolbarItem(placement: .topBarLeading) {
              Button(role: .close, action: onDismiss)
            }
          }
      }
    case .inline:
      VStack(spacing: 0) {
        inlineTitleRow
        contentBody
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
  }

  /// The inline queue's stand-in for the navigation bar: its name, and the Clear overflow.
  private var inlineTitleRow: some View {
    HStack(spacing: WhirrSpacing.small) {
      Text(ListeningQueueSheetPresentation.title)
        .font(WhirrTypeToken.headline.font)
        .accessibilityAddTraits(.isHeader)
      Spacer(minLength: 0)
      overflowMenu
    }
    .padding(.horizontal, WhirrSpacing.large)
    .frame(minHeight: WhirrMetric.minimumTouchTarget)
  }

  /// Inline rows sit on the player's ambient canvas rather than on a list's own background.
  private var rowBackground: Color? { style == .inline ? .clear : nil }

  @ViewBuilder private var contentBody: some View {
    let layout = ListeningQueueSheetPresentation.layout(content: content, run: smartListRun?.run)
    if let runSection = layout.runSection, let queueHeader = layout.queueHeader {
      runList(runSection, queueHeader: queueHeader, content: layout.content)
    } else {
      stateBody(layout.content)
    }
  }

  @ViewBuilder private func stateBody(_ content: ListeningQueueSheetPresentation.Content)
    -> some View
  {
    switch content {
    case .loading:
      LoadingStateView(message: ListeningQueueModel.State.loading.copyText)
    case .empty:
      EmptyStateView(
        title: ListeningQueueSheetPresentation.emptyTitle,
        message: ListeningQueueSheetPresentation.emptyMessage,
        systemImage: ListeningQueueSheetPresentation.emptySymbol)
    case .cleared:
      clearedBanner
    case .rows:
      queueList
    }
  }

  /// The sheet stays open after Clear and offers the restore in place. VoiceOver focus moves to
  /// Undo once, when the banner appears, and is never re-asserted, so a playback update behind the
  /// sheet cannot make it interrupt repeatedly.
  private var clearedBanner: some View {
    VStack(spacing: WhirrSpacing.small) {
      Text(ListeningQueueSheetPresentation.clearedTitle)
        .font(WhirrTypeToken.headline.font)
        .foregroundStyle(WhirrMetadataProminence.queueRowLabel.adaptiveStyle)

      Button(ListeningQueueSheetPresentation.undoLabel) {
        Task { await model.undoClear() }
      }
      .buttonStyle(.bordered)
      .frame(minWidth: WhirrMetric.minimumTouchTarget, minHeight: WhirrMetric.minimumTouchTarget)
      .accessibilityHint(ListeningQueueSheetPresentation.undoHint)
      .accessibilityFocused($isUndoFocused)
      .accessibilityIdentifier(PlayerAccessibilityID.queueUndo)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .onAppear { isUndoFocused = true }
  }

  private var queueList: some View {
    let rows = ListeningQueueViewPresentation.rows(model.items)
    return List {
      queueRows(rows)
    }
    .listStyle(.plain)
    .scrollContentBackground(style == .inline ? .hidden : .automatic)
    .contentMargins(.horizontal, style == .inline ? WhirrSpacing.xSmall : 0, for: .scrollContent)
    .accessibilityIdentifier(PlayerAccessibilityID.queueList)
  }

  private func queueRows(_ rows: [ListeningQueueViewPresentation.Row]) -> some View {
    ForEach(rows) { row in
      queueRow(row, total: rows.count)
    }
    .onMove { source, destination in
      move(rows: rows, from: source, to: destination)
    }
    .listRowBackground(rowBackground)
  }

  /// With a run: the run's section first in every state, then the queue under its own header. The
  /// non-row states sit in the queue's section as a single row so the run is never hidden by them.
  private func runList(
    _ run: ListeningQueueSheetPresentation.RunSection, queueHeader: String,
    content: ListeningQueueSheetPresentation.Content
  ) -> some View {
    List {
      Section {
        ForEach(run.rows) { row in
          VStack(alignment: .leading, spacing: WhirrSpacing.xxSmall) {
            Text(row.title).font(WhirrTypeToken.body.font).lineLimit(2)
            Text(row.subtitle).font(WhirrTypeToken.caption.font)
              .foregroundStyle(WhirrMetadataProminence.queueRowSubtitle.adaptiveStyle)
          }
          .accessibilityElement(children: .combine)
        }
        if let emptyMessage = run.emptyMessage {
          Text(emptyMessage).font(WhirrTypeToken.caption.font)
            .foregroundStyle(WhirrMetadataProminence.queueRowLabel.adaptiveStyle)
        }
        Button(run.stopLabel, role: .destructive) {
          Task { await smartListRun?.stop() }
        }
        .accessibilityHint(run.stopHint)
        .accessibilityIdentifier(PlayerAccessibilityID.queueStopSmartList)
      } header: {
        Text(run.header)
      }
      .listRowBackground(rowBackground)
      Section {
        switch content {
        case .loading:
          LoadingStateView(message: ListeningQueueModel.State.loading.copyText)
            .frame(maxWidth: .infinity)
        case .empty:
          EmptyStateView(
            title: ListeningQueueSheetPresentation.emptyTitle,
            message: ListeningQueueSheetPresentation.emptyMessage,
            systemImage: ListeningQueueSheetPresentation.emptySymbol
          )
          .frame(maxWidth: .infinity)
        case .cleared:
          clearedBanner
        case .rows:
          queueRows(ListeningQueueViewPresentation.rows(model.items))
        }
      } header: {
        Text(queueHeader)
      }
      .listRowBackground(rowBackground)
    }
    .listStyle(.plain)
    .scrollContentBackground(style == .inline ? .hidden : .automatic)
    .contentMargins(.horizontal, style == .inline ? WhirrSpacing.xSmall : 0, for: .scrollContent)
    .accessibilityIdentifier(PlayerAccessibilityID.queueList)
  }

  private func queueRow(
    _ row: ListeningQueueViewPresentation.Row, total: Int
  ) -> some View {
    let removeAction = ListeningQueueSheetPresentation.removeContextAction
    let contextActions = ListeningQueueSheetPresentation.rowContextActions(
      for: row.category,
      displacedTitle: ListeningQueueSheetPresentation.displacedTitle(
        row: row.identity, nowPlaying: playback.nowPlayingIdentity,
        displayed: playback.displayedItem))

    return ListeningQueueRowView(
      primaryTitle: row.primaryTitle,
      secondaryTitle: row.secondaryTitle,
      mediaKind: row.mediaKind,
      mediaKindLabel: row.mediaKindLabel,
      isNext: row.isNext,
      nextLabel: ListeningQueueSheetPresentation.nextLabel,
      isTombstone: row.isSelectable == false,
      unavailableLabel: ListeningQueueSheetPresentation.unavailableLabel,
      positionText: ListeningQueueViewPresentation.positionText(
        rank: row.position + 1, total: total),
      moveEarlierLabel: ListeningQueueSheetPresentation.moveEarlierLabel,
      canMoveEarlier: row.canMoveEarlier,
      moveLaterLabel: ListeningQueueSheetPresentation.moveLaterLabel,
      canMoveLater: row.canMoveLater,
      removeLabel: ListeningQueueSheetPresentation.removeLabel,
      contextMenuAccessibilityLabel: ListeningQueueSheetPresentation.rowActionsLabel,
      contextMenuAccessibilityHint: ListeningQueueSheetPresentation.rowActionsHint,
      contextActions: contextActions,
      onSelect: { playNow(row) },
      onMoveEarlier: { move(row, to: row.position - 1) },
      onMoveLater: { move(row, to: row.position + 1) },
      onRemove: { remove(row) },
      onSelectAction: { action in
        if action.id == removeAction.id {
          remove(row)
        } else {
          switch action.id {
          case "play-now": playNow(row)
          case ListeningQueueSheetPresentation.swapActionID: playNow(row, swapping: true)
          default: onOpen(row.identity, row.category)
          }
        }
      },
      cover: {
        // The shared artwork pipeline and its concurrency cap, as every other list row uses it.
        CoverImageView(
          itemID: row.identity.itemID,
          title: row.itemTitle,
          displaySize: PlayerMetric.queueRowCoverSize,
          client: coverClient,
          source: row.providerArtworkSource,
          author: row.itemAuthor,
          role: .libraryThumbnail,
          revision: row.artworkRevision
        )
        .frame(width: PlayerMetric.queueRowCoverSize, height: PlayerMetric.queueRowCoverSize)
      }
    )
    .swipeActions(edge: .trailing) {
      // The removal hint lives here, not on the row: a swipe action is a real `Button` and can
      // carry one, whereas the row's Move Earlier/Move Later custom actions cannot.
      Button(role: removeAction.role == .destructive ? .destructive : nil) {
        remove(row)
      } label: {
        Label(
          removeAction.label,
          systemImage: removeAction.systemImage)
      }
      // Tinted explicitly (as `podcastEpisodeSwipeButtons` does). The expanded player hands its
      // content `.tint(Color.primary)` for the neutral transport controls, so an untinted swipe
      // button inherits that instead of destructive red. `Color.primary` against the ambient dark
      // presentation is the black-on-dark failure `CoverAmbientPalette` documents, and left the
      // trash glyph unreadable on its own fill.
      .tint(.red)
      .accessibilityHint(removeAction.hint)
    }
    .accessibilityIdentifier(PlayerAccessibilityID.queueRow(identity: row.identity, rowID: row.id))
  }

  /// No confirmation. Clearing never touches Now Playing: nothing here stops or reloads the
  /// session, and the store only removes future rows.
  @ViewBuilder private var overflowMenu: some View {
    if ListeningQueueSheetPresentation.showsClearAction(state: model.state) {
      Menu {
        Button(role: .destructive) {
          edit {
            await model.clear()
            didClear = true
          }
        } label: {
          Label(ListeningQueueSheetPresentation.clearLabel, systemImage: "trash")
        }
        .accessibilityHint(ListeningQueueSheetPresentation.clearHint)
        .accessibilityIdentifier(PlayerAccessibilityID.queueClear)
      } label: {
        Image(systemName: "ellipsis")
          .frame(
            minWidth: WhirrMetric.minimumTouchTarget, minHeight: WhirrMetric.minimumTouchTarget)
      }
      .accessibilityLabel(ListeningQueueSheetPresentation.overflowLabel)
      .accessibilityHint(ListeningQueueSheetPresentation.overflowHint)
    }
  }

  /// Starts through `PlaybackModel`, which consumes the queue row itself on a successful start
  /// (`acknowledgeStarted`). This view never removes the row it just played, so a failed start
  /// leaves it where it was. The start names the row, since a book may hold several chapter rows.
  /// `swapping` also returns what was playing to the front of Up Next once the start succeeds.
  private func playNow(_ row: ListeningQueueViewPresentation.Row, swapping: Bool = false) {
    guard row.isSelectable, let item = model.items.first(where: { $0.id == row.id }) else { return }
    onPlayNowCommitted(ListeningQueueSheetPresentation.playerSeed(for: row))
    Task {
      if swapping {
        await playback.swap(toQueueItem: item)
      } else {
        await playback.start(queueItem: item)
      }
      let outcome = ListeningQueueSheetPresentation.playNowOutcome(
        requested: row.identity,
        nowPlaying: playback.nowPlayingIdentity,
        startFailureMessage: playback.startFailureMessage)
      if outcome == .dismiss {
        onDismiss()
      }
    }
  }

  private func remove(_ row: ListeningQueueViewPresentation.Row) {
    edit { await model.remove(rowID: row.id) }
  }

  private func move(_ row: ListeningQueueViewPresentation.Row, to position: Int) {
    edit { await model.move(rowID: row.id, to: position) }
  }

  /// Runs one queue edit and confirms it with a tap. `ListeningQueueModel` reports a failed edit by
  /// raising `actionErrorMessage` rather than throwing, so that, not the absence of an error from
  /// the call, says whether the edit landed. A failure gets the alert's own `.error` instead and
  /// must not also tap as though it had worked.
  private func edit(_ mutate: @escaping () async -> Void) {
    Task {
      await mutate()
      guard model.actionErrorMessage == nil else { return }
      editTick += 1
    }
  }

  private func move(
    rows: [ListeningQueueViewPresentation.Row], from source: IndexSet, to destination: Int
  ) {
    guard let first = source.first, let row = rows.indices.contains(first) ? rows[first] : nil,
      let resolved = ListeningQueueSheetPresentation.moveDestination(
        from: first, to: destination)
    else { return }
    move(row, to: resolved)
  }
}
