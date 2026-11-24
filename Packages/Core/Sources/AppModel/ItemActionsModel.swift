import Observation
import Persistence
import SyncEngine

public enum SavedForLaterCopy {
  public static let saved = "Saved for Later"
  public static let alreadySaved = "Already Saved"
  public static let removed = "Removed from Saved"
  public static let saveFailed = "Couldn't save for later. Try again."
  public static let removeFailed = "Couldn't remove from Saved. Try again."
}

public enum ContinueListeningCopy {
  public static let action = "Remove from Continue Listening"
  public static let removed = "Removed from Continue Listening"
  public static let removeFailed = "Couldn't remove from Continue Listening. Try again."
}

/// What one item intent did. A batch reads this instead of the screen's single error slot, which
/// keeps only the last failure and stays silent for a refusal.
public enum ItemActionResult: Sendable, Equatable {
  case succeeded
  case failed
  /// Gated and never sent: today only a download intent on an identity that is mid-removal.
  case refused
}

public enum ItemContextMenuDownloadAction: Sendable, Equatable {
  case download
  case remove
  case unavailable

  public static func resolve(_ status: ItemDownloadStatus) -> Self {
    switch status {
    case .notDownloaded:
      return .download
    case .deleting:
      return .unavailable
    case .waitingForWiFi, .queued, .downloading, .paused, .pausedAuth, .interrupted, .failed, .completed:
      return .remove
    }
  }
}

/// One screen's item-action model: every long-press menu on a list delegates to this instance,
/// taking the item id as a parameter. Per-screen, not per-row, so:
///
/// - the failure message surfaces even when the row has scrolled away or been recycled;
/// - narrator lookups are cached per item across rows.
///
/// Download state comes from the screen's shared `DownloadStatusStore`; no observation of its own.
@MainActor
@Observable
public final class ItemActionsModel {
  /// The single failure message this screen is currently showing, from whichever item's intent
  /// most recently failed. One alert per screen, not one per row.
  public private(set) var actionErrorMessage: String?

  /// The last successful queue mutation's brief confirmation, from whichever item's intent most
  /// recently succeeded. One per screen, like `actionErrorMessage`. Per-item Undo is not offered;
  /// Clear Undo belongs to `ListeningQueueModel`.
  public private(set) var queueFeedbackMessage: String?

  /// The last successful Saved for Later action's brief confirmation, kept separate from queue
  /// feedback because the two actions have independent ownership and copy.
  public private(set) var savedFeedbackMessage: String?

  /// The last successful Continue Listening visibility mutation's brief confirmation. It is a
  /// separate channel so a shelf dismissal cannot overwrite queue or Saved for Later feedback.
  public private(set) var continueListeningFeedbackMessage: String?

  /// The last successful Send to E-reader confirmation. Failures and uncertain sends use
  /// `actionErrorMessage`, because both need the reader to act or check.
  public private(set) var ebookDeliveryFeedbackMessage: String?

  /// The devices the book menus may offer, from the most recent load. Menus render whatever is
  /// here and `loadEreaderDevicesIfNeeded` refreshes it; the service decides how fresh a read is.
  public private(set) var ereaderDevices: [EbookDeliveryDevice] = []

  private var narratorByItemID: [String: String] = [:]
  private var extrasTasks: [String: Task<ItemDetailExtras?, Never>] = [:]
  private var deviceLoad: Task<[EbookDeliveryDevice], Never>?
  private var ebookSendsInFlight: Set<EbookSendKey> = []

  private let downloadStatus: DownloadStatusStore
  private let downloadIntents: any DownloadIntents
  private let progressIntents: any ItemProgressIntents
  /// Only identifiers that strictly decode as native RSS are diverted. ABS and malformed ids
  /// take the account-scoped service path.
  private let episodeIntents: any PodcastEpisodeIntents
  private let extrasAccess: any ItemDetailExtrasAccess
  private let listeningQueue: any ListeningQueueStoring
  private let savedShelf: any SavedShelfStoring
  private let savedStatus: SavedStatusStore
  private let continueListeningVisibility: ContinueListeningVisibilityStore
  private let ebookDelivery: any EbookDelivering
  /// The active smart list's name, or nil. Play Next queues behind a run, so its confirmation
  /// names the list ("Plays after Commute").
  @ObservationIgnored private let activeSmartListName: @MainActor @Sendable () -> String?

