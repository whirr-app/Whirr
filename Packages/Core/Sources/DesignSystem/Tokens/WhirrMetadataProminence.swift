import SwiftUI

/// How brightly a line of supporting metadata is drawn, shared so an author looks the same on the
/// item-detail hero and in the player. Brightness carries hierarchy only: the accent is reserved
/// for the two focal actions (Resume and the play/pause disc), because accent-tinted credits above
/// an accent-filled button read as one gold wash.
public enum WhirrMetadataProminence: Sendable, Equatable {
  case primary
  case secondary
  case tertiary
  case quaternary
  case quinary

  /// White at an explicit opacity, not `HierarchicalShapeStyle`: its third level (white at about
  /// 0.30) reaches only 2.46:1 on pure black, so nothing could bring it to AA's 4.5:1, and its
  /// second level lands anywhere from 2.7:1 to 5.3:1 depending on the cover.
  ///
  /// The rungs are fixed and the page's lightness is clamped into a band where the ink clears AA at
  /// `Self.floor`, so every rung clears AA on every cover without a scrim.
  ///
  /// Title to author is the widest gap, the break the eye has to find; below it the credits step by
  /// 0.08 so author, series and narrator recede without dropping out.
  ///
  /// Ambient pages choose their ink polarity, so they read the ladder through `adaptiveStyle`.
  /// `style`'s fixed white is only for structurally dark callers; on a page whose polarity is data
  /// it inverts the ladder.
  public var opacity: Double {
    switch self {
    case .primary: 1.0
    case .secondary: 0.88
    case .tertiary: 0.8
    case .quaternary: 0.72
    case .quinary: Self.floor
    }
  }

  /// The standard ladder's dimmest rung, and the contrast reference the ambient page's lightness
  /// bands are solved against. Changing it without re-solving the bands makes some cover's credits
  /// illegible. A page the standard ladder cannot carry lifts its own floor via
  /// `WhirrMetadataLadder`.
  public static let floor = 0.64

  public var style: AnyShapeStyle { AnyShapeStyle(Color.white.opacity(opacity)) }

  /// The same hierarchy for a surface that may resolve Light or Dark: ink polarity from the pinned
  /// colour scheme, opacity read from `EnvironmentValues.whirrMetadataLadder` at resolve time
  /// because a dim page cannot carry `Self.floor` (`ADR 0004`). No published ladder means
  /// `.standard`.
  public var adaptiveStyle: AnyShapeStyle { AnyShapeStyle(LadderedInk(prominence: self)) }

  /// Resolves `Color.primary` at whichever rung the surrounding surface's ladder puts this
  /// prominence on.
  private struct LadderedInk: ShapeStyle {
    let prominence: WhirrMetadataProminence

    func resolve(in environment: EnvironmentValues) -> some ShapeStyle {
      Color.primary.opacity(environment.whirrMetadataLadder.opacity(for: prominence))
    }
  }

  /// Higher is brighter. Lets tests state the relationships between the roles below. The ranks
  /// and `opacity` agree by construction.
  public var emphasisRank: Int {
    switch self {
    case .primary: 4
    case .secondary: 3
    case .tertiary: 2
    case .quaternary: 1
    case .quinary: 0
    }
  }

  /// The item-detail hero's credit lines in print order, each a step down: the author is looked
  /// for, the series places the book, the narrator is checked. One shared level would make the
  /// block a slab with no entry point; the shared `WhirrTypeToken.subheadline` size holds them
  /// together. None is `.primary`, or the hero loses its entry point under the title and the author
  /// prints two levels apart from the player.
  public static let authorName: WhirrMetadataProminence = .secondary
  public static let seriesName: WhirrMetadataProminence = .tertiary
  public static let narratorName: WhirrMetadataProminence = .quaternary

  /// The non-tappable words around a credit ("Narrated by", the commas), a step below the dimmest
  /// credit so they separate from names without colour. As the dimmest text on the page it is the
  /// contrast reference. Names are semibold against it.
  public static let creditLeadIn: WhirrMetadataProminence = .quinary

  /// A stat rather than a name: the item-detail hero's supporting figure, which on a part-played
  /// title is the total runtime. Same rung as the lead-in, set apart from the credits by size
  /// (`WhirrTypeToken.caption` against their subheadline).
  public static let heroStat: WhirrMetadataProminence = .quinary

  /// The leading half of that stat: the remainder on a part-played title, the runtime otherwise.
  /// Printed first so "3 hrs, 44 min left" is not buried under "20h 27m". At
  /// `WhirrTypeToken.caption` and no brighter than the narrator so the staircase keeps descending;
  /// order and semibold weight carry the separation.
  public static let heroStatLead: WhirrMetadataProminence = narratorName

  /// The expanded player's chapter row: the chapter name and its disclosure chevron. Subordinate
  /// to the byline above it, so it takes the floor rung. Hierarchical `.secondary` measured
  /// 3.5-3.7:1 there.
  public static let playerChapterRow: WhirrMetadataProminence = .quinary

  /// The player's byline, at the detail hero's author level since it is the same author. Dimmer
  /// rungs are too faint on the darkest ambient palettes below a two-line title, with no series or
  /// narrator beside it to read against.
  public static let playerByline: WhirrMetadataProminence = authorName

  /// The mini-player's show or author line. The floor rung, which clears AA on the glass over both
  /// the editorial page and a tinted ambient page. The standard ladder is read directly, since the
  /// system accessory host publishes no ambient ladder.
  public static let miniPlayerSubtitle: WhirrMetadataProminence = .quinary

  /// The Up Next row's creator-or-show line and its media glyph. Caption under a headline title,
  /// so size already marks it as supporting; a credit rung rather than the floor keeps it readable
  /// at a glance on the ambient page.
  public static let queueRowSubtitle: WhirrMetadataProminence = .tertiary

  /// The Up Next row's labels: the "Next" eyebrow, "No longer available", the reorder handle and
  /// the queue's status copy. Below the subtitle; the eyebrow's semibold weight separates it.
  public static let queueRowLabel: WhirrMetadataProminence = .quinary
}
