import ABSApi
import Foundation
import Persistence

/// What the phone's library says about one Audiobookshelf title it may send to the Watch: the two
/// lines an offer and a row show, and the size it knows. Every read is local; nothing
/// here reaches the server.
struct ABSWatchTitleFacts: Equatable, Sendable {
  let title: String
  /// The author of a book, or the show of an episode.
  let subtitle: String?
  /// Nil when the phone does not know it, and then a send never asks first.
  let declaredBytes: Int64?
}

/// An Audiobookshelf item's cover as the shared artwork pipeline keys it.
struct ABSWatchArtwork: Equatable, Sendable {
  let source: ArtworkSource?
  let revision: ArtworkRevision
}

/// A send the listener is asked about first.
struct ABSWatchOversizedSend: Equatable, Sendable {
  let declaredBytes: Int64
  let freeBytes: Int64
}

/// Reads `ABSWatchTitleFacts` from the bound account's library. A title the library no longer
/// holds, as a Watch-origin download of a pruned item can be, gets a placeholder rather than no row.
@MainActor
struct ABSWatchTitleResolver {
  var book: @MainActor (_ itemID: String) -> ItemSummary?
  var episode: @MainActor (_ itemID: String, _ episodeID: String) async -> PodcastEpisodeContext?

  init(
    book: @escaping @MainActor (_ itemID: String) -> ItemSummary?,
    episode: @escaping @MainActor (_ itemID: String, _ episodeID: String) async -> PodcastEpisodeContext?
  ) {
    self.book = book
    self.episode = episode
  }

  init(library: any LibraryReading, podcasts: any PodcastReading) {
    self.init(
      book: { library.currentItemDetail(itemId: $0) },
      episode: { itemID, episodeID in try? await podcasts.episode(itemID: itemID, episodeID: episodeID) })
  }

  /// The facts for a title the library holds, or nil when it holds none.
  func facts(_ key: ABSWatchCopyKey) async -> ABSWatchTitleFacts? {
    if let episodeID = key.episodeId {
      guard let context = await episode(key.itemId, episodeID) else { return nil }
      return ABSWatchTitleFacts(
        title: Self.nonEmpty(context.episode.title) ?? "Episode",
        subtitle: Self.nonEmpty(context.showTitle),
        declaredBytes: context.episode.sizeBytes.flatMap(Self.positive))
    }
    return bookFacts(key.itemId)
  }

  /// A book's facts, read synchronously from the local cache, as a presented menu reads them.
  func bookFacts(_ itemID: String) -> ABSWatchTitleFacts? {
    guard let item = book(itemID) else { return nil }
    return ABSWatchTitleFacts(
      title: Self.nonEmpty(item.title) ?? "Audiobook",
      subtitle: item.author.flatMap(Self.nonEmpty),
      declaredBytes: item.audioDownloadExpectedBytes.flatMap { Self.positive(Int($0)) })
  }

  /// The cover of a book or of an episode's show: both are library items.
  func artwork(itemID: String) -> ABSWatchArtwork? {
    guard let item = book(itemID) else { return nil }
    return ABSWatchArtwork(source: item.providerArtworkSource, revision: item.artworkRevision)
  }

  /// The facts, or a placeholder naming only the kind of title.
  func titles(_ key: ABSWatchCopyKey) async -> ABSWatchTitleFacts {
    await facts(key)
      ?? ABSWatchTitleFacts(
        title: key.episodeId == nil ? "Audiobook" : "Episode", subtitle: nil, declaredBytes: nil)
  }

  private static func nonEmpty(_ value: String) -> String? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  private static func positive(_ value: Int) -> Int64? {
    value > 0 ? Int64(value) : nil
  }
}
