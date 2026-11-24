import SwiftUI

/// Where an Up Next row hangs its media-type glyph. On the title line an `HStack` centres it, so a
/// wrapped title floats the glyph mid-row and pushes the title's leading edge a glyph's width right
/// of the secondary line's. Prefixing the secondary line keeps title and eyebrow flush with the
/// text column and reads as a badge on the show/creator name.
public enum ListeningQueueGlyphPlacement: Sendable, Equatable {
  case titleLine
  case secondaryLine
}

/// The Up Next row's own line-limit branch, separate from `MediaRowLayoutValues`: podcast episode
/// rows keep unbounded essential text, but the queue row's text column is narrowed by a cover, an
/// ellipsis and a reorder handle at once, so it caps at standard sizes. Accessibility sizes keep
/// the unbounded wrap in both places.
public struct ListeningQueueRowLayoutValues: Sendable, Equatable {
  public let titleLineLimit: Int?
  public let secondaryLineLimit: Int?

  public static func resolve(isAccessibilitySize: Bool) -> ListeningQueueRowLayoutValues {
    ListeningQueueRowLayoutValues(
      titleLineLimit: isAccessibilitySize ? nil : 2,
      secondaryLineLimit: isAccessibilitySize ? nil : 1)
  }
}

/// One Up Next row for the universal listening queue: a primary title / secondary creator-or-show
/// pair plus a media category, so an audiobook and a podcast episode render as one sequence.
/// Stateless: the caller supplies every string and owns queue mutation and cover fetching. This
/// view only renders and forwards.
///
/// Reordering is a visible drag handle plus `Move Earlier`/`Move Later` accessibility actions, so
/// VoiceOver never has to drag. Those actions take a label only (`accessibilityAction(named:)` has
/// no hint parameter), so the labels say what the action does and this view holds no hint strings.
///
/// Removal is swipe-only: the row exposes `onRemove`/`removeLabel` and the hosting list wires
/// `.swipeActions`, so the removal hint belongs on that button.
/// `Cover` is a generic `@ViewBuilder` slot; the app layer injects `CoverImageView`, reusing the
/// artwork pipeline and its concurrency cap.
public struct ListeningQueueRowView<Cover: View>: View {
  public let primaryTitle: String
  public let secondaryTitle: String
  public let mediaKind: MediaKindBadge
  public let mediaKindLabel: String
  /// The first live row gets a quiet distinction on the row itself, never a separate section or
  /// heading. This flag is the only thing that expresses "next".
  public let isNext: Bool
  public let nextLabel: String
  public let isTombstone: Bool
  public let unavailableLabel: String
  /// Caller-composed ordinal ("Position 2 of 4"). The accessibility value combines title,
  /// creator/show, media type, unavailable state and position.
  public let positionText: String
  public let moveEarlierLabel: String
  public let canMoveEarlier: Bool
  public let moveLaterLabel: String
  public let canMoveLater: Bool
  public let removeLabel: String
  public let contextMenuAccessibilityLabel: String
  public let contextMenuAccessibilityHint: String
  public let contextActions: [MediaContextAction]
  /// Tapping the content area means Play Now. Not wired to a tap target when tombstoned (see
  /// `isSelectable`).
  public let onSelect: () -> Void
  public let onMoveEarlier: () -> Void
  public let onMoveLater: () -> Void
  public let onRemove: () -> Void
  public let onSelectAction: (MediaContextAction) -> Void
  public let cover: Cover

  @Environment(\.dynamicTypeSize) private var dynamicTypeSize

  public init(
    primaryTitle: String,
    secondaryTitle: String,
    mediaKind: MediaKindBadge,
    mediaKindLabel: String,
    isNext: Bool,
    nextLabel: String,
    isTombstone: Bool,
    unavailableLabel: String,
    positionText: String,
    moveEarlierLabel: String,
    canMoveEarlier: Bool,
    moveLaterLabel: String,
    canMoveLater: Bool,
    removeLabel: String,
    contextMenuAccessibilityLabel: String,
    contextMenuAccessibilityHint: String,
    contextActions: [MediaContextAction],
    onSelect: @escaping () -> Void,
    onMoveEarlier: @escaping () -> Void,
    onMoveLater: @escaping () -> Void,
    onRemove: @escaping () -> Void,
    onSelectAction: @escaping (MediaContextAction) -> Void,
    @ViewBuilder cover: () -> Cover
  ) {
    self.primaryTitle = primaryTitle
    self.secondaryTitle = secondaryTitle
    self.mediaKind = mediaKind
    self.mediaKindLabel = mediaKindLabel
    self.isNext = isNext
    self.nextLabel = nextLabel
    self.isTombstone = isTombstone
    self.unavailableLabel = unavailableLabel
    self.positionText = positionText
    self.moveEarlierLabel = moveEarlierLabel
    self.canMoveEarlier = canMoveEarlier
    self.moveLaterLabel = moveLaterLabel
    self.canMoveLater = canMoveLater
    self.removeLabel = removeLabel
    self.contextMenuAccessibilityLabel = contextMenuAccessibilityLabel
    self.contextMenuAccessibilityHint = contextMenuAccessibilityHint
    self.contextActions = contextActions
    self.onSelect = onSelect
    self.onMoveEarlier = onMoveEarlier
    self.onMoveLater = onMoveLater
    self.onRemove = onRemove
    self.onSelectAction = onSelectAction
    self.cover = cover()
  }

