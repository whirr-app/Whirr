import Foundation
import PlayerCore
import SyncEngine

/// Which loaded file a skip-range question is about. The file is part of the question because
/// ranges hold only for the file that was analysed.
public struct PlaybackSkipRangeRequest: Sendable, Equatable {
  public let itemID: String
  public let episodeID: String?
  public let fileURL: URL

  public init(itemID: String, episodeID: String?, fileURL: URL) {
    self.itemID = itemID
    self.episodeID = episodeID
    self.fileURL = fileURL
  }
}

/// Where `PlaybackModel` gets ranges to skip. The ad-skip coordinator is the production source;
/// it answers empty for a file it has not analysed or whose fingerprint no longer matches.
public protocol PlaybackSkipRangeSource: Sendable {
  func skipRanges(for request: PlaybackSkipRangeRequest) async -> [PlayerSkipRange]
  /// Yields whenever stored ranges may have changed.
  func skipRangeChanges() -> AsyncStream<Void>
  /// The listener undid this skip: never skip that ad again, here or anywhere it was learned.
  func undoSkip(_ range: PlayerSkipRange, for request: PlaybackSkipRangeRequest) async
  /// Whether the loaded file is being checked for ads, or why it is waiting.
  func analysisStatus(for request: PlaybackSkipRangeRequest) async -> PlaybackAdAnalysisStatus
  /// Yields whenever `analysisStatus` may have changed.
  func analysisStatusChanges() -> AsyncStream<Void>
  /// The listener's Check Now: analyse the loaded file even while analysis waits for charging.
  func checkNow(for request: PlaybackSkipRangeRequest) async
}

extension PlaybackSkipRangeSource {
  public func analysisStatus(for request: PlaybackSkipRangeRequest) async -> PlaybackAdAnalysisStatus {
    .none
  }

  public func analysisStatusChanges() -> AsyncStream<Void> {
    AsyncStream { $0.finish() }
  }

  public func checkNow(for request: PlaybackSkipRangeRequest) async {}
}

/// What the expanded player says about the loaded episode's ad analysis, shown only while the
/// episode is not ready, and whether ad skip is off for a file it would cover.
public enum PlaybackAdAnalysisStatus: Sendable, Equatable {
  /// Nothing to say: the setting is not known yet, the file is not one analysis covers, or it is
  /// analysed.
  case none
  /// Ad skip is off, and this file is one analysis would cover.
  case notEnabled
  /// The episode is being analysed, or is next.
  case checking
  /// Analysis is held, and the episode is not analysed yet.
  case waiting(Hold)

  public enum Hold: Sendable, Equatable {
    /// Power, Low Power Mode or heat; the app knows which.
    case conditions
    /// The speech model has not arrived.
    case speechModel
  }
}

/// The most recent skip, for the receipt. Only the in-app player shows it.
public struct PlaybackSkipReceipt: Sendable, Equatable {
  public let range: PlayerSkipRange
  /// Progress-event sequence of the skip, so a view can tell two skips of equal ranges apart.
  public let sequence: Int
  /// A range that ended the item has nothing to return to.
  public var canUndo: Bool { range.endsItem == false }

  public init(range: PlayerSkipRange, sequence: Int) {
    self.range = range
    self.sequence = sequence
  }
}

extension PlaybackModel {

  /// Asks for the loaded file's ranges and hands them to the player. Only a single-file local
  /// preparation qualifies: a stream can carry different dynamic ads from the analysed download.
  internal func loadSkipRanges(for prepared: PreparedPlayback, generation: Int) {
    skipRangeTask?.cancel()
    skipRangeTask = nil
    loadedSkipRequest = nil
    clearAnalysisStatus()
    guard let skipRanges, prepared.source == .local, prepared.tracks.count == 1,
      let track = prepared.tracks.first, track.url.isFileURL
    else { return }
    let request = PlaybackSkipRangeRequest(
      itemID: prepared.itemID, episodeID: prepared.episodeID, fileURL: track.url)
    loadedSkipRequest = request
    observeSkipRangeChanges(from: skipRanges)
    observeAnalysisStatusChanges(from: skipRanges)
    sendSkipRanges(for: request, from: skipRanges, generation: generation)
    refreshAnalysisStatus(for: request, from: skipRanges, generation: generation)
  }

  /// The listener's Check Now for the loaded file: analyse it even while analysis waits for
  /// charging. Low Power Mode and heat still hold it.
  public func checkLoadedEpisodeForAds() {
    guard let skipRanges, let request = loadedSkipRequest,
      let generation = loadedPlaybackGeneration
    else { return }
    Task { [weak self] in
      await skipRanges.checkNow(for: request)
      self?.refreshAnalysisStatus(for: request, from: skipRanges, generation: generation)
    }
  }

