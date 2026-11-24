import Foundation
import Observation
import Persistence
import SyncEngine

/// One audiobook's Audiobookshelf bookmarks and the listener's intents on them
/// The list comes from the local database only; every write is durable before it returns and
/// reaches the server through the outbox.
///
/// Whether the loaded item may be bookmarked (a server audiobook, not an episode, and actually
/// loaded) is the presenting surface's decision; the store also refuses a device-owned RSS item.
@MainActor
@Observable
public final class AudioBookmarksModel {
  public enum AddOutcome: Equatable, Sendable {
    case added(AudioBookmark)
    /// A bookmark already lies within a second of this position.
    case alreadyBookmarked(AudioBookmark)
    case failed
  }

  public private(set) var bookmarks: [AudioBookmark] = []
  /// The last write's failure as renderable copy, `nil` once a write succeeds.
  public private(set) var actionErrorMessage: String?

  public let itemID: String
  private let intents: any AudioBookmarkIntents

  @ObservationIgnored private var task: Task<Void, Never>?

  public init(itemID: String, intents: any AudioBookmarkIntents) {
    self.itemID = itemID
    self.intents = intents
    let stream = intents.observeBookmarks(itemID: itemID)
    task = Task { [weak self] in
      for await bookmarks in stream {
        guard let self else { return }
        self.bookmarks = bookmarks
      }
    }
  }

  deinit {
    task?.cancel()
  }

  /// Saves a bookmark at the whole second at or before `position`, titled `title`.
  @discardableResult
  public func addBookmark(at position: Double, title: String) async -> AddOutcome {
    do {
      let outcome = try await intents.addBookmark(itemID: itemID, at: position, title: title)
      actionErrorMessage = nil
      switch outcome {
      case .created(let bookmark):
        return .added(bookmark)
      case .tooCloseToExisting(let existing):
        return .alreadyBookmarked(existing)
      }
    } catch {
      actionErrorMessage = AudioBookmarkCopy.saveFailed
      return .failed
    }
  }

  public func rename(_ bookmark: AudioBookmark, to title: String) async {
    do {
      try await intents.renameBookmark(itemID: itemID, time: bookmark.time, to: title)
      actionErrorMessage = nil
    } catch AudioBookmarkStoreError.emptyTitle {
      actionErrorMessage = AudioBookmarkCopy.emptyTitle
    } catch {
      actionErrorMessage = AudioBookmarkCopy.renameFailed
    }
  }

  public func delete(_ bookmark: AudioBookmark) async {
    do {
      try await intents.deleteBookmark(itemID: itemID, time: bookmark.time)
      actionErrorMessage = nil
    } catch {
      actionErrorMessage = AudioBookmarkCopy.deleteFailed
    }
  }
}

/// The bookmark surfaces' shared copy, kept out of the views so they cannot drift.
public enum AudioBookmarkCopy {
  public static let saveFailed = "Couldn't save this bookmark."
  public static let renameFailed = "Couldn't rename this bookmark."
  public static let deleteFailed = "Couldn't delete this bookmark."
  public static let emptyTitle = "A bookmark needs a title."
}
