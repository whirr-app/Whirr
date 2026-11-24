import Foundation
import Persistence
import SyncEngine

/// Save Show to Audiobookshelf…
///
/// The menu item is a front door to the existing multi-select save. It enters selection with one
/// episode pre-selected and arms a mark; the batch the user then starts copies the mark into its
/// session, and if that batch created the show the model turns its automatic downloads on.

extension NativeEpisodeServerSaveCopy {
  public static let showSaveAction = "Save Show to Server\u{2026}"
  public static let showSaveHint =
    "Chooses episodes to copy to Audiobookshelf and turns on automatic downloads for a new show."
  /// Replaces the sole-destination footer, and is the picker's footer, for a show save.
  public static let showSaveDestinationLine =
    "New episodes will download automatically. Change this in Show Settings."
  /// The batch banner when the save created the show: the summary alone ("Requested 1 episode")
  /// does not say the show was saved, and its row only appears after the library sync.
  public static func showSaved(summary: String) -> String {
    "Show saved to Audiobookshelf. \(summary). It will appear in your library shortly."
  }
  public static let automaticDownloadsNotTurnedOn =
    "Automatic downloads were not turned on. Turn them on in Show Settings."
}

/// What the menu item reads. Observed, so the item appears and disappears with its inputs.
struct PodcastShowSaveState: Equatable {
  enum CredentialRead: Equatable {
    /// The read has not finished. The item stays hidden.
    case pending
    /// The read finished and the feed has no device-held credential.
    case noneFound
    case held
    /// The read threw. Hidden, like a held credential.
    case failed
  }

  var credentialRead: CredentialRead = .pending
  /// The server shows whose feed fingerprint equals this feed's. `nil` until a read has answered.
  var serverCopyItemIDs: [String]?
}

/// The mark, the injected seams and the observation tasks. Not observed: the view never reads
/// the mark, and a task handle changing must not invalidate the menu.
@MainActor
final class PodcastShowSaveSupport {
  let shows: any NativePodcastShowsReading
  let writer: any ServerPodcastAutomationSettingsWriting
  var isArmed = false
  var showTask: Task<Void, Never>?
  var copyTask: Task<Void, Never>?
  /// Whether the show stream has answered, and the fingerprint it carried.
  var hasShow = false
  var fingerprint: String?
  var observedFingerprint: String?

  init(
    shows: any NativePodcastShowsReading, writer: any ServerPodcastAutomationSettingsWriting
  ) {
    self.shows = shows
    self.writer = writer
  }

  func reset() {
    isArmed = false
    showTask?.cancel()
    showTask = nil
    copyTask?.cancel()
    copyTask = nil
    hasShow = false
    fingerprint = nil
    observedFingerprint = nil
  }

  deinit {
    showTask?.cancel()
    copyTask?.cancel()
  }
}

extension PodcastShowServerSaveModel {
  // MARK: Menu item

  /// True once the credential read has finished and found no credential. `isCredentialedNativeFeed`
  /// is false both while that read is pending and when it throws, so it cannot gate the item.
  public var isCredentialReadCompleteWithNoCredential: Bool {
    showSave.credentialRead == .noneFound
  }

  /// Whether the show page offers Save Show to Audiobookshelf…: a native feed whose account can
  /// save, whose credential read finished with none, with no server copy of the feed, and no
  /// episode with any server-save status (hiding the item straight after a save, before the
  /// library sync produces the copy's row). `serverSaveStatuses` covers the whole feed, not the
  /// loaded prefix.
  public var offersSaveShow: Bool {
    isNativeFeed && serverMutationCapability.canSave
      && showSave.credentialRead == .noneFound
      && showSave.serverCopyItemIDs?.isEmpty == true
      && serverSaveStatuses.values.allSatisfy { $0 == .none }
  }

  /// The episode the entry pre-selects: the first in the current filtered list (newest first)
  /// that the save action accepts. The filter and search are not changed. `nil` when none is.
  public var showSavePreselectedEpisodeID: String? {
    (host?.serverSaveVisibleEpisodes ?? []).first { acceptsSave($0) }?.id
  }

  // MARK: The mark

  public var isShowSaveArmed: Bool { showSaveSupport.isArmed }

  /// Armed by the menu handler as selection opens.
  public func armShowSave() {
    showSaveSupport.isArmed = true
  }