  public static var surface: MediaContentSurface { .ordinaryContent }
  public static var coverAlignment: VerticalAlignment {
    ArtworkLedRowMetrics.artworkAlignment
  }
  public var isSelectable: Bool { isTombstone == false }
  public var isButton: Bool { isSelectable }
  public let removeRole: MediaActionRole = .destructive
  public let presentsActionsOnLongPress = true
  public let selectionMinimumHeight: CGFloat = WhirrMetric.minimumTouchTarget
  public let handleMinimumDimension: CGFloat = WhirrMetric.minimumTouchTarget

  public var accessibilityLabel: String { primaryTitle }
  public var accessibilityValue: String {
    var parts = [secondaryTitle, mediaKindLabel]
    if isNext { parts.append(nextLabel) }
    if isTombstone { parts.append(unavailableLabel) }
    parts.append(positionText)
    return parts.filter { $0.isEmpty == false }.joined(separator: ". ")
  }

  public var titleLineLimit: Int? { queueLayoutValues.titleLineLimit }
  public var secondaryLineLimit: Int? { queueLayoutValues.secondaryLineLimit }
  public var glyphPlacement: ListeningQueueGlyphPlacement { .secondaryLine }

  private var layoutValues: MediaRowLayoutValues {
    MediaRowLayoutValues.resolve(isAccessibilitySize: dynamicTypeSize.isAccessibilitySize)
  }
  private var queueLayoutValues: ListeningQueueRowLayoutValues {
    ListeningQueueRowLayoutValues.resolve(isAccessibilitySize: dynamicTypeSize.isAccessibilitySize)
  }

  public var body: some View {
    Group {
      if layoutValues.axis == .vertical {
        VStack(alignment: .leading, spacing: WhirrSpacing.xSmall) {
          selectionRegion
          HStack(spacing: WhirrSpacing.small) {
            contextMenuButton
            reorderHandle
          }
        }
      } else {
        HStack(alignment: .center, spacing: WhirrSpacing.small) {
          selectionRegion
          contextMenuButton
          reorderHandle
        }
      }
    }
    .padding(.vertical, WhirrSpacing.xSmall)
    .accessibilityElement(children: .contain)
    .withMoveActions(
      canMoveEarlier: canMoveEarlier, moveEarlierLabel: moveEarlierLabel, onMoveEarlier: onMoveEarlier,
      canMoveLater: canMoveLater, moveLaterLabel: moveLaterLabel, onMoveLater: onMoveLater)
  }

  @ViewBuilder private var selectionRegion: some View {
    if isSelectable {
      Button(action: onSelect) {
        selectionContent
      }
      .buttonStyle(.plain)
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(accessibilityLabel)
      .accessibilityValue(accessibilityValue)
      .accessibilityAddTraits(.isButton)
      // Long press raises the same list as the ellipsis, built from one `contextActions` array
      // so the two entry points cannot drift apart.
      .contextMenu { actionMenuItems }
    } else {
      selectionContent
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(accessibilityValue)
        .contextMenu { actionMenuItems }
    }
  }

