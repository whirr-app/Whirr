import SwiftUI

/// One card in a Home screen horizontally-scrolling row: caller-supplied cover, title, subtitle
/// (author or episode), an optional progress bar, a trailing caption ("6h 50m left"/"18%"), and a
/// media-kind badge overlaid on the cover. Content layer, not the floating control layer, so it
/// never uses glass (ARCHITECTURE.md §6).
///
/// The cover is a generic `@ViewBuilder` slot, like `ItemListRow`'s (the App target injects
/// `CoverImageView`). The slot is not clipped: the cover clips itself, and may draw a `CoverGlow`
/// past its frame, which the card clips at its own edge.
public struct HomeCardView<Cover: View>: View {
  public let title: String
  public let subtitle: String
  public let badgeKind: MediaKindBadge
  public let badgeLabel: String
  /// A provenance mark drawn in the cover's leading corner, opposite the media-kind badge, for a
  /// shelf whose podcasts come from more than one place. `nil` on a shelf that does not need one
  /// (the common case). The caller's policy decides; this target only draws it.
  public let sourceMarkSymbol: String?
  /// What the mark contributes to the card's one spoken utterance. `nil` leaves it silent.
  public let sourceMarkLabel: String?
  public let progressFraction: Double?
  /// Holds the bar's line open, empty, when this card has no bar. A shelf sets it on every card
  /// once any of them has progress, so a shelf mixing started and unstarted episodes keeps one card
  /// height; a shelf where nothing is started does not set it and keeps its shorter cards.
  public let reservesProgressLine: Bool
  /// Draws a held line as the bar's empty track rather than a blank gap. Only for a shelf where an
  /// empty track can only mean "not started": one that keeps finished titles would draw the same
  /// track under a title that is done.
  public let showsEmptyProgressTrack: Bool
  public let trailingCaption: String?
  /// The title area stays tall enough for this many lines so the metadata below it does not move
  /// when a neighbouring card's title wraps. `nil` removes the limit, and the reservation follows
  /// the title's own wrapped height instead, which accessibility sizes need because truncating
  /// the title would cost more than an uneven row of cards.
  public let titleLineLimit: Int?
  public let subtitleLineLimit: Int?
  /// Non-nil marks this card's title finished and is what VoiceOver hears; nil leaves the card
  /// unmarked. Caller-supplied copy, as with `badgeLabel`, because this target owns no strings.
  public let finishedLabel: String?
  /// Optional copy describing the action performed by the card's primary tap.
  public let accessibilityHint: String?
  public let wash: CoverWash?
  public let cover: Cover
  public let onSelect: () -> Void

  #if PERF_INVESTIGATION
    @Environment(\.colorScheme) private var washColorScheme
    @Environment(\.colorSchemeContrast) private var washColorSchemeContrast
  #endif
  #if canImport(UIKit)
    @Environment(\.colorScheme) private var secondaryColorScheme
    @Environment(\.colorSchemeContrast) private var secondaryColorSchemeContrast
  #endif

  /// `progressFraction` is clamped to `0...1` here as a second layer, though `HomeRowPresentation
  /// .progressFraction` (AppModel) already clamps.
  public init(
    title: String,
    subtitle: String,
    badgeKind: MediaKindBadge,
    badgeLabel: String,
    sourceMarkSymbol: String? = nil,
    sourceMarkLabel: String? = nil,
    progressFraction: Double? = nil,
    reservesProgressLine: Bool = false,
    showsEmptyProgressTrack: Bool = false,
    trailingCaption: String? = nil,
    finishedLabel: String? = nil,
    titleLineLimit: Int? = 2,
    subtitleLineLimit: Int? = 1,
    accessibilityHint: String? = nil,
    wash: CoverWash? = nil,
    @ViewBuilder cover: () -> Cover,
    onSelect: @escaping () -> Void
  ) {
    self.finishedLabel = finishedLabel
    self.accessibilityHint = accessibilityHint
    self.wash = wash
    self.title = title
    self.subtitle = subtitle
    self.badgeKind = badgeKind
    self.badgeLabel = badgeLabel
    self.sourceMarkSymbol = sourceMarkSymbol
    self.sourceMarkLabel = sourceMarkLabel
    self.progressFraction = progressFraction.map(PlaybackProgressBar.clamp)
    self.reservesProgressLine = reservesProgressLine
    self.showsEmptyProgressTrack = showsEmptyProgressTrack
    self.trailingCaption = trailingCaption
    self.titleLineLimit = titleLineLimit
    self.subtitleLineLimit = subtitleLineLimit
    self.cover = cover()
    self.onSelect = onSelect
  }

