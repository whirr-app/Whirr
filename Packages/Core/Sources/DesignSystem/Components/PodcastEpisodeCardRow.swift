import SwiftUI

/// A card-style, selectable podcast episode row with a separate inline play control.
public struct PodcastEpisodeCardRow<Cover: View>: View {
  public let title: String
  public let showTitle: String
  /// `nil` where the list already says the day. The Podcasts tab files episodes under day
  /// headings, so a date on every card there only repeats its heading.
  public let dateText: String?
  public let durationText: String
  public let accessibilityLabel: String
  public let coverSize: CGFloat
  public let wash: CoverWash?
  public let isPlaying: Bool
  /// Whether an enclosing multiselect list is drawing its own selection control for this row.
  ///
  /// Only the controls differ: a `List(selection:)` cell owns both the tap and the checkmark, and a
  /// nested button competes with it. The card keeps its shape in edit mode, so nothing reflows.
  public let isSelecting: Bool
  /// How far through the episode the listener is ("36 min left", "Played"). Replaces the
  /// duration on the time line rather than joining it: one time fact per card, and a started card
  /// keeps the height of an unstarted one.
  public let progressText: String?
  /// The bar over the cover's bottom edge, drawn only part way through. Over the cover for the same
  /// reason as `progressText`: a line of its own would make this card taller than its neighbours.
  public let progressFraction: Double?
  /// Non-nil marks the episode as downloaded to this device and is what VoiceOver hears. Caller-
  /// supplied copy: this target owns no strings.
  public let downloadedLabel: String?
  /// The episode is being checked for ads now; drawn only while it is downloaded.
  public let isCheckingForAds: Bool
  public let cover: Cover
  public let onSelect: () -> Void
  public let onPlay: () -> Void

  /// This row never fills its own card: chrome is the call site's, via `podcastEpisodeCardListRow`
  /// inside a `List` or `editorialCardSurface` outside one. Only the call site knows whether a
  /// swipe container will mask a fill drawn inside the cell. See `EditorialCardListRowModifier`.
  public static var paintsCardBackground: Bool { false }

  /// The row owns the card's padding, unlike the fill: applied by the card modifier it would sit
  /// outside every control here, a dead ring inside the card's edge. `podcastEpisodeCardListRow`
  /// is the matching chrome and passes `contentPadding: 0`.
  public static var cardContentPadding: CGFloat { PodcastEpisodeCardRowMetrics.contentPadding }

  /// Every card is one height: the title always occupies two lines whether or not it needs them,
  /// so a one-word episode and a wrapping one sit on the same rhythm. The show line and the time
  /// line are held to one line each for the same reason. `PodcastEpisodeCardRowHeightTests`
  /// measures the result; change none of these without it.
  public static var titleLineLimit: Int { 2 }
  public static var showTitleLineLimit: Int { 1 }
  public static var metadataLineLimit: Int { 1 }

  /// Podcast artwork follows the same vertical alignment contract as every other artwork-led
  /// editorial card. The copy column can be taller than the cover, so top alignment visibly
  /// strands the artwork at the card's upper edge.
  public static var coverAlignment: VerticalAlignment {
    ArtworkLedRowMetrics.artworkAlignment
  }

  public var reservesTitleSpace: Bool { true }

  public init(
    title: String,
    showTitle: String,
    dateText: String?,
    durationText: String,
    accessibilityLabel: String,
    coverSize: CGFloat,
    wash: CoverWash? = nil,
    isPlaying: Bool = false,
    isSelecting: Bool = false,
    progressText: String? = nil,
    progressFraction: Double? = nil,
    downloadedLabel: String? = nil,
    isCheckingForAds: Bool = false,
    @ViewBuilder cover: () -> Cover,
    onSelect: @escaping () -> Void,
    onPlay: @escaping () -> Void
  ) {
    self.title = title
    self.showTitle = showTitle
    self.dateText = dateText
    self.durationText = durationText
    self.accessibilityLabel = accessibilityLabel
    self.coverSize = coverSize
    self.wash = wash
    self.isPlaying = isPlaying
    self.isSelecting = isSelecting
    self.progressText = progressText
    self.progressFraction = progressFraction
    self.downloadedLabel = downloadedLabel
    self.isCheckingForAds = isCheckingForAds
    self.cover = cover()
    self.onSelect = onSelect
    self.onPlay = onPlay
  }

