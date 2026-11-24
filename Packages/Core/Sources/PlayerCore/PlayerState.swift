/// Pure playback state-machine values. No AVFoundation, no I/O. Every value here is
/// `Sendable`/`Equatable` and safe to construct in any context.

/// Where the state machine currently is. `idle` only at the start or after `.stop`; `preparing`
/// while the engine loads a track; `buffering`/`ready` are both reachable from `preparing` (a slow
/// network buffers before ready); `ready` means "loaded, never yet told to play this item", and
/// once playback has started a non-playing loaded state is `paused`. `seeking` covers same-track
/// and cross-track seeks. `stalled` is terminal for a stream buffered past its deadline. `ended`
/// is terminal for the current item. `failed` carries the engine's failure detail so `.retry` can
/// inspect `isRecoverable`.
public enum PlayerPhase: Sendable, Equatable {
  case idle
  case preparing
  case buffering
  case ready
  case playing
  case paused
  case seeking
  case stalled
  case ended
  case failed(AudioEngineFailure)
}

/// One item PlayerCore can play: a stable id, the global timeline over its tracks, and the item's
/// chapter map. Credential-free: PlayerCore never sees ABSApi's wire DTOs, only this descriptor.
public struct PlayerItem: Sendable, Equatable {
  public let id: String
  public let episodeID: String?
  /// Whether this item depends on a remote server while it plays. The conservative default keeps
  /// a forgotten call site from treating a complete local download as a network stall.
  public let isStreaming: Bool
  public let timeline: PlaybackTimeline
  public let chapters: PlaybackChapterMap

  public init(
    id: String,
    episodeID: String? = nil,
    timeline: PlaybackTimeline,
    chapters: PlaybackChapterMap = PlaybackChapterMap(chapters: []),
    isStreaming: Bool = false
  ) {
    self.id = id
    self.episodeID = episodeID
    self.timeline = timeline
    self.chapters = chapters
    self.isStreaming = isStreaming
  }
}

/// The state machine's observable snapshot: current phase, loaded item (nil when idle), which
/// track owns the current global position, the position itself, the active playback rate, and the
/// sleep timer (a local preference, never synced to ABS), plus the output volume PlayerCore owns
/// for the active sleep-timer fade and the timestamp of a rewindable pause.
public struct PlayerState: Sendable, Equatable {
  public var phase: PlayerPhase
  public var item: PlayerItem?
  public var currentTrackIndex: Int?
  public var globalPosition: Double
  public var rate: Double
  public var sleepTimer: SleepTimerState
  /// Whether playback is currently intended. Transient engine phases do not change it, but a
  /// terminal streamed stall clears it because recovery needs a new explicit preparation.
  /// A play/pause control renders this: `phase` flaps with stream health, intent doesn't.
  public var isPlaybackIntended: Bool
  public var volume: Double
  /// Wall-clock time at which the current pause began, when resuming may trigger smart rewind.
  public var pausedAt: Double?

  public init(
    phase: PlayerPhase, item: PlayerItem?, currentTrackIndex: Int?, globalPosition: Double, rate: Double,
    sleepTimer: SleepTimerState = .off, isPlaybackIntended: Bool = false, volume: Double = 1.0,
    pausedAt: Double? = nil
  ) {
    self.phase = phase
    self.item = item
    self.currentTrackIndex = currentTrackIndex
    self.globalPosition = globalPosition
    self.rate = rate
    self.sleepTimer = sleepTimer
    self.isPlaybackIntended = isPlaybackIntended
    self.volume = volume
    self.pausedAt = pausedAt
  }

  public static let idle = PlayerState(
    phase: .idle, item: nil, currentTrackIndex: nil, globalPosition: 0, rate: 1.0
  )
}