  public init(
    downloadStatus: DownloadStatusStore,
    downloadIntents: any DownloadIntents,
    progressIntents: any ItemProgressIntents,
    extrasAccess: any ItemDetailExtrasAccess,
    listeningQueue: any ListeningQueueStoring = NoOpListeningQueueStore(),
    episodeIntents: any PodcastEpisodeIntents = NoOpPodcastEpisodeIntents(),
    savedShelf: any SavedShelfStoring = NoOpSavedShelfStore(),
    savedStatus: SavedStatusStore? = nil,
    continueListeningVisibility: ContinueListeningVisibilityStore? = nil,
    ebookDelivery: any EbookDelivering = NoOpEbookDelivering(),
    activeSmartListName: @escaping @MainActor @Sendable () -> String? = { nil }
  ) {
    self.activeSmartListName = activeSmartListName
    self.downloadStatus = downloadStatus
    self.downloadIntents = downloadIntents
    self.progressIntents = progressIntents
    self.episodeIntents = episodeIntents
    self.extrasAccess = extrasAccess
    self.listeningQueue = listeningQueue
    self.savedShelf = savedShelf
    self.savedStatus = savedStatus ?? SavedStatusStore(savedShelf: NoOpSavedShelfReading())
    self.continueListeningVisibility =
      continueListeningVisibility ?? ContinueListeningVisibilityStore(hidden: [])
    self.ebookDelivery = ebookDelivery
  }

  /// Both queue ends are offered wherever an episode or audiobook menu is.
  ///
  /// Which rows offer these entries is `ListeningQueueActionPolicy`'s decision, not this model's;
  /// a category mismatch that slipped past it is still rejected by the store.
  public func playNext(itemID: String, episodeID: String?) async {
    let confirmation = ListeningQueueCopy.playNextConfirmation(afterList: activeSmartListName())
    _ = await performQueueIntent(succeedingWith: confirmation) {
      if PodcastSourceIdentity(itemId: itemID)?.rssFeedId != nil {
        guard let episodeID else { throw Self.missingRSSEpisodeFailure }
        try await self.episodeIntents.playNext(itemID: itemID, episodeID: episodeID)
        return .added
      }
      let identity = try Self.identity(itemID: itemID, episodeID: episodeID)
      // An identity already queued is moved to the front, so this is always a mutation.
      try await self.listeningQueue.insertNext(identity: identity)
      return .added
    }
  }

  /// Queues one chapter of an audiobook at the front. A chapter already queued moves there; any
  /// other chapter takes a row of its own, and the whole book replaces its chapter rows. Always a
  /// mutation.
  public func playNext(itemID: String, chapter: ListeningQueueChapter) async {
    _ = await performQueueIntent(succeedingWith: ListeningQueueCopy.playingNext) {
      let identity = try Self.identity(itemID: itemID, episodeID: nil)
      try await self.listeningQueue.insertNext(identity: identity, chapter: chapter)
      return .added
    }
  }

  /// Queues one chapter of an audiobook at the end, in a row of its own. A chapter already queued
  /// is left where it is; a book queued whole keeps its place and takes this chapter instead.
  @discardableResult
  public func addToUpNext(itemID: String, chapter: ListeningQueueChapter) async -> ItemActionResult {
    await performQueueIntent(succeedingWith: ListeningQueueCopy.chapterAddedToUpNext) {
      let identity = try Self.identity(itemID: itemID, episodeID: nil)
      return Self.queueChange(try await self.listeningQueue.append(identity: identity, chapter: chapter))
    }
  }

  /// Queues several chapters of an audiobook at the end, in the order given, with one
  /// confirmation for the lot. A failure part-way leaves the chapters already queued in place.
  @discardableResult
  public func addToUpNext(itemID: String, chapters: [ListeningQueueChapter]) async -> ItemActionResult {
    var added = 0
    var replaced = false
    do {
      let identity = try Self.identity(itemID: itemID, episodeID: nil)
      for chapter in chapters {
        switch Self.queueChange(try await listeningQueue.append(identity: identity, chapter: chapter)) {
        case .added: added += 1
        case .replaced: replaced = true
        case .alreadyQueued: break
        }
      }
    } catch {
      queueFeedbackMessage = nil
      actionErrorMessage = ListeningQueueCopy.editFailed
      return .failed
    }
    queueFeedbackMessage =
      if replaced { ListeningQueueCopy.upNextUpdated } else if added == 0 { ListeningQueueCopy.alreadyInUpNext } else {
        ListeningQueueCopy.chaptersAddedToUpNext(added)
      }
    return .succeeded
  }

