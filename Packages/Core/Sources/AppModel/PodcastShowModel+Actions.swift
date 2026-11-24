import Foundation
import Persistence
import PlayerCore

extension PodcastShowModel {
  public func episodeTapped(_ episodeID: String) async {
    await performAction(.playPause, episodeID: episodeID)
  }

  public func playNext(_ episodeID: String) async {
    await performAction(.playNext, episodeID: episodeID)
  }

  public func addToUpNext(_ episodeID: String) async {
    await performAction(.addToUpNext, episodeID: episodeID)
  }

  public func download(_ episodeID: String) async {
    await performAction(.download, episodeID: episodeID)
  }

  public func pauseDownload(_ episodeID: String) async {
    await performAction(.pauseDownload, episodeID: episodeID)
  }

  public func resumeDownload(_ episodeID: String) async {
    await performAction(.resumeDownload, episodeID: episodeID)
  }

  public func removeDownload(_ episodeID: String) async {
    await performAction(.removeDownload, episodeID: episodeID)
  }

  public func markAsFinished(_ episodeID: String) async {
    await performAction(.markAsFinished, episodeID: episodeID)
  }

  public func resetProgress(_ episodeID: String) async {
    await performAction(.resetProgress, episodeID: episodeID)
  }

  public func isSaved(episodeID: String) -> Bool? {
    guard let savedStatus, savedStatus.hasResolvedMembership else { return nil }
    return savedStatus.isSaved(itemID: itemID, episodeID: episodeID)
  }

  public func isHiddenFromContinueListening(episodeID: String) -> Bool {
    continueListeningVisibility?.isHidden(itemID: itemID, episodeID: episodeID) ?? false
  }

  public func dismissQueueFeedback() {
    queueFeedbackMessage = nil
  }

  public func dismissSavedFeedback() {
    savedFeedbackMessage = nil
  }

  public func dismissContinueListeningFeedback() {
    continueListeningFeedbackMessage = nil
  }

  /// Routes a canonical episode action through the shared executor. The duration is resolved from
  /// this show's own cached episode row, so an uncached episode records none rather than borrowing
  /// a neighbour's or the show's duration.
  public func performAction(_ action: MediaItemAction, episodeID: String) async {
    let itemID = self.itemID
    let duration =
      action == .markAsFinished
      ? episodes.first { $0.id == episodeID }?.durationSeconds
      : nil
    await performEpisodeAction(action, itemID: itemID, episodeID: episodeID, duration: duration)
  }

  /// Selection is scoped to the current search/filter and current cached identities. Unsupported
  /// actions (including playback and server mutations requiring individual prompts) are no-ops.
  public func selectedActionTargets(
    _ action: MediaItemAction, episodeIDs: Set<String>,
    nowPlaying: ListeningIdentity? = nil
  ) -> [PodcastEpisodeSummary] {
    let eligible: [PodcastEpisodeSummary]
    switch action {
    case .download: eligible = episodesToDownload()
    case .removeDownload: eligible = episodesToRemove()
    case .markAsFinished: eligible = episodesToMark(isFinished: true)
    case .resetProgress:
      eligible = filteredEpisodes.filter { $0.isFinished || $0.progressSeconds > 0 }
    case .addToUpNext:
      eligible = filteredEpisodes.filter {
        ListeningQueueActionPolicy.availability(
          itemID: itemID, episodeID: $0.id, category: .podcast, nowPlaying: nowPlaying
        ).offersAddToUpNext
      }
    case .saveForLater:
      eligible = filteredEpisodes.filter { isSaved(episodeID: $0.id) == false }
    case .saveToServer:
      eligible = filteredEpisodes.filter { serverSave.acceptsSave($0) }
    default: eligible = []
    }
    return eligible.filter { episodeIDs.contains($0.id) }
  }

  /// Runs `action` over the eligible selected episodes and returns the ones that succeeded, so the
  /// screen can leave exactly the failures selected. Marking is one bulk call, so it reports every
  /// target or none. Episodes not reached after the show changed or the task was cancelled are not
  /// reported.
  @discardableResult
  public func performSelectedAction(
    _ action: MediaItemAction, episodeIDs: Set<String>,
    nowPlaying: ListeningIdentity? = nil
  ) async -> Set<String> {
    actionErrorMessage = nil
    guard action != .saveToServer else { return [] }
    serverSave.disarmShowSave()
    let targets = selectedActionTargets(action, episodeIDs: episodeIDs, nowPlaying: nowPlaying)
    guard targets.isEmpty == false else { return [] }
    let itemID = self.itemID
    if action == .markAsFinished || action == .resetProgress {
      let finished = action == .markAsFinished
      let changes = targets.map {
        EpisodeProgressChange(
          episodeID: $0.id, currentTime: finished ? max(0, $0.durationSeconds ?? 0) : 0)
      }
      let didMark = await performBulk {
        try await episodeIntents.markAll(itemID: itemID, episodes: changes, isFinished: finished)
      }
      return didMark ? Set(targets.map(\.id)) : []
    }
    var failureMessage: String?
    var succeeded: Set<String> = []
    for episode in targets {
      guard itemID == self.itemID, Task.isCancelled == false else { break }
      if await performEpisodeAction(action, itemID: itemID, episodeID: episode.id, duration: nil) {
        succeeded.insert(episode.id)
      }
      if let actionErrorMessage { failureMessage = actionErrorMessage }
    }
    guard itemID == self.itemID else { return [] }
    if let failureMessage {
      actionErrorMessage = failureMessage
      queueFeedbackMessage = nil
      savedFeedbackMessage = nil
    }
    return succeeded
  }

