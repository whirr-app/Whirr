import Foundation
import Observation
import Persistence
import SyncEngine

/// One collection or playlist: its held entries in the server's order, followed by server identity
/// so it survives a refresh that replaces the stored rows, and reporting `.unavailable` when a
/// refresh removes the list.
///
/// It also owns the two list-level actions' targets, both skipping finished entries and entries
/// without audio. Play starts the first target and, only if that start happened, puts the rest at
/// the front of Up Next in order, moving any already queued. When every entry with audio is
/// finished, Play replays the first from its start and queues nothing, as Up Next would resume a
/// finished title at its saved position. Add to Up Next runs in the screen through
/// `ItemActionsModel.performBatch` with `upNextTargets`, sharing the batch banner and the queue
/// intent's RSS handling.
///
/// Members are server entries: an episode is always `.podcastEpisode`, never resolved to a native
/// RSS episode.
@MainActor
@Observable
public final class LibraryCollectionModel {
  public enum State: Sendable, Equatable {
    case loading
    /// Stored, but the local catalogue holds none of its members.
    case empty
    case loaded
    /// Not stored: removed by a refresh, or its library is no longer included.
    case unavailable
  }

  public let key: LibraryCollectionKey
  public private(set) var state: State = .loading
  /// The last stored listing seen, kept after the list becomes unavailable so the screen can
  /// still name it.
  public private(set) var listing: LibraryCollectionListing?
  public private(set) var entries: [LibraryCollectionEntry] = []
  public private(set) var isStartingPlay = false

  /// Unfinished entries with audio, in order: what Play and Add to Up Next act on.
  public var playableEntries: [LibraryCollectionEntry] { entries.filter(Self.isPlayable) }

  /// What Play replays when nothing is unfinished: the first entry with audio.
  public var replayEntry: LibraryCollectionEntry? {
    playableEntries.isEmpty ? entries.first(where: Self.hasAudio) : nil
  }

  public var canPlay: Bool { playableEntries.isEmpty == false || replayEntry != nil }

  public var upNextTargets: [ItemBatchTarget] {
    playableEntries.map { entry in
      ItemBatchTarget(
        itemID: entry.itemID, episodeID: entry.episodeID, category: entry.category,
        durationSeconds: entry.durationSeconds, downloadFormat: nil)
    }
  }

  private let queue: any ListeningQueueStoring
  private let reading: any LibraryCollectionReading
  private let startPlayback: @MainActor (_ itemID: String, _ episodeID: String?, _ fromStart: Bool) async -> Bool
  @ObservationIgnored private var contentsTask: Task<Void, Never>?

  /// `startPlayback` reports whether the start happened; the App binds it to
  /// `PlaybackModel.startReportingSuccess(itemID:episodeID:fromStart:)`.
  public init(
    key: LibraryCollectionKey,
    reading: any LibraryCollectionReading,
    queue: any ListeningQueueStoring,
    startPlayback:
      @escaping @MainActor (_ itemID: String, _ episodeID: String?, _ fromStart: Bool) async -> Bool
  ) {
    self.key = key
    self.queue = queue
    self.reading = reading
    self.startPlayback = startPlayback
    contentsTask = Task { [weak self, reading, key] in
      for await contents in reading.observeContents(key: key) {
        guard let self, Task.isCancelled == false else { return }
        self.apply(contents)
      }
    }
  }

  deinit {
    contentsTask?.cancel()
  }

  /// Starts the first playable entry and, if it started, inserts the rest at the front of Up
  /// Next. Returns whether playback started. A failed start leaves Up Next untouched.
  @discardableResult
  public func play() async -> Bool {
    guard isStartingPlay == false else { return false }
    if let replay = replayEntry {
      isStartingPlay = true
      defer { isStartingPlay = false }
      return await startPlayback(replay.itemID, replay.episodeID, true)
    }
    let targets = playableEntries
    guard let first = targets.first else { return false }
    isStartingPlay = true
    defer { isStartingPlay = false }

    guard await startPlayback(first.itemID, first.episodeID, false) else { return false }
    let rest = targets.dropFirst().compactMap(Self.identity)
    if rest.isEmpty == false {
      // Rejections (an ebook the catalogue mislabelled, an episode gone since) are skipped by
      // the store; a thrown error leaves the queue as it was and playback already started.
      _ = try? await queue.insertNext(identities: rest)
    }
    return true
  }

  private func apply(_ contents: LibraryCollectionContents?) {
    guard let contents else {
      entries = []
      state = .unavailable
      return
    }
    listing = contents.listing
    entries = contents.entries
    state = contents.entries.isEmpty ? .empty : .loaded
  }

  static func isPlayable(_ entry: LibraryCollectionEntry) -> Bool {
    entry.isFinished == false && hasAudio(entry)
  }

  private static func hasAudio(_ entry: LibraryCollectionEntry) -> Bool {
    switch entry {
    case .title(let summary, _): return summary.category == .audiobook
    case .episode: return true
    }
  }

  private static func identity(_ entry: LibraryCollectionEntry) -> ListeningIdentity? {
    switch entry {
    case .title(let summary, _): .audiobook(itemID: summary.serverItemId)
    case .episode(let episode): .podcastEpisode(itemID: episode.itemID, episodeID: episode.episodeID)
    }
  }
}
