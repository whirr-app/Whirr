import ABSApi
import AppModel
import Persistence
import SwiftUI

nonisolated enum HomeArtworkPrefetching {
  static func orderedIDs(for content: HomeViewPresentation.Section.Content) -> [String] {
    switch content {
    case .items(let items): items.map(\.serverItemId)
    case .podcastEpisodes(let episodes): episodes.map(\.itemID)
    case .savedEntries(let entries): entries.map(\.identity.itemID)
    case .listeningStats, .smartLists: []
    }
  }

  /// Keyed by item id, which entries in one shelf can share (several episodes of one RSS show).
  /// Duplicates are folded because `Dictionary(uniqueKeysWithValues:)` traps on a repeat; one show
  /// resolves to one artwork, so keeping the first loses nothing.
  static func sourcesByID(
    for content: HomeViewPresentation.Section.Content
  ) -> [String: ArtworkSource] {
    switch content {
    case .items(let items):
      Dictionary(
        items.compactMap { item in
          item.itemSummary.providerArtworkSource.map { (item.serverItemId, $0) }
        },
        uniquingKeysWith: { first, _ in first })
    case .podcastEpisodes(let episodes):
      Dictionary(
        episodes.compactMap { episode in
          episode.providerArtworkSource.map { (episode.itemID, $0) }
        },
        uniquingKeysWith: { first, _ in first })
    case .savedEntries(let entries):
      Dictionary(
        entries.compactMap { entry in
          let itemID = entry.identity.itemID
          let source =
            entry.episode?.providerArtworkSource
            ?? entry.itemSummary?.providerArtworkSource
          return source.map { (itemID, $0) }
        },
        uniquingKeysWith: { first, _ in first })
    case .listeningStats, .smartLists: [:]
    }
  }

  /// Folded like `sourcesByID`: every episode of a show draws the show's cover and so carries its
  /// revision.
  static func revisionsByID(
    for content: HomeViewPresentation.Section.Content
  ) -> [String: ArtworkRevision] {
    switch content {
    case .items(let items):
      Dictionary(
        items.map { ($0.serverItemId, $0.artworkRevision) }, uniquingKeysWith: { first, _ in first })
    case .podcastEpisodes(let episodes):
      Dictionary(
        episodes.map { ($0.itemID, $0.artworkRevision) }, uniquingKeysWith: { first, _ in first })
    case .savedEntries(let entries):
      Dictionary(
        entries.map { ($0.identity.itemID, $0.artworkRevision) },
        uniquingKeysWith: { first, _ in first })
    case .listeningStats, .smartLists: [:]
    }
  }
}

@MainActor
protocol HomeArtworkPrefetcher: AnyObject {
  func observe(
    visibleIndex: Int,
    orderedIDs: [String],
    displaySize: CGFloat,
    displayScale: CGFloat,
    client: any ArtworkServing,
    sourcesByID: [String: ArtworkSource],
    revisionsByID: [String: ArtworkRevision]
  )

  func cancel()
}

/// Keeps the Home shelf registry outside SwiftUI-observed value state while leaving the
/// directional prefetcher's request and cancellation behavior unchanged.
@MainActor
final class DirectionalArtworkPrefetcherAdapter: HomeArtworkPrefetcher {
  private let prefetcher: DirectionalArtworkPrefetcher

  init(artworkRole: DirectionalArtworkPrefetchRole) {
    prefetcher = DirectionalArtworkPrefetcher(artworkRole: artworkRole)
  }

  func observe(
    visibleIndex: Int,
    orderedIDs: [String],
    displaySize: CGFloat,
    displayScale: CGFloat,
    client: any ArtworkServing,
    sourcesByID: [String: ArtworkSource],
    revisionsByID: [String: ArtworkRevision]
  ) {
    prefetcher.observe(
      visibleIndex: visibleIndex,
      orderedIDs: orderedIDs,
      displaySize: displaySize,
      displayScale: displayScale,
      client: client,
      sourcesByID: sourcesByID,
      revisionsByID: revisionsByID)
  }

  func cancel() {
    prefetcher.cancel()
  }
}

@MainActor
final class HomeArtworkPrefetchController {
  typealias PrefetcherFactory = @MainActor () -> any HomeArtworkPrefetcher

  private let makePrefetcher: PrefetcherFactory
  private var prefetchers: [HomeMoreSection: any HomeArtworkPrefetcher] = [:]

  init(
    prefetcherFactory: @escaping PrefetcherFactory = {
      DirectionalArtworkPrefetcherAdapter(artworkRole: .homeCard)
    }
  ) {
    makePrefetcher = prefetcherFactory
  }

  func observe(
    section: HomeMoreSection,
    visibleIndex: Int,
    orderedIDs: [String],
    displaySize: CGFloat,
    displayScale: CGFloat,
    client: any ArtworkServing,
    sourcesByID: [String: ArtworkSource] = [:],
    revisionsByID: [String: ArtworkRevision]
  ) {
    let prefetcher: any HomeArtworkPrefetcher
    if let existing = prefetchers[section] {
      prefetcher = existing
    } else {
      let created = makePrefetcher()
      prefetchers[section] = created
      prefetcher = created
    }

    prefetcher.observe(
      visibleIndex: visibleIndex,
      orderedIDs: orderedIDs,
      displaySize: displaySize,
      displayScale: displayScale,
      client: client,
      sourcesByID: sourcesByID,
      revisionsByID: revisionsByID)
  }

  /// Clears every shelf prefetcher when the screen disappears, so a later appearance gets a fresh
  /// directional window and prefetch task.
  func cancelAll() {
    for prefetcher in prefetchers.values {
      prefetcher.cancel()
    }
    prefetchers.removeAll()
  }

  var retainedSectionCount: Int {
    prefetchers.count
  }
}
