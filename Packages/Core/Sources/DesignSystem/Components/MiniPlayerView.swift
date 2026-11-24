import SwiftUI

/// The two layouts a system `tabViewBottomAccessory` asks its content to support. The app maps
/// SwiftUI's `TabViewBottomAccessoryPlacement` environment value onto this platform-neutral value
/// so DesignSystem remains renderable and testable on its macOS package host.
public enum MiniPlayerLayout: Sendable, Equatable {
  /// The accessory sits above a full-size tab bar and has room for the audiobook skip controls.
  case expanded
  /// The accessory sits in line with a minimized tab bar. Match Apple Music's compact hierarchy:
  /// artwork, metadata, and the primary play/pause action only.
  case inline
}

/// The foreground contract for content hosted by the system's Liquid Glass bottom accessory.
/// A small value type, so the contract is testable while the view resolves it at render time.
public enum MiniPlayerForegroundStyle: Sendable, Equatable {
  case primary
  case secondary

  /// Semantic primary ink at this role's opacity, not a `HierarchicalShapeStyle`. The view
  /// resolves it under `contentColorScheme`, which the caller captures before crossing into the
  /// system-owned bottom-accessory host.
  public var color: Color {
    switch self {
    case .primary: .primary
    case .secondary: Color.primary.opacity(opacity)
    }
  }

  /// An explicit rung rather than system `.secondary`: the glass takes on the page behind it, and
  /// the system label falls below AA on both light and tinted glass.
  public var opacity: Double {
    switch self {
    case .primary: 1
    case .secondary: WhirrMetadataProminence.miniPlayerSubtitle.opacity
    }
  }
}

/// The persistent mini-player: cover slot, title/subtitle, a play/pause control, and a progress
/// value. Stateless and driven entirely by caller-supplied data (DesignSystem owns no playback
/// logic or copy, per ARCHITECTURE.md). Its system `tabViewBottomAccessory` host owns the Liquid
/// Glass surface; this view supplies content only, avoiding glass nested inside glass.
///
/// `Accessory` is an optional caller-owned cluster between the title column and the transport,
/// in the expanded layout only (the phone bar has no space for it).
public struct MiniPlayerView<Cover: View, Accessory: View>: View {
  public let title: String
  public let subtitle: String
  /// Optional status glyph supplied by the caller. DesignSystem renders it but does not decide
  /// what playback state it represents or provide its copy.
  public let subtitleSystemImage: String?
  public let isPlaying: Bool
  public let playPauseAccessibilityLabel: String
  public let skipBackAccessibilityLabel: String
  public let skipBackAccessibilityHint: String
  public let skipBackSystemImage: String
  public let skipForwardAccessibilityLabel: String
  public let skipForwardAccessibilityHint: String
  public let skipForwardSystemImage: String
  /// Resolved by a small modifier around the info target, not by the parent body. Lazy so a caller
  /// can read a high-frequency playhead for VoiceOver without the visible artwork and transport
  /// depending on every position tick.
  public let progressAccessibilityValue: () -> String
  public let expandAccessibilityHint: String
  /// Cover accessibility alternative. `nil` means the cover is redundant with the adjacent
  /// title/subtitle and is hidden from accessibility (as `CoverPlaceholder` does); a non-nil
  /// value is announced on its own.
  public let coverAccessibilityLabel: String?
  public let layout: MiniPlayerLayout
  /// The widest the row may draw, or `nil` for the offered width. The system bottom accessory
  /// sizes its glass to its content, so this stops a regular-width host stretching a 44pt cover
  /// and transport cluster across an iPad window. Centred in the offered width when capped.
  public let contentMaxWidth: CGFloat?
  /// Whether an overflowing title scrolls. A presentation input, not playback state.
  public let isTitleMarqueeActive: Bool
  /// The presenting shell's resolved appearance. `tabViewBottomAccessory` renders its closure in a
  /// system-owned vibrancy host, so `colorScheme` read inside it can disagree with the glass.
  public let contentColorScheme: ColorScheme
  /// Disables the play/pause and skip controls (e.g. while no item is loaded) without touching
  /// the tap-to-expand target, which stays reachable.
  public let isTransportEnabled: Bool
  public let onPlayPauseTap: () -> Void
  public let onSkipBackTap: () -> Void
  public let onSkipForwardTap: () -> Void
  public let onExpandTap: () -> Void

