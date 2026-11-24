import SwiftUI

/// A value-driven podcast show header with a caller-provided cover. All displayed copy is injected,
/// and the layout stacks at accessibility Dynamic Type sizes without truncating essential text.
public struct PodcastShowHeaderView<Cover: View>: View {
  public let title: String
  public let subtitle: String?
  /// The show's own blurb, already stripped to plain text by the caller (AppModel owns
  /// that; this view never parses markup).
  public let synopsis: String?
  /// A short note on where the show comes from, shown under the subtitle. `nil` for the ordinary
  /// case so the header only says something when there is something to say.
  public let sourceCaption: String?
  /// The glyph beside `sourceCaption`; defaults to the feed glyph.
  public let sourceCaptionSymbolName: String
  public let badgeLabel: String
  public let cover: Cover
  /// Told whether the title itself is on screen, so a screen can name the show in its bar only
  /// once this header no longer does.
  public let onTitleVisibilityChange: ((Bool) -> Void)?

  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  /// The header only ever shows the synopsis's first three lines, so its height never changes.
  /// Expanded, the screen shows the rest below it in a `PodcastShowSynopsisContinuationView`.
  @Binding private var isSynopsisExpanded: Bool
  @State private var synopsisCollapsedHeight: CGFloat = 0
  @State private var synopsisFullHeight: CGFloat = 0

  public init(
    title: String,
    subtitle: String?,
    synopsis: String? = nil,
    isSynopsisExpanded: Binding<Bool> = .constant(false),
    sourceCaption: String? = nil,
    sourceCaptionSymbolName: String = PodcastShowHeaderView.feedCaptionSymbolName,
    badgeLabel: String,
    onTitleVisibilityChange: ((Bool) -> Void)? = nil,
    @ViewBuilder cover: () -> Cover
  ) {
    self.title = title
    self.subtitle = subtitle
    self.synopsis = synopsis
    self._isSynopsisExpanded = isSynopsisExpanded
    self.sourceCaption = sourceCaption
    self.sourceCaptionSymbolName = sourceCaptionSymbolName
    self.badgeLabel = badgeLabel
    self.onTitleVisibilityChange = onTitleVisibilityChange
    self.cover = cover()
  }

  public static var surface: MediaContentSurface { .ordinaryContent }
  public var isAccessibilityHeader: Bool { true }
  private var layoutValues: MediaRowLayoutValues {
    MediaRowLayoutValues.resolve(isAccessibilitySize: dynamicTypeSize.isAccessibilitySize)
  }

  /// The synopsis is absent from this label. A feed blurb runs to thousands of characters, and
  /// combining it in would make VoiceOver read the whole thing before reaching anything
  /// actionable. It is voiced as its own element (`synopsisAccessibilityLabel`).
  public var accessibilityLabel: String {
    [title, subtitle, sourceCaption]
      .compactMap { value in
        guard let value, value.isEmpty == false else { return nil }
        return value
      }
      .joined(separator: ". ")
  }

  public static var collapsedSynopsisLineLimit: Int { PodcastShowSynopsisStyle.collapsedLineLimit }

  public var synopsisAccessibilityLabel: String? {
    guard let synopsis, synopsis.isEmpty == false else { return nil }
    return synopsis
  }

