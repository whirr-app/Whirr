import Foundation

/// The accumulate-or-persist rule for playback progress ticks, shared by both playback
/// coordinators so an account-owned item and a native RSS episode save on one schedule.
///
/// While playing, ordinary ticks merge in memory and persist at most once per `interval`. A tick
/// persists at once (after any held tick is written separately) when it starts a stream, changes
/// item or episode, seeks, changes the finished flag, or arrives while not playing. The interval
/// bounds only what a crash can lose: screens must not take live position from these writes.
///
/// A pure value. Callers own the writes, the clock and their flush points (pause, close, stop,
/// backgrounding), where they call `takePending(now:)`.
public struct ProgressPersistThrottle: Sendable {
  public struct Tick: Sendable, Equatable {
    public var itemID: String
    public var episodeID: String?
    public var currentTime: Double
    public var listenedDelta: Double
    public var isFinished: Bool

    public init(
      itemID: String, episodeID: String?, currentTime: Double, listenedDelta: Double,
      isFinished: Bool
    ) {
      self.itemID = itemID
      self.episodeID = episodeID
      self.currentTime = currentTime
      self.listenedDelta = listenedDelta
      self.isFinished = isFinished
    }
  }

  public struct Write: Sendable, Equatable {
    public let tick: Tick
    public let isSeek: Bool

    public init(tick: Tick, isSeek: Bool) {
      self.tick = tick
      self.isSeek = isSeek
    }
  }

  public struct Decision: Sendable, Equatable {
    /// Writes to make now, in order: a held tick flushed by a boundary, then the tick itself.
    public let writes: [Write]
    /// Whether the tick was persisted as a boundary rather than as a due merge. A finished
    /// transition is always a boundary, so only an immediate decision can carry one.
    public let isImmediate: Bool
    /// The previous tick's finished flag for this exact stream, or `nil` when there is no
    /// continuity to compare against (a fresh stream, or a switch of item or episode).
    public let previousFinished: Bool?
  }

  private struct Stream: Sendable {
    let itemID: String
    let episodeID: String?
    var lastPersistedAt: Date
    var lastFinished: Bool
    var pending: Tick?
  }

  public let interval: TimeInterval
  private var stream: Stream?

  public init(interval: TimeInterval) {
    self.interval = interval
  }

  public mutating func record(
    _ tick: Tick, isSeek: Bool, isPlaying: Bool, now: Date
  ) -> Decision {
    let isSameStream = stream?.itemID == tick.itemID && stream?.episodeID == tick.episodeID
    let previousFinished = isSameStream ? stream?.lastFinished : nil
    let changesStream = stream != nil && isSameStream == false
    let changesFinished = isSameStream && previousFinished != tick.isFinished
    let isBoundary = isSeek || changesStream || changesFinished

    guard isPlaying, isSameStream, isBoundary == false, var current = stream else {
      var writes: [Write] = []
      if let held = stream?.pending {
        writes.append(Write(tick: held, isSeek: false))
      }
      writes.append(Write(tick: tick, isSeek: isSeek))
      stream = Stream(
        itemID: tick.itemID, episodeID: tick.episodeID, lastPersistedAt: now,
        lastFinished: tick.isFinished, pending: nil)
      return Decision(writes: writes, isImmediate: true, previousFinished: previousFinished)
    }

    var merged =
      current.pending
      ?? Tick(
        itemID: tick.itemID, episodeID: tick.episodeID, currentTime: tick.currentTime,
        listenedDelta: 0, isFinished: tick.isFinished)
    merged.currentTime = tick.currentTime
    merged.listenedDelta += tick.listenedDelta
    merged.isFinished = tick.isFinished
    current.lastFinished = tick.isFinished
    if now.timeIntervalSince(current.lastPersistedAt) >= interval {
      current.pending = nil
      current.lastPersistedAt = now
      stream = current
      return Decision(
        writes: [Write(tick: merged, isSeek: false)], isImmediate: false,
        previousFinished: previousFinished)
    }
    current.pending = merged
    stream = current
    return Decision(writes: [], isImmediate: false, previousFinished: previousFinished)
  }

  /// The held tick, if any, which the caller must now write. Restarts the interval.
  public mutating func takePending(now: Date) -> Tick? {
    guard var current = stream, let held = current.pending else { return nil }
    current.pending = nil
    current.lastPersistedAt = now
    stream = current
    return held
  }

  /// Forgets the stream, so the next tick starts a fresh one. Any held tick is dropped: take it
  /// first.
  public mutating func reset() {
    stream = nil
  }
}