  @discardableResult
  public func addToUpNext(itemID: String, episodeID: String?) async -> ItemActionResult {
    await performQueueIntent(succeedingWith: ListeningQueueCopy.addedToUpNext) {
      if PodcastSourceIdentity(itemId: itemID)?.rssFeedId != nil {
        guard let episodeID else { throw Self.missingRSSEpisodeFailure }
        try await self.episodeIntents.addToUpNext(itemID: itemID, episodeID: episodeID)
        return .added
      }
      let identity = try Self.identity(itemID: itemID, episodeID: episodeID)
      return Self.queueChange(try await self.listeningQueue.append(identity: identity))
    }
  }

  /// The current membership for the exact whole-item or podcast-episode identity. Menus use this
  /// to choose Save for Later versus Remove from Saved without opening their own observation.
  public func isSaved(itemID: String, episodeID: String? = nil) -> Bool {
    savedStatus.isSaved(itemID: itemID, episodeID: episodeID)
  }

  /// Whether this item's whole-item or podcast-episode identity is hidden from Continue Listening.
  public func isHiddenFromContinueListening(itemID: String, episodeID: String? = nil) -> Bool {
    continueListeningVisibility.isHidden(itemID: itemID, episodeID: episodeID)
  }

  /// Whether the screen-wide Saved for Later membership projection has emitted its first value.
  public var hasResolvedSavedMembership: Bool {
    savedStatus.hasResolvedMembership
  }

  @discardableResult
  public func saveForLater(itemID: String, episodeID: String? = nil) async -> ItemActionResult {
    await performSavedIntent(failingWith: SavedForLaterCopy.saveFailed) {
      let outcome: SavedShelfSaveOutcome =
        switch try Self.savedIdentity(itemID: itemID, episodeID: episodeID) {
        case .rssEpisode(let itemID, let episodeID):
          try await self.episodeIntents.saveForLater(itemID: itemID, episodeID: episodeID)
        case let identity:
          try await self.savedShelf.save(identity)
        }
      return switch outcome {
      case .saved: SavedForLaterCopy.saved
      case .alreadySaved: SavedForLaterCopy.alreadySaved
      }
    }
  }

  @discardableResult
  public func removeFromSaved(itemID: String, episodeID: String? = nil) async -> ItemActionResult {
    await performSavedIntent(failingWith: SavedForLaterCopy.removeFailed) {
      switch try Self.savedIdentity(itemID: itemID, episodeID: episodeID) {
      case .rssEpisode(let itemID, let episodeID):
        try await self.episodeIntents.removeFromSaved(itemID: itemID, episodeID: episodeID)
      case let identity:
        try await self.savedShelf.remove(identity)
      }
      return SavedForLaterCopy.removed
    }
  }

  /// `episodeID` scopes every action on this model to one podcast episode; `nil` keeps the
  /// item-level behaviour every list row already relies on.
  public func downloadAction(for itemID: String, episodeID: String? = nil)
    -> ItemContextMenuDownloadAction
  {
    downloadStatus.downloadAction(for: itemID, episodeID: episodeID)
  }

  /// Whether every download row has finished. `downloadAction` cannot say: its `.remove` also
  /// covers queued, paused and failed downloads.
  public func isDownloadComplete(itemID: String, episodeID: String? = nil) -> Bool {
    downloadStatus.presence(for: itemID, episodeID: episodeID) == .completed
  }

  /// This item's narrator if already fetched; `nil` before the first fetch and for an item whose
  /// extras carry none. Never triggers a fetch: the menu renders what is cached and
  /// `loadExtrasIfNeeded` fills it in.
  public func narrator(for itemID: String) -> String? {
    narratorByItemID[itemID]
  }

  /// Fetches this item's expanded metadata at most once per item, per screen. Called when the
  /// system asks for the context-menu preview, never on the scroll path.
  public func loadExtrasIfNeeded(itemID: String) async {
    let task: Task<ItemDetailExtras?, Never>
    if let existing = extrasTasks[itemID] {
      task = existing
    } else {
      let access = extrasAccess
      let created = Task { await access.itemDetailExtras(itemId: itemID) }
      extrasTasks[itemID] = created
      task = created
    }
    guard let extras = await task.value else {
      extrasTasks[itemID] = nil
      return
    }
    if let narrator = extras.narrator {
      narratorByItemID[itemID] = narrator
    }
  }

  /// `format` is the medium the menu's row was for, not derived from the item's category: a mixed
  /// audiobook + EPUB has category `.audiobook`, so deriving it would download audio alone. Which
  /// formats an item may be asked for is `ItemMediaCapability.downloadFormats`.
  @discardableResult
  public func requestDownload(
    itemID: String, episodeID: String? = nil, format: ItemDownloadFormat = .audio
  ) async -> ItemActionResult {
    await performDownloadIntent(.download, itemID: itemID, episodeID: episodeID) {
      intents, itemID, episodeID in
      if PodcastSourceIdentity(itemId: itemID)?.rssFeedId != nil {
        guard let episodeID else { throw Self.missingRSSEpisodeFailure }
        try await self.episodeIntents.download(itemID: itemID, episodeID: episodeID)
        return
      }
      if let episodeID {
        try await intents.requestEpisodeDownload(itemID: itemID, episodeID: episodeID)
      } else {
        try await intents.requestDownload(itemID: itemID, format: format)
      }
    }
  }