  /// Disarmed when selection mode ends and when another selection action runs.
  public func disarmShowSave() {
    showSaveSupport.isArmed = false
  }

  /// Read and cleared by `beginBatchServerSave` once a batch really starts.
  func consumeShowSaveMark() -> Bool {
    let armed = showSaveSupport.isArmed
    showSaveSupport.isArmed = false
    return armed
  }

  // MARK: Observation

  /// Starts afresh for the current `itemID`: pending credential, unknown copies, mark cleared.
  func restartShowSaveObservation() {
    showSaveSupport.reset()
    showSave = PodcastShowSaveState()
    guard nativeFeedID != nil else { return }
    let itemID = self.itemID
    let stream = showSaveSupport.shows.observeShow(itemId: itemID)
    showSaveSupport.showTask = Task { [weak self] in
      for await show in stream {
        guard let self, self.itemID == itemID else { return }
        // A cold route emits nil first; the answer is still unknown then.
        guard let show else { continue }
        self.showSaveSupport.hasShow = true
        self.showSaveSupport.fingerprint = show.podcastFeedFingerprint
        self.reconcileShowSaveCopies()
      }
    }
  }

  func applyShowSaveCredentialRead(_ credentialed: Bool?) {
    let read: PodcastShowSaveState.CredentialRead =
      switch credentialed {
      case .some(true): .held
      case .some(false): .noneFound
      case nil: .failed
      }
    if showSave.credentialRead != read { showSave.credentialRead = read }
    reconcileShowSaveCopies()
  }

  /// A feed with a device-held credential never reads the fingerprint (ADR 0006, SECURITY rule 19),
  /// and a credential state that is pending or failed counts as held.
  private func reconcileShowSaveCopies() {
    let support = showSaveSupport
    guard showSave.credentialRead == .noneFound, support.hasShow else {
      support.copyTask?.cancel()
      support.copyTask = nil
      support.observedFingerprint = nil
      setServerCopyItemIDs(nil)
      return
    }
    guard let fingerprint = support.fingerprint else {
      // The feed carries no fingerprint, so no server copy can be matched to it.
      support.copyTask?.cancel()
      support.copyTask = nil
      support.observedFingerprint = nil
      setServerCopyItemIDs([])
      return
    }
    guard support.observedFingerprint != fingerprint else { return }
    support.observedFingerprint = fingerprint
    support.copyTask?.cancel()
    setServerCopyItemIDs(nil)
    let stream = reading.observeServerCopyItemIDs(podcastFeedFingerprint: fingerprint)
    support.copyTask = Task { [weak self] in
      for await ids in stream {
        guard let self, self.showSaveSupport.observedFingerprint == fingerprint else { return }
        self.setServerCopyItemIDs(ids)
      }
    }
  }

  private func setServerCopyItemIDs(_ ids: [String]?) {
    if showSave.serverCopyItemIDs != ids { showSave.serverCopyItemIDs = ids }
  }

  // MARK: Turning downloads on

  /// The server item to enable, when this batch was a show save that created the show and had at
  /// least one episode accepted: its destination choice was `.libraryAndFolder` (the resolver
  /// never creates without that prompt), and the accepted episode is the one that created it.
  /// `reuse` and a chosen existing show create nothing and so enable nothing.
  func showSaveEnableTarget(
    choice: ServerPodcastSaveChoice?, result: NativeEpisodeServerSaveBatchResult
  ) -> String? {
    guard batchServerSave?.isShowSave == true, choice?.createsShow == true,
      result.outcomes.contains(where: { $0.outcome.wasAccepted }),
      let serverItemID = result.serverItemID, serverItemID.isEmpty == false
    else { return nil }
    return serverItemID
  }

  /// One write, from the response alone: the item has no local row until the next library sync,
  /// so nothing here refreshes one. The save stands whatever this returns.
  func turnOnAutomaticDownloads(serverItemID: String, generation: Int) async {
    let outcome = await showSaveSupport.writer.update(
      itemID: serverItemID,
      change: PodcastAutomationSettingsRequest(autoDownloadEpisodes: true),
      confirmation: .responseOnly)
    // A teardown while the request was in flight owns the presentation now.
    guard generation == serverSavePresentationGeneration else { return }
    switch outcome {
    case .confirmed, .accountChanged, .cancelled:
      break
    default:
      serverSaveBannerMessage = NativeEpisodeServerSaveCopy.automaticDownloadsNotTurnedOn
    }
  }
}
