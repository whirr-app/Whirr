import ABSApi
import AppModel
import DesignSystem
import Persistence
import SwiftUI
import SyncEngine

struct ItemDetailScrollContentView: View {
  let item: ItemSummary
  let coverClient: any ArtworkServing
  let paletteService: CoverPaletteService
  let ambientCanvas: AmbientCanvas
  let playback: PlaybackModel
  let extrasModel: ItemDetailExtrasModel
  let readAffordance: ReadAffordanceState
  let readAffordanceCopy: String?
  let actionLayout: ItemDetailActionLayout
  let isFinished: Bool
  let displayScale: CGFloat
  let reduceMotion: Bool
  let onPresentReader: (String, String, ItemMediaCategory) -> Void
  let onPresentChapters: () -> Void
  let supplements: [ItemSupplement]
  let isOffline: Bool
  let onPresentSupplements: () -> Void
  let onOpenMetadata: (ItemMetadataLink) -> Void
  @Binding var metadataLayout: ItemDetailMetadataLayout?
  @Binding var isInlineTitleRevealed: Bool

  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @Environment(\.horizontalSizeClass) private var horizontalSizeClass
  @State private var availableWidth: CGFloat?
  @State private var measuredHeroHeight: CGFloat?

  /// The resolved canvas's primary action fill and its legible ink. The dark-safe fallback canvas
  /// owns the unresolved state, so this stays valid while artwork analysis is still in flight.
  private var accentFill: WhirrAccentPair {
    ambientCanvas.primaryAction
  }

  var body: some View {
    let initialLayout = metadataLayout ?? ItemDetailMetadataLayout(item: item)
    let presentation = ItemDetailLayoutPresentation.resolve(
      horizontalSizeClass: horizontalSizeClass,
      isAccessibilitySize: dynamicTypeSize.isAccessibilitySize,
      availableWidth: availableWidth,
      measuredHeroHeight: measuredHeroHeight)
    return ScrollView {
      VStack(alignment: .leading, spacing: WhirrSpacing.large) {
        readingMeasured(
          ItemDetailHeroView(
            item: item,
            coverClient: coverClient,
            paletteService: paletteService,
            playback: playback,
            displayScale: displayScale,
            reduceMotion: reduceMotion,
            isFinished: isFinished,
            metadataLayout: metadataLayout,
            heroLayout: presentation.hero,
            readAffordance: readAffordance,
            onOpenMetadata: onOpenMetadata),
          cap: presentation.readableWidth
        )
        .onGeometryChange(for: CGFloat.self) {
          $0.size.height
        } action: {
          measuredHeroHeight = $0.isFinite && $0 > 0 ? $0 : nil
        }

        ItemDetailActionRow(
          item: item,
          playback: playback,
          isFinished: isFinished,
          readAffordance: readAffordance,
          actionLayout: actionLayout,
          accentFill: accentFill,
          onPresentReader: onPresentReader,
          onPresentChapters: onPresentChapters
        )
        // This is the only width ceiling applied to the action row. The row still decides
        // whether its controls are horizontal or accessibility-stacked.
        .frame(maxWidth: presentation.actionWidth)
        .frame(maxWidth: .infinity, alignment: .center)

        // Aligned with the action row above it, not the blurb's narrower measure.
        if supplements.isEmpty == false {
          ItemDetailSupplementRow(
            supplements: supplements, isOffline: isOffline, onOpen: onPresentSupplements
          )
          .frame(maxWidth: presentation.actionWidth)
          .frame(maxWidth: .infinity, alignment: .center)
        }

        ItemDetailReaderAffordanceNotice(
          readAffordance: readAffordance, readAffordanceCopy: readAffordanceCopy)
        readingMeasured(
          ItemDetailBlurbView(item: item, extrasModel: extrasModel),
          cap: presentation.readableWidth)
        readingMeasured(
          ItemDetailDetailsSection(item: item),
          cap: presentation.readableWidth)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, WhirrSpacing.large)
      .padding(.vertical, WhirrSpacing.large)
      // Only a report that could be a pane is kept. `ItemDetailLayoutPresentation` applies the
      // same floor, but it cannot un-latch a bad value once it is in this state: a transient pass
      // would otherwise sit here squeezing the action row until some later layout displaced it.
      .onGeometryChange(for: CGFloat.self) {
        max(0, $0.size.width - 2 * WhirrSpacing.large)
      } action: {
        guard $0 >= ItemDetailLayoutPresentation.minimumMeasuredWidth else { return }
        availableWidth = $0
      }
    }
    .background {
      ItemDetailAmbientBackground(canvas: ambientCanvas)
    }
    .onScrollGeometryChange(for: Bool.self) { geometry in
      presentation.shouldRevealInlineTitle(at: geometry.contentOffset.y)
    } action: { _, isPastHero in
      isInlineTitleRevealed = isPastHero
    }
    .primaryScrollEdgeEffect()
    .onAppear {
      if metadataLayout == nil {
        metadataLayout = initialLayout
      }
    }
  }