  @discardableResult
  public func removeDownload(itemID: String, episodeID: String? = nil) async -> ItemActionResult {
    await performDownloadIntent(.remove, itemID: itemID, episodeID: episodeID) {
      intents, itemID, episodeID in
      if PodcastSourceIdentity(itemId: itemID)?.rssFeedId != nil {
        guard let episodeID else { throw Self.missingRSSEpisodeFailure }
        try await self.episodeIntents.removeDownload(itemID: itemID, episodeID: episodeID)
        return
      }
      if let episodeID {
        try await intents.purgeEpisodeDownload(
          itemID: itemID, episodeID: episodeID, source: .contextMenu)
      } else {
        try await intents.purgeItemDownload(itemID: itemID, source: .contextMenu)
      }
    }
  }

  @discardableResult
  public func resetProgress(
    itemID: String,
    episodeID: String? = nil,
    category: ItemMediaCategory = .audiobook
  ) async -> ItemActionResult {
    await performProgressIntent {
      if PodcastSourceIdentity(itemId: itemID)?.rssFeedId != nil {
        guard let episodeID else { throw Self.missingRSSEpisodeFailure }
        try await self.episodeIntents.resetProgress(itemID: itemID, episodeID: episodeID)
      } else if category == .ebook && episodeID == nil {
        try await self.progressIntents.resetEbookProgress(itemID: itemID)
      } else {
        try await self.progressIntents.resetProgress(itemID: itemID, episodeID: episodeID)
      }
    }
  }

  @discardableResult
  public func markAsFinished(
    itemID: String, episodeID: String? = nil, duration: Double?
  ) async -> ItemActionResult {
    await performProgressIntent {
      if PodcastSourceIdentity(itemId: itemID)?.rssFeedId != nil {
        guard let episodeID else { throw Self.missingRSSEpisodeFailure }
        try await self.episodeIntents.markAsFinished(
          itemID: itemID, episodeID: episodeID, duration: duration)
      } else {
        try await self.progressIntents.markAsFinished(
          itemID: itemID, episodeID: episodeID, duration: duration)
      }
    }
  }

  @discardableResult
  public func removeFromContinueListening(
    itemID: String, episodeID: String? = nil
  ) async -> ItemActionResult {
    await performContinueListeningIntent {
      if PodcastSourceIdentity(itemId: itemID)?.rssFeedId != nil {
        guard let episodeID else { throw Self.missingRSSEpisodeFailure }
        try await self.episodeIntents.removeFromContinueListening(
          itemID: itemID, episodeID: episodeID)
      } else {
        try await self.progressIntents.setContinueListeningVisibility(
          itemID: itemID, episodeID: episodeID, isHidden: true)
      }
      return ContinueListeningCopy.removed
    }
  }

  /// Called when a book menu is about to show. Overlapping calls share one read.
  public func loadEreaderDevicesIfNeeded() async {
    let task: Task<[EbookDeliveryDevice], Never>
    if let deviceLoad {
      task = deviceLoad
    } else {
      let delivery = ebookDelivery
      task = Task { await delivery.ereaderDevices() }
      deviceLoad = task
    }
    let devices = await task.value
    if deviceLoad == task { deviceLoad = nil }
    if ereaderDevices != devices { ereaderDevices = devices }
  }

  public func isSendingEbook(itemID: String, deviceName: String) -> Bool {
    ebookSendsInFlight.contains(EbookSendKey(itemID: itemID, deviceName: deviceName))
  }

  /// A tap on a device that is already sending this item is ignored rather than queued: the
  /// server's send is not idempotent.
  public func sendEbook(itemID: String, deviceName: String) async {
    let key = EbookSendKey(itemID: itemID, deviceName: deviceName)
    guard ebookSendsInFlight.insert(key).inserted else { return }
    let outcome = await ebookDelivery.sendEbook(itemID: itemID, deviceName: deviceName)
    ebookSendsInFlight.remove(key)

    switch outcome {
    case .sent:
      ebookDeliveryFeedbackMessage = EbookDeliveryCopy.sent(deviceName: deviceName)
    case .uncertain:
      actionErrorMessage = EbookDeliveryCopy.uncertain(deviceName: deviceName)
    case .notSent(let reason):
      actionErrorMessage = EbookDeliveryCopy.notSent(reason, deviceName: deviceName)
      if reason == .deviceNotFound { await loadEreaderDevicesIfNeeded() }
    }
  }

