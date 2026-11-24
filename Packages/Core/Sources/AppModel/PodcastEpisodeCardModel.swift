import Observation
import Persistence
import SyncEngine

/// The episode card's self-loading model. Built from `(itemID, episodeID)`, it loads itself from
/// `PodcastReading.episode(itemID:episodeID:)` and exposes `PodcastEpisodeCardPresentation`.
///
/// Refresh piggybacks on `PodcastReading.observeEpisodes(itemId:)`, as `PodcastShowModel` does. It
/// emits the show's full episode list, so each tick only means "something about this show changed"
/// and re-runs the one-shot single-episode read.
@MainActor
@Observable
public final class PodcastEpisodeCardModel {
  public enum State: Sendable, Equatable {
    case loading
    case loaded(PodcastEpisodeCardPresentation)
    /// The store has no such episode (a stale search index, or a show purged from another screen
    /// while this card was coming up). The shell maps this to the fallback show push; it is not
    /// an error, so there is no retry here.
    case missing
  }

  public private(set) var state: State = .loading
  public internal(set) var actionErrorMessage: String?
  public private(set) var queueFeedbackMessage: String?
  public private(set) var savedFeedbackMessage: String?
  public private(set) var continueListeningFeedbackMessage: String?
  public internal(set) var serverSaveStatus: NativeEpisodeServerSaveStatus = .none
  public internal(set) var serverSaveFeedbackMessage: String?
  /// The transient confirmation for a result the listener just caused or was waiting on:
  /// requested, saved, removed. `serverSaveFeedbackMessage` mirrors the durable status for as
  /// long as it holds; this is raised once and cleared by the banner's own timer, and clearing it
  /// touches nothing else.
  public internal(set) var serverSaveBannerMessage: String?
  public internal(set) var pendingServerSaveChoice: PendingServerSaveChoice?
  public internal(set) var serverSavePreflightPresence: NativeEpisodeServerSavePreflightPresence?
  public internal(set) var serverSavePresentationVersion = 0

  public var isNativeFeed: Bool { nativeFeedID != nil }

  /// Whether this card can identify a Whirr-saved server copy: a native episode by its own RSS
  /// row, a server episode by the server episode id a Whirr save confirmed.
  public var hostsServerSaveRemoval: Bool { isNativeFeed || serverItemID != nil }

  public var isCredentialedNativeFeed: Bool { serverSaveCredentialedFeed }

  public var serverMutationCapability: ServerPodcastMutationCapability {
    serverPodcastMutationCapability
  }

  /// The card's live saved-membership read. An absent or unresolved store withholds the saved
  /// section so the menu never flashes the wrong action.
  public var isSaved: Bool? {
    guard let savedStatus, savedStatus.hasResolvedMembership else { return nil }
    return savedStatus.isSaved(itemID: itemID, episodeID: episodeID)
  }

  /// Whether this episode is already off the Continue Listening shelf. Unlike `isSaved` above this
  /// never withholds its answer: an unresolved projection reads as "not hidden", which offers a
  /// removal that is idempotent, where an unresolved saved membership would flash the wrong label.
  public var isHiddenFromContinueListening: Bool {
    continueListeningVisibility?.isHidden(itemID: itemID, episodeID: episodeID) ?? false
  }

  let itemID: String
  let episodeID: String
  private let reading: any PodcastReading
  private let episodeActionExecutor: PodcastEpisodeIntentExecutor
  private let savedStatus: SavedStatusStore?
  private let continueListeningVisibility: ContinueListeningVisibilityStore?
  let nativeEpisodeServerSaving: any NativeEpisodeServerSaving
  let nativeEpisodeServerSaveStatusReading: any NativeEpisodeServerSaveStatusReading
  let nativeEpisodeIDResolving: any NativeEpisodeIDResolving
  let serverPodcastMutationCapabilityReading: any ServerPodcastMutationCapabilityReading
  private let librarySyncRequester: any LibrarySyncRequesting
  /// The active smart list's name, or nil. Play Next queues behind a run, so its confirmation
  /// names the list ("Plays after Commute").
  @ObservationIgnored private let activeSmartListName: @MainActor @Sendable () -> String?
  var serverPodcastMutationCapability: ServerPodcastMutationCapability = .none
  let nativeFeedManaging: any NativeFeedManaging
  let nativePodcastSubscriptionsReading: any NativePodcastSubscriptionsReading
  let accountIdentityReading: any AccountIdentityReading
  var serverSaveCredentialedFeed = false
  /// The card consumes one aggregate stream for its one visible row. It is separate from the
  /// lifecycle observers so stopping/restarting a card can cancel only the status source.
  @ObservationIgnored var serverSaveStatusTask: Task<Void, Never>?
  @ObservationIgnored var serverSaveLifecycleTask: Task<Void, Never>?
  @ObservationIgnored var serverSaveAccountIdentityTask: Task<Void, Never>?
  var serverSavePresentationGeneration = 0
  @ObservationIgnored var serverSaveFence = NativeEpisodeServerSaveAttemptFence()
  /// Single-episode Save and Remove, shared with the show's server-save model.
  @ObservationIgnored let serverSavePresenter: NativeEpisodeServerSavePresenter
  /// The raw episode behind the current presentation, kept for facts the presentation does not
  /// carry: its own cached duration, needed by `markAsFinished`.
  private var loadedEpisode: PodcastEpisodeSummary?
  /// The show's recent descriptions behind `boilerplate`, kept so an unchanged list skips
  /// rebuilding the detector. Refreshed on episode-list emissions only, never on byte progress.
  private var recentDescriptions: [String]?
  private var boilerplate: ShowNotesBoilerplate = .none
  @ObservationIgnored private var observationTask: Task<Void, Never>?
  @ObservationIgnored private var downloadProgressTask: Task<Void, Never>?

