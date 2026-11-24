import Foundation
import SyncEngine

public struct PodcastShowBatchServerSaveSession: Sendable, Equatable {
  public enum Phase: Sendable, Equatable {
    case running
    case cancelling
    case awaitingChoice
  }

  public let id: UUID
  public let total: Int
  public private(set) var completed: Int
  public private(set) var phase: Phase
  /// Copied from the show-save mark when the batch began, so the view clearing its own
  /// selection later cannot race the enable that follows a created show.
  public let isShowSave: Bool

  init(id: UUID, total: Int, completed: Int, phase: Phase, isShowSave: Bool = false) {
    self.id = id
    self.total = total
    self.completed = completed
    self.phase = phase
    self.isShowSave = isShowSave
  }

  mutating func setPhase(_ phase: Phase) {
    self.phase = phase
  }

  mutating func incrementCompleted() {
    completed += 1
  }

  public var isWorking: Bool {
    phase == .running || phase == .cancelling
  }

  public var progressText: String? {
    guard isWorking else { return nil }
    switch phase {
    case .running:
      return NativeEpisodeServerSaveBatchCopy.progress(completed: completed, total: total)
    case .cancelling:
      return NativeEpisodeServerSaveBatchCopy.cancelling(completed: completed, total: total)
    case .awaitingChoice:
      return nil
    }
  }

  public var progressAccessibilityLabel: String? {
    guard isWorking else { return nil }
    return NativeEpisodeServerSaveBatchCopy.progressAccessibilityLabel(
      completed: completed, total: total)
  }
}

struct PodcastShowBatchServerSaveResume {
  let rowIDs: [Int64]
  let rowToEpisodeID: [Int64: String]
  let tally: NativeEpisodeServerSaveBatchCopy.Tally
}

extension PodcastShowServerSaveModel {
  public func beginBatchServerSave(episodeIDs: Set<String>) {
    guard let feedID = nativeFeedID, batchServerSave == nil, pendingServerSaveChoice == nil else {
      return
    }
    let targets = saveTargets(episodeIDs: episodeIDs)
    guard targets.isEmpty == false else { return }
    guard targets.count <= NativeEpisodeServerSaveBatchCopy.maximumEpisodesPerBatch else {
      updateActionError(
        NativeEpisodeServerSaveBatchCopy.limitExceeded(selected: targets.count))
      // The show page never displays `actionErrorMessage`; the banner is its channel for a batch.
      serverSaveBannerMessage = NativeEpisodeServerSaveBatchCopy.limitExceeded(selected: targets.count)
      return
    }

    let sessionID = UUID()
    let token = NativeEpisodeServerSaveBatchCancellationToken()
    let targetKeys = targets.map(\.id)
    batchServerSave = PodcastShowBatchServerSaveSession(
      id: sessionID, total: targetKeys.count, completed: 0, phase: .running,
      isShowSave: consumeShowSaveMark())
    batchServerSaveCancellation = token
    batchServerSavePendingEpisodeIDs = Set(targetKeys)
    batchServerSaveTally = NativeEpisodeServerSaveBatchCopy.Tally()
    batchServerSaveAppliedEpisodeIDs.removeAll()
    updateActionError(nil)
    // Members stay mid-mutation until their batch outcome lands, so a buffered stream snapshot
    // cannot replace the batch's own result between submission and projection.
    for key in targetKeys {
      serverSaveFences[key, default: .init()].beginMutation(clearingRemoval: false)
    }

    let generation = serverSavePresentationGeneration
    let itemID = self.itemID
    Task { [weak self] in
      guard let self else { return }
      await self.resolveAndRunBatchServerSave(
        generation: generation,
        sessionID: sessionID,
        itemID: itemID,
        feedID: feedID,
        targetKeys: targetKeys,
        cancellation: token)
    }
  }

  public func cancelBatchServerSave() {
    guard let session = batchServerSave else { return }
    if session.phase == .awaitingChoice {
      dismissServerSaveFeedback()
      return
    }
    batchServerSaveCancellation?.cancel()
    if session.phase == .running {
      batchServerSave?.setPhase(.cancelling)
    }
  }

  public func isBatchServerSaveMember(_ episodeID: String) -> Bool {
    batchServerSave != nil && batchServerSavePendingEpisodeIDs.contains(episodeID)
  }

  private func resolveAndRunBatchServerSave(
    generation: Int,
    sessionID: UUID,
    itemID: String,
    feedID: Int64,
    targetKeys: [String],
    cancellation: NativeEpisodeServerSaveBatchCancellationToken
  ) async {
    let resolved = await nativeEpisodeIDResolving.nativeEpisodeIDs(
      feedId: feedID, identityKeys: targetKeys)
    guard isCurrentBatch(generation: generation, sessionID: sessionID, itemID: itemID) else {
      return
    }

    for key in targetKeys where resolved[key] == nil {
      applyBatchMissingEpisode(key)
    }

    var rowIDs: [Int64] = []
    var rowToEpisodeID: [Int64: String] = [:]
    for key in targetKeys {
      guard let rowID = resolved[key] else { continue }
      rowIDs.append(rowID)
      rowToEpisodeID[rowID] = key
    }
    await runBatchServerSave(
      generation: generation,
      sessionID: sessionID,
      itemID: itemID,
      request: NativeEpisodeServerSaveBatchRequest(
        feedId: feedID, episodeIds: rowIDs, choice: nil),
      rowToEpisodeID: rowToEpisodeID,
      cancellation: cancellation)
  }