  private var selectionContent: some View {
    HStack(alignment: Self.coverAlignment, spacing: WhirrSpacing.small) {
      cover
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: WhirrSpacing.xxSmall) {
        if isNext {
          // A label, not a sentence: small, semibold and on the floor rung so it does not read as a first
          // line of content competing with the title.
          Text(nextLabel)
            .font(WhirrTypeToken.caption.font.weight(.semibold))
            .foregroundStyle(WhirrMetadataProminence.queueRowLabel.adaptiveStyle)
        }
        Text(primaryTitle)
          .font(WhirrTypeToken.headline.font)
          .lineLimit(titleLineLimit)
          .fixedSize(horizontal: false, vertical: true)
        HStack(alignment: .firstTextBaseline, spacing: WhirrSpacing.xxSmall) {
          Image(systemName: mediaKind.symbolName)
            .font(WhirrTypeToken.caption.font)
            .foregroundStyle(WhirrMetadataProminence.queueRowSubtitle.adaptiveStyle)
          Text(secondaryTitle)
            .font(WhirrTypeToken.caption.font)
            .foregroundStyle(WhirrMetadataProminence.queueRowSubtitle.adaptiveStyle)
            .lineLimit(secondaryLineLimit)
            .fixedSize(horizontal: false, vertical: true)
        }
        if isTombstone {
          Text(unavailableLabel)
            .font(WhirrTypeToken.caption.font)
            .foregroundStyle(WhirrMetadataProminence.queueRowLabel.adaptiveStyle)
            .lineLimit(secondaryLineLimit)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
    }
    .frame(maxWidth: .infinity, minHeight: selectionMinimumHeight, alignment: .leading)
    .contentShape(Rectangle())
  }

  /// The visible reorder affordance, purely decorative. The containing list recognises the drag
  /// and calls back into queue mutation; VoiceOver users reorder through the Move Earlier/Move
  /// Later accessibility actions on the row instead.
  private var reorderHandle: some View {
    Image(systemName: "line.3.horizontal")
      .font(WhirrTypeToken.body.font)
      .foregroundStyle(WhirrMetadataProminence.queueRowLabel.adaptiveStyle)
      .frame(minWidth: handleMinimumDimension, minHeight: handleMinimumDimension)
      .accessibilityHidden(true)
  }

  /// The row's menu as data: the two reorder moves, then whatever the caller supplies.
  ///
  /// The moves are here for WCAG SC 2.5.7 (Dragging Movements): the handle and the VoiceOver
  /// rotor would otherwise be the only routes, leaving switch and head-pointer users unable to
  /// move a row. They stay on the rotor too.
  ///
  /// An edge row lists the move it cannot make, greyed: a menu whose length changes as a row moves
  /// is worse than one greyed entry. `withMoveActions` omits it for the rotor, where an action
  /// that does nothing is worse than none.
  ///
  /// A value, so the ellipsis button and the long press cannot drift apart and the inventory is
  /// assertable without evaluating `body`.
  public struct MenuEntry: Identifiable, Equatable, Sendable {
    public let id: String
    public let label: String
    public let hint: String
    public let systemImage: String
    public let isDestructive: Bool
    public let isEnabled: Bool
  }

  public var menuEntries: [MenuEntry] {
    [
      MenuEntry(
        id: "move-earlier", label: moveEarlierLabel, hint: "", systemImage: "arrow.up",
        isDestructive: false, isEnabled: canMoveEarlier),
      MenuEntry(
        id: "move-later", label: moveLaterLabel, hint: "", systemImage: "arrow.down",
        isDestructive: false, isEnabled: canMoveLater),
    ]
      + contextActions.map { action in
        MenuEntry(
          id: action.id, label: action.label, hint: action.hint, systemImage: action.systemImage,
          isDestructive: action.role == .destructive, isEnabled: action.isEnabled)
      }
  }

  /// Routes a chosen entry back to the closure that owns it. The two moves are the row's own;
  /// everything else is the caller's, and goes back out as the `MediaContextAction` it came from.
  public func perform(_ entry: MenuEntry) {
    switch entry.id {
    case "move-earlier": onMoveEarlier()
    case "move-later": onMoveLater()
    default:
      if let action = contextActions.first(where: { $0.id == entry.id }) { onSelectAction(action) }
    }
  }

  @ViewBuilder private var actionMenuItems: some View {
    ForEach(menuEntries) { entry in
      Button(role: entry.isDestructive ? .destructive : nil) {
        perform(entry)
      } label: {
        Label(entry.label, systemImage: entry.systemImage)
      }
      .disabled(entry.isEnabled == false)
      .accessibilityHint(entry.hint)
    }
  }

  /// A visible, VoiceOver-reachable entry point for `contextActions`. A bare `.contextMenu` is
  /// neither discoverable nor reliably reachable by VoiceOver, so the row keeps this button
  /// alongside the long press that raises the same list.
  @ViewBuilder private var contextMenuButton: some View {
    if contextActions.isEmpty == false {
      Menu {
        actionMenuItems
      } label: {
        Image(systemName: "ellipsis")
          .frame(minWidth: handleMinimumDimension, minHeight: handleMinimumDimension)
      }
      .accessibilityLabel(contextMenuAccessibilityLabel)
      .accessibilityHint(contextMenuAccessibilityHint)
    }
  }
}

extension View {
  /// Attaches only the Move Earlier/Move Later custom accessibility actions the caller's queue
  /// position allows. An edge row doesn't get the action that would do nothing, as its visible
  /// counterpart is `.disabled` at the same edge.
  @ViewBuilder
  fileprivate func withMoveActions(
    canMoveEarlier: Bool, moveEarlierLabel: String, onMoveEarlier: @escaping () -> Void,
    canMoveLater: Bool, moveLaterLabel: String, onMoveLater: @escaping () -> Void
  ) -> some View {
    switch (canMoveEarlier, canMoveLater) {
    case (true, true):
      self
        .accessibilityAction(named: Text(moveEarlierLabel), onMoveEarlier)
        .accessibilityAction(named: Text(moveLaterLabel), onMoveLater)
    case (true, false):
      self.accessibilityAction(named: Text(moveEarlierLabel), onMoveEarlier)
    case (false, true):
      self.accessibilityAction(named: Text(moveLaterLabel), onMoveLater)
    case (false, false):
      self
    }
  }
}
