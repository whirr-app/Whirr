import AdSkip
import Foundation

/// One downloaded file of a book, placed on the book's clock.
public struct LookBackTrack: Sendable, Equatable {
  public let fileURL: URL
  /// Where the file begins on the book's clock, in seconds.
  public let startOffset: Double
  /// The declared length the player's timeline uses, not the decoded one.
  public let duration: Double

  public init(fileURL: URL, startOffset: Double, duration: Double) {
    self.fileURL = fileURL
    self.startOffset = startOffset
    self.duration = duration
  }
}

/// One stretch of one file to transcribe: `localWindow` is on the file's clock, and its words go
/// onto the book's clock by adding `startOffset`.
public struct LookBackSegment: Sendable, Equatable {
  public let fileURL: URL
  public let localWindow: TimeSpan
  public let startOffset: Double

  public init(fileURL: URL, localWindow: TimeSpan, startOffset: Double) {
    self.fileURL = fileURL
    self.localWindow = localWindow
    self.startOffset = startOffset
  }

  /// The same stretch on the book's clock.
  public var bookWindow: TimeSpan {
    TimeSpan(start: localWindow.start + startOffset, end: localWindow.end + startOffset)
  }
}

/// Maps a stretch of book time before the playhead onto the loaded files, in chunks that run
/// newest first.
public enum LookBackPlan {
  /// How far back the sheet transcribes when it opens, in seconds.
  public static let initialReach: Double = 300
  /// How far back scrolling up can take it, in seconds.
  public static let maximumReach: Double = 1_800
  /// Each chunk is one transcription call; the sheet shows each as it lands.
  public static let chunkSeconds: Double = 150

  /// The part of each track that overlaps `window`, earliest first. A track is clamped by its
  /// declared duration, the length the player's timeline seeks against.
  public static func segments(window: TimeSpan, tracks: [LookBackTrack]) -> [LookBackSegment] {
    tracks
      .sorted { $0.startOffset < $1.startOffset }
      .compactMap { track in
        let start = max(window.start, track.startOffset)
        let end = min(window.end, track.startOffset + track.duration)
        guard end > start else { return nil }
        return LookBackSegment(
          fileURL: track.fileURL,
          localWindow: TimeSpan(start: start - track.startOffset, end: end - track.startOffset),
          startOffset: track.startOffset)
      }
  }

  /// The calls that cover `length` seconds before `playhead`, newest first, leaving out the
  /// `alreadyCovered` seconds nearest the playhead. Chunks are cut every `chunkSeconds` back from
  /// the playhead, so a longer length only adds older chunks; a chunk that crosses a track
  /// boundary becomes one call per file.
  public static func chunks(
    playhead: Double, length: Double, alreadyCovered: Double = 0, tracks: [LookBackTrack]
  ) -> [LookBackSegment] {
    let earliest = max(0, playhead - length)
    let newest = playhead - max(0, alreadyCovered)
    var result: [LookBackSegment] = []
    var chunkEnd = playhead
    while chunkEnd > earliest {
      let chunkStart = max(earliest, chunkEnd - chunkSeconds)
      let end = min(chunkEnd, newest)
      if end > chunkStart {
        let window = TimeSpan(start: chunkStart, end: end)
        result.append(contentsOf: segments(window: window, tracks: tracks).reversed())
      }
      chunkEnd -= chunkSeconds
    }
    return result
  }
}
