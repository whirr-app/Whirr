import SwiftUI
import Testing

@testable import DesignSystem

/// The stateless mixed-queue row: a primary title, a secondary creator-or-show line and a media
/// category. As with `PodcastComponentTests`, these assert the values the view derives rather
/// than snapshotting the `View` struct, which never evaluates `body`.
@Suite("Listening queue row")
@MainActor
struct ListeningQueueRowViewTests {
  @Test func audiobookRowCombinesTitleAuthorAndMediaGlyph() {
    let row = makeRow(
      primaryTitle: "The Fellowship", secondaryTitle: "J.R.R. Tolkien",
      mediaKind: .audiobook, mediaKindLabel: "Audiobook")

    #expect(row.accessibilityLabel == "The Fellowship")
    #expect(row.accessibilityValue == "J.R.R. Tolkien. Audiobook. Position 2 of 4")
    #expect(row.mediaKind == .audiobook)
  }

  @Test func episodeRowCombinesTitleShowAndMediaGlyph() {
    let row = makeRow(
      primaryTitle: "The Mystery of the Missing Hit", secondaryTitle: "Decoder Ring",
      mediaKind: .podcast, mediaKindLabel: "Podcast episode")

    #expect(row.accessibilityLabel == "The Mystery of the Missing Hit")
    #expect(row.accessibilityValue == "Decoder Ring. Podcast episode. Position 2 of 4")
    #expect(row.mediaKind == .podcast)
  }

  /// The first row gets a quiet distinction on the row itself. This stateless view has no section
  /// or heading concept, so this flag is the only way to express "next".
  @Test func nextRowCarriesAQuietDistinctionNotASeparateSection() {
    let row = makeRow(isNext: true, nextLabel: "Next")
    #expect(row.isNext)
    #expect(row.accessibilityValue.contains("Next"))
  }

  @Test func nonNextRowOmitsTheNextDistinction() {
    let row = makeRow(isNext: false, nextLabel: "Next")
    #expect(row.isNext == false)
    #expect(row.accessibilityValue.contains("Next") == false)
  }

  @Test func tombstoneRowIsUnselectableAndReadsNoLongerAvailable() {
    let row = makeRow(isTombstone: true, unavailableLabel: "No longer available")

    #expect(row.isSelectable == false)
    #expect(row.isButton == false)
    #expect(row.accessibilityValue.contains("No longer available"))
  }

  @Test func liveRowOmitsTheUnavailableCopy() {
    let row = makeRow(isTombstone: false, unavailableLabel: "No longer available")
    #expect(row.isSelectable)
    #expect(row.accessibilityValue.contains("No longer available") == false)
  }

  @Test func tombstoneRowRemainsReorderableAndRemovable() {
    var movedEarlier = 0
    var movedLater = 0
    var removed = 0
    let row = makeRow(
      isTombstone: true,
      onMoveEarlier: { movedEarlier += 1 }, onMoveLater: { movedLater += 1 },
      onRemove: { removed += 1 })

    row.onMoveEarlier()
    row.onMoveLater()
    row.onRemove()

    #expect(movedEarlier == 1)
    #expect(movedLater == 1)
    #expect(removed == 1)
  }

  @Test func rowForwardsSelectMoveAndRemoveIndependently() {
    var selected = 0
    var movedEarlier = 0
    var movedLater = 0
    var removed = 0
    let row = makeRow(
      onSelect: { selected += 1 },
      onMoveEarlier: { movedEarlier += 1 }, onMoveLater: { movedLater += 1 },
      onRemove: { removed += 1 })

    row.onSelect()
    row.onMoveEarlier()
    row.onMoveLater()
    row.onRemove()

    #expect(selected == 1)
    #expect(movedEarlier == 1)
    #expect(movedLater == 1)
    #expect(removed == 1)
  }

  @Test func moveAffordanceRespectsQueueEdgesFromTheCaller() {
    let first = makeRow(canMoveEarlier: false, canMoveLater: true)
    let last = makeRow(canMoveEarlier: true, canMoveLater: false)

    #expect(first.canMoveEarlier == false)
    #expect(first.canMoveLater)
    #expect(last.canMoveEarlier)
    #expect(last.canMoveLater == false)
  }

  /// The move labels reach VoiceOver through `accessibilityAction(named:)`, which takes a label
  /// and no hint, so they are the entire spoken description of those actions and have to make
  /// sense alone. The row holds no hint strings for them, since an unattached hint reads as
  /// accessible without being so.
  @Test func moveAndRemoveCopyIsCallerOwned() {
    let row = makeRow(
      moveEarlierLabel: "Move earlier",
      moveLaterLabel: "Move later",
      removeLabel: "Remove")

    #expect(row.moveEarlierLabel == "Move earlier")
    #expect(row.moveLaterLabel == "Move later")
    #expect(row.removeLabel == "Remove")
  }