  let cover: Cover
  let accessory: Accessory

  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  /// Fixed regardless of Dynamic Type so the control never shrinks below the HIG minimum.
  public let playPauseButtonSize: CGFloat = PlayerMetric.miniPlayerPlayPauseSize
  /// Content owns its semantic foregrounds; `contentColorScheme` anchors their resolution to the
  /// app appearance instead of the system accessory host's transient vibrancy environment.
  public let contentForegroundStyle: MiniPlayerForegroundStyle = .primary
  /// The subtitle's demoted role.
  public let subtitleForegroundStyle: MiniPlayerForegroundStyle = .secondary
  /// Skip-back/skip-forward hit target, the same minimum as the play/pause control.
  public let skipButtonSize: CGFloat = PlayerMetric.miniPlayerPlayPauseSize
  /// The three transport controls sit edge to edge. Each glyph is centred in a 44pt target, so
  /// even at zero spacing the symbols are over 20pt apart, and any row spacing would come out of
  /// the title column, the tightest in the row.
  public let transportSpacing: CGFloat = 0
  /// Minimum height of the tap-to-expand region.
  /// See `PlayerMetric.miniPlayerExpandTargetMinHeight`.
  public let expandTargetMinHeight: CGFloat = PlayerMetric.miniPlayerExpandTargetMinHeight

  /// VoiceOver reads the info region (title/subtitle/progress, also the expand target), then
  /// skip-back, play/pause, skip-forward: the visual left-to-right order. Pure `Double`s so the
  /// order is testable without a renderer.
  public let infoSortPriority: Double = 3
  /// Between the info region and skip-back, matching where the accessory cluster is drawn.
  public let accessorySortPriority: Double = 2.5
  public let skipBackSortPriority: Double = 2
  public let playPauseSortPriority: Double = 1
  public let skipForwardSortPriority: Double = 0

  public var showsSkipControls: Bool {
    layout == .expanded
  }

  /// The inline layout sits beside a minimized tab bar and keeps Apple Music's artwork, metadata,
  /// and play/pause hierarchy, so the accessory cluster drops out with the skip controls.
  public var showsAccessory: Bool {
    layout == .expanded
  }

  /// Whether the title is handed to a scrolling single line. Accessibility Dynamic Type sizes
  /// keep the plain one-line label: `MarqueeText` wraps to two lines at those sizes, and the
  /// bottom accessory sizes its content to a single title line in both layouts. Reduce Motion
  /// needs no branch here, since `MarqueeText` at rest is one truncated line.
  public static func usesTitleMarquee(isAccessibilitySize: Bool) -> Bool {
    isAccessibilitySize == false
  }

  /// The info region is one spoken element even when the visible subtitle has a decorative status
  /// glyph beside it.
  public var combinedAccessibilityLabel: String {
    "\(title), \(subtitle)"
  }

  public init(
    title: String,
    subtitle: String,
    subtitleSystemImage: String? = nil,
    isPlaying: Bool,
    playPauseAccessibilityLabel: String,
    skipBackAccessibilityLabel: String,
    skipBackAccessibilityHint: String,
    skipBackSystemImage: String,
    skipForwardAccessibilityLabel: String,
    skipForwardAccessibilityHint: String,
    skipForwardSystemImage: String,
    progressAccessibilityValue: @escaping () -> String,
    expandAccessibilityHint: String,
    coverAccessibilityLabel: String?,
    layout: MiniPlayerLayout = .expanded,
    contentMaxWidth: CGFloat? = nil,
    isTitleMarqueeActive: Bool = false,
    contentColorScheme: ColorScheme,
    isTransportEnabled: Bool = true,
    @ViewBuilder cover: () -> Cover,
    @ViewBuilder accessory: () -> Accessory,
    onPlayPauseTap: @escaping () -> Void,
    onSkipBackTap: @escaping () -> Void,
    onSkipForwardTap: @escaping () -> Void,
    onExpandTap: @escaping () -> Void
  ) {
    self.title = title
    self.subtitle = subtitle
    self.subtitleSystemImage = subtitleSystemImage
    self.isPlaying = isPlaying
    self.playPauseAccessibilityLabel = playPauseAccessibilityLabel
    self.skipBackAccessibilityLabel = skipBackAccessibilityLabel
    self.skipBackAccessibilityHint = skipBackAccessibilityHint
    self.skipBackSystemImage = skipBackSystemImage
    self.skipForwardAccessibilityLabel = skipForwardAccessibilityLabel
    self.skipForwardAccessibilityHint = skipForwardAccessibilityHint
    self.skipForwardSystemImage = skipForwardSystemImage
    self.progressAccessibilityValue = progressAccessibilityValue
    self.expandAccessibilityHint = expandAccessibilityHint
    self.coverAccessibilityLabel = coverAccessibilityLabel
    self.layout = layout
    self.contentMaxWidth = contentMaxWidth
    self.isTitleMarqueeActive = isTitleMarqueeActive
    self.contentColorScheme = contentColorScheme
    self.isTransportEnabled = isTransportEnabled
    self.cover = cover()
    self.accessory = accessory()
    self.onPlayPauseTap = onPlayPauseTap
    self.onSkipBackTap = onSkipBackTap
    self.onSkipForwardTap = onSkipForwardTap
    self.onExpandTap = onExpandTap
  }