  /// The card's one time fact: what is left once started, otherwise the episode's length.
  public var timeText: String {
    progressText ?? durationText
  }

  public var metadataText: String {
    [dateText, timeText].compactMap { $0 }.joined(separator: " · ")
  }

  /// The cover bar's fill: part way through only, the same rule as the show row's
  /// `visiblePlaybackProgressFraction`, so the two rows never disagree about drawing a bar.
  public var visibleProgressFraction: Double? {
    guard let progressFraction, !progressFraction.isNaN, progressFraction > 0,
      progressFraction < 1
    else { return nil }
    return progressFraction
  }

  public var showsDownloadedMark: Bool {
    downloadedLabel.map { !$0.isEmpty } ?? false
  }

  /// The downloaded mark gives way to the ad check's, in the same place, so the card keeps its
  /// height.
  public var showsCheckingForAds: Bool { isCheckingForAds && showsDownloadedMark }

  /// The row's one utterance: the caller's label, then the downloaded state the glyph shows.
  public var spokenLabel: String {
    guard showsDownloadedMark, let downloadedLabel else { return accessibilityLabel }
    let checking = showsCheckingForAds ? CheckingForAdsGlyph.accessibilityText : nil
    return [accessibilityLabel, downloadedLabel, checking].compactMap { $0 }.joined(separator: ", ")
  }

  /// The show line, which is text on the card wash and so owes 4.5:1. The band alone was
  /// under that across the warm arc of the hue circle; `accentColor(on:minimumRatio:)` moves it
  /// only as far as the ground in front of it requires.
  public var accentColor: Color {
    wash?.accentColor(on: .card, minimumRatio: 4.5) ?? WhirrColorToken.brandInk.color
  }

  /// The accent as a fill with a glyph on it, so the glyph colour has to be chosen against it.
  /// `editorialBackground` on the raw accent is under 4.5:1 across the whole yellow-to-cyan arc
  /// of the hue circle in the light appearance. The resolver settles the two together; the
  /// brand-ink fallback is the app's own pinned pair and keeps its exact values.
  public var playControl: (fill: Color, ink: Color) {
    guard let accent = wash?.accentColor else {
      return (WhirrColorToken.brandInk.color, WhirrColorToken.editorialBackground.color)
    }
    return legibleAccentColors(for: accent)
  }

  /// Whether the accent came from the wash rather than the brand-ink fallback. Tests assert this
  /// decision instead of comparing `Color`s: trait-dynamic colors are rebuilt per access, so two
  /// reads of the same wash accent never compare equal.
  public var usesWashAccent: Bool {
    wash?.accentColor != nil
  }

  public var playButtonAccessibilityLabel: String {
    isPlaying ? "Pause" : "Play"
  }

  /// Whether the row installs its own tap target for opening the episode. False while selecting:
  /// the list cell's tap toggles selection, and a button over the card would swallow it.
  public var ownsRowSelection: Bool { !isSelecting }

  /// Whether the inline play control is drawn. False while selecting: starting playback from a
  /// row the user is ticking is never what they meant, and the control would sit where the list
  /// wants its own trailing chrome.
  public var showsPlayControl: Bool { !isSelecting }

  public var visibleText: [String] {
    [showTitle, title, dateText, timeText].compactMap { $0 }
  }