/// User/system-facing playback intents; lock-screen and Control Center commands share them
/// (ARCHITECTURE.md §4). `load` replaces whatever is active, from any phase; its `rate` is only
/// the starting rate, and choosing it (e.g. via `PlaybackPreferences`) is the caller's job.
///
/// `setRate` changes the active rate (clamped to `PlayerReducer.supportedRateRange`, rejected if
/// non-finite) and survives track replacement, since every `loadEngine` effect reads `state.rate`.
/// Persistence is outside this intent. The chapter intents are navigation implemented as seeks.
/// `setSleepTimer`/`extendSleepTimer` drive PlayerCore's own sleep-timer deadline.
public enum PlayerIntent: Sendable, Equatable {
  /// `trim` is the item's trim map when already known, so a trimmed episode starts with one load
  /// rather than two.
  case load(item: PlayerItem, initialGlobalPosition: Double, rate: Double, trim: PlayerTrimMap? = nil)
  case play
  case pause
  case toggle
  case seek(toGlobalOffset: Double)
  /// Relative movement from the current position, and the only intent that may complete the item
  /// by running past its end. `seek` cannot: several callers seek to an absolute position
  /// recovered from persistence (a resume point, a history entry, a chapter row), which can
  /// legitimately sit past a declared duration that under-ran the real audio. Treating one as a
  /// request to finish would finish an item the listener asked to resume.
  case skip(by: Double)
  case stop
  case retry
  case setRate(Double)
  case selectChapter(PlaybackChapter)
  case previousChapter
  case nextChapter
  case setSleepTimer(SleepTimerDuration)
  case extendSleepTimer(by: Double)
  /// The ranges to skip in the loaded episode. Ignored unless both
  /// ids name the loaded item: two episodes of one Audiobookshelf podcast share an item id. A load
  /// drops them, so the caller sends them again for each load.
  case setSkipRanges(itemID: String, episodeID: String?, ranges: [PlayerSkipRange])
  /// Returns to the start of a range this load skipped, and plays it.
  case undoSkip(PlayerSkipRange)
  /// The pauses to cut from the loaded episode, or nil to play it whole. Guarded by both ids, as
  /// `setSkipRanges` is. A change reloads the engine where the listener is; the map is kept until
  /// the next load.
  case setTrimMap(itemID: String, episodeID: String?, map: PlayerTrimMap?)
  /// The stretch of the loaded item to stop at the end of, in global positions: playback that
  /// reaches `end` pauses there and reports `segmentEnd: .reached`, without ending the item. Sent
  /// after the `load` it belongs to, which drops any segment before it. A stretch that ends where
  /// the item does is not armed, so the ordinary item end runs.
  case setSegment(start: Double, end: Double)
  case clearSegment
}

/// One tick PlayerCore hands upward for AppModel to forward to `SyncEngine` (ARCHITECTURE.md §4).
/// `sequence` is a monotonically increasing per-controller counter a downstream store can use to
/// reject a stale captured value. `listenedDelta` is wall-clock time spent `.playing` since the
/// previous event, never inflated by rate or by a raw media-position jump (see `PlayerReducer`).
public struct PlaybackProgressEvent: Sendable, Equatable {
  public enum EndBehavior: Sendable, Equatable {
    /// A natural completion may consume and start the next explicit Up Next row.
    case advanceQueue
    /// The item genuinely completed, but a sleep timer owns the boundary and playback must stop.
    case stop
  }

  /// Why this event reached the pause boundary. The marker is emitted only by the reducer's
  /// sleep-timer expiry path; downstream code must not infer it from timing or timer state.
  public enum SleepTimerExpiry: Sendable, Equatable {
    case none
    case expired
  }

  /// Whether this event is playback stopping at the end of the armed segment. Emitted only by the
  /// reducer; an event never carries both this and `sleepTimerExpiry: .expired`.
  public enum SegmentEnd: Sendable, Equatable {
    case none
    case reached
  }