  public func synopsisAccessibilityHint(isExpanded: Bool) -> String? {
    guard synopsisAccessibilityLabel != nil else { return nil }
    return isExpanded ? "Shows less" : "Shows the full description"
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: WhirrSpacing.small) {
      Group {
        if layoutValues.axis == .vertical {
          VStack(alignment: .leading, spacing: WhirrSpacing.medium) {
            cover
            textContent
          }
        } else {
          HStack(alignment: .top, spacing: WhirrSpacing.medium) {
            cover
            textContent
          }
        }
      }
      .accessibilityElement(children: .combine)
      .accessibilityLabel(accessibilityLabel)
      .accessibilityAddTraits(isAccessibilityHeader ? .isHeader : [])

      synopsisContent
    }
  }

  /// The first three lines of the full blurb, cut from one layout so the rest continues exactly
  /// where it stops. Animating `lineLimit` instead cross-fades two differently truncated layouts.
  @ViewBuilder private var synopsisContent: some View {
    if let synopsisAccessibilityLabel {
      let isTruncated = PodcastShowSynopsisWindow.isTruncated(
        collapsedHeight: synopsisCollapsedHeight, fullHeight: synopsisFullHeight)
      PodcastShowSynopsisWindowView(synopsis: synopsisAccessibilityLabel, window: .head) {
        synopsisCollapsedHeight = $0
        synopsisFullHeight = $1
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .mask(alignment: .top) {
        synopsisFadeMask(fades: isTruncated && isSynopsisExpanded == false)
      }
      .contentShape(Rectangle())
      .onTapGesture {
        guard isTruncated else { return }
        withAnimation(Self.synopsisAnimation) { isSynopsisExpanded.toggle() }
      }
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(synopsisAccessibilityLabel)
      .accessibilityAddTraits(isTruncated ? .isButton : [])
      .accessibilityHint(isTruncated ? synopsisAccessibilityHint(isExpanded: isSynopsisExpanded) ?? "" : "")
    }
  }

  /// Collapsed and truncated, the end of the last line fades out where an ellipsis would sit;
  /// expanded, the mask is solid and the line runs on into the continuation below.
  private func synopsisFadeMask(fades: Bool) -> some View {
    let lineHeight = synopsisCollapsedHeight / CGFloat(Self.collapsedSynopsisLineLimit)
    return ZStack(alignment: .top) {
      VStack(spacing: 0) {
        Color.black.frame(height: max(synopsisCollapsedHeight - lineHeight, 0))
        HStack(spacing: 0) {
          Color.black
          LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
            .frame(width: Self.synopsisFadeWidth)
        }
        .frame(height: lineHeight)
        Spacer(minLength: 0)
      }
      Color.black.opacity(fades ? 0 : 1)
    }
  }

  private var textContent: some View {
    VStack(alignment: .leading, spacing: WhirrSpacing.xSmall) {
      HStack(alignment: .firstTextBaseline, spacing: WhirrSpacing.xSmall) {
        Text(title)
          .font(WhirrTypeToken.title.font)
          .fixedSize(horizontal: false, vertical: true)
          // Measured, not observed with `onScrollVisibilityChange`: in a `List` that event briefly
          // reports the title hidden while the header row re-sizes (the synopsis expanding), which
          // flashed the show's name into the bar. Geometry stays put through that re-layout.
          .onGeometryChange(for: Bool.self) { proxy in
            PodcastShowHeaderTitleVisibility.isVisible(
              titleFrame: proxy.frame(in: .local), scrollBounds: proxy.bounds(of: .scrollView))
          } action: {
            onTitleVisibilityChange?($0)
          }
        MediaKindBadgeView(kind: .podcast, label: badgeLabel)
      }
      if let subtitle, subtitle.isEmpty == false {
        Text(subtitle)
          .font(WhirrTypeToken.headline.font)
          .foregroundStyle(WashInk.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      if let sourceCaption, sourceCaption.isEmpty == false {
        // Not a `Label`: inside a `List` row it takes the list's icon column, which left a wide
        // gap after the glyph and hung a wrapped caption's second line off the text.
        HStack(alignment: .firstTextBaseline, spacing: Self.sourceCaptionGlyphSpacing) {
          Image(systemName: sourceCaptionSymbolName)
            .imageScale(.small)
            .accessibilityHidden(true)
          Text(sourceCaption)
            .fixedSize(horizontal: false, vertical: true)
        }
        .font(WhirrTypeToken.caption.font)
        .foregroundStyle(WashInk.secondary)
      }
    }
  }

  /// The fraction of the title that must be inside the scroll view for the header to still name
  /// the show.
  nonisolated public static var titleVisibilityThreshold: CGFloat {
    PodcastShowHeaderTitleVisibility.threshold
  }

  /// `scrollBounds` is the enclosing scroll view's bounds in the title's own space; `nil` outside
  /// a scroll view. A title not yet laid out counts as visible, so a bar never names the show
  /// before its header has had a chance to.
  nonisolated public static func isTitleVisible(titleFrame: CGRect, scrollBounds: CGRect?) -> Bool {
    PodcastShowHeaderTitleVisibility.isVisible(titleFrame: titleFrame, scrollBounds: scrollBounds)
  }

  nonisolated public static var synopsisAnimation: Animation { .snappy(duration: 0.3) }
  nonisolated static var synopsisFadeWidth: CGFloat { 72 }

  nonisolated public static var sourceCaptionGlyphSpacing: CGFloat { WhirrSpacing.xxSmall }
  /// Source glyphs say where the show is kept (this phone, or the server). They must not resemble
  /// the podcast badge beside the title, which says what kind of item it is.
  nonisolated public static var feedCaptionSymbolName: String { "iphone" }
  nonisolated public static var serverCaptionSymbolName: String { "server.rack" }
}

/// Non-generic so the geometry transform, which runs off the main actor, captures no `Cover`
/// metatype.
nonisolated enum PodcastShowHeaderTitleVisibility {
  static let threshold: CGFloat = 0.2

  static func isVisible(titleFrame: CGRect, scrollBounds: CGRect?) -> Bool {
    guard let scrollBounds, titleFrame.height > 0 else { return true }
    let shown = titleFrame.intersection(scrollBounds)
    guard shown.isNull == false else { return false }
    return shown.height / titleFrame.height >= threshold
  }
}