  public init(
    itemID: String,
    episodeID: String,
    reading: any PodcastReading,
    nativeEpisodeIDResolving: any NativeEpisodeIDResolving = NoOpNativeEpisodeIDResolving(),
    episodeIntents: any PodcastEpisodeIntents = NoOpPodcastEpisodeIntents(),
    savedStatus: SavedStatusStore? = nil,
    continueListeningVisibility: ContinueListeningVisibilityStore? = nil,
    nativeEpisodeServerSaving: any NativeEpisodeServerSaving = NoOpNativeEpisodeServerSaving(),
    nativeEpisodeServerSaveStatusReading: any NativeEpisodeServerSaveStatusReading =
      NoOpNativeEpisodeServerSaveStatusReading(),
    serverPodcastMutationCapabilityReading: any ServerPodcastMutationCapabilityReading =
      NoOpServerPodcastMutationCapabilityReading(),
    nativeFeedManaging: any NativeFeedManaging = NoOpNativeFeedManaging(),
    nativePodcastSubscriptionsReading: any NativePodcastSubscriptionsReading =
      NoOpNativePodcastSubscriptionsReading(),
    accountIdentityReading: any AccountIdentityReading = NoOpAccountIdentityReading(),
    librarySyncRequester: any LibrarySyncRequesting = NoOpLibrarySyncRequester(),
    activeSmartListName: @escaping @MainActor @Sendable () -> String? = { nil }
  ) {
    self.activeSmartListName = activeSmartListName
    self.itemID = itemID
    self.episodeID = episodeID
    self.reading = reading
    self.episodeActionExecutor = PodcastEpisodeIntentExecutor(intents: episodeIntents)
    self.savedStatus = savedStatus
    self.continueListeningVisibility = continueListeningVisibility
    self.nativeEpisodeServerSaving = nativeEpisodeServerSaving
    self.nativeEpisodeServerSaveStatusReading = nativeEpisodeServerSaveStatusReading
    self.nativeEpisodeIDResolving = nativeEpisodeIDResolving
    self.serverPodcastMutationCapabilityReading = serverPodcastMutationCapabilityReading
    self.nativeFeedManaging = nativeFeedManaging
    self.nativePodcastSubscriptionsReading = nativePodcastSubscriptionsReading
    self.accountIdentityReading = accountIdentityReading
    self.librarySyncRequester = librarySyncRequester
    self.serverSavePresenter = NativeEpisodeServerSavePresenter(
      saving: nativeEpisodeServerSaving,
      resolving: nativeEpisodeIDResolving,
      librarySyncRequester: librarySyncRequester)
    startObserving()
  }

  deinit {
    observationTask?.cancel()
    downloadProgressTask?.cancel()
    serverSaveStatusTask?.cancel()
    serverSaveLifecycleTask?.cancel()
    serverSaveAccountIdentityTask?.cancel()
  }

  public func play() async {
    await performAction(.playPause)
  }

  public func playNext() async {
    await performAction(.playNext)
  }

  public func addToUpNext() async {
    await performAction(.addToUpNext)
  }

  public func download() async {
    await performAction(.download)
  }

  public func pauseDownload() async {
    await performAction(.pauseDownload)
  }

  public func resumeDownload() async {
    await performAction(.resumeDownload)
  }

  public func removeDownload() async {
    await performAction(.removeDownload)
  }

  public func markAsFinished() async {
    await performAction(.markAsFinished)
  }

  public func resetProgress() async {
    await performAction(.resetProgress)
  }

  public func removeFromContinueListening() async {
    await performAction(.removeFromContinueListening)
  }

  public func dismissSavedFeedback() {
    savedFeedbackMessage = nil
  }

