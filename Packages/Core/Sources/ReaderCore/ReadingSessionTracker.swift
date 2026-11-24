import Foundation

/// Monotonic time and deterministic waiting for the reading-session debounce policy.
public protocol ReadingSessionClock: Sendable {
  func now() -> TimeInterval
  func sleep(until deadline: TimeInterval) async
}

/// Production clock for `ReadingSessionTracker`. The uptime reference is process-local; only
/// differences between readings are meaningful.
public struct SystemReadingSessionClock: ReadingSessionClock, Sendable {
  public init() {}

  public func now() -> TimeInterval {
    ProcessInfo.processInfo.systemUptime
  }

  public func sleep(until deadline: TimeInterval) async {
    let remaining = deadline - now()
    guard remaining.isFinite, remaining > 0 else { return }
    let nanoseconds = min(remaining * 1_000_000_000, Double(UInt64.max))
    try? await Task.sleep(nanoseconds: UInt64(nanoseconds))
  }
}

/// Supplies the already-resolved local/server restore choice. Conflict resolution does not belong
/// to the tracker; the caller makes that choice once for each opening.
public protocol ReadingRestoreTargetProviding: Sendable {
  func resolvedRestoreTarget() async -> ReadingPosition?
}

/// Receives a coalesced ebook-position sync intent. The boundary owns persistence/outbox work.
public protocol ReadingSyncIntentEmitting: Sendable {
  func emit(_ intent: ReadingSyncIntent) async throws
}

/// Receives the offer signal raised when a final reading position is observed. Category gating and
/// presentation are outside this boundary.
public protocol ReadingFinishOffering: Sendable {
  func offerFinish() async
}

/// The tracker’s ebook-only sync value. A missing `ebookLocation` is valid: `ReadingPosition`
/// has already applied the genuine-EPUB-CFI gate, while `ebookProgress` remains present.
public struct ReadingSyncIntent: Equatable, Sendable {
  public let position: ReadingPosition
  public let ebookProgress: Double
  public let ebookLocation: String?

  public init(position: ReadingPosition) {
    self.position = position
    ebookProgress = position.ebookProgress
    ebookLocation = position.ebookLocation
  }
}