  @Test func contextMenuOffersPlayNowAndOpenBookForAnAudiobook() {
    let row = makeRow(
      mediaKind: .audiobook,
      contextActions: [
        MediaContextAction(
          id: "play-now", label: "Play Now", hint: "Starts playing this item now",
          systemImage: "play.fill"),
        MediaContextAction(
          id: "open-item", label: "Open Book", hint: "Opens this book",
          systemImage: "book"),
      ])

    #expect(row.contextActions.map(\.id) == ["play-now", "open-item"])
    #expect(row.contextActions.map(\.label) == ["Play Now", "Open Book"])
    #expect(row.presentsActionsOnLongPress)
  }

  @Test func contextMenuOffersPlayNowAndOpenShowForAnEpisode() {
    let row = makeRow(
      mediaKind: .podcast,
      contextActions: [
        MediaContextAction(
          id: "play-now", label: "Play Now", hint: "Starts playing this item now",
          systemImage: "play.fill"),
        MediaContextAction(
          id: "open-item", label: "Open Show", hint: "Opens this episode's show",
          systemImage: "antenna.radiowaves.left.and.right"),
      ])

    #expect(row.contextActions.map(\.id) == ["play-now", "open-item"])
    #expect(row.contextActions.map(\.label) == ["Play Now", "Open Show"])
  }

  /// WCAG 2.5.7 (Dragging Movements). The queue reorders by dragging the handle, so Move Earlier
  /// and Move Later must be reachable without a drag. `accessibilityAction(named:)` only serves
  /// VoiceOver's rotor, leaving switch and head-pointer users without a route. They go in the
  /// menu, as both its entry points (ellipsis button, row long press) build from this one list.
  @Test func theMenuCarriesTheMovesSoReorderingNeedsNoDrag() {
    let row = makeRow(
      moveEarlierLabel: "Move Earlier", canMoveEarlier: true,
      moveLaterLabel: "Move Later", canMoveLater: true,
      contextActions: [
        MediaContextAction(
          id: "play-now", label: "Play Now", hint: "Starts playing this item now",
          systemImage: "play.fill")
      ])

    #expect(row.menuEntries.map(\.id) == ["move-earlier", "move-later", "play-now"])
    #expect(row.menuEntries.map(\.label) == ["Move Earlier", "Move Later", "Play Now"])
    #expect(row.menuEntries.map(\.isEnabled) == [true, true, true])
  }

  /// Listed and greyed rather than dropped, which is the opposite of what the custom actions do.
  /// A rotor that offers an action doing nothing is worse than one that never mentions it; a menu
  /// whose length changes as a row moves is worse than one greyed entry.
  @Test func anEdgeRowStillListsTheMoveItCannotMake() {
    let first = makeRow(canMoveEarlier: false, canMoveLater: true, contextActions: [])
    let last = makeRow(canMoveEarlier: true, canMoveLater: false, contextActions: [])

    #expect(first.menuEntries.map(\.id) == ["move-earlier", "move-later"])
    #expect(first.menuEntries.map(\.isEnabled) == [false, true])
    #expect(last.menuEntries.map(\.isEnabled) == [true, false])
  }

  @Test func choosingAMoveFromTheMenuRunsTheSameClosureTheRotorDoes() {
    var movedEarlier = 0
    var movedLater = 0
    var selectedIDs: [String] = []
    let row = makeRow(
      canMoveEarlier: true, canMoveLater: true, contextActions: [],
      onMoveEarlier: { movedEarlier += 1 }, onMoveLater: { movedLater += 1 },
      onSelectAction: { selectedIDs.append($0.id) })

    // One at a time, so a swapped pair cannot pass by both closures having run once.
    row.perform(row.menuEntries[0])
    #expect((movedEarlier, movedLater) == (1, 0))
    row.perform(row.menuEntries[1])
    #expect((movedEarlier, movedLater) == (1, 1))
    #expect(selectedIDs.isEmpty)
  }

  @Test func contextMenuAccessibilityCopyIsCallerOwned() {
    let row = makeRow(
      contextMenuAccessibilityLabel: "Item actions",
      contextMenuAccessibilityHint: "Shows actions for this item")

    #expect(row.contextMenuAccessibilityLabel == "Item actions")
    #expect(row.contextMenuAccessibilityHint == "Shows actions for this item")
  }

  @Test func selectingAContextActionForwardsIt() {
    var selectedIDs: [String] = []
    let action = MediaContextAction(
      id: "open-item", label: "Open Book", hint: "Opens this book", systemImage: "book")
    let row = makeRow(
      contextActions: [action],
      onSelectAction: { selectedIDs.append($0.id) })

    row.onSelectAction(action)
    #expect(selectedIDs == ["open-item"])
  }