  public var body: some View {
    HStack(spacing: WhirrSpacing.small) {
      Button(action: onExpandTap) {
        HStack(spacing: WhirrSpacing.small) {
          cover
            .frame(width: PlayerMetric.miniPlayerCoverSize, height: PlayerMetric.miniPlayerCoverSize)
            .clipShape(RoundedRectangle(cornerRadius: WhirrSpacing.xSmall, style: .continuous))
            .overlay {
              RoundedRectangle(cornerRadius: WhirrSpacing.xSmall, style: .continuous)
                .stroke(.white.opacity(0.14), lineWidth: 0.5)
            }
            .modifier(MiniPlayerCoverAccessibility(label: coverAccessibilityLabel))

          VStack(alignment: .leading, spacing: WhirrSpacing.xxSmall) {
            if Self.usesTitleMarquee(isAccessibilitySize: dynamicTypeSize.isAccessibilitySize) {
              MarqueeText(
                title, font: WhirrTypeToken.headline.font,
                isActive: isTitleMarqueeActive, alignment: .leading)
            } else {
              Text(title)
                .font(WhirrTypeToken.headline.font)
                .lineLimit(1)
            }
            HStack(spacing: WhirrSpacing.xxSmall) {
              if let subtitleSystemImage {
                Image(systemName: subtitleSystemImage)
                  .accessibilityHidden(true)
              }
              Text(subtitle)
                .lineLimit(1)
            }
            // On the row rather than the label so a status glyph matches the words beside it.
            .font(WhirrTypeToken.caption.font)
            .foregroundStyle(subtitleForegroundStyle.color)
          }
          .frame(maxWidth: .infinity, alignment: .leading)
        }
        // The artwork and every spare point before transport form one rectangular expand target,
        // larger and more predictable than making only the text glyphs live.
        .frame(maxWidth: .infinity, minHeight: expandTargetMinHeight, alignment: .leading)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityElement(children: .combine)
      .accessibilityLabel(combinedAccessibilityLabel)
      .modifier(MiniPlayerProgressAccessibility(value: progressAccessibilityValue))
      .accessibilityHint(expandAccessibilityHint)
      .accessibilitySortPriority(infoSortPriority)

      if showsAccessory {
        accessory
          .accessibilityElement(children: .contain)
          .accessibilitySortPriority(accessorySortPriority)
      }

      HStack(spacing: transportSpacing) {
        if showsSkipControls {
          Button(action: onSkipBackTap) {
            Image(systemName: skipBackSystemImage)
              .frame(width: skipButtonSize, height: skipButtonSize)
              .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .accessibilityLabel(skipBackAccessibilityLabel)
          .accessibilityHint(skipBackAccessibilityHint)
          .accessibilitySortPriority(skipBackSortPriority)
          .disabled(!isTransportEnabled)
        }

        Button(action: onPlayPauseTap) {
          Image(systemName: isPlaying ? "pause.fill" : "play.fill")
            // Same glyph swap as the expanded player's transport, so the two read as one control.
            .contentTransition(
              reduceMotion
                ? .identity
                : .symbolEffect(
                  .replace, options: .speed(PlayerMetric.transportSymbolTransitionSpeed))
            )
            .frame(width: playPauseButtonSize, height: playPauseButtonSize)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(reduceMotion ? nil : PlayerMetric.transportIntentAnimation, value: isPlaying)
        .accessibilityLabel(playPauseAccessibilityLabel)
        .accessibilitySortPriority(playPauseSortPriority)
        .disabled(!isTransportEnabled)

        if showsSkipControls {
          Button(action: onSkipForwardTap) {
            Image(systemName: skipForwardSystemImage)
              .frame(width: skipButtonSize, height: skipButtonSize)
              .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .accessibilityLabel(skipForwardAccessibilityLabel)
          .accessibilityHint(skipForwardAccessibilityHint)
          .accessibilitySortPriority(skipForwardSortPriority)
          .disabled(!isTransportEnabled)
        }
      }
    }
    .padding(.horizontal, WhirrSpacing.small)
    .padding(.vertical, WhirrSpacing.xxSmall)
    .frame(maxWidth: contentMaxWidth ?? .infinity)
    .foregroundStyle(contentForegroundStyle.color)
    // A direct environment override stops at this content hierarchy. `preferredColorScheme` would
    // push upward and repaint the enclosing system presentation.
    .environment(\.colorScheme, contentColorScheme)
  }
}

extension MiniPlayerView where Accessory == EmptyView {
  /// The bar with no accessory cluster: the phone bar, and every host that does not offer one.
  public init(
    title: String,
    subtitle: String,
    subtitleSystemImage: String? = nil,
    isPlaying: Bool,
    playPauseAccessibilityLabel: String,
    skipBackAccessibilityLabel: String,
    skipBackAccessibilityHint: String,
    skipBackSystemImage: String,
    skipForwardAccessibilityLabel: String,
    skipForwardAccessibilityHint: String,
    skipForwardSystemImage: String,
    progressAccessibilityValue: @escaping () -> String,
    expandAccessibilityHint: String,
    coverAccessibilityLabel: String?,
    layout: MiniPlayerLayout = .expanded,
    contentMaxWidth: CGFloat? = nil,
    isTitleMarqueeActive: Bool = false,
    contentColorScheme: ColorScheme,
    isTransportEnabled: Bool = true,
    @ViewBuilder cover: () -> Cover,
    onPlayPauseTap: @escaping () -> Void,
    onSkipBackTap: @escaping () -> Void,
    onSkipForwardTap: @escaping () -> Void,
    onExpandTap: @escaping () -> Void
  ) {
    self.init(
      title: title, subtitle: subtitle, subtitleSystemImage: subtitleSystemImage,
      isPlaying: isPlaying, playPauseAccessibilityLabel: playPauseAccessibilityLabel,
      skipBackAccessibilityLabel: skipBackAccessibilityLabel,
      skipBackAccessibilityHint: skipBackAccessibilityHint,
      skipBackSystemImage: skipBackSystemImage,
      skipForwardAccessibilityLabel: skipForwardAccessibilityLabel,
      skipForwardAccessibilityHint: skipForwardAccessibilityHint,
      skipForwardSystemImage: skipForwardSystemImage,
      progressAccessibilityValue: progressAccessibilityValue,
      expandAccessibilityHint: expandAccessibilityHint,
      coverAccessibilityLabel: coverAccessibilityLabel, layout: layout,
      contentMaxWidth: contentMaxWidth, isTitleMarqueeActive: isTitleMarqueeActive,
      contentColorScheme: contentColorScheme, isTransportEnabled: isTransportEnabled,
      cover: cover, accessory: { EmptyView() }, onPlayPauseTap: onPlayPauseTap,
      onSkipBackTap: onSkipBackTap, onSkipForwardTap: onSkipForwardTap, onExpandTap: onExpandTap)
  }
}

/// The observation boundary for the mini-player's spoken progress. SwiftUI tracks reads in this
/// modifier's body separately from `MiniPlayerView.body`, so a live playhead update only
/// refreshes the accessibility value on the info target.
private struct MiniPlayerProgressAccessibility: ViewModifier {
  let value: () -> String

  func body(content: Content) -> some View {
    content.accessibilityValue(value())
  }
}

private struct MiniPlayerCoverAccessibility: ViewModifier {
  let label: String?

  func body(content: Content) -> some View {
    if let label {
      content.accessibilityLabel(label)
    } else {
      content.accessibilityHidden(true)
    }
  }
}
