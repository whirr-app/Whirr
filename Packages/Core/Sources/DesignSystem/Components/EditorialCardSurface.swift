import SwiftUI

private struct EditorialCardRowIsOutsideListKey: EnvironmentKey {
  static let defaultValue = false
}

extension EnvironmentValues {
  fileprivate var editorialCardRowIsOutsideList: Bool {
    get { self[EditorialCardRowIsOutsideListKey.self] }
    set { self[EditorialCardRowIsOutsideListKey.self] = newValue }
  }
}

/// The modifier that applies the shared editorial card chrome when a wash is available.
///
/// For a card that is a row in a `List`, use `editorialCardListRow` instead (see
/// `EditorialCardListRowModifier`).
public struct EditorialCardSurfaceModifier: ViewModifier {
  /// The card's shape and inner padding, shared with `EditorialCardListRowModifier` so a row card
  /// and a tile card for the same content can never drift into two radii.
  public nonisolated static let cornerRadius: CGFloat = 20
  public nonisolated static let contentPadding: CGFloat = WhirrSpacing.small

  public let wash: CoverWash?

  public init(wash: CoverWash?) {
    self.wash = wash
  }

  public var appliesChrome: Bool {
    wash != nil
  }

  public func body(content: Content) -> some View {
    if let wash {
      content
        .drawnOnCoverWash(wash)
        .padding(Self.contentPadding)
        .background {
          RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
            .fill(wash.cardColor)
        }
    } else {
      content
    }
  }
}

/// Editorial card chrome for a card that is a row inside a `List`.
///
/// A fill drawn inside the cell is masked square at the trailing corners as the swipe container
/// shrinks, while the cell's default backdrop stays behind it at a different radius. Painting the
/// fill as the row's background hands the shape to the view the swipe resizes and replaces that
/// backdrop.
///
/// It owns the row's insets too: a `.listRowBackground` spans the whole row including its insets,
/// so the fill is padded back by them, and two separately-declared numbers would drift.
///
/// Selection, and a row hosted outside its `List`, put the fill back inside the cell (see
/// `fillsInsideCell`).
public struct EditorialCardListRowModifier: ViewModifier {
  public static var cornerRadius: CGFloat { EditorialCardSurfaceModifier.cornerRadius }
  public static var contentPadding: CGFloat { EditorialCardSurfaceModifier.contentPadding }

  public let wash: CoverWash?
  /// The card's inner padding. Zero hands it to the content, which is what a row whose own tap
  /// target has to cover the whole card needs: padding applied out here sits outside every control
  /// the content declares, so it becomes a dead ring inside the card's edge.
  public let contentPadding: CGFloat
  public let horizontalInset: CGFloat
  public let verticalInset: CGFloat

  @Environment(\.editorialCardRowIsOutsideList) private var isOutsideList
  #if os(iOS)
    @Environment(\.editMode) private var editMode
  #endif

  /// Whether the enclosing `List` is running a multiselect.
  ///
  /// Read from the environment rather than passed in: every screen that selects reaches this
  /// modifier through `WideCompactCard`, so no call site can forget it. A screen that does not
  /// select installs no edit mode, and one that selects on only some lists installs it only there.
  private var isSelecting: Bool {
    #if os(iOS)
      editMode?.wrappedValue.isEditing == true
    #else
      false
    #endif
  }

  public init(
    wash: CoverWash?,
    contentPadding: CGFloat = EditorialCardSurfaceModifier.contentPadding,
    horizontalInset: CGFloat = WhirrSpacing.medium,
    verticalInset: CGFloat = WhirrSpacing.xSmall
  ) {
    self.wash = wash
    self.contentPadding = contentPadding
    self.horizontalInset = horizontalInset
    self.verticalInset = verticalInset
  }

  public var appliesChrome: Bool {
    wash != nil
  }

  public var rowInsets: EdgeInsets {
    Self.insets(horizontalInset: horizontalInset, verticalInset: verticalInset)
  }

  /// Always equal to `rowInsets`; declared separately only so a test can state the invariant.
  public var fillInsets: EdgeInsets { rowInsets }

  public static func insets(horizontalInset: CGFloat, verticalInset: CGFloat) -> EdgeInsets {
    EdgeInsets(
      top: verticalInset, leading: horizontalInset, bottom: verticalInset,
      trailing: horizontalInset)
  }

  /// Whether the card fill belongs inside the cell rather than in the row's background.
  ///
  /// Selection is explained under `fillOpacity`. A row outside any `List` (such as the Podcasts
  /// page's Latest Episodes) has no `.listRowBackground` to draw into, and swiping it slides the
  /// whole row aside, fill and all, so the card keeps its corners.
  public static func fillsInsideCell(isSelecting: Bool, isOutsideList: Bool) -> Bool {
    isSelecting || isOutsideList
  }