  public func markAllAsPlayed() async {
    await markAll(isFinished: true)
  }

  public func markAllAsUnplayed() async {
    await markAll(isFinished: false)
  }

  public func episodesToMark(isFinished: Bool) -> [PodcastEpisodeSummary] {
    filteredEpisodes.filter { $0.isFinished != isFinished }
  }

  public func episodesToDownload() -> [PodcastEpisodeSummary] {
    filteredEpisodes.filter { $0.isAvailableOnServer && $0.downloadStatus == .notDownloaded }
  }

  public func episodesToRemove() -> [PodcastEpisodeSummary] {
    filteredEpisodes.filter {
      $0.downloadStatus != .notDownloaded && $0.downloadStatus != .deleting
    }
  }

  public func downloadAllInFilter() async {
    let itemID = self.itemID
    await performEpisodeActions(.download, itemID: itemID, episodes: episodesToDownload())
  }

  public func removeAllDownloadsInFilter() async {
    let itemID = self.itemID
    await performEpisodeActions(.removeDownload, itemID: itemID, episodes: episodesToRemove())
  }

  private func markAll(isFinished: Bool) async {
    let targets = episodesToMark(isFinished: isFinished)
    guard targets.isEmpty == false else { return }
    let changes = targets.map { episode in
      EpisodeProgressChange(
        episodeID: episode.id,
        currentTime: isFinished ? max(0, episode.durationSeconds ?? 0) : 0)
    }
    await performBulk {
      try await episodeIntents.markAll(
        itemID: itemID, episodes: changes, isFinished: isFinished)
    }
  }

  /// Whether the intent succeeded for a show that is still this one. A result the executor drops
  /// because the show changed underneath it is not a success.
  @discardableResult
  private func performEpisodeAction(
    _ action: MediaItemAction,
    itemID: String,
    episodeID: String,
    duration: Double?
  ) async -> Bool {
    queueFeedbackMessage = nil
    savedFeedbackMessage = nil
    continueListeningFeedbackMessage = nil
    let didSucceed = EpisodeActionSuccess()
    await episodeActionExecutor.execute(
      action: action,
      itemID: itemID,
      episodeID: episodeID,
      duration: duration,
      currentItemID: { [weak self] in self?.itemID },
      onSuccess: { [weak self] outcome in
        didSucceed.value = true
        guard let self else { return }
        self.actionErrorMessage = nil
        switch action {
        case .playNext:
          self.queueFeedbackMessage = ListeningQueueCopy.playNextConfirmation(
            afterList: self.activeSmartListName())
        case .addToUpNext:
          self.queueFeedbackMessage = ListeningQueueCopy.addedToUpNext
        case .saveForLater:
          if case .saved(.alreadySaved) = outcome {
            self.savedFeedbackMessage = SavedForLaterCopy.alreadySaved
          } else {
            self.savedFeedbackMessage = SavedForLaterCopy.saved
          }
        case .removeFromSaved:
          self.savedFeedbackMessage = SavedForLaterCopy.removed
        case .removeFromContinueListening:
          self.continueListeningFeedbackMessage = ContinueListeningCopy.removed
        default:
          self.queueFeedbackMessage = nil
        }
      },
      onFailure: { [weak self] message in self?.actionErrorMessage = message })
    return didSucceed.value
  }

  private func performEpisodeActions(
    _ action: MediaItemAction, itemID: String, episodes: [PodcastEpisodeSummary]
  ) async {
    for episode in episodes {
      await performEpisodeAction(action, itemID: itemID, episodeID: episode.id, duration: nil)
    }
  }

  /// Whether the bulk call succeeded for a show that is still this one.
  @discardableResult
  private func performBulk(_ action: () async throws -> Void) async -> Bool {
    let itemID = self.itemID
    do {
      try await action()
      guard itemID == self.itemID else { return false }
      actionErrorMessage = nil
      return true
    } catch {
      guard itemID == self.itemID else { return false }
      actionErrorMessage = PodcastEpisodeIntentExecutor.errorMessage(for: error)
      return false
    }
  }
}

/// Set by the executor's success callback, which is escaping and cannot write a local.
@MainActor private final class EpisodeActionSuccess {
  var value = false
}
