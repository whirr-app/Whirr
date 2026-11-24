import ABSApi
import AppModel
import DesignSystem
import Persistence
import SwiftUI

/// Pure copy for one collection or playlist's screen.
nonisolated enum LibraryCollectionPresentation {
  static let unavailableTitle = "No Longer Available"
  static let emptyTitle = "Nothing on This Device"
  static let playLabel = "Play"
  static let addToUpNextLabel = MediaActionCopy.addToUpNext.title
  static let descriptionLineLimit = 3

  static func unavailableMessage(for kind: LibraryCollectionListKind) -> String {
    switch kind {
    case .collection: "This collection is no longer available."
    case .playlist: "This playlist is no longer available."
    }
  }

  static func emptyMessage(for kind: LibraryCollectionListKind) -> String {
    switch kind {
    case .collection: "None of this collection's titles are in your library on this device."
    case .playlist: "None of this playlist's items are in your library on this device."
    }
  }

  static func navigationTitle(listing: LibraryCollectionListing?, kind: LibraryCollectionListKind)
    -> String
  {
    listing.map(LibraryCollectionsPresentation.displayName(for:))
      ?? LibraryCollectionsPresentation.kindLabel(for: kind)
  }

  /// The header already names the list, so the bar repeats it only once that name is off screen.
  static func showsBarTitle(hasHeader: Bool, isHeaderTitleVisible: Bool) -> Bool {
    hasHeader == false || isHeaderTitleVisible == false
  }

  /// The overlay over the entries. `loaded` has none.
  static func placeholder(
    for state: LibraryCollectionModel.State, kind: LibraryCollectionListKind
  ) -> LibraryBrowsePresentation.Placeholder? {
    switch state {
    case .loading: .loading(message: "Loading…")
    case .empty:
      .empty(
        title: emptyTitle,
        message: emptyMessage(for: kind),
        systemImage: LibraryCollectionsPresentation.symbol(for: kind))
    case .unavailable:
      .empty(
        title: unavailableTitle, message: unavailableMessage(for: kind),
        systemImage: "exclamationmark.triangle")
    case .loaded: nil
    }
  }

  static func subtitle(for entry: LibraryCollectionEntry) -> String? {
    switch entry {
    case .title(let summary, _): LibraryBrowsePresentation.subtitle(for: summary)
    case .episode(let episode): episode.showTitle
    }
  }

  static func title(for entry: LibraryCollectionEntry) -> String {
    switch entry {
    case .title(let summary, _): summary.title
    case .episode(let episode): episode.title
    }
  }

  /// "Episode, Title, Show, Finished". The kind comes first for an episode, since a playlist of
  /// episodes otherwise reads as a list of show names.
  static func accessibilityLabel(for entry: LibraryCollectionEntry) -> String {
    var parts: [String] = []
    if case .episode = entry { parts.append("Episode") }
    parts.append(title(for: entry))
    if let subtitle = subtitle(for: entry), subtitle.isEmpty == false { parts.append(subtitle) }
    if entry.isFinished { parts.append(ItemFinishedCopy.badgeLabel) }
    return parts.joined(separator: ", ")
  }

  /// "Playlist of 2 episodes".
  static func summary(
    kind: LibraryCollectionListKind, heldCount: Int, categories: Set<ItemMediaCategory>
  ) -> String {
    "\(LibraryCollectionsPresentation.kindLabel(for: kind)) of "
      + LibraryCollectionsPresentation.countText(heldCount: heldCount, categories: categories)
  }

  static func playAccessibilityHint(playableCount: Int) -> String {
    switch playableCount {
    case 0: "Everything here is finished. Plays the first item again from the start."
    case 1: "Plays the first unfinished item."
    default: "Plays the first unfinished item and puts the rest at the front of Up Next."
    }
  }
}

/// One collection or playlist: a header with its name, description, count and the two list-level
/// actions, then its entries in the server's order. A row opens its title or episode; Select
/// starts a selection (`LibraryCollectionView+Selection.swift`).
struct LibraryCollectionView: View {
  @State private var deferredModel = DeferredModel<LibraryCollectionModel>()
  @State private var deferredPinModel = DeferredModel<PinnedListDownloadModel>()
  @State private var isAddingToUpNext = false
  @State private var isDescriptionExpanded = false
  @State private var isHeaderTitleVisible = true
  @State var editMode: EditMode = .inactive
  @State var selection = BatchSelectionController<String, LibraryCollectionSelectionAction>()