  func runBatchServerSave(
    generation: Int,
    sessionID: UUID,
    itemID: String,
    request: NativeEpisodeServerSaveBatchRequest,
    rowToEpisodeID: [Int64: String],
    cancellation: NativeEpisodeServerSaveBatchCancellationToken
  ) async {
    guard isCurrentBatch(generation: generation, sessionID: sessionID, itemID: itemID) else {
      return
    }
    batchServerSaveAppliedEpisodeIDs.removeAll()
    let saving = nativeEpisodeServerSaveBatchSaving
    // Only a run that itself chose a library and folder can create the show, and the first
    // accepted episode is the one that did.
    let createsShow = request.choice?.createsShow == true
    let creationSync = ShowCreationSyncRequest(requester: librarySyncRequester)
    let result = await saving.saveBatch(
      request,
      cancellation: cancellation,
      onEpisodeOutcome: { [weak self] outcome in
        // The show exists from the first accepted episode, so the sync starts then and not when
        // the rest of the batch ends. It does not depend on this model still showing the batch.
        if createsShow, outcome.outcome.wasAccepted { await creationSync.send() }
        guard let self else { return }
        await self.applyBatchEpisodeOutcome(
          outcome,
          generation: generation,
          sessionID: sessionID,
          itemID: itemID,
          rowToEpisodeID: rowToEpisodeID)
      })
    // A saver that returns an accepted outcome without delivering it still gets its one request.
    if createsShow, result.outcomes.contains(where: { $0.outcome.wasAccepted }) {
      creationSync.send()
    }
    guard isCurrentBatch(generation: generation, sessionID: sessionID, itemID: itemID) else {
      return
    }
    let enableTarget = showSaveEnableTarget(choice: request.choice, result: result)

    // The coordinator normally delivers each outcome through the callback. Precondition failures
    // and inert test doubles may return an outcome without calling it, so fold only rows not seen.
    for entry in result.outcomes
    where batchServerSaveAppliedEpisodeIDs.contains(entry.episodeId) == false {
      applyBatchEpisodeOutcome(
        entry,
        generation: generation,
        sessionID: sessionID,
        itemID: itemID,
        rowToEpisodeID: rowToEpisodeID)
    }
    guard isCurrentBatch(generation: generation, sessionID: sessionID, itemID: itemID) else {
      return
    }

    switch result.stop {
    case .needsChoice(let rowID, let attemptID, let prompt):
      guard let episodeID = rowToEpisodeID[rowID] else {
        finishBatchServerSave()
        return
      }
      let remainingRowIDs = [rowID] + result.notAttempted.filter { $0 != rowID }
      let remainingMap = Dictionary(
        uniqueKeysWithValues: remainingRowIDs.compactMap { rowID in
          rowToEpisodeID[rowID].map { (rowID, $0) }
        })
      batchServerSaveResume = PodcastShowBatchServerSaveResume(
        rowIDs: remainingRowIDs, rowToEpisodeID: remainingMap, tally: batchServerSaveTally)
      batchServerSave?.setPhase(.awaitingChoice)
      pendingServerSaveChoice = PendingServerSaveChoice(
        episodeID: episodeID,
        attemptID: attemptID,
        prompt: prompt,
        episodeCount: remainingRowIDs.count,
        batchID: sessionID)
    default:
      batchServerSaveTally.notAttempted += result.notAttempted.count
      batchServerSaveTally.cancelled = result.stop == .cancelled
      switch result.stop {
      case .failed(_, let category), .uncertain(_, _, let category):
        updateActionError(NativeEpisodeServerSaveCopy.disabledReason(for: category))
      default:
        break
      }
      finishBatchServerSave(createdShow: enableTarget != nil)
      // After the summary banner and the end of selection, never before and never in their way.
      if let enableTarget {
        await turnOnAutomaticDownloads(serverItemID: enableTarget, generation: generation)
      }
    }
  }

  private func isCurrentBatch(generation: Int, sessionID: UUID, itemID: String) -> Bool {
    generation == serverSavePresentationGeneration && batchServerSave?.id == sessionID
      && self.itemID == itemID
  }

