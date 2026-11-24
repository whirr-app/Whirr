import ABSApi
import DesignSystem
import Persistence
import SwiftUI
import UIKit

extension CoverImageView {
  /// Waits between re-probes, each measured from the end of the previous attempt.
  ///
  /// `.unavailable` is about the item: only surfaces showing one cover at a time re-ask it, since
  /// a library grid would turn one scrolled-past screen of missing art into dozens of requests.
  ///
  /// `.failed` is about this attempt, so every surface retries (at most three times, backing off):
  /// its tile keeps the blank placeholder, so one timeout would leave it empty while materialised.
  ///
  /// A `seeded` `.unavailable` (a smaller rung is on screen) means the larger width was asked for
  /// before the server attached the cover, so it takes the `.failed` backoff everywhere.
  static func reprobeSchedule(
    for role: Role, outcome: ArtworkFetchOutcome, seeded: Bool = false
  ) -> [Duration] {
    switch outcome {
    case .image:
      []
    case .failed:
      [.seconds(2), .seconds(15), .seconds(60)]
    case .unavailable where seeded:
      [.seconds(2), .seconds(15), .seconds(60)]
    case .unavailable:
      switch role {
      case .libraryThumbnail:
        []
      case .homeCard, .highFidelity, .detail:
        [.seconds(30), .seconds(150)]
      }
    }
  }

  /// The artwork's aspect ratio for its glow: the image's own for a fitted cover, `nil` (the
  /// frame's) for a filled one.
  static func glowAspectRatio(presentation: Presentation, imageSize: CGSize) -> CGFloat? {
    guard presentation == .fitTransparent, imageSize.width > 0, imageSize.height > 0 else {
      return nil
    }
    return imageSize.width / imageSize.height
  }

  /// Prepared hits are already present on the first frame and should never animate in. A cold
  /// async completion gets the measured 200ms crossfade unless the listener requested reduced
  /// motion, in which case the replacement is immediate. A prompt completion is the third case:
  /// the bytes were already on disk, or another consumer filled the prepared cache between the
  /// body and the task, and a fade would only add 200ms to a wait too short to need softening.
  static func completionAnimation(
    isPreparedHit: Bool, isPromptCompletion: Bool, reduceMotion: Bool
  ) -> Animation? {
    guard isPreparedHit == false, isPromptCompletion == false, reduceMotion == false else {
      return nil
    }
    return .easeInOut(duration: 0.2)
  }

  /// How long a cover may take, from this view asking to the image arriving, and still land
  /// without a crossfade. Past it the blank placeholder has been seen, and the fade is what stops
  /// the arrival reading as a pop.
  static let promptCompletionWindow: Duration = .milliseconds(100)

  static func isPromptCompletion(elapsed: Duration) -> Bool {
    elapsed <= promptCompletionWindow
  }

  /// Prepared variants are display-ready and safe to reuse even when they are larger than the
  /// requested target. Unlike `ArtworkSeedLadder` (which governs compressed-byte probes for a
  /// high-fidelity request), this list is memory-only and serves the first frame of every role.
  static func preparedSeedKeys(
    for key: ArtworkKey, seedVariants: [ArtworkVariant]
  ) -> [ArtworkKey] {
    seedVariants.compactMap { variant in
      guard variant != key.variant else { return nil }
      return ArtworkKey(
        source: key.source,
        itemID: key.itemID,
        variant: variant,
        revision: key.revision)
    }
  }

  /// Returns whether pixels from `previousKey` can remain visible while `key` loads. A generated
  /// source is only a placeholder identity, so it may hand its pixels to a newly resolved real
  /// source when the item and artwork revision are unchanged.
  static func canRetainImage(from previousKey: ArtworkKey, for key: ArtworkKey) -> Bool {
    canReuseArtwork(from: previousKey, for: key)
  }

  /// Returns whether a seed from `previousKey` is still valid for `key`. It follows the same
  /// identity rule as retained artwork so a source resolution cannot blank an otherwise useful
  /// seed.
  static func canUseSeed(from previousKey: ArtworkKey, for key: ArtworkKey) -> Bool {
    canReuseArtwork(from: previousKey, for: key)
  }

  /// `.unavailable` is meaningful only for a real provider source. A generated source means the
  /// resolver has not supplied an artwork identity yet, so that outcome must not promote art.
  /// Nor may it when `seeded`: a smaller cached rung of the same identity proves the cover exists.
  static func shouldMarkMissing(
    for outcome: ArtworkFetchOutcome, key: ArtworkKey, seeded: Bool = false
  ) -> Bool {
    guard case .unavailable = outcome, seeded == false else { return false }
    if case .generated = key.source { return false }
    return true
  }

  /// The key for the fallback's cover (see `ArtworkKey.fallingBack(to:)`).
  static func fallbackKey(for key: ArtworkKey, fallbackSource: ArtworkSource?) -> ArtworkKey? {
    key.fallingBack(to: fallbackSource)
  }

  /// A primary that ended unavailable (no usable cover) or failed (this attempt could not reach it)
  /// draws the fallback in place of the generated cover or the blank; a failed one keeps being
  /// reprobed, and the real cover replaces the fallback when it arrives. A seed means a smaller
  /// rung of the primary is already on screen, which outranks the fallback.
  static func shouldDrawFallback(
    after outcome: ArtworkFetchOutcome, fallbackKey: ArtworkKey?, seeded: Bool
  ) -> Bool {
    guard fallbackKey != nil, seeded == false else { return false }
    switch outcome {
    case .image: return false
    case .unavailable, .failed: return true
    }
  }

  static func artworkKey(
    itemID: String,
    client: any ArtworkServing,
    source: ArtworkSource? = nil,
    displaySize: CGFloat,
    displayScale: CGFloat,
    role: Role,
    revision: ArtworkRevision
  ) -> ArtworkKey {
    let variant: ArtworkVariant =
      switch role {
      case .libraryThumbnail:
        .libraryThumbnail(displaySize: Double(displaySize), displayScale: displayScale)
      case .homeCard:
        .homeCard(displaySize: Double(displaySize), displayScale: displayScale)
      case .highFidelity:
        .highFidelity(displaySize: Double(displaySize), displayScale: displayScale)
      case .detail:
        DetailArtwork.variant(
          itemID: itemID, revision: revision, displayScale: Double(displayScale))
      }
    let resolvedSource: ArtworkSource? =
      if let source {
        source
      } else if PodcastSourceIdentity(itemId: itemID)?.rssFeedId != nil {
        .generated(ArtworkAccountScope("artwork:generated:rss"))
      } else {
        client.defaultSource
      }
    guard let resolvedSource else {
      preconditionFailure("ArtworkServing must provide a default source when none is explicit")
    }
    return ArtworkKey(
      source: resolvedSource,
      itemID: itemID,
      variant: variant,
      revision: revision)
  }

  private static func canReuseArtwork(from previousKey: ArtworkKey, for key: ArtworkKey) -> Bool {
    guard previousKey.itemID == key.itemID, previousKey.revision == key.revision else {
      return false
    }
    if previousKey.accountScope == key.accountScope { return true }

    // The generated scope carries no item identity; only its transition to a real source is safe.
    guard case .generated = previousKey.source else { return false }
    if case .generated = key.source { return false }
    return true
  }
}
