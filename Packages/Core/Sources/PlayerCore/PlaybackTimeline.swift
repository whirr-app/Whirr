/// One server-provided audio file within a multi-file audiobook's track manifest
/// (ARCHITECTURE.md §4: ABS returns `audioTracks[]` with `startOffset`/`duration` per track).
/// Credential- and framework-free: PlayerCore sees this descriptor, never ABSApi's wire DTOs.
/// `index` orders the track; `startOffset` is its fixed position on the global book timeline;
/// `duration` is its own length. Both are optional as upstream can omit them: `PlaybackTimeline`
/// falls back to cumulative offsets and raises a typed preparation error, never a crash, for an
/// absent/invalid duration.
public struct PlaybackTrack: Sendable, Equatable {
  public let index: Int
  public let startOffset: Double?
  public let duration: Double?

  public init(index: Int, startOffset: Double? = nil, duration: Double?) {
    self.index = index
    self.startOffset = startOffset
    self.duration = duration
  }
}

/// Why a track manifest could not become a `PlaybackTimeline` (ARCHITECTURE.md §4). An unusable
/// manifest is a typed preparation error, never a crash. Always caller-recoverable.
public enum PlaybackTimelinePreparationError: Error, Sendable, Equatable {
  /// The manifest had no tracks, so there is no timeline to build.
  case noTracks
  /// `trackIndex`'s duration was missing, non-finite, zero, or negative.
  case invalidDuration(trackIndex: Int)
}

/// One global timeline over many server tracks (ARCHITECTURE.md §4). Tracks are ordered by `index`
/// regardless of input order; a track's global position is its explicit `startOffset`, else the
/// running end of the previous track. Building assumes explicit offsets are monotonic and does not
/// police that. All lookup/mapping below is pure arithmetic.
public struct PlaybackTimeline: Sendable, Equatable {
  /// Tracks sorted ascending by `index`.
  public let tracks: [PlaybackTrack]
  /// The global start offset of each track in `tracks`, at the same array index.
  private let trackStarts: [Double]
  /// The sum of every track's duration, i.e. the global position at which the book ends.
  public let totalDuration: Double

  public init(tracks: [PlaybackTrack]) throws {
    guard !tracks.isEmpty else { throw PlaybackTimelinePreparationError.noTracks }
    let sorted = tracks.sorted { $0.index < $1.index }
    var starts: [Double] = []
    starts.reserveCapacity(sorted.count)
    var runningEnd: Double = 0
    for track in sorted {
      guard let duration = track.duration, duration.isFinite, duration > 0 else {
        throw PlaybackTimelinePreparationError.invalidDuration(trackIndex: track.index)
      }
      let start = track.startOffset ?? runningEnd
      starts.append(start)
      runningEnd = start + duration
    }
    self.tracks = sorted
    self.trackStarts = starts
    self.totalDuration = runningEnd
  }

  /// Maps a global book position to the track that owns it plus the local offset within that
  /// track. Positions before 0 clamp to the very start of the first track; positions after
  /// `totalDuration` clamp to the very end of the last track. An interior track boundary
  /// belongs to the next track (local offset 0); the final boundary (`totalDuration` itself)
  /// belongs to the last track, since there is no next one.
  public func trackAndLocalOffset(atGlobalOffset globalOffset: Double) -> (
    track: PlaybackTrack, localOffset: Double
  ) {
    let clamped = min(max(globalOffset, 0), totalDuration)
    var chosenIndex = 0
    for index in trackStarts.indices {
      if trackStarts[index] <= clamped {
        chosenIndex = index
      } else {
        break
      }
    }
    let track = tracks[chosenIndex]
    // Validated non-nil/finite/positive at construction, so the 0 fallback is unreachable.
    let duration = track.duration ?? 0
    let local = min(max(clamped - trackStarts[chosenIndex], 0), duration)
    return (track, local)
  }

  /// Maps a track index + local offset back to a global book position, clamping the local
  /// offset to that track's own duration. Returns nil if `trackIndex` is not part of this
  /// timeline.
  public func globalOffset(forTrackIndex trackIndex: Int, localOffset: Double) -> Double? {
    guard let index = tracks.firstIndex(where: { $0.index == trackIndex }) else { return nil }
    let duration = tracks[index].duration ?? 0
    let clampedLocal = min(max(localOffset, 0), duration)
    return trackStarts[index] + clampedLocal
  }

  /// How much longer than the declared duration an observation must be before it counts as the
  /// audio genuinely outrunning the manifest rather than container rounding. A whole second is
  /// tighter than any real trailing segment and wider than any encoder's slack.
  public static let observedExtentTolerance: Double = 1.0

  /// A copy of this timeline grown to an extent the engine actually observed, or nil when no
  /// correction applies.
  ///
  /// Podcast feed and ABS manifest durations often come from a stale MP3 header written before a
  /// dynamically inserted advert, so the audio outruns the declared number. Both engines feed
  /// this AVFoundation's item duration and any reported local offset past the declared end.
  /// Growth is grow-only (a partially loaded stream can briefly report a short duration) and
  /// idempotent.
  ///
  /// Single-track only: ABS pins every track of a multi-file book to an explicit `startOffset`,
  /// so growing one would overlap the next track's fixed start. Podcast episodes are single-track.
  public func grown(toObservedLocalExtent observed: Double) -> PlaybackTimeline? {
    guard tracks.count == 1, let track = tracks.first, let declared = track.duration else { return nil }
    guard observed.isFinite, observed > 0, observed > declared + Self.observedExtentTolerance else { return nil }
    return try? PlaybackTimeline(tracks: [
      PlaybackTrack(index: track.index, startOffset: track.startOffset, duration: observed)
    ])
  }
}