  /// Clears what a previous load set up; `setLoaded` calls it for every change of source. A
  /// receipt with Undo belongs to the loaded item and goes with it; one for a range that ended the
  /// item outlives the completion that unloads it (when it is shown), but not the next load.
  internal func resetSkipRanges(isUnload: Bool) {
    skipRangeTask?.cancel()
    skipRangeTask = nil
    loadedSkipRequest = nil
    clearAnalysisStatus()
    if isUnload == false || lastSkip?.canUndo == true { lastSkip = nil }
  }

  /// Returns to the start of the last skipped range and plays it, and tells the source to forget
  /// that ad.
  public func undoLastSkip() {
    guard let receipt = lastSkip, receipt.canUndo else { return }
    lastSkip = nil
    timeSaved?.add(-adSeconds(of: receipt.range), to: .ads)
    player.send(.undoSkip(receipt.range))
    guard let skipRanges, let request = loadedSkipRequest else { return }
    Task { await skipRanges.undoSkip(receipt.range, for: request) }
  }

  /// Undoes a range the transcript view showed, for the loaded episode, without the receipt. The
  /// coordinator's undo (`AdSkipCoordinator.undoRange`) is the caller's half and signals the
  /// player's ranges, which is what keeps a range still ahead from skipping.
  ///
  /// Only a skip that happened this load is sent to the player as `.undoSkip`, which returns to
  /// the range's start: the reducer's own record of what it skipped is not readable, so the one
  /// skip this model knows, the receipt's, stands for it. For any other range the player is left
  /// alone, since `.undoSkip` on a range ahead would seek forward into it. The receipt's `timeSaved`
  /// credit is taken back; no other skip's credit can be, as none is recorded.
  public func undoSkippedRange(_ range: TranscriptAdRange, itemID: String, episodeID: String?) {
    guard let request = loadedSkipRequest, request.itemID == itemID, request.episodeID == episodeID,
      let receipt = lastSkip, receipt.range.start < range.end, range.start < receipt.range.end
    else { return }
    lastSkip = nil
    timeSaved?.add(-adSeconds(of: receipt.range), to: .ads)
    player.send(.undoSkip(receipt.range))
  }

  internal func noteSkip(in event: PlaybackProgressEvent) {
    guard let range = event.skippedRange else { return }
    lastSkip = PlaybackSkipReceipt(range: range, sequence: event.sequence)
    timeSaved?.add(adSeconds(of: range), to: .ads)
  }

  private func sendSkipRanges(
    for request: PlaybackSkipRangeRequest, from source: any PlaybackSkipRangeSource, generation: Int
  ) {
    skipRangeTask?.cancel()
    skipRangeTask = Task { [weak self] in
      let ranges = await source.skipRanges(for: request)
      guard Task.isCancelled == false, let self, self.loadedSkipRequest == request,
        self.loadedPlaybackGeneration == generation
      else { return }
      // The reducer also ignores ranges for any item but the loaded one.
      self.player.send(
        .setSkipRanges(itemID: request.itemID, episodeID: request.episodeID, ranges: ranges))
    }
  }

  /// One observation for the model's lifetime, opened on the first local load.
  private func observeSkipRangeChanges(from source: any PlaybackSkipRangeSource) {
    guard skipRangeChangesTask == nil else { return }
    let changes = source.skipRangeChanges()
    skipRangeChangesTask = Task { [weak self] in
      for await _ in changes {
        guard let self, let request = self.loadedSkipRequest,
          let generation = self.loadedPlaybackGeneration
        else { continue }
        self.sendSkipRanges(for: request, from: source, generation: generation)
        // New ranges usually mean the episode just became ready.
        self.refreshAnalysisStatus(for: request, from: source, generation: generation)
      }
    }
  }

  private func clearAnalysisStatus() {
    analysisStatusTask?.cancel()
    analysisStatusTask = nil
    if adAnalysisStatus != .none { adAnalysisStatus = .none }
  }

  private func refreshAnalysisStatus(
    for request: PlaybackSkipRangeRequest, from source: any PlaybackSkipRangeSource, generation: Int
  ) {
    analysisStatusTask?.cancel()
    analysisStatusTask = Task { [weak self] in
      let status = await source.analysisStatus(for: request)
      guard Task.isCancelled == false, let self, self.loadedSkipRequest == request,
        self.loadedPlaybackGeneration == generation
      else { return }
      if self.adAnalysisStatus != status { self.adAnalysisStatus = status }
    }
  }

  /// One observation for the model's lifetime, opened on the first local load.
  private func observeAnalysisStatusChanges(from source: any PlaybackSkipRangeSource) {
    guard analysisStatusChangesTask == nil else { return }
    let changes = source.analysisStatusChanges()
    analysisStatusChangesTask = Task { [weak self] in
      for await _ in changes {
        guard let self, let request = self.loadedSkipRequest,
          let generation = self.loadedPlaybackGeneration
        else { continue }
        self.refreshAnalysisStatus(for: request, from: source, generation: generation)
      }
    }
  }
}
