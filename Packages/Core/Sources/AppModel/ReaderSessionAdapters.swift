import ReaderCore
import SyncEngine
import Synchronization

actor ReaderRestoreBox {
  private var target: ReaderRestoreTarget?
  func set(_ target: ReaderRestoreTarget?) { self.target = target }
  func position() -> ReadingPosition? {
    guard case .position(let position) = target else { return nil }
    return position
  }
}

struct ReaderRestoreProvider: ReadingRestoreTargetProviding {
  let box: ReaderRestoreBox
  func resolvedRestoreTarget() async -> ReadingPosition? { await box.position() }
}

struct ReaderIntentEmitter: ReadingSyncIntentEmitting {
  let itemID: String
  let progress: any ReaderProgressAccessing
  func emit(_ intent: ReadingSyncIntent) async throws {
    try await progress.write(position: intent.position, itemID: itemID)
  }
}

final class ReaderFinishOfferer: ReadingFinishOffering {
  private let storedHandler = Mutex<(@Sendable () async -> Void)?>(nil)

  /// Set once, from `ReaderModel.init`: the model cannot hand a handler to its initialiser before
  /// it is fully formed. Reading under the lock keeps the detached offer from racing the write.
  var handler: (@Sendable () async -> Void)? {
    get { storedHandler.withLock { $0 } }
    set { storedHandler.withLock { $0 = newValue } }
  }

  func offerFinish() async {
    let handler = storedHandler.withLock { $0 }
    await handler?()
  }
}

actor ReaderCloseCoordinator {
  let tracker: ReadingSessionTracker
  let renderer: any EPUBRendering
  private var closed = false

  init(tracker: ReadingSessionTracker, renderer: any EPUBRendering) {
    self.tracker = tracker
    self.renderer = renderer
  }

  /// Ends the reading session and leaves the renderer alone. The renderer is shared, so a model
  /// that is going away without having been dismissed may only close its own session.
  func closeSession() async {
    await tracker.close()
  }

  func close() async {
    guard closed == false else { return }
    closed = true
    await closeSession()
    await renderer.close()
  }
}