/// Tracks one reader opening at a time. The actor owns the mutable lifecycle/debounce state; the
/// injected boundaries make restore, emission, and finish-offer effects independently testable.
public actor ReadingSessionTracker {
  public static let syncInterval: TimeInterval = 15

  private enum SessionPhase: Equatable {
    case closed
    case opening(UInt64)
    case open(UInt64)
    case closing(UInt64)
  }

  private let restoreTargetProvider: any ReadingRestoreTargetProviding
  private let intentEmitter: any ReadingSyncIntentEmitting
  private let finishOfferer: any ReadingFinishOffering
  private let clock: any ReadingSessionClock

  private var phase: SessionPhase = .closed
  private var nextSessionID: UInt64 = 0

  private var positionTask: Task<Void, Never>?
  private var debounceTask: Task<Void, Never>?
  private var emissionTask: Task<Void, Never>?

  /// `private(set)` rather than `private` purely so a test can observe that a yielded position has
  /// actually been consumed off the stream. Nothing outside this actor writes it.
  private(set) var latestPosition: ReadingPosition?
  private var lastEmittedPosition: ReadingPosition?
  private var lastEmissionTime: TimeInterval?
  private var flushAfterEmission = false
  private var finishWasOffered = false
  private var closeWaiters: [UInt64: [CheckedContinuation<Void, Never>]] = [:]

  public init(
    restoreTargetProvider: any ReadingRestoreTargetProviding,
    intentEmitter: any ReadingSyncIntentEmitting,
    finishOfferer: any ReadingFinishOffering,
    clock: any ReadingSessionClock
  ) {
    self.restoreTargetProvider = restoreTargetProvider
    self.intentEmitter = intentEmitter
    self.finishOfferer = finishOfferer
    self.clock = clock
  }

  /// Opens a reader session. Restore is awaited before the stream is consumed, so buffered
  /// positions cannot produce an emission before the resolved target becomes the baseline.
  public func open(positions: AsyncStream<ReadingPosition>) async {
    if phase != .closed {
      await close()
    }

    nextSessionID &+= 1
    let sessionID = nextSessionID
    phase = .opening(sessionID)
    latestPosition = nil
    lastEmittedPosition = nil
    lastEmissionTime = nil
    flushAfterEmission = false
    finishWasOffered = false

    let restoreTarget = await restoreTargetProvider.resolvedRestoreTarget()
    guard phase == .opening(sessionID) else { return }

    latestPosition = restoreTarget
    lastEmittedPosition = restoreTarget
    if let restoreTarget {
      offerFinishIfNeeded(for: restoreTarget)
    }
    phase = .open(sessionID)

    positionTask = Task { [weak self] in
      for await position in positions {
        guard Task.isCancelled == false else { return }
        await self?.receive(position, sessionID: sessionID)
      }
      await self?.positionStreamEnded(sessionID: sessionID)
    }
  }

  /// Ends the opening after an immediate final flush. Any position already in flight is allowed
  /// to finish; a newer position observed during it receives one close-triggered trailing flush.
  public func close() async {
    switch phase {
    case .closed:
      return
    case .opening:
      cancelPositionAndDebounceTasks()
      phase = .closed
      return
    case .open(let sessionID):
      beginClosing(sessionID: sessionID)
      await waitForClose(sessionID: sessionID)
    case .closing(let sessionID):
      await waitForClose(sessionID: sessionID)
    }
  }

  /// Flushes the latest changed position immediately while leaving the opening active. App
  /// backgrounding therefore does not close an otherwise-running reader session.
  public func background() async {
    await flushImmediately()
  }

  private func receive(_ position: ReadingPosition, sessionID: UInt64) {
    guard phase == .open(sessionID) else { return }

    latestPosition = position
    offerFinishIfNeeded(for: position)

    guard position != lastEmittedPosition else {
      if emissionTask == nil {
        cancelDebounceTask()
      }
      return
    }
    guard emissionTask == nil else { return }
    scheduleDebounce(sessionID: sessionID)
  }

  private func offerFinishIfNeeded(for position: ReadingPosition) {
    guard position.totalProgression >= 1, finishWasOffered == false else { return }
    finishWasOffered = true

    let finishOfferer = self.finishOfferer
    Task {
      await finishOfferer.offerFinish()
    }
  }

  private func scheduleDebounce(sessionID: UInt64) {
    guard debounceTask == nil else { return }

    let now = clock.now()
    let deadline = max(now, (lastEmissionTime ?? now) + Self.syncInterval)
    let clock = self.clock
    debounceTask = Task { [weak self] in
      await clock.sleep(until: deadline)
      guard Task.isCancelled == false else { return }
      await self?.debounceReached(sessionID: sessionID)
    }
  }

  private func debounceReached(sessionID: UInt64) {
    guard phase == .open(sessionID) else { return }
    debounceTask = nil
    guard emissionTask == nil else { return }
    guard let latestPosition, latestPosition != lastEmittedPosition else { return }
    startEmission(sessionID: sessionID, force: false)
  }

  private func flushImmediately() async {
    guard case .open(let sessionID) = phase else { return }
    cancelDebounceTask()

    if hasPendingPosition {
      if emissionTask == nil {
        startEmission(sessionID: sessionID, force: true)
      } else {
        flushAfterEmission = true
      }
    }

    while let emissionTask {
      await emissionTask.value
    }
  }

  private var hasPendingPosition: Bool {
    guard let latestPosition else { return false }
    return latestPosition != lastEmittedPosition
  }

  private func startEmission(sessionID: UInt64, force: Bool) {
    guard emissionTask == nil else { return }
    guard phase == .open(sessionID) || phase == .closing(sessionID) else { return }
    guard let position = latestPosition, position != lastEmittedPosition else { return }

    if force == false,
      let lastEmissionTime,
      clock.now() - lastEmissionTime < Self.syncInterval
    {
      scheduleDebounce(sessionID: sessionID)
      return
    }

    cancelDebounceTask()
    lastEmissionTime = clock.now()
    let intent = ReadingSyncIntent(position: position)
    let intentEmitter = self.intentEmitter
    emissionTask = Task { [weak self] in
      do {
        try await intentEmitter.emit(intent)
        await self?.emissionCompleted(sessionID: sessionID, persistedPosition: position)
      } catch {
        await self?.emissionCompleted(sessionID: sessionID)
      }
    }
  }

  private func emissionCompleted(sessionID: UInt64, persistedPosition: ReadingPosition? = nil) {
    guard phase == .open(sessionID) || phase == .closing(sessionID) else { return }
    if let persistedPosition {
      lastEmittedPosition = persistedPosition
    }
    emissionTask = nil

    switch phase {
    case .open:
      if hasPendingPosition {
        if flushAfterEmission {
          flushAfterEmission = false
          startEmission(sessionID: sessionID, force: true)
        } else {
          scheduleDebounce(sessionID: sessionID)
        }
      } else {
        flushAfterEmission = false
      }
    case .closing:
      if flushAfterEmission, hasPendingPosition {
        flushAfterEmission = false
        startEmission(sessionID: sessionID, force: true)
      } else {
        finishClosing(sessionID: sessionID)
      }
    case .closed, .opening:
      break
    }
  }

  private func beginClosing(sessionID: UInt64) {
    guard phase == .open(sessionID) else { return }
    cancelPositionAndDebounceTasks()
    phase = .closing(sessionID)

    if hasPendingPosition {
      if emissionTask == nil {
        startEmission(sessionID: sessionID, force: true)
      } else {
        flushAfterEmission = true
      }
    } else if emissionTask == nil {
      finishClosing(sessionID: sessionID)
    }
  }

  private func finishClosing(sessionID: UInt64) {
    guard phase == .closing(sessionID) else { return }
    phase = .closed
    latestPosition = nil
    lastEmittedPosition = nil
    lastEmissionTime = nil
    flushAfterEmission = false

    let waiters = closeWaiters.removeValue(forKey: sessionID) ?? []
    for waiter in waiters {
      waiter.resume()
    }
  }

  private func waitForClose(sessionID: UInt64) async {
    guard phase == .closing(sessionID) else { return }
    await withCheckedContinuation { continuation in
      closeWaiters[sessionID, default: []].append(continuation)
    }
  }

  private func cancelPositionAndDebounceTasks() {
    positionTask?.cancel()
    positionTask = nil
    cancelDebounceTask()
  }

  private func cancelDebounceTask() {
    debounceTask?.cancel()
    debounceTask = nil
  }

  private func positionStreamEnded(sessionID: UInt64) {
    guard phase == .open(sessionID) else { return }
    positionTask = nil
  }
}
