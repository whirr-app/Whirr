import Persistence

/// Every action a multi-select toolbar can apply through `ItemActionsModel`. Each screen keeps its
/// own action enum and confirmation rules and maps onto this one.
public enum ItemBatchAction: Sendable, Equatable {
  case download
  case removeDownload
  case markAsFinished
  case resetProgress
  case addToUpNext
  case saveForLater
  case removeFromSaved
  case removeFromContinueListening
}

/// One selected row as the batch needs it. The screen resolves `downloadFormat` with its own
/// policy; `nil` means the row has no format to download and the batch refuses it.
public struct ItemBatchTarget: Sendable, Hashable {
  public let itemID: String
  public let episodeID: String?
  public let category: ItemMediaCategory
  public let durationSeconds: Double?
  public let downloadFormat: ItemDownloadFormat?

  public init(
    itemID: String,
    episodeID: String?,
    category: ItemMediaCategory,
    durationSeconds: Double?,
    downloadFormat: ItemDownloadFormat?
  ) {
    self.itemID = itemID
    self.episodeID = episodeID
    self.category = category
    self.durationSeconds = durationSeconds
    self.downloadFormat = downloadFormat
  }
}

/// What a batch did to each target, in the order the targets ran.
public struct ItemBatchOutcome: Sendable, Equatable {
  public struct Entry: Sendable, Equatable {
    public let target: ItemBatchTarget
    /// `nil` when the batch stopped before reaching this target.
    public let result: ItemActionResult?
  }

  public let entries: [Entry]
  /// The screen's error copy as the last failing intent wrote it; `nil` when nothing failed.
  public let failureMessage: String?

  public var succeeded: Set<ItemBatchTarget> { targets(where: { $0 == .succeeded }) }
  public var failed: Set<ItemBatchTarget> { targets(where: { $0 == .failed }) }
  public var skipped: Set<ItemBatchTarget> { targets(where: { $0 == .refused }) }
  public var notAttempted: Set<ItemBatchTarget> { targets(where: { $0 == nil }) }
  public var isComplete: Bool { entries.allSatisfy { $0.result != nil } }

  private func targets(where matches: (ItemActionResult?) -> Bool) -> Set<ItemBatchTarget> {
    Set(entries.filter { matches($0.result) }.map(\.target))
  }
}

extension ItemActionsModel {
  /// Applies `action` to each target one at a time, in the order given, and carries on past a
  /// failure. Cancellation is checked between targets; whatever has not started is reported as not
  /// attempted. The screen's alert stays the single failure report: on any failure every success
  /// banner is dismissed, and `actionErrorMessage` keeps the last failure's copy.
  public func performBatch(
    _ action: ItemBatchAction,
    on targets: [ItemBatchTarget],
    playback: PlaybackModel
  ) async -> ItemBatchOutcome {
    dismissActionError()
    let progress = PodcastEpisodeProgressActions(actions: self, playback: playback)
    var entries: [ItemBatchOutcome.Entry] = []
    var finishedIdentities: [ListeningIdentity] = []
    var stopped: (identity: ListeningIdentity, generation: Int)?
    for target in targets {
      guard Task.isCancelled == false else {
        entries.append(ItemBatchOutcome.Entry(target: target, result: nil))
        continue
      }
      if action == .markAsFinished {
        let finished = await progress.finish(
          itemID: target.itemID, episodeID: target.episodeID, duration: target.durationSeconds)
        entries.append(ItemBatchOutcome.Entry(target: target, result: finished.result))
        if let identity = finished.identity {
          finishedIdentities.append(identity)
          if let generation = finished.stoppedGeneration {
            stopped = (identity: identity, generation: generation)
          }
        }
        continue
      }
      let result = await perform(action, on: target, progress: progress)
      entries.append(ItemBatchOutcome.Entry(target: target, result: result))
    }
    // One continuation for the whole batch, after every target has run. Finishing several targets
    // one at a time could otherwise prepare a row a later target was about to finish.
    if let stopped {
      await progress.prepareContinuation(
        after: stopped.identity, generation: stopped.generation,
        alsoFinished: finishedIdentities)
    }
    let anyFailed = entries.contains { $0.result == .failed }
    if anyFailed {
      dismissQueueFeedback()
      dismissSavedFeedback()
      dismissContinueListeningFeedback()
    }
    return ItemBatchOutcome(entries: entries, failureMessage: anyFailed ? actionErrorMessage : nil)
  }

  private func perform(
    _ action: ItemBatchAction,
    on target: ItemBatchTarget,
    progress: PodcastEpisodeProgressActions
  ) async -> ItemActionResult {
    let itemID = target.itemID
    let episodeID = target.episodeID
    switch action {
    case .download:
      guard let format = target.downloadFormat else { return .refused }
      return await requestDownload(itemID: itemID, episodeID: episodeID, format: format)
    case .removeDownload:
      return await removeDownload(itemID: itemID, episodeID: episodeID)
    case .markAsFinished:
      return await progress.markAsFinished(
        itemID: itemID, episodeID: episodeID, duration: target.durationSeconds)
    case .resetProgress:
      return await progress.resetProgress(
        itemID: itemID, episodeID: episodeID, category: target.category)
    case .addToUpNext:
      return await addToUpNext(itemID: itemID, episodeID: episodeID)
    case .saveForLater:
      return await saveForLater(itemID: itemID, episodeID: episodeID)
    case .removeFromSaved:
      return await removeFromSaved(itemID: itemID, episodeID: episodeID)
    case .removeFromContinueListening:
      return await removeFromContinueListening(itemID: itemID, episodeID: episodeID)
    }
  }
}