  /// The card's copy column, identical in both states so a row does not reflow when its screen
  /// enters edit mode.
  private var cardContent: some View {
    HStack(alignment: Self.coverAlignment, spacing: WhirrSpacing.small) {
      cover
        .frame(width: coverSize, height: coverSize)
        .clipShape(RoundedRectangle(cornerRadius: WhirrSpacing.xSmall))
        .overlay(alignment: .bottom) {
          if let visibleProgressFraction {
            // On the badge ground so the bar reads over any artwork.
            PlaybackProgressBar(fraction: visibleProgressFraction)
              .padding(WhirrSpacing.xxSmall)
              .badgeBackground(in: Capsule())
              .padding(WhirrSpacing.xxSmall)
          }
        }

      VStack(alignment: .leading, spacing: WhirrSpacing.xxSmall) {
        // Sentence case at subheadline weight: the artwork already names the show, so this line
        // confirms it rather than announcing it.
        Text(showTitle)
          .font(WhirrTypeToken.subheadline.font.weight(.medium))
          .foregroundStyle(WashInk.eyebrow(accentColor, wash: wash))
          .lineLimit(Self.showTitleLineLimit)

        Text(title)
          .font(WhirrTypeToken.headline.font)
          .foregroundStyle(.primary)
          .lineLimit(Self.titleLineLimit, reservesSpace: true)
          .multilineTextAlignment(.leading)

        HStack(spacing: WhirrSpacing.xxSmall) {
          if showsCheckingForAds {
            // Drawn in the downloaded mark's own box: the waveform is taller at large text
            // sizes, and every card must keep one height.
            Image(systemName: "arrow.down.circle.fill")
              .hidden()
              .overlay { CheckingForAdsGlyph().imageScale(.small) }
          } else if showsDownloadedMark {
            Image(systemName: "arrow.down.circle.fill")
          }
          Text(metadataText)
            .lineLimit(Self.metadataLineLimit)
        }
        .font(WhirrTypeToken.caption.font)
        .foregroundStyle(WashInk.secondary)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    // `.buttonStyle(.plain)` hit-tests the label's drawn content, not its frame: without this
    // the blank space beside a short episode title was not part of the button at all.
    .contentShape(.rect)
  }

  public var body: some View {
    HStack(alignment: .center, spacing: WhirrSpacing.small) {
      if ownsRowSelection {
        Button(action: onSelect) { cardContent }
          .buttonStyle(.plain)
          .accessibilityElement(children: .ignore)
          .accessibilityLabel(spokenLabel)
      } else {
        cardContent
          .accessibilityElement(children: .ignore)
          .accessibilityLabel(spokenLabel)
      }

      if showsPlayControl {
        Button(action: onPlay) {
          Image(systemName: isPlaying ? "pause.fill" : "play.fill")
            .foregroundStyle(playControl.ink)
            .frame(width: WhirrMetric.minimumTouchTarget, height: WhirrMetric.minimumTouchTarget)
            .background(playControl.fill, in: Circle())
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(playButtonAccessibilityLabel)
        .accessibilityValue(title)
      }
    }
    // The card's padding, and the tap that covers it. Everything the two buttons above do not
    // claim (the padding ring and the gap between them) still selects the episode, so the play
    // control is the card's only distinct target. A descendant's own gesture wins, so the play
    // button keeps its taps. While selecting there is no gesture at all: the list cell's own tap
    // must reach it, and a `contentShape` alone does not intercept one.
    .padding(Self.cardContentPadding)
    .contentShape(.rect)
    .modifier(RowSelectTap(onSelect: ownsRowSelection ? onSelect : nil))
  }
}

/// Installs the card's whole-surface tap only when the row owns it. A `nil` action leaves the view
/// untouched, so an enclosing `List(selection:)` cell receives the tap instead.
private struct RowSelectTap: ViewModifier {
  let onSelect: (() -> Void)?

  func body(content: Content) -> some View {
    if let onSelect {
      content.onTapGesture(perform: onSelect)
    } else {
      content
    }
  }
}