  public func dismissQueueFeedback() {
    queueFeedbackMessage = nil
  }

  public func dismissContinueListeningFeedback() {
    continueListeningFeedbackMessage = nil
  }

  /// Begins the card's live episode observation. Repeated starts keep the existing observation.
  public func startObserving() {
    guard observationTask == nil else { return }

    startServerSaveLifecycleObservation()

    let itemID = self.itemID
    let episodeID = self.episodeID
    let episodeStream = reading.observeEpisodes(itemId: itemID)
    observationTask = Task { [weak self] in
      for await _ in episodeStream {
        guard Task.isCancelled == false, let self else { return }
        guard itemID == self.itemID, episodeID == self.episodeID else { return }
        await self.reload(refreshingBoilerplate: true)
      }
    }

    // The list does not move on byte progress, so the card's ring refreshes from the progress
    // projection, at a 2% quantum and only when this episode's own fraction changes.
    let progressStream = reading.observeEpisodeDownloadProgress(itemId: itemID)
    downloadProgressTask = Task { [weak self] in
      var lastFraction: Double?
      for await progress in progressStream {
        guard Task.isCancelled == false, let self else { return }
        guard itemID == self.itemID, episodeID == self.episodeID else { return }
        let fraction = progress[episodeID]
        guard fraction != lastFraction else { continue }
        lastFraction = fraction
        await self.reload()
      }
    }
  }

  /// Stops the card's live episode observation without changing its current rendering. Repeated
  /// stops are harmless; a later `startObserving()` creates a fresh observation stream.
  public func stopObserving() {
    observationTask?.cancel()
    observationTask = nil
    downloadProgressTask?.cancel()
    downloadProgressTask = nil
    serverSaveStatusTask?.cancel()
    serverSaveStatusTask = nil
    serverSaveLifecycleTask?.cancel()
    serverSaveLifecycleTask = nil
    serverSaveAccountIdentityTask?.cancel()
    serverSaveAccountIdentityTask = nil
  }

  /// The canonical episode menu's full dispatch, every entry routed through the same
  /// `episodeIntents` the show model uses. Stays exhaustive because the card's own controls
  /// dispatch through here too, so an action suppressed from the menu is still performed here.
  /// `.openShow` and `.moreFromCreator` are navigation/search concerns the shell owns.
  public func performAction(_ action: MediaItemAction) async {
    queueFeedbackMessage = nil
    savedFeedbackMessage = nil
    continueListeningFeedbackMessage = nil
    switch action {
    case .saveToServer:
      await saveEpisodeToServer()
      return
    case .removeFromServer:
      await removeEpisodeFromServer()
      return
    default:
      break
    }

    let duration = action == .markAsFinished ? loadedEpisode?.durationSeconds : nil
    await episodeActionExecutor.execute(
      action: action,
      itemID: itemID,
      episodeID: episodeID,
      duration: duration,
      currentItemID: { [weak self] in self?.itemID },
      onSuccess: { [weak self] outcome in
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
          break
        }
      },
      onFailure: { [weak self] message in self?.actionErrorMessage = message })
  }

  private func reload(refreshingBoilerplate: Bool = false) async {
    let itemID = self.itemID
    let episodeID = self.episodeID
    let context = try? await reading.episode(itemID: itemID, episodeID: episodeID)
    guard Task.isCancelled == false else { return }
    guard itemID == self.itemID, episodeID == self.episodeID else { return }
    if refreshingBoilerplate, context != nil {
      await refreshBoilerplate(itemID: itemID)
      guard Task.isCancelled == false, itemID == self.itemID, episodeID == self.episodeID else {
        return
      }
    }
    guard let context else {
      loadedEpisode = nil
      state = .missing
      return
    }
    loadedEpisode = context.episode
    state = .loaded(PodcastEpisodeCardPresentation(context: context, boilerplate: boilerplate))
    await refreshServerSaveProjection()
  }

  /// A failed read degrades to the single-episode fold rather than failing the card.
  private func refreshBoilerplate(itemID: String) async {
    let descriptions =
      (try? await reading.recentEpisodeDescriptions(
        itemId: itemID, limit: ShowNotesBoilerplate.window)) ?? []
    guard Task.isCancelled == false, descriptions != recentDescriptions else { return }
    // Up to 20 descriptions of HTML walked per list change: kept off the main actor.
    let detected = await Task.detached { ShowNotesBoilerplate(descriptions: descriptions) }.value
    guard Task.isCancelled == false else { return }
    recentDescriptions = descriptions
    boilerplate = detected
  }

  var nativeFeedID: Int64? {
    PodcastSourceIdentity(itemId: itemID)?.rssFeedId
  }

  var serverItemID: String? {
    PodcastSourceIdentity(itemId: itemID)?.absItemId
  }
}
