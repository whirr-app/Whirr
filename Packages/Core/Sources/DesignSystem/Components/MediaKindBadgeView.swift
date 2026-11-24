import SwiftUI

/// The three media kinds `HomeCardView` badges a cover with.
/// Mirrors `Persistence.ItemMediaCategory` but is decoupled from it: this target imports no
/// `Persistence` (ARCHITECTURE.md layering), so the App target maps its category to this kind at
/// the call site, as `DownloadControlKind` does for `Persistence.ItemDownloadStatus`.
public enum MediaKindBadge: Sendable, Equatable, CaseIterable {
  case audiobook
  case podcast
  case ebook

  /// The symbol that pictures this kind. Lives on the kind, not `MediaKindBadgeView`, because
  /// other surfaces (a filtered empty state, say) must use the same one.
  public var symbolName: String {
    switch self {
    case .audiobook: return "headphones"
    case .podcast: return "antenna.radiowaves.left.and.right"
    case .ebook: return "book"
    }
  }
}

/// A small media-kind badge overlaid on a cover in Home cards and Library rows. The symbol is
/// fixed per kind (unlike a download control's `systemImage`) because the kinds are a closed set.
/// The label is caller-supplied so copy stays owned by `HomeRowPresentation.badgeLabel`.
public struct MediaKindBadgeView: View {
  public let kind: MediaKindBadge
  public let label: String

  public init(kind: MediaKindBadge, label: String) {
    self.kind = kind
    self.label = label
  }

  public var systemImage: String { kind.symbolName }

  public var accessibilityLabel: String { label }

  public var body: some View {
    CoverBadgeSymbolView(systemImage: systemImage, label: accessibilityLabel)
  }
}

/// The disc a cover's corner marks are drawn in: a caption-scaled symbol on a translucent disc.
/// Shared so a media-kind badge and a source mark on the same grid read as one family. A `nil`
/// label leaves no accessibility element, for callers that already combine their children into
/// one utterance.
public struct CoverBadgeSymbolView: View {
  public let systemImage: String
  public let label: String?

  public init(systemImage: String, label: String? = nil) {
    self.systemImage = systemImage
    self.label = label
  }

  public var body: some View {
    Image(systemName: systemImage)
      .font(WhirrTypeToken.caption.font)
      .modifier(CoverMarkDisc())
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(label ?? "")
      .accessibilityHidden(label == nil)
  }
}

/// The marks a cover carries in its top corners: what the item is, on the trailing end, and what
/// state it is in, on the leading end.
///
/// Passed to the view that draws the artwork, not overlaid on the frame by the caller: a fitted
/// cover whose shape differs from its frame is inset on two sides, so a mark on the frame's
/// corner would float beside the art.
public struct CoverArtworkMarks: Equatable, Sendable {
  /// The playback-state symbol, which each screen's own projection chooses.
  public var stateSymbol: String?
  /// The media kind, which owns its own symbol.
  public var mediaKind: MediaKindBadge?
  /// Where the item came from, for a grid whose tiles are all one media kind (a podcast grid
  /// mixing server shows with followed feeds). Drawn in the same trailing corner as the kind, so
  /// set one or the other; `mediaKind` wins if both are set.
  public var sourceSymbol: String?

  public static let none = CoverArtworkMarks()

  public init(
    stateSymbol: String? = nil, mediaKind: MediaKindBadge? = nil, sourceSymbol: String? = nil
  ) {
    self.stateSymbol = stateSymbol
    self.mediaKind = mediaKind
    self.sourceSymbol = sourceSymbol
  }

  public var isEmpty: Bool { stateSymbol == nil && mediaKind == nil && sourceSymbol == nil }
}

/// Draws `CoverArtworkMarks` in the corners of whatever it covers, at opposite ends of the top
/// edge so the two never collide.
///
/// Decorative and silent: every surface using it combines its whole tile into one spoken sentence
/// that already names the kind and the state.
public struct CoverArtworkMarksOverlay: View {
  public let marks: CoverArtworkMarks

  public init(marks: CoverArtworkMarks) {
    self.marks = marks
  }

  public var body: some View {
    Color.clear
      .overlay(alignment: .topLeading) {
        if let stateSymbol = marks.stateSymbol {
          CoverMarkView(systemImage: stateSymbol)
            .padding(WhirrSpacing.xxSmall)
        }
      }
      .overlay(alignment: .topTrailing) {
        if let mediaKind = marks.mediaKind {
          MediaKindBadgeView(kind: mediaKind, label: "")
            .padding(WhirrSpacing.xxSmall)
        } else if let sourceSymbol = marks.sourceSymbol {
          CoverBadgeSymbolView(systemImage: sourceSymbol)
            .padding(WhirrSpacing.xxSmall)
        }
      }
      .allowsHitTesting(false)
      .accessibilityHidden(true)
  }
}

/// A state mark on a cover (finished, in progress) in `MediaKindBadgeView`'s shape: the same disc
/// and caption-scaled symbol, so the two marks on one cover read as one family. Tinted, not
/// coloured: the app's chrome is a neutral tint (`AppChrome.tint`), not a green "done".
///
/// The symbol is caller-supplied since each screen's projection decides which states a cover can
/// be in. A `nil` label leaves no accessibility element, for callers that already combine their
/// children into one utterance.
public struct CoverMarkView: View {
  public let systemImage: String
  public let label: String?

  public init(systemImage: String, label: String? = nil) {
    self.systemImage = systemImage
    self.label = label
  }

  public var body: some View {
    Image(systemName: systemImage)
      .font(WhirrTypeToken.caption.font.weight(.bold))
      .foregroundStyle(.tint)
      .modifier(CoverMarkDisc())
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(label ?? "")
      .accessibilityHidden(label == nil)
  }
}

/// The disc a cover mark sits on: the shared badge fill. On a drained dark wash
/// (`CoverWash.drainsDark`) the disc takes the cover's colour and the glyph the card's, so the
/// marks carry the colour the card gave up, as they do on the light card.
private struct CoverMarkDisc: ViewModifier {
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.colorSchemeContrast) private var colorSchemeContrast
  @Environment(\.drainedCoverWash) private var drainedCoverWash

  func body(content: Content) -> some View {
    if let drainedCoverWash,
      let mark = WashInk.drainedMark(
        colorScheme: colorScheme, wash: drainedCoverWash,
        increasedContrast: colorSchemeContrast == .increased)
    {
      // The tint as well as the foreground: a state mark draws its glyph in the tint.
      content
        .foregroundStyle(drainedCoverWash.dark.color)
        .tint(drainedCoverWash.dark.color)
        .padding(WhirrSpacing.xxSmall)
        .background(Circle().fill(mark.color))
    } else {
      content
        .padding(WhirrSpacing.xxSmall)
        .badgeBackground(in: Circle())
    }
  }
}