  public func dismissEbookDeliveryFeedback() {
    ebookDeliveryFeedbackMessage = nil
  }

  public func dismissActionError() {
    actionErrorMessage = nil
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

  private enum QueueChange {
    case added, replaced, alreadyQueued
  }

  private static func queueChange(_ outcome: ListeningQueueAppendOutcome) -> QueueChange {
    switch outcome {
    case .appended: .added
    case .replaced: .replaced
    case .alreadyQueued: .alreadyQueued
    }
  }

  /// A successful intent does not clear a message raised by a different item. The screen shows one
  /// alert, and dismissing it is the user's action.
  ///
  /// `intent` reports what it did to the queue. A second Add to Up Next for the same identity is
  /// an idempotent no-op, and the confirmation must not claim a mutation that never happened; a
  /// queued book that took a different chapter was changed, not added.
  private func performQueueIntent(
    succeedingWith message: String, _ intent: () async throws -> QueueChange
  ) async -> ItemActionResult {
    do {
      queueFeedbackMessage =
        switch try await intent() {
        case .added: message
        case .replaced: ListeningQueueCopy.upNextUpdated
        case .alreadyQueued: ListeningQueueCopy.alreadyInUpNext
        }
      return .succeeded
    } catch {
      queueFeedbackMessage = nil
      actionErrorMessage = ListeningQueueCopy.editFailed
      return .failed
    }
  }

  /// A successful saved intent does not clear a message raised by a different item; dismissing
  /// the screen's alert is the user's action. Saved feedback is independent of queue feedback.
  private func performSavedIntent(
    failingWith errorMessage: String, _ intent: () async throws -> String
  ) async -> ItemActionResult {
    do {
      savedFeedbackMessage = try await intent()
      return .succeeded
    } catch {
      savedFeedbackMessage = nil
      actionErrorMessage = errorMessage
      return .failed
    }
  }

  private func performContinueListeningIntent(
    _ intent: () async throws -> String
  ) async -> ItemActionResult {
    do {
      continueListeningFeedbackMessage = try await intent()
      return .succeeded
    } catch {
      continueListeningFeedbackMessage = nil
      actionErrorMessage = ContinueListeningCopy.removeFailed
      return .failed
    }
  }

  private static func identity(itemID: String, episodeID: String?) throws -> ListeningIdentity {
    let identity =
      if let episodeID {
        ListeningIdentity.podcastEpisode(itemID: itemID, episodeID: episodeID)
      } else {
        ListeningIdentity.audiobook(itemID: itemID)
      }
    guard let identity else { throw missingRSSEpisodeFailure }
    return identity
  }

  /// Native episodes still save through `episodeIntents`, which owns their failure copy and the
  /// unconfigured-shelf refusal; only the identity rule is shared with `SavedStatusStore`.
  private static func savedIdentity(itemID: String, episodeID: String?) throws
    -> SavedShelfIdentity
  {
    guard let identity = SavedShelfIdentity.resolving(itemID: itemID, episodeID: episodeID) else {
      throw missingRSSEpisodeFailure
    }
    return identity
  }

  private static let missingRSSEpisodeFailure = PodcastEpisodeIntentFailure(
    message: PodcastCopy.actionFailed)

  private func performProgressIntent(_ intent: () async throws -> Void) async -> ItemActionResult {
    do {
      try await intent()
      return .succeeded
    } catch {
      actionErrorMessage = "Couldn't update progress. Try again."
      return .failed
    }
  }

  /// Mirrors `ItemDownloadModel.perform`'s gate and copy: refused while the acted-on identity is
  /// mid-removal, and failures are surfaced. The gate reads the scope the intent writes, so a
  /// deleting episode never blocks its siblings.
  private func performDownloadIntent(
    _ action: ItemDownloadCopy.Action,
    itemID: String,
    episodeID: String?,
    _ intent: (any DownloadIntents, String, String?) async throws -> Void
  ) async -> ItemActionResult {
    guard downloadStatus.presence(for: itemID, episodeID: episodeID) != .deleting else {
      return .refused
    }
    do {
      try await intent(downloadIntents, itemID, episodeID)
      return .succeeded
    } catch {
      actionErrorMessage = ItemDownloadCopy.actionFailed(action, error: error)
      return .failed
    }
  }
}

private struct EbookSendKey: Hashable {
  let itemID: String
  let deviceName: String
}