  /// Every block is capped at its own measure and centred in the pane. The hero is a centred
  /// stack, so its own centre line is the page's, and prose and controls hang from the same one.
  private func readingMeasured<Content: View>(
    _ content: Content,
    cap: CGFloat
  ) -> some View {
    content
      .frame(maxWidth: cap)
      .frame(maxWidth: .infinity, alignment: .center)
  }
}

/// The blurb, always visible in the page flow.
///
/// Takes the shared prominence ladder through `adaptiveStyle`, not its own colour token: the
/// page's lightness bands are solved so `WhirrMetadataProminence.floor` clears AA at every hue,
/// and nothing checks a foreground off the ladder.
private struct ItemDetailBlurbView: View {
  let item: ItemSummary
  let extrasModel: ItemDetailExtrasModel

  @State private var isExpanded = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  private var description: String? {
    switch extrasModel.state {
    case .loading, .unavailable:
      return ItemDetailAboutPresentation.trimmed(item.itemDescription)
    case .loaded(let extras):
      return ItemDetailAboutPresentation.trimmed(extras.description)
        ?? ItemDetailAboutPresentation.trimmed(item.itemDescription)
    }
  }

  @ViewBuilder
  var body: some View {
    if let description {
      // The whole blurb is the control, not just the word under it: a paragraph the reader is
      // already looking at is a far better target than a caption-sized label, and reaching for
      // that label is the one interaction on this page that asks for precision. The word stays,
      // because without it nothing says the paragraph can be opened at all.
      Button {
        withAnimation(ItemDetailBlurbPresentation.motion(reduceMotion: reduceMotion)) {
          isExpanded.toggle()
        }
      } label: {
        VStack(alignment: .leading, spacing: WhirrSpacing.xSmall) {
          Text(description)
            .font(WhirrTypeToken.body.font)
            .foregroundStyle(WhirrMetadataProminence.secondary.adaptiveStyle)
            .lineLimit(ItemDetailBlurbPresentation.lineLimit(isExpanded: isExpanded))
            .fixedSize(horizontal: false, vertical: true)
            // Top-anchored and clipped so the paragraph is wiped in and out by the growing box
            // instead of sliding within it: the text is laid out at its final position on the
            // first frame, and only how much of it is visible changes.
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .clipped()

          Text(ItemDetailBlurbPresentation.toggleLabel(isExpanded: isExpanded))
            .font(WhirrTypeToken.caption.font.weight(.semibold))
            // The screen's tint, read through the environment rather than named, so the word keeps
            // the accent the plain button style would otherwise drop.
            .foregroundStyle(.tint)
            .contentTransition(.opacity)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // The gap between the paragraph and the word has no background of its own, so without this
        // the target would be the two texts and a dead strip between them.
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityIdentifier(ItemDetailDetailsAccessibilityID.description)
      .accessibilityHint(ItemDetailBlurbPresentation.toggleHint(isExpanded: isExpanded))
    }
  }
}

/// A flat background that changes with its text and controls, with no separate colour animation.
private struct ItemDetailAmbientBackground: View {
  let canvas: AmbientCanvas

  var body: some View {
    canvas.background
      .ignoresSafeArea()
  }
}

private struct ItemDetailReaderAffordanceNotice: View {
  let readAffordance: ReadAffordanceState
  let readAffordanceCopy: String?

  @ViewBuilder
  var body: some View {
    switch readAffordance {
    case .advertisedButUnavailable, .downloading, .protected:
      if let copy = readAffordanceCopy {
        Text(copy)
          .font(WhirrTypeToken.caption.font)
          // On the ladder for the same reason as the blurb: this notice sits on the ambient page,
          // and only the ladder's rungs have a contrast guarantee against it.
          .foregroundStyle(WhirrMetadataProminence.tertiary.adaptiveStyle)
          .multilineTextAlignment(.center)
          .frame(maxWidth: .infinity)
          .accessibilityIdentifier(ItemDetailReaderAccessibilityID.notice)
      }
    case .none, .read, .continueReading:
      EmptyView()
    }
  }
}
