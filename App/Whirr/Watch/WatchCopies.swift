import AppModel
import Foundation
import Persistence

/// The one value screens read for Send to Watch, over both desired sets (ADR 0021).
///
/// Per item, it routes by `PodcastSourceIdentity`: a native-RSS episode goes to
/// `WatchEpisodeCopiesModel`, and an Audiobookshelf book or episode to `ABSWatchCopiesModel`. The
/// aggregate half (install state, readiness, the Watch's storage, lifecycle) is the Watch's, so it
/// is read once here rather than from two models. It wraps the two models `WatchCompanionRuntime`
/// owns and replaces neither; both are `@Observable`, so a view reading through it is invalidated by
/// either.
@MainActor
struct WatchCopies {
  let episodes: WatchEpisodeCopiesModel
  let audiobookshelf: ABSWatchCopiesModel

  /// The process runtime's own models, so a view and the runtime can never hold different instances.
  static let shared = WatchCopies(
    episodes: WatchCompanionRuntime.shared.episodeCopies,
    audiobookshelf: WatchCompanionRuntime.shared.absCopies)

  // MARK: - Per item

  /// The canonical menu's answer for one episode, or nil to hide both Watch entries.
  func watchCopy(itemID: String, episodeID: String) -> PodcastEpisodeWatchCopy? {
    if PodcastSourceIdentity(itemId: itemID)?.rssFeedId != nil {
      return episodes.watchCopy(itemID: itemID, episodeID: episodeID)
    }
    guard let key = Self.absKey(itemID: itemID, episodeID: episodeID) else { return nil }
    return audiobookshelf.watchCopy(key)
  }

  /// The row mark's finer answer for one episode.
  func watchCopyState(itemID: String, episodeID: String) -> WatchCopyState? {
    if PodcastSourceIdentity(itemId: itemID)?.rssFeedId != nil {
      return episodes.watchCopyState(itemID: itemID, episodeID: episodeID)
    }
    guard isWatchAppInstalled, let key = Self.absKey(itemID: itemID, episodeID: episodeID) else {
      return nil
    }
    return audiobookshelf.copyState(key)
  }

  func send(itemID: String, episodeID: String) async {
    if PodcastSourceIdentity(itemId: itemID)?.rssFeedId != nil {
      await episodes.send(itemID: itemID, episodeID: episodeID)
    } else if let key = Self.absKey(itemID: itemID, episodeID: episodeID) {
      await audiobookshelf.send(key)
    }
  }

  func remove(itemID: String, episodeID: String) async {
    if PodcastSourceIdentity(itemId: itemID)?.rssFeedId != nil {
      await episodes.remove(itemID: itemID, episodeID: episodeID)
    } else if let key = Self.absKey(itemID: itemID, episodeID: episodeID) {
      await audiobookshelf.remove(key)
    }
  }

  /// The menu's answer for a book, or nil to hide both Watch entries.
  func bookWatchCopy(itemID: String) -> PodcastEpisodeWatchCopy? {
    guard isWatchAppInstalled, let key = Self.absKey(itemID: itemID, episodeID: nil) else {
      return nil
    }
    return audiobookshelf.watchCopy(key)
  }

  func sendBook(itemID: String) async {
    guard let key = Self.absKey(itemID: itemID, episodeID: nil) else { return }
    await audiobookshelf.send(key)
  }

  func removeBook(itemID: String) async {
    guard let key = Self.absKey(itemID: itemID, episodeID: nil) else { return }
    await audiobookshelf.remove(key)
  }

  /// What the Watch says about a book, for the detail page's status line, or nil when it holds
  /// nothing the phone can speak for.
  func bookStatus(itemID: String) -> OnAppleWatchStatus? {
    guard isWatchAppInstalled, let key = Self.absKey(itemID: itemID, episodeID: nil),
      let row = audiobookshelf.row(key)
    else { return nil }
    return OnAppleWatchPresentation.status(for: row, readiness: audiobookshelf.effectiveReadiness)
  }

  /// The sizes to ask about before sending a book, or nil to send at once.
  func oversizedBook(itemID: String) -> ABSWatchOversizedSend? {
    guard Self.absKey(itemID: itemID, episodeID: nil) != nil else { return nil }
    return audiobookshelf.oversizedBook(itemID: itemID)
  }

  // MARK: - The On Apple Watch screen

  /// Every title the screen lists. Audiobookshelf rows are hidden while the Watch is signed out or
  /// on another account.
  var sections: OnAppleWatchSections {
    OnAppleWatchPresentation.sections(
      rss: OnAppleWatchPresentation.rows(episodes.rows, readiness: watchAppReadiness),
      audiobookshelf: OnAppleWatchPresentation.rows(
        audiobookshelf.visibleRows, readiness: audiobookshelf.effectiveReadiness))
  }

  /// Whether the screen leads with "Set up Whirr on your Watch" in place of the account's rows.
  var asksToSetUpWatch: Bool {
    audiobookshelf.isBound && isWatchAppInstalled && audiobookshelf.effectiveReadiness == .setUpWatch
  }

  /// Sends a row's title again, or retries it, in its own desired set.
  func send(_ target: OnAppleWatchRow.Target) async {
    switch target {
    case .rss(let episodeId): await episodes.send(episodeId: episodeId)
    case .audiobookshelf(let key): await audiobookshelf.send(key)
    }
  }

  func remove(_ target: OnAppleWatchRow.Target) async {
    switch target {
    case .rss(let episodeId): await episodes.remove(episodeId: episodeId)
    case .audiobookshelf(let key): await audiobookshelf.remove(key)
    }
  }

  /// An Audiobookshelf key, or nil for an identity that is not one.
  static func absKey(itemID: String, episodeID: String?) -> ABSWatchCopyKey? {
    guard let itemId = PodcastSourceIdentity(itemId: itemID)?.absItemId else { return nil }
    return ABSWatchCopyKey(itemId: itemId, episodeId: episodeID)
  }

  // MARK: - The Watch

  var isWatchAppInstalled: Bool { episodes.isWatchAppInstalled }
  var watchAppReadiness: WatchAppReadiness { episodes.watchAppReadiness }
  /// The Watch's one storage figure, shared by both sets. Each inventory carries one, so the RSS
  /// half's copy of it is the latest.
  var budgetUsedBytes: Int64? { episodes.setState.budgetUsedBytes }
  var budgetTotalBytes: Int64? { episodes.setState.budgetTotalBytes }

  func start() { episodes.start() }
  func refreshWatchAvailability() { episodes.refreshWatchAvailability() }
}
