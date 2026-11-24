import ABSApi
import Persistence
import SwiftUI

nonisolated enum DirectionalPrefetchWindow {
  enum Direction {
    case forward
    case backward
  }

  static func candidates(
    orderedIDs: [String],
    visibleIndices: ClosedRange<Int>,
    direction: Direction,
    aheadCount: Int,
    behindCount: Int
  ) -> [String] {
    guard orderedIDs.isEmpty == false else { return [] }
    let lower = max(0, min(visibleIndices.lowerBound, orderedIDs.count - 1))
    let upper = max(lower, min(visibleIndices.upperBound, orderedIDs.count - 1))

    func ids(in range: Range<Int>) -> [String] {
      guard range.isEmpty == false else { return [] }
      return range.compactMap { orderedIDs.indices.contains($0) ? orderedIDs[$0] : nil }
    }

    switch direction {
    case .forward:
      let retained = ids(in: max(0, lower - behindCount)..<lower)
      let ahead = ids(in: min(orderedIDs.count, upper + 1)..<min(orderedIDs.count, upper + 1 + aheadCount))
      return retained + ahead
    case .backward:
      let ahead = ids(in: max(0, lower - aheadCount)..<lower)
      let retained = ids(
        in: min(orderedIDs.count, upper + 1)..<min(orderedIDs.count, upper + 1 + behindCount))
      return ahead + retained
    }
  }
}

nonisolated enum DirectionalArtworkPrefetchRole: Sendable {
  case libraryThumbnail
  case homeCard
  case highFidelity

  func variant(displaySize: Double, displayScale: Double) -> ArtworkVariant {
    switch self {
    case .libraryThumbnail:
      .libraryThumbnail(displaySize: displaySize, displayScale: displayScale)
    case .homeCard:
      .homeCard(displaySize: displaySize, displayScale: displayScale)
    case .highFidelity:
      .highFidelity(displaySize: displaySize, displayScale: displayScale)
    }
  }
}

@MainActor
final class DirectionalArtworkPrefetcher {
  private static let aheadCount = 12
  private static let behindCount = 3

  private let artworkRole: DirectionalArtworkPrefetchRole
  private var batchTask: Task<Void, Never>?
  private var candidateIDs: [String] = []
  private var previousVisibleIndex: Int?

  init(artworkRole: DirectionalArtworkPrefetchRole = .libraryThumbnail) {
    self.artworkRole = artworkRole
  }

  nonisolated static func artworkKey(
    source: ArtworkSource,
    itemID: String,
    displaySize: Double,
    displayScale: Double,
    artworkRole: DirectionalArtworkPrefetchRole = .libraryThumbnail,
    revision: ArtworkRevision
  ) -> ArtworkKey {
    ArtworkKey(
      source: source,
      itemID: itemID,
      variant: artworkRole.variant(displaySize: displaySize, displayScale: displayScale),
      revision: revision)
  }

  /// Collapses every tile in one grid row onto that row's leading index.
  ///
  /// `observe` early-returns only when the window (derived from `visibleIndex`) is unchanged, so a
  /// row's tiles with consecutive indices would restart the batch once per column, and
  /// cancelling drops the in-flight transfer if it was the last subscriber. Aligning makes one
  /// row one window.
  nonisolated static func rowAlignedIndex(_ index: Int, columns: Int) -> Int {
    guard index > 0 else { return 0 }
    guard columns > 1 else { return index }
    return index - index % columns
  }

  func observe(
    visibleIndex: Int,
    orderedIDs: [String],
    displaySize: CGFloat,
    displayScale: CGFloat,
    client: any ArtworkServing,
    sourcesByID: [String: ArtworkSource] = [:],
    revisionsByID: [String: ArtworkRevision]
  ) {
    let direction: DirectionalPrefetchWindow.Direction =
      if let previousVisibleIndex, visibleIndex < previousVisibleIndex { .backward } else { .forward }
    previousVisibleIndex = visibleIndex

    let candidates = DirectionalPrefetchWindow.candidates(
      orderedIDs: orderedIDs,
      visibleIndices: visibleIndex...visibleIndex,
      direction: direction,
      aheadCount: Self.aheadCount,
      behindCount: Self.behindCount)
    guard candidates != candidateIDs else { return }
    candidateIDs = candidates
    batchTask?.cancel()
    batchTask = Task {
      for itemID in candidates {
        guard Task.isCancelled == false else { return }
        if PodcastSourceIdentity(itemId: itemID)?.rssFeedId != nil, sourcesByID[itemID] == nil {
          continue
        }
        guard let source = sourcesByID[itemID] ?? client.defaultSource else { continue }
        let key = Self.artworkKey(
          source: source,
          itemID: itemID,
          displaySize: Double(displaySize),
          displayScale: Double(displayScale),
          artworkRole: artworkRole,
          revision: revisionsByID[itemID] ?? .unversioned)
        _ = await ArtworkImagePipeline.shared.image(
          for: key, priority: .scrollPrefetch, client: client)
      }
    }
  }

  func cancel() {
    batchTask?.cancel()
    batchTask = nil
    candidateIDs = []
    previousVisibleIndex = nil
  }
}