  /// The card's single combined VoiceOver utterance: title, subtitle, badge kind and the trailing
  /// caption (which already carries the progress/remaining-time meaning, per
  /// `HomeRowPresentation.remainingCaption`), rather than four separate stops.
  public var accessibilityLabel: String {
    var parts = [title, subtitle, badgeLabel]
    if let sourceMarkLabel, !sourceMarkLabel.isEmpty {
      parts.append(sourceMarkLabel)
    }
    if let trailingCaption, !trailingCaption.isEmpty {
      parts.append(trailingCaption)
    }
    // A continuation card's caption already reads "Finished" for a finished title, so the mark
    // only adds its own utterance when the caption has not already said it.
    if let finishedLabel, finishedLabel != trailingCaption {
      parts.append(finishedLabel)
    }
    return parts.joined(separator: ". ")
  }

  /// Whether this card carries the finished mark. Exposed so tests need not inspect the rendered
  /// view.
  public var isFinished: Bool { finishedLabel != nil }

  /// Whether the bar's line takes space in the card, drawn or held empty.
  public var holdsProgressLine: Bool { progressFraction != nil || reservesProgressLine }
  public var drawsProgressBar: Bool { progressFraction != nil }
  public var drawsEmptyProgressTrack: Bool {
    progressFraction == nil && reservesProgressLine && showsEmptyProgressTrack
  }

  /// The progress bar's tint: the wash's punched-up accent, else the shared tint (neutral washes
  /// have no accent). On a dark wash the bar takes the shared tint unless the wash is drained; see
  /// `PlaybackProgressBar`.
  public var progressBarTint: Color { wash?.accentColor ?? PlaybackProgressBar.progressTint }

  @ViewBuilder public var body: some View {
    if let accessibilityHint {
      cardButton.accessibilityHint(accessibilityHint)
    } else {
      cardButton
    }
  }

  @ViewBuilder
  private var cardButton: some View {
    let button = Button(action: onSelect) {
      cardContent
        .drawnOnCoverWash(wash)
        .padding(wash == nil ? 0 : WhirrSpacing.small)
        .background {
          if let wash {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
              .fill(resolvedCardColor(for: wash))
          }
        }
        // The cover's `CoverGlow` stops at the card's edge. Square (a no-op) on a card with no
        // wash rather than a conditional modifier: the wash can land after the card appears, and
        // a change of structure there would rebuild the cover.
        .clipShape(RoundedRectangle(cornerRadius: wash == nil ? 0 : 20, style: .continuous))
    }
    .buttonStyle(.plain)

    #if PERF_INVESTIGATION
      if HomeCardAccessibilityInvestigation.ignoreChildren {
        button
          .accessibilityElement(children: .ignore)
          .accessibilityLabel(accessibilityLabel)
          .accessibilityAddTraits(.isButton)
      } else {
        button
          .accessibilityElement(children: .combine)
          .accessibilityLabel(accessibilityLabel)
      }
    #else
      button
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    #endif
  }

  private func resolvedCardColor(for wash: CoverWash) -> Color {
    #if PERF_INVESTIGATION
      if HomeCardResolvedWashInvestigation.enabled {
        return HomeCardResolvedWashInvestigation.color(
          for: wash, colorScheme: washColorScheme, contrast: washColorSchemeContrast)
      }
    #endif
    return wash.cardColor
  }

  private var resolvedSecondaryTextColor: Color {
    #if canImport(UIKit)
      #if PERF_INVESTIGATION
        if HomeCardDynamicSecondaryInvestigation.restoreDynamic {
          return WhirrColorToken.textSecondary.color
        }
      #endif
      // `WashInk.secondary`'s dark ink, resolved here to a concrete colour like the rest of this
      // card's text.
      if wash != nil, WashInk.drawsDarkInk(colorScheme: secondaryColorScheme, isOnWash: true) {
        return .white.opacity(
          WashInk.darkSecondaryOpacity(increasedContrast: secondaryColorSchemeContrast == .increased))
      }
      return HomeCardSecondaryTextResolver.color(
        colorScheme: secondaryColorScheme, contrast: secondaryColorSchemeContrast)
    #else
      return WhirrColorToken.textSecondary.color
    #endif
  }

