import ABSApi
import AppModel
import DesignSystem
import SwiftUI

/// Playback-state ownership stays in this leaf so a play/pause transition updates the artwork,
/// not the full ambient player hierarchy. The reserved frame never changes: only the rendered
/// cover recedes, so metadata and transport controls remain still under the listener's fingers.
struct ExpandedPlayerArtwork: View {
  let itemID: String
  let title: String
  let coverSize: CGFloat
  let coverClient: any ArtworkServing
  let source: ArtworkSource?
  var fallbackSource: ArtworkSource? = nil
  let revision: ArtworkRevision
  let playback: PlaybackModel
  /// The page's ink, which the edge rim is drawn in: the drop shadow vanishes on a dark page, so
  /// the rim separates there.
  let ink: Color

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.displayScale) private var displayScale
  /// What the cover last drew, for the collapse's cover flight once the prepared cache has
  /// dropped it. Unobserved, so the cover recording a draw never re-evaluates this body.
  @State private var drawnCover = DrawnArtwork()

  var body: some View {
    let isPlaybackIntended = playback.isPlaybackIntended(for: itemID)
    let emphasis = ExpandedPlayerPresentation.artworkEmphasis(
      isPlaybackIntended: isPlaybackIntended)
    let stateAnimation: Animation? =
      reduceMotion ? nil : .spring(response: 0.42, dampingFraction: 0.86)

    // Follows the frame, so the cover shrinking into the Up Next header keeps its proportions.
    let cornerRadius = InlineUpNextPresentation.artworkCornerRadius(coverSize: coverSize)

    CoverImageView(
      itemID: itemID,
      title: title,
      // The cap, not `coverSize`: see `artworkRequestSize`. `displaySize` keys the cache and
      // sizes the decode; the `.frame` below is what sets the layout.
      displaySize: ExpandedPlayerView.artworkRequestSize,
      client: coverClient,
      source: source,
      fallbackSource: fallbackSource,
      role: .highFidelity,
      revision: revision,
      drawnArtwork: drawnCover
    )
    .frame(width: coverSize, height: coverSize)
    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        .stroke(ink.opacity(0.12), lineWidth: 0.5)
    }
    // Inside the scale effect, so the morph's flying cover starts from the cover as drawn: 0.92
    // of its frame when paused. The key is the one `CoverImageView` above reads the cache with.
    .playerMorphAnchor(.pageCover, drawnCover: drawnCover) { [itemID, coverClient, source, revision, displayScale] in
      CoverImageView.artworkKey(
        itemID: itemID, client: coverClient, source: source,
        displaySize: ExpandedPlayerView.artworkRequestSize, displayScale: displayScale,
        role: .highFidelity, revision: revision)
    }
    .scaleEffect(emphasis.scale)
    .playerMorphCoverShadow(emphasis)
    // Shadow included: the flying copy carries none. After an open the cover returns at once and
    // its shadow fades in (`isCoverShadowHeld`).
    .playerMorphHidesDuringCoverFlight()
    .animation(stateAnimation, value: isPlaybackIntended)
    .accessibilityIdentifier(PlayerAccessibilityID.expandedCover)
    .accessibilityLabel("Cover art for \(title)")
  }
}