  let kind: LibraryCollectionListKind
  let makeModel: () -> LibraryCollectionModel
  let makePinModel: () -> PinnedListDownloadModel
  let coverClient: any ArtworkServing
  let actions: ItemActionsModel
  let playback: PlaybackModel
  let onSelectItem: (ItemSummary) -> Void
  let onSelectEpisode: (String, String) -> Void

  var model: LibraryCollectionModel { deferredModel.resolve(makeModel) }
  var pinModel: PinnedListDownloadModel { deferredPinModel.resolve(makePinModel) }

  var body: some View {
    let model = model
    let hasHeader = model.listing != nil && model.state != .unavailable
    let navigationTitle = LibraryCollectionPresentation.navigationTitle(listing: model.listing, kind: kind)
    let isSelecting = editMode.isEditing
    let barTitle = isSelecting ? selectionTitle : navigationTitle
    let list = List(selection: isSelecting ? $selection.selected : nil) {
      if let listing = model.listing, model.state != .unavailable {
        header(listing, model: model)
          .plainListRow(top: WhirrSpacing.medium, bottom: WhirrSpacing.small)
      }
      if model.state == .loaded {
        ForEach(model.entries, id: \.id) { entry in
          entryRow(entry, isSelecting: isSelecting)
            .editorialListRow()
            .tag(entry.id)
        }
        LibraryCollectionsEditingNote()
          .selectionDisabled()
      }
    }
    .listStyle(.plain)
    .scrollContentBackground(.hidden)
    .background(WhirrColorToken.editorialBackground.color.ignoresSafeArea())
    .selectionMarkTint(isSelecting: isSelecting)
    .disabled(selection.isPerforming)
    .selectionChrome(
      isSelecting: isSelecting, selectionTitle: selectionTitle, title: navigationTitle,
      titleDisplayMode: .inline
    )
    .toolbar {
      // Always present, only its opacity changes, so the bar never re-lays-out as the header
      // crosses it.
      ToolbarItem(placement: .principal) {
        Text(barTitle)
          .font(.headline)
          .lineLimit(1)
          .opacity(
            isSelecting
              || LibraryCollectionPresentation.showsBarTitle(
                hasHeader: hasHeader, isHeaderTitleVisible: isHeaderTitleVisible)
              ? 1 : 0
          )
          .animation(.easeInOut(duration: 0.2), value: isHeaderTitleVisible)
          .accessibilityHidden(!isSelecting && hasHeader && isHeaderTitleVisible)
      }
    }
    .overlay {
      if let placeholder = LibraryCollectionPresentation.placeholder(for: model.state, kind: kind) {
        switch placeholder {
        case .loading(let message):
          LoadingStateView(message: message)
            .allowsHitTesting(false)
        case .empty(let title, let message, let systemImage):
          EmptyStateView(title: title, message: message, systemImage: systemImage)
            .allowsHitTesting(false)
        case .error:
          EmptyView()
        }
      }
    }
    .itemActionErrorAlert(actions, isSuppressed: isAddingToUpNext || selection.isPerforming)
    pinnedDownloadHost(selectionHost(list))
  }

