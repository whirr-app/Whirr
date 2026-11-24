import Foundation
import Persistence

/// Follows the saved rows of the identities `CoverPaletteService` left unanswered, through one
/// batched observation, until each is answered or the service stops it. The service decides what
/// a row answers; this only keeps the observation matched to what is still unanswered.
@MainActor
final class CoverPaletteFollower {
  /// Identities a request left without a palette.
  private(set) var unanswered: Set<CoverPaletteIdentity> = []
  private var followedRowIDs: Set<String> = []
  private var followTask: Task<Void, Never>?
  /// Coalesces a burst of misses, a screen's first resolution pass, into one new observation.
  private var followRestart: Task<Void, Never>?
  private let recordStore: (any CoverPaletteRecordStoring)?
  /// Every batch the observation delivers. Set once by the owning service.
  var onRecords: ([CoverPaletteRecord]) -> Void = { _ in }

  init(recordStore: (any CoverPaletteRecordStoring)?) {
    self.recordStore = recordStore
  }

  /// Whether there are rows to follow at all.
  var canFollow: Bool { recordStore != nil }

  func contains(_ identity: CoverPaletteIdentity) -> Bool {
    unanswered.contains(identity)
  }

  /// Follows `missed` as well. The observation is replaced once per burst rather than added to.
  func follow(_ missed: [CoverPaletteIdentity]) {
    guard missed.isEmpty == false, recordStore != nil else { return }
    unanswered.formUnion(missed)
    guard followRestart == nil else { return }
    followRestart = Task { [weak self] in
      await Task.yield()
      guard Task.isCancelled == false, let self else { return }
      self.followRestart = nil
      self.restart()
    }
  }

  /// Stops following `identity`, now answered. Reports whether it was being followed.
  func answered(_ identity: CoverPaletteIdentity) -> Bool {
    unanswered.remove(identity) != nil
  }

  /// Matches the observation to the rows still unanswered, ending it once none are.
  func restart() {
    let rowIDs = Set(unanswered.map(\.rowID))
    guard rowIDs != followedRowIDs, let recordStore else { return }
    followTask?.cancel()
    followTask = nil
    followedRowIDs = rowIDs
    guard rowIDs.isEmpty == false else { return }
    let rows = recordStore.observe(itemIds: Array(rowIDs))
    followTask = Task { [weak self] in
      for await records in rows {
        guard Task.isCancelled == false, let self else { return }
        self.onRecords(records)
      }
      // The observation ended on its own (a database error finishes it): forget it, so the next
      // miss follows again instead of matching the dead observation's row set.
      guard Task.isCancelled == false else { return }
      self?.followedRowIDs.removeAll()
    }
  }

  /// Forgets everything unanswered and ends the observation.
  func stop() {
    unanswered.removeAll()
    followRestart?.cancel()
    followRestart = nil
    followTask?.cancel()
    followTask = nil
    followedRowIDs.removeAll()
  }

  isolated deinit {
    followRestart?.cancel()
    followTask?.cancel()
  }
}
