import Foundation
import Observation
import Persistence
import SyncEngine

public enum ListeningQueueCopy {
  public static let loading = "Loading Up Next…"
  public static let empty = "Up Next is empty."
  public static let editFailed = "Couldn't update Up Next. Try again."
  public static let cleared = "Up Next cleared"
  public static let undoFailed = "Couldn't restore Up Next."
  public static let playingNext = "Playing Next"
  private static let playsAfterPrefix = "Plays after "

  /// The Play Next confirmation. While a smart list runs, Play Next queues behind it (ADR 0016), so
  /// the copy names the list instead of promising the episode is next.
  public static func playNextConfirmation(afterList listName: String?) -> String {
    guard let listName, listName.isEmpty == false else { return playingNext }
    return playsAfterPrefix + listName
  }

  /// Whether `message` is a Play Next confirmation in either form, for the banner's icon match.
  public static func isPlayNextConfirmation(_ message: String) -> Bool {
    message == playingNext || message.hasPrefix(playsAfterPrefix)
  }
  public static let addedToUpNext = "Added to Up Next"
  /// For the idempotent append. Not "Added to Up Next", since nothing was added.
  public static let alreadyInUpNext = "Already in Up Next"
  public static let chapterAddedToUpNext = "Chapter added to Up Next"

  public static func chaptersAddedToUpNext(_ count: Int) -> String {
    count == 1 ? chapterAddedToUpNext : "\(count) chapters added to Up Next"
  }
  /// For a queued book whose extent changed: a chapter replaced it, or it replaced a chapter.
  public static let upNextUpdated = "Up Next updated"
}

/// The two lines of an Up Next row, shared by the phone's sheet and CarPlay. A chapter row is
/// named by its chapter, with the book it belongs to on the second line.
public enum ListeningQueueRowText {
  public static let untitledChapter = "Chapter"

  public static func primary(_ item: ListeningQueueItem) -> String {
    guard let chapter = item.chapter else { return item.primaryTitle }
    return chapterTitle(chapter)
  }

  /// Nil when the row has no second line.
  public static func secondary(_ item: ListeningQueueItem) -> String? {
    guard item.chapter != nil else { return item.secondaryTitle.isEmpty ? nil : item.secondaryTitle }
    return item.secondaryTitle.isEmpty ? item.primaryTitle : "\(item.primaryTitle) · \(item.secondaryTitle)"
  }

  private static func chapterTitle(_ chapter: ListeningQueueChapter) -> String {
    let title = chapter.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return title.isEmpty ? untitledChapter : title
  }
}

/// The universal Up Next queue's observable state over a mixed audiobook/podcast-episode order.
/// Beyond projecting `ListeningQueueReading` it owns the clear/undo command state: the transient
/// restore token has to outlive the queue sheet's view identity, since the sheet is reconstructed
/// freely while the player stays presented.
@MainActor
@Observable
public final class ListeningQueueModel {
  public enum State: Sendable, Equatable {
    case loading
    case empty
    case loaded

    public var copyText: String {
      switch self {
      case .loading: ListeningQueueCopy.loading
      case .empty: ListeningQueueCopy.empty
      case .loaded: ""
      }
    }
  }

  /// How long the Undo affordance lives after `clear()` commits, measured against the injected
  /// clock (never a real sleep).
  public static let clearUndoLifetime: TimeInterval = 10

  private struct ClearUndoOffer {
    let token: ListeningQueueRestoreToken
    let expiresAt: Date
  }

  public private(set) var state: State = .loading
  public private(set) var items: [ListeningQueueItem] = []
  public private(set) var actionErrorMessage: String?

  /// Whether the post-clear Undo affordance is still live. Expiry is evaluated on read against the
  /// injected clock rather than scheduled, so there is nothing to cancel.
  public var canUndoClear: Bool {
    guard let clearUndoOffer else { return false }
    return clock.now() < clearUndoOffer.expiresAt
  }

  private let storing: any ListeningQueueStoring
  private let clock: any SyncClock
  private var clearUndoOffer: ClearUndoOffer?
  @ObservationIgnored private var observationTask: Task<Void, Never>?

  public init(
    reading: any ListeningQueueReading = NoOpListeningQueueStore(),
    storing: any ListeningQueueStoring = NoOpListeningQueueStore(),
    clock: any SyncClock = SystemSyncClock()
  ) {
    self.storing = storing
    self.clock = clock
    let stream = reading.observeQueue()
    observationTask = Task { [weak self] in
      for await items in stream {
        guard let self else { return }
        self.items = items
        self.state = items.isEmpty ? .empty : .loaded
        self.actionErrorMessage = nil
      }
    }
  }

  deinit {
    observationTask?.cancel()
  }

  public func append(identity: ListeningIdentity) async {
    await perform { _ = try await storing.append(identity: identity) }
  }

  public func insertNext(identity: ListeningIdentity) async {
    await perform { try await storing.insertNext(identity: identity) }
  }

  /// One row, named by `ListeningQueueItem.id`: a book may have several chapter rows.
  public func remove(rowID: Int64) async {
    await perform { try await storing.remove(rowID: rowID) }
  }

  public func move(rowID: Int64, to position: Int) async {
    await perform { try await storing.move(rowID: rowID, to: position) }
  }

  /// Immediate and never confirmed. Retains the token the emptied sheet's Undo needs.
  public func clear() async {
    do {
      let token = try await storing.clear()
      clearUndoOffer = ClearUndoOffer(
        token: token, expiresAt: clock.now().addingTimeInterval(Self.clearUndoLifetime))
      actionErrorMessage = nil
    } catch {
      clearUndoOffer = nil
      actionErrorMessage = ListeningQueueCopy.editFailed
    }
  }

  /// Restores the exact cleared order. An expired, consumed, or stale offer restores nothing and
  /// reports one message, never a partial rebuild.
  public func undoClear() async {
    guard canUndoClear, let offer = clearUndoOffer else {
      clearUndoOffer = nil
      actionErrorMessage = ListeningQueueCopy.undoFailed
      return
    }
    clearUndoOffer = nil
    do {
      try await storing.restore(token: offer.token)
      actionErrorMessage = nil
    } catch {
      actionErrorMessage = ListeningQueueCopy.undoFailed
    }
  }

  public func dismissActionError() {
    actionErrorMessage = nil
  }

  /// Any later queue mutation makes the clear snapshot stale. The store would reject the token on
  /// its revision anyway, so the offer is retired here rather than offering an Undo that fails.
  private func perform(_ edit: () async throws -> Void) async {
    do {
      try await edit()
      clearUndoOffer = nil
    } catch {
      actionErrorMessage = ListeningQueueCopy.editFailed
    }
  }
}