  /// How visible each of the two card fills is, in each state. One is opaque at a time.
  ///
  /// A `List` opens the gutter for its selection circles by indenting each row's content, but a
  /// `.listRowBackground` spans the whole cell, so the card stays put while its content slides
  /// right and the circle lands on the card's edge.
  ///
  /// While selecting, the fill moves inside the cell, wrapping the already-indented content (no
  /// accessory width assumed). The reason it sits outside otherwise (a swipe container masking an
  /// inner fill square, see `EditorialCardSwipeChromeTests`) does not apply: a list in edit mode
  /// has no swipe actions.
  ///
  /// Both fills are always declared and crossfaded rather than swapped behind an `if`, so entering
  /// selection does not re-create the row and lose the scroll position. At rest the two occupy the
  /// same rectangle, so the crossfade has nothing to move until the content moves.
  public static func fillOpacity(insideCell: Bool, fillsInsideCell: Bool) -> Double {
    insideCell == fillsInsideCell ? 1 : 0
  }

  public func body(content: Content) -> some View {
    let insets = rowInsets
    let fillsInsideCell = Self.fillsInsideCell(
      isSelecting: isSelecting, isOutsideList: isOutsideList)
    return
      content
      .drawnOnCoverWash(wash)
      .padding(appliesChrome ? contentPadding : 0)
      .background(
        fill(insets: EdgeInsets())
          .opacity(Self.fillOpacity(insideCell: true, fillsInsideCell: fillsInsideCell))
      )
      .listRowInsets(insets)
      .listRowBackground(
        fill(insets: insets)
          .opacity(Self.fillOpacity(insideCell: false, fillsInsideCell: fillsInsideCell)))
  }

  @ViewBuilder
  private func fill(insets: EdgeInsets) -> some View {
    if let wash {
      RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
        .fill(wash.cardColor)
        .padding(insets)
    } else {
      // Explicit: the default cell backdrop is a second, differently-rounded shape behind a
      // card row, and only stays invisible until something moves.
      Color.clear
    }
  }
}

extension View {
  /// Editorial card chrome: radius-20 continuous fill of the wash's card colour with
  /// WhirrSpacing.small inner padding. A nil wash leaves the content unchanged.
  ///
  /// For a row inside a `List`, use `editorialCardListRow` instead.
  public func editorialCardSurface(_ wash: CoverWash?) -> some View {
    modifier(EditorialCardSurfaceModifier(wash: wash))
  }

  /// Editorial card chrome for a `List` row: the same card, painted as the row's background and
  /// inset to match, so a swipe cannot mask it square. Also sets the row's insets.
  ///
  /// `contentPadding: 0` hands the card's inner padding to the content (see
  /// `podcastEpisodeCardListRow`).
  public func editorialCardListRow(
    _ wash: CoverWash?,
    contentPadding: CGFloat = EditorialCardSurfaceModifier.contentPadding,
    horizontalInset: CGFloat = WhirrSpacing.medium,
    verticalInset: CGFloat = WhirrSpacing.xSmall
  ) -> some View {
    modifier(
      EditorialCardListRowModifier(
        wash: wash, contentPadding: contentPadding, horizontalInset: horizontalInset,
        verticalInset: verticalInset))
  }

  /// The canonical chrome for a `PodcastEpisodeCardRow` in a `List`, shared by every screen that
  /// lists episodes so their insets cannot drift apart.
  ///
  /// The card's inner padding is the row's: `PodcastEpisodeCardRow` applies it inside its own tap
  /// shape so the whole card selects the episode, leaving play as the only distinct target.
  public func podcastEpisodeCardListRow(
    _ wash: CoverWash?,
    horizontalInset: CGFloat = WhirrSpacing.medium
  ) -> some View {
    editorialCardListRow(
      wash,
      contentPadding: PodcastEpisodeCardRowMetrics.chromeContentPadding,
      horizontalInset: horizontalInset,
      verticalInset: PodcastEpisodeCardRowMetrics.verticalInset
    )
    .listRowSeparator(.hidden)
  }

  /// Declares that the canonical rows below are not `List` rows, so no list draws their
  /// `.listRowBackground` and the card fill is painted inside the row instead. The row's insets
  /// are then the caller's padding; `.listRowInsets` has nothing to apply to.
  public func editorialCardRowOutsideList() -> some View {
    environment(\.editorialCardRowIsOutsideList, true)
  }
}

/// Layout metrics shared by every artwork-led summary row, regardless of media type or surface.
/// Keeping the artwork alignment here prevents generic items, podcast episodes, and Up Next from
/// acquiring separate alignment rules as their copy layouts evolve.
public enum ArtworkLedRowMetrics {
  public static var artworkAlignment: VerticalAlignment { .center }
}

/// The row metrics shared by `PodcastEpisodeCardRow` and the modifier that cards it. They live
/// outside the generic row type so a call site can read them without naming a `Cover` type.
public enum PodcastEpisodeCardRowMetrics {
  /// The artwork square, and the size it is requested at. Larger than the 44pt browse thumbnail
  /// because these cards carry three lines of text beside the cover. One value for both episode
  /// lists, so covers have no second decoded variant.
  public static var coverSize: CGFloat { 56 }

  /// The card's inner padding, applied by the row itself.
  public static var contentPadding: CGFloat { EditorialCardSurfaceModifier.contentPadding }

  /// What the card modifier adds on top: nothing. The padding is applied once, by the row, where
  /// it falls inside the row's tap shape.
  public static var chromeContentPadding: CGFloat { 0 }

  /// The gap between one episode card and the next.
  public static var verticalInset: CGFloat { WhirrSpacing.xSmall }
}
