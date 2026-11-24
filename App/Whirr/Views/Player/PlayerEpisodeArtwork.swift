import ABSApi
import Foundation
import Observation
import Persistence
import SwiftUI

/// The image the playing RSS episode declares, observed once for the bar and the page. A playback
/// bookmark carries no episode image, so this is how a cold launch, or any open with no seed,
/// learns it; observing means a refresh that adds one reaches a player already on screen. Until a
/// value arrives the players draw the show's cover.
///
/// Both players ask about the identity they show, so each is followed under its own key; only a
/// few are kept at once, oldest first out.
@MainActor @Observable
final class PlayerEpisodeArtwork {
  nonisolated struct Key: Hashable, Sendable {
    let itemID: String
    let episodeID: String
  }

  private static let capacity = 4

  private(set) var urls: [Key: URL] = [:]
  @ObservationIgnored private var tasks: [Key: Task<Void, Never>] = [:]
  @ObservationIgnored private var order: [Key] = []
  @ObservationIgnored private let reading: any RSSEpisodeArtworkReading

  init(reading: any RSSEpisodeArtworkReading) {
    self.reading = reading
  }

  /// Starts following `episodeID` of `itemID`. Idempotent; ignores anything that is not an RSS
  /// episode.
  func track(itemID: String, episodeID: String?) {
    guard let episodeID, let feedID = PodcastSourceIdentity(itemId: itemID)?.rssFeedId else {
      return
    }
    let key = Key(itemID: itemID, episodeID: episodeID)
    guard tasks[key] == nil else { return }
    if order.count >= Self.capacity, let oldest = order.first { forget(oldest) }
    order.append(key)
    tasks[key] = Task { [weak self, reading] in
      for await url in reading.observeEpisodeArtworkURL(feedId: feedID, identityKey: episodeID) {
        guard Task.isCancelled == false else { break }
        self?.apply(url, for: key)
      }
    }
  }

  /// The episode's own image under its show's feed identity, or nil while unanswered, when the
  /// episode declares none, and for an item that is not an RSS episode.
  func source(itemID: String, episodeID: String?, feedURL: URL?) -> ArtworkSource? {
    guard let episodeID else { return nil }
    return makeEpisodeArtworkSource(
      itemID: itemID, episodeArtworkURL: urls[Key(itemID: itemID, episodeID: episodeID)],
      artworkFeedURL: feedURL)
  }

  func apply(_ url: URL?, for key: Key) {
    guard tasks[key] != nil, urls[key] != url else { return }
    urls[key] = url
  }

  private func forget(_ key: Key) {
    tasks.removeValue(forKey: key)?.cancel()
    order.removeAll { $0 == key }
    urls.removeValue(forKey: key)
  }

  isolated deinit {
    for task in tasks.values { task.cancel() }
  }
}

extension View {
  /// Has `episodeArtwork` follow the episode this surface shows, again whenever it changes.
  func tracksEpisodeArtwork(
    _ episodeArtwork: PlayerEpisodeArtwork?, itemID: String, episodeID: String?
  ) -> some View {
    task(id: PlayerEpisodeArtwork.Key(itemID: itemID, episodeID: episodeID ?? "")) {
      episodeArtwork?.track(itemID: itemID, episodeID: episodeID)
    }
  }
}