  private func header(_ listing: LibraryCollectionListing, model: LibraryCollectionModel)
    -> some View
  {
    VStack(alignment: .leading, spacing: WhirrSpacing.small) {
      Text(LibraryCollectionsPresentation.displayName(for: listing))
        .font(WhirrTypeToken.title.font)
        .accessibilityAddTraits(.isHeader)
        .onScrollVisibilityChange(threshold: 0.2) { isHeaderTitleVisible = $0 }
      Text(
        LibraryCollectionPresentation.summary(
          kind: kind, heldCount: listing.heldMemberCount, categories: listing.heldCategories)
      )
      .font(WhirrTypeToken.caption.font)
      .foregroundStyle(WhirrColorToken.textSecondary.color)
      if let description = listing.description, description.isEmpty == false {
        Text(description)
          .font(WhirrTypeToken.body.font)
          .lineLimit(isDescriptionExpanded ? nil : LibraryCollectionPresentation.descriptionLineLimit)
          .onTapGesture { isDescriptionExpanded.toggle() }
          .accessibilityAddTraits(.isButton)
          .accessibilityHint(isDescriptionExpanded ? "Collapses the description." : "Shows the full description.")
      }
      ViewThatFits(in: .horizontal) {
        HStack(spacing: WhirrSpacing.small) { actionButtons(model: model) }
        VStack(alignment: .leading, spacing: WhirrSpacing.small) { actionButtons(model: model) }
      }
      .padding(.top, WhirrSpacing.xSmall)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    // `plainListRow` zeroes the row's side insets; this matches the entries' default inset.
    .padding(.horizontal, WhirrSpacing.medium)
  }

  @ViewBuilder
  private func actionButtons(model: LibraryCollectionModel) -> some View {
    let targets = model.playableEntries
    Button {
      Task { await model.play() }
    } label: {
      Label(LibraryCollectionPresentation.playLabel, systemImage: "play.fill")
        .playCapsuleLabel()
        // `.borderedProminent` paints its label white whatever the tint is, and `AppChrome.tint`
        // is near-white in dark mode (see `AppChrome.onTint`).
        .foregroundStyle(AppChrome.onTint)
    }
    .buttonStyle(.borderedProminent)
    .buttonBorderShape(.capsule)
    .disabled(model.canPlay == false || model.isStartingPlay || editMode.isEditing)
    .accessibilityHint(LibraryCollectionPresentation.playAccessibilityHint(playableCount: targets.count))
    .accessibilityIdentifier(LibraryAccessibilityID.collectionPlayButton)

    Button {
      addToUpNext(model.upNextTargets)
    } label: {
      Label(LibraryCollectionPresentation.addToUpNextLabel, systemImage: "text.line.last.and.arrowtriangle.forward")
        .playCapsuleLabel()
    }
    .buttonStyle(.bordered)
    .buttonBorderShape(.capsule)
    .disabled(targets.isEmpty || isAddingToUpNext || editMode.isEditing)
    .accessibilityIdentifier(LibraryAccessibilityID.collectionAddToUpNextButton)
  }

  /// One batch, so one banner, with the queue intent's RSS handling. Saved for Later's selection
  /// takes the same path.
  private func addToUpNext(_ targets: [ItemBatchTarget]) {
    guard isAddingToUpNext == false, targets.isEmpty == false else { return }
    actions.dismissActionError()
    isAddingToUpNext = true
    Task {
      _ = await actions.performBatch(.addToUpNext, on: targets, playback: playback)
      isAddingToUpNext = false
    }
  }

  @ViewBuilder
  private func entryRow(_ entry: LibraryCollectionEntry, isSelecting: Bool) -> some View {
    let row = ItemListRow(
      title: LibraryCollectionPresentation.title(for: entry),
      author: LibraryCollectionPresentation.subtitle(for: entry)
    ) {
      cover(entry)
    } progress: {
      if entry.isFinished {
        LibraryPlaybackStatusBadge(itemID: entry.itemID, status: .finished)
      }
    }
    Group {
      // While selecting, the list cell owns the tap; a button over the row would swallow it.
      if isSelecting {
        row.contentShape(Rectangle())
      } else {
        Button {
          switch entry {
          case .title(let summary, _): onSelectItem(summary)
          case .episode(let episode): onSelectEpisode(episode.itemID, episode.episodeID)
          }
        } label: {
          row
        }
      }
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(LibraryCollectionPresentation.accessibilityLabel(for: entry))
    .accessibilityAddTraits(isSelecting ? [] : .isButton)
  }

  @ViewBuilder
  private func cover(_ entry: LibraryCollectionEntry) -> some View {
    switch entry {
    case .title(let summary, _):
      CoverImageView(
        itemID: summary.serverItemId, title: summary.title,
        displaySize: WhirrMetric.minimumTouchTarget, client: coverClient, source: nil,
        author: summary.author, revision: summary.artworkRevision)
    case .episode(let episode):
      CoverImageView(
        itemID: episode.itemID, title: episode.showTitle,
        displaySize: WhirrMetric.minimumTouchTarget, client: coverClient,
        source: episode.providerArtworkSource, author: episode.showAuthor,
        revision: episode.artworkRevision)
    }
  }
}