  private func applyBatchMissingEpisode(_ episodeID: String) {
    serverSaveStatuses[episodeID] = .failed(.missingEpisode, phase: .save)
    serverSavePreflightPresence[episodeID] = nil
    serverSaveAttemptIDs[episodeID] = nil
    serverSaveFences[episodeID]?.endMutation()
    batchServerSavePendingEpisodeIDs.remove(episodeID)
    batchServerSaveTally.skipped += 1
    batchServerSave?.incrementCompleted()
  }

  private func applyBatchEpisodeOutcome(
    _ entry: NativeEpisodeServerSaveBatchEpisodeOutcome,
    generation: Int,
    sessionID: UUID,
    itemID: String,
    rowToEpisodeID: [Int64: String]
  ) {
    guard isCurrentBatch(generation: generation, sessionID: sessionID, itemID: itemID) else {
      return
    }
    guard batchServerSaveAppliedEpisodeIDs.insert(entry.episodeId).inserted else { return }
    guard let episodeID = rowToEpisodeID[entry.episodeId] else { return }
    let outcome = entry.outcome
    serverSaveFences[episodeID, default: .init()].record(outcome)
    if case .needsChoice = outcome {
      serverSaveAttemptIDs[episodeID] = outcome.attemptID
      serverSaveStatuses[episodeID] = .preparing
      return
    }

    serverSaveFences[episodeID]?.endMutation()
    batchServerSavePendingEpisodeIDs.remove(episodeID)
    applyBatchMaps(outcome, episodeID: episodeID)
    if case .accepted(let attemptID, _) = outcome {
      batchServerSaveRequestedAttemptIDs.insert(attemptID)
    }
    batchServerSaveTally.adding(outcome)
    batchServerSave?.incrementCompleted()
  }

  private func applyBatchMaps(
    _ outcome: NativeEpisodeServerSaveOutcome,
    episodeID: String
  ) {
    serverSaveAttemptIDs[episodeID] = outcome.attemptID
    serverSavePreflightPresence[episodeID] = nil
    let status: NativeEpisodeServerSaveStatus
    switch outcome {
    case .needsChoice:
      status = .preparing
    case .alreadyPresent:
      status = .saved
    case .accepted:
      status = .requested
    case .uncertain(_, _, let category):
      status = .uncertain(category, phase: .save)
    case .failed(_, _, let category):
      status = .failed(category, phase: .save)
    case .inProgress(_, let state, _):
      status = NativeEpisodeServerSaveStatus.status(for: state, category: .unknown)
    }
    serverSaveStatuses[episodeID] = status
  }

  private func finishBatchServerSave(createdShow: Bool = false) {
    let summary = NativeEpisodeServerSaveBatchCopy.summary(batchServerSaveTally)
    serverSaveBannerMessage = createdShow ? NativeEpisodeServerSaveCopy.showSaved(summary: summary) : summary
    endBatchMemberMutations()
    batchServerSavePendingEpisodeIDs.removeAll()
    batchServerSave = nil
    batchServerSaveCancellation = nil
    batchServerSaveResume = nil
    batchServerSaveAppliedEpisodeIDs.removeAll()
    batchServerSaveCompletionVersion += 1
  }

  private func endBatchMemberMutations() {
    for key in batchServerSavePendingEpisodeIDs {
      serverSaveFences[key]?.endMutation()
    }
  }

  func clearBatchServerSaveAfterDismissal(episodeID: String) {
    batchServerSaveCancellation?.cancel()
    serverSaveStatuses[episodeID] = nil
    serverSavePreflightPresence[episodeID] = nil
    serverSaveAttemptIDs[episodeID] = nil
    if serverSaveCurrentEpisodeID == episodeID {
      serverSaveStatus = .none
    }
    endBatchMemberMutations()
    batchServerSavePendingEpisodeIDs.removeAll()
    batchServerSave = nil
    batchServerSaveCancellation = nil
    batchServerSaveResume = nil
    batchServerSaveAppliedEpisodeIDs.removeAll()
  }
}

/// Sends the library sync a created show needs, once per run however many episodes are accepted.
@MainActor
private final class ShowCreationSyncRequest {
  private let requester: any LibrarySyncRequesting
  private var isSent = false

  init(requester: any LibrarySyncRequesting) {
    self.requester = requester
  }

  func send() {
    guard isSent == false else { return }
    isSent = true
    // Not awaited: a whole-library sync must not hold the save's own result back.
    let requester = requester
    Task { await requester.requestLibrarySync() }
  }
}

extension NativeEpisodeServerSaveBatchCopy.Tally {
  fileprivate mutating func adding(_ outcome: NativeEpisodeServerSaveOutcome) {
    switch outcome {
    case .accepted:
      requested += 1
    case .alreadyPresent:
      alreadySaved += 1
    case .inProgress(_, let state, _):
      if state == .confirmed {
        alreadySaved += 1
      } else {
        inProgress += 1
      }
    case .failed(_, _, .missingEpisode):
      skipped += 1
    case .failed:
      failed += 1
    case .uncertain:
      uncertain += 1
    case .needsChoice:
      break
    }
  }
}