  @Test func rowMaintainsMinimumTouchTargetsAtAccessibilitySizes() {
    let row = makeRow()
    #expect(row.selectionMinimumHeight == 44)
    #expect(MediaRowLayoutValues.resolve(isAccessibilitySize: true).minimumActionDimension == 44)
  }

  /// Text wraps unbounded at accessibility sizes. At standard sizes it is capped, because
  /// three-line titles in a column already narrowed by the cover, the ellipsis and the reorder
  /// handle made the sheet messy. The cap lives in a queue-scoped resolver, so
  /// `PodcastEpisodeRowView`'s own unbounded essential text is untouched.
  @Test func rowTitleCapsAtTwoLinesAtStandardSizes() {
    #expect(makeRow().titleLineLimit == 2)
    #expect(ListeningQueueRowLayoutValues.resolve(isAccessibilitySize: false).titleLineLimit == 2)
  }

  @Test func rowSecondaryLineStaysOnOneLineAtStandardSizes() {
    #expect(makeRow().secondaryLineLimit == 1)
    #expect(
      ListeningQueueRowLayoutValues.resolve(isAccessibilitySize: false).secondaryLineLimit == 1)
  }

  @Test func rowTextWrapsFreelyAtAccessibilitySizes() {
    let values = ListeningQueueRowLayoutValues.resolve(isAccessibilitySize: true)
    #expect(values.titleLineLimit == nil)
    #expect(values.secondaryLineLimit == nil)
  }

  /// The glyph rides the secondary line, so both text lines share one leading edge (inside the
  /// title's `HStack` it would centre against the wrapped title and push that edge right). `body`
  /// is never evaluated by this suite, so this guards the decision rather than the pixels.
  @Test func mediaGlyphSitsWithTheSecondaryLineNotTheTitle() {
    #expect(makeRow().glyphPlacement == .secondaryLine)
  }

  @Test func rowSurfaceIsOrdinaryContentNeverGlass() {
    #expect(ListeningQueueRowView<Color>.surface == .ordinaryContent)
  }

  @Test func artworkCentresThroughTheSharedRowMetric() {
    #expect(ListeningQueueRowView<Color>.coverAlignment == .center)
    #expect(
      ListeningQueueRowView<Color>.coverAlignment
        == ArtworkLedRowMetrics.artworkAlignment)
  }

  private func makeRow(
    primaryTitle: String = "The Fellowship",
    secondaryTitle: String = "J.R.R. Tolkien",
    mediaKind: MediaKindBadge = .audiobook,
    mediaKindLabel: String = "Audiobook",
    isNext: Bool = false,
    nextLabel: String = "Next",
    isTombstone: Bool = false,
    unavailableLabel: String = "No longer available",
    positionText: String = "Position 2 of 4",
    moveEarlierLabel: String = "Move earlier",
    canMoveEarlier: Bool = true,
    moveLaterLabel: String = "Move later",
    canMoveLater: Bool = true,
    removeLabel: String = "Remove",
    contextMenuAccessibilityLabel: String = "Item actions",
    contextMenuAccessibilityHint: String = "Shows actions for this item",
    contextActions: [MediaContextAction] = [],
    onSelect: @escaping () -> Void = {},
    onMoveEarlier: @escaping () -> Void = {},
    onMoveLater: @escaping () -> Void = {},
    onRemove: @escaping () -> Void = {},
    onSelectAction: @escaping (MediaContextAction) -> Void = { _ in }
  ) -> ListeningQueueRowView<Color> {
    ListeningQueueRowView(
      primaryTitle: primaryTitle,
      secondaryTitle: secondaryTitle,
      mediaKind: mediaKind,
      mediaKindLabel: mediaKindLabel,
      isNext: isNext,
      nextLabel: nextLabel,
      isTombstone: isTombstone,
      unavailableLabel: unavailableLabel,
      positionText: positionText,
      moveEarlierLabel: moveEarlierLabel,
      canMoveEarlier: canMoveEarlier,
      moveLaterLabel: moveLaterLabel,
      canMoveLater: canMoveLater,
      removeLabel: removeLabel,
      contextMenuAccessibilityLabel: contextMenuAccessibilityLabel,
      contextMenuAccessibilityHint: contextMenuAccessibilityHint,
      contextActions: contextActions,
      onSelect: onSelect,
      onMoveEarlier: onMoveEarlier,
      onMoveLater: onMoveLater,
      onRemove: onRemove,
      onSelectAction: onSelectAction,
      cover: { Color.clear })
  }
}
