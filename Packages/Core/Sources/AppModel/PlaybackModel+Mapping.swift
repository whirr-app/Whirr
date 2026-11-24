import CoreSupport
import Foundation
import Observation
import Persistence
import PlayerCore
import SyncEngine

extension PlaybackModel {

  // MARK: - Sibling-module value mapping

  internal static func isResumable(_ phase: Phase) -> Bool {
    switch phase {
    case .stalled:
      // A bare `.play` would target the dead engine resource. Returning false routes a fresh play
      // intent through `performStart`, which re-prepares the server session before playing.
      return false
    case .idle, .ended, .recoverableError, .unrecoverableError: return false
    case .preparing, .buffering, .playing, .paused, .seeking: return true
    }
  }

  internal static func isDeadSessionPhase(_ phase: Phase) -> Bool {
    phase == .stalled || phase == .buffering
  }

  internal static func makePlayerItem(itemID: String, prepared: PreparedPlayback) throws -> PlayerItem {
    let tracks = prepared.tracks.map {
      PlaybackTrack(index: $0.index, startOffset: $0.startOffset, duration: $0.duration)
    }
    let timeline = try PlaybackTimeline(tracks: tracks)
    let chapters = prepared.chapters.map {
      PlaybackChapter(id: String($0.id), title: $0.title, start: $0.start, end: $0.end)
    }
    return PlayerItem(
      id: itemID, episodeID: prepared.episodeID, timeline: timeline,
      chapters: PlaybackChapterMap(chapters: chapters), isStreaming: prepared.source == .streaming)
  }

  internal static func mapPhase(_ playerPhase: PlayerPhase) -> Phase {
    switch playerPhase {
    case .idle: return .idle
    case .preparing: return .preparing
    case .buffering: return .buffering
    case .stalled: return .stalled
    case .ready, .paused: return .paused
    case .playing: return .playing
    case .seeking: return .seeking
    case .ended: return .ended
    case .failed(let failure): return failure.isRecoverable ? .recoverableError : .unrecoverableError
    }
  }
}

extension PlaybackModel.Phase {
  /// The literal copy a screen renders for this phase, mirroring `SetupFlowModel.State.copyText`.
  /// Empty for `.idle`: no mini-player is showing, so there is nothing to say.
  public var copyText: String {
    switch self {
    case .idle: return ""
    case .preparing: return PlaybackCopy.preparing
    case .buffering: return PlaybackCopy.buffering
    case .stalled: return PlaybackCopy.stalled
    case .playing: return PlaybackCopy.playing
    case .paused: return PlaybackCopy.paused
    case .seeking: return PlaybackCopy.seeking
    case .recoverableError: return PlaybackCopy.recoverableError
    case .unrecoverableError: return PlaybackCopy.unrecoverableError
    case .ended: return PlaybackCopy.ended
    }
  }
}