  @ViewBuilder
  private var cardContent: some View {
    VStack(alignment: .leading, spacing: WhirrSpacing.xSmall) {
      ZStack(alignment: .topTrailing) {
        // Not clipped here: the cover rounds itself, so a glow it draws behind its artwork can
        // reach the card.
        cover
          .aspectRatio(1, contentMode: .fit)
          // The free corner: the kind badge holds top trailing and the finished mark bottom
          // trailing, so all three fit without colliding. Drawn on the artwork rather than the
          // card frame (as `CoverArtworkMarks` does), since a mark on the frame of an inset cover
          // floats beside the art it marks.
          .overlay(alignment: .topLeading) {
            if let sourceMarkSymbol {
              CoverBadgeSymbolView(systemImage: sourceMarkSymbol)
                .padding(WhirrSpacing.xxSmall)
            }
          }
          // Opposite corner from the media-kind badge, in the same badge shape, so a finished
          // cover reads as finished at a glance down a shelf.
          .overlay(alignment: .bottomTrailing) {
            if isFinished {
              FinishedMarkView()
                .padding(WhirrSpacing.xxSmall)
            }
          }
        MediaKindBadgeView(kind: badgeKind, label: badgeLabel)
          .padding(WhirrSpacing.xxSmall)
      }

      titleArea

      Text(subtitle)
        .font(WhirrTypeToken.caption.font)
        .foregroundStyle(resolvedSecondaryTextColor)
        .lineLimit(subtitleLineLimit)

      if let progressFraction {
        PlaybackProgressBar(fraction: progressFraction, tint: progressBarTint)
      } else if reservesProgressLine {
        // The bar itself, so the held line is exactly its height at every text size. Silent either
        // way: an unstarted card's caption already says what VoiceOver needs.
        PlaybackProgressBar(fraction: 0, tint: progressBarTint)
          .opacity(drawsEmptyProgressTrack ? 1 : 0)
          .accessibilityHidden(true)
      }

      if let trailingCaption, !trailingCaption.isEmpty {
        Text(trailingCaption)
          .font(WhirrTypeToken.caption.font)
          .foregroundStyle(resolvedSecondaryTextColor)
      }
    }
  }

  @ViewBuilder
  private var titleArea: some View {
    #if PERF_INVESTIGATION
      if HomeCardLayoutInvestigation.nativeTitleReservation {
        if let titleLineLimit {
          Text(title)
            .font(WhirrTypeToken.headline.font)
            .lineLimit(titleLineLimit, reservesSpace: true)
        } else {
          Text(title)
            .font(WhirrTypeToken.headline.font)
        }
      } else {
        sampledTitleArea
      }
    #else
      sampledTitleArea
    #endif
  }

  private var sampledTitleArea: some View {
    ZStack(alignment: .topLeading) {
      // A hidden sample of the reserved line count gives the title area its intrinsic, Dynamic
      // Type-aware height without hard-coding a line height. An unlimited title samples the
      // actual text, so the reservation follows what it wraps to.
      Text(titlePlaceholder)
        .font(WhirrTypeToken.headline.font)
        .hidden()
        .accessibilityHidden(true)

      Text(title)
        .font(WhirrTypeToken.headline.font)
        .lineLimit(titleLineLimit)
    }
  }

  private var titlePlaceholder: String {
    guard let titleLineLimit else { return title }
    return Array(repeating: "Title", count: titleLineLimit).joined(separator: "\n")
  }
}

/// The finished mark on a card's cover: `CoverMarkView` with this screen's symbol.
///
/// It carries no accessibility element of its own: `HomeCardView` combines its children into one
/// utterance, which already names the finished state via `finishedLabel`.
struct FinishedMarkView: View {
  var body: some View {
    CoverMarkView(systemImage: "checkmark")
  }
}

#if canImport(UIKit)
  /// Resolves the existing text palette and contrast policy from the SwiftUI environment.
  /// These Home text sites then carry concrete Color through sheet tint and trait propagation,
  /// avoiding the dynamic UIColor-backed token while preserving its appearance values.
  private enum HomeCardSecondaryTextResolver {
    static func color(
      colorScheme: ColorScheme, contrast: ColorSchemeContrast
    ) -> Color {
      let token = WhirrColorToken.textSecondary
      let policy = WhirrContrastPolicy.decide(prefersIncreasedContrast: contrast == .increased)
      let value: WhirrRGBColor
      if colorScheme == .dark {
        value = policy.usesStrengthenedInk ? token.darkHighContrastRGB : token.darkRGB
      } else {
        value = policy.usesStrengthenedInk ? token.lightHighContrastRGB : token.lightRGB
      }
      return value.color
    }
  }
#endif

#if PERF_INVESTIGATION
  private enum HomeCardLayoutInvestigation {
    static let nativeTitleReservation = ProcessInfo.processInfo.arguments.contains(
      "-perf-native-title-reservation")
  }

  private enum HomeCardResolvedWashInvestigation {
    static let enabled = ProcessInfo.processInfo.arguments.contains(
      "-perf-card-resolved-wash")

    /// Selects the same CoverWashValue as CoverWash.cardColor, then creates a concrete Color.
    static func color(
      for wash: CoverWash, colorScheme: ColorScheme, contrast: ColorSchemeContrast
    ) -> Color {
      let policy = WhirrContrastPolicy.decide(prefersIncreasedContrast: contrast == .increased)
      let value =
        policy.usesArtworkWash
        ? (colorScheme == .dark ? wash.dark : wash.light)
        : (colorScheme == .dark ? CoverWash.neutral.dark : CoverWash.neutral.light)
      return value.color
    }
  }

  private enum HomeCardDynamicSecondaryInvestigation {
    static let restoreDynamic = ProcessInfo.processInfo.arguments.contains(
      "-perf-card-dynamic-secondary")
  }

  private enum HomeCardAccessibilityInvestigation {
    static let ignoreChildren = ProcessInfo.processInfo.arguments.contains(
      "-perf-card-ax-ignore")
  }
#endif
