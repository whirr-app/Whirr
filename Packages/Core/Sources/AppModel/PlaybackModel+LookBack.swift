import Foundation
import SyncEngine

/// The loaded book as Look Back sees it: its downloaded files on the book's clock and its
/// chapters.
public struct LookBackSource: Sendable, Equatable {
  public struct Chapter: Sendable, Equatable {
    public let start: Double
    public let title: String

    public init(start: Double, title: String) {
      self.start = start
      self.title = title
    }
  }

  public let itemID: String
  public let tracks: [LookBackTrack]
  public let chapters: [Chapter]

  public init(itemID: String, tracks: [LookBackTrack], chapters: [Chapter]) {
    self.itemID = itemID
    self.tracks = tracks
    self.chapters = chapters
  }
}

extension PlaybackModel {
  /// Records the book's files for Look Back. Called at both load sites, a fresh load and a
  /// streaming-to-local promotion, after `setLoaded` has cleared the previous one: a book
  /// downloaded mid-play becomes local only through promotion.
  internal func loadLookBack(for prepared: PreparedPlayback) {
    guard prepared.source == .local, prepared.episodeID == nil, prepared.tracks.isEmpty == false,
      prepared.tracks.allSatisfy({ $0.url.isFileURL })
    else { return }
    loadedLookBack = LookBackSource(
      itemID: prepared.itemID,
      tracks: prepared.tracks.map {
        LookBackTrack(fileURL: $0.url, startOffset: $0.startOffset, duration: $0.duration)
      },
      chapters: prepared.chapters.map { LookBackSource.Chapter(start: $0.start, title: $0.title ?? "") })
  }

  /// Whether `itemID` is the unfinished audiobook a cold launch restored, shown but not yet loaded.
  /// Look Back is offered for it, and `loadForLookBack` loads it on demand. A finished bookmark is
  /// retained for its metadata but is not shown anywhere, so it is not a restored book.
  public func isRestoredAudiobook(itemID: String) -> Bool {
    guard activeItemID == nil, let bookmark = displayedItem, bookmark.isFinished == false
    else { return false }
    return bookmark.serverItemId == itemID && bookmark.episodeID == nil
  }

  /// Loads `itemID` paused so Look Back has its files and playhead, as a chapter skip on a cold
  /// launch does: the restored book is shown, but nothing is loaded until playback is asked for.
  /// True when `itemID` is the loaded book afterwards; a failed start leaves its own message.
  public func loadForLookBack(itemID: String) async -> Bool {
    if isLoaded(itemID: itemID, episodeID: nil) { return true }
    guard isRestoredAudiobook(itemID: itemID) else { return false }
    await start(
      itemID: itemID, episodeID: nil, fromStart: false, origin: .requested,
      forceFreshSession: false, expectedGeneration: playbackGeneration, playAfterStart: false)
    return isLoaded(itemID: itemID, episodeID: nil)
  }

  /// Pauses the loaded item; does nothing when playback is not intended. `togglePlayPause()` is
  /// wrong for this: it would start a paused book.
  public func pause() {
    guard player.isPlaybackIntended else { return }
    player.send(.pause)
  }

  /// Pauses and returns the playhead, in book time, for a Look Back opening now. Views
  /// read no playhead themselves, so the sheet's host takes it from here.
  public func pauseForLookBack() -> Double {
    pause()
    return currentTime
  }

  /// Seeks the loaded item to `offset` and plays from there.
  public func play(fromGlobalOffset offset: Double) {
    player.send(.seek(toGlobalOffset: offset))
    guard player.isPlaybackIntended == false else { return }
    if resumeThroughFreshLocalSessionIfLatched() { return }
    player.send(.play)
  }
}