  public let sequence: Int
  public let itemId: String
  public let episodeID: String?
  public let phase: PlayerPhase
  public let currentTime: Double
  public let listenedDelta: Double
  /// Wall-clock time Trim Silences saved during this event's interval: the cut seconds a credited
  /// tick crossed, at the current rate. Zero for every event without a credited position.
  public let trimmedDelta: Double
  /// Seconds of audio this event's credited listening covered beyond what it took: `listenedDelta`
  /// × (rate − 1), and zero at or below 1×. Measured against playing the original at 1×.
  public let speedSavedDelta: Double
  /// Source seconds Trim Silences cut during this event's interval, whatever the rate. Like
  /// `trimmedDelta`, only a credited tick with a position reports it.
  public let trimmedSourceDelta: Double
  public let endBehavior: EndBehavior
  public let sleepTimerExpiry: SleepTimerExpiry
  /// Set on the event of the step that skipped this range: its `.seeking` event, or its `.ended`
  /// event for a range that ends the item. The receipt and Undo are built from it.
  public let skippedRange: PlayerSkipRange?
  public let segmentEnd: SegmentEnd

  public init(
    sequence: Int,
    itemId: String,
    episodeID: String? = nil,
    phase: PlayerPhase,
    currentTime: Double,
    listenedDelta: Double,
    trimmedDelta: Double = 0,
    speedSavedDelta: Double = 0,
    trimmedSourceDelta: Double = 0,
    endBehavior: EndBehavior = .advanceQueue,
    sleepTimerExpiry: SleepTimerExpiry = .none,
    skippedRange: PlayerSkipRange? = nil,
    segmentEnd: SegmentEnd = .none
  ) {
    self.sequence = sequence
    self.itemId = itemId
    self.episodeID = episodeID
    self.phase = phase
    self.currentTime = currentTime
    self.listenedDelta = listenedDelta
    self.trimmedDelta = trimmedDelta
    self.speedSavedDelta = speedSavedDelta
    self.trimmedSourceDelta = trimmedSourceDelta
    self.endBehavior = endBehavior
    self.sleepTimerExpiry = sleepTimerExpiry
    self.skippedRange = skippedRange
    self.segmentEnd = segmentEnd
  }
}

/// A command `PlayerReducer` asks its caller to carry out against `AudioEngine`. Kept as data so
/// the reducer stays pure and testable; `PlayerController` is the only thing that calls
/// `AudioEngine`.
public enum PlayerEffect: Sendable, Equatable {
  /// `trim` is the map the engine should cut by, or nil to play the track whole.
  case loadEngine(
    track: PlaybackTrack, localOffset: Double, rate: Double, generation: Int, trim: PlayerTrimMap? = nil)
  case seekEngine(localOffset: Double)
  case play
  case pause
  case stop
  /// Applies the active rate through `AudioEngine.setRate(_:)`.
  case setRate(Double)
  case setVolume(Double)
  /// Arms the engine to report its position the moment it reaches `localOffset` in the loaded
  /// track, replacing any boundary armed before; nil disarms. The report arrives as an ordinary
  /// `positionUpdated`.
  case setBoundary(localOffset: Double?)
}

/// What one `PlayerReducer.handle` call produced: zero or more engine effects to carry out (in
/// order) and zero or more progress events to publish (in order). Two progress events occur only
/// when a single step both closes out one item/track's accrued listening time and immediately
/// opens the next (item switch, automatic track advance).
public struct PlayerStepResult: Sendable, Equatable {
  public let effects: [PlayerEffect]
  public let progressEvents: [PlaybackProgressEvent]

  public init(effects: [PlayerEffect] = [], progressEvents: [PlaybackProgressEvent] = []) {
    self.effects = effects
    self.progressEvents = progressEvents
  }

  public static let none = PlayerStepResult()
}

extension PlayerState {
  /// The chapter a chapter-scoped surface is showing: the current chapter of a loaded audiobook.
  /// Nil for a podcast episode (the episode is already the unit the listener thinks in), a book
  /// with no chapters, and a position in a gap between chapters. One rule, because the surfaces
  /// that publish chapter-relative time, map a scrub back and offer a chapter list must agree.
  public var chapterWindow: PlaybackChapter? {
    guard let item, item.episodeID == nil else { return nil }
    return item.chapters.currentChapter(at: globalPosition)
  }
}
