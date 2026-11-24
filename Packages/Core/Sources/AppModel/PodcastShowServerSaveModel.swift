import Foundation
import Persistence
import SyncEngine

/// The request retained while the destination sheet is open. It carries only the opaque choice
/// values supplied by SyncEngine; no URL, path, or server response crosses into AppModel.
public struct PendingServerSaveChoice: Sendable, Equatable {
  public let episodeID: String
  public let attemptID: Int64
  public let prompt: NativeEpisodeServerSaveChoicePrompt
  public let episodeCount: Int
  public let batchID: UUID?

  public init(
    episodeID: String,
    attemptID: Int64,
    prompt: NativeEpisodeServerSaveChoicePrompt,
    episodeCount: Int = 1,
    batchID: UUID? = nil
  ) {
    self.episodeID = episodeID
    self.attemptID = attemptID
    self.prompt = prompt
    self.episodeCount = episodeCount
    self.batchID = batchID
  }
}

public struct NoOpNativeEpisodeServerSaving: NativeEpisodeServerSaving, Sendable {
  public init() {}

  public func save(
    feedId: Int64,
    episodeId: Int64,
    choice: ServerPodcastSaveChoice?
  ) async -> NativeEpisodeServerSaveOutcome {
    .failed(attemptID: nil, state: .failed, category: .permissionChanged)
  }

  public func remove(attemptID: Int64) async -> NativeEpisodeServerSaveOutcome {
    .failed(attemptID: attemptID, state: .deleteFailed, category: .permissionChanged)
  }
}

/// What `PodcastShowServerSaveModel` reads from the show that owns it. Read at the moment of use,
/// never stored: the episode list includes the first-frame prefix, which arrives without an
/// emission.
@MainActor
protocol PodcastShowServerSaveHost: AnyObject {
  /// Every cached episode of the show.
  var serverSaveEpisodes: [PodcastEpisodeSummary] { get }
  /// The episodes the current filter and search show; selection is scoped to these.
  var serverSaveVisibleEpisodes: [PodcastEpisodeSummary] { get }
  /// The show's one action-error channel, shared with its episode actions.
  func reportServerSaveActionError(_ message: String?)
}

/// Single-episode server save, batch server save and Save Show for one podcast show. Owned by
/// `PodcastShowModel`, which hands it the show's episodes through `PodcastShowServerSaveHost` and
/// asks for a teardown when the show changes.
///
/// Every asynchronous result is applied only if `serverSavePresentationGeneration` still holds the
/// value captured when its work began; every teardown bumps it before clearing anything.
@MainActor
@Observable
public final class PodcastShowServerSaveModel {
  public internal(set) var serverSaveStatus: NativeEpisodeServerSaveStatus = .none
  public internal(set) var serverSaveFeedbackMessage: String?
  /// The transient confirmation for a server-save result the listener just caused or was waiting
  /// on: requested, saved, removed. Unlike `serverSaveFeedbackMessage`, which mirrors the durable
  /// status for as long as it holds, this is raised once and cleared by the banner's own timer.
  /// Clearing it touches nothing else (no pending choice, no cached status).
  public internal(set) var serverSaveBannerMessage: String?
  public internal(set) var pendingServerSaveChoice: PendingServerSaveChoice?
  public internal(set) var batchServerSave: PodcastShowBatchServerSaveSession?
  public internal(set) var batchServerSaveCompletionVersion = 0
  /// Bumped by every lifecycle teardown so a view can drop a staged confirmation that belongs to
  /// the presentation being cleared. Views hold that dialog state themselves.
  public internal(set) var serverSavePresentationVersion = 0

  var serverPodcastMutationCapability: ServerPodcastMutationCapability = .none
  /// What the Save Show menu item reads, and the support object that owns its mark and tasks.
  var showSave = PodcastShowSaveState()
  @ObservationIgnored let showSaveSupport: PodcastShowSaveSupport
  var serverSaveStatuses: [String: NativeEpisodeServerSaveStatus] = [:]
  var serverSavePreflightPresence: [String: NativeEpisodeServerSavePreflightPresence?] = [:]
  var serverSaveAttemptIDs: [String: Int64?] = [:]
  var serverSaveCredentialedFeed = false
  var serverSaveCurrentEpisodeID: String?
  /// One stale-snapshot fence per episode key. `serverSaveAttemptIDs` is what rows and Remove
  /// read; the fence keeps its own high-water mark, so lowering the published ID reopens nothing.
  @ObservationIgnored var serverSaveFences: [String: NativeEpisodeServerSaveAttemptFence] = [:]
  /// The episode ids the server-save projection was last read for. The episode observation
  /// re-emits for progress and download writes that change no id, and re-reading every status on
  /// each is expensive. Cleared by every teardown so the next emission reads afresh.
  @ObservationIgnored var serverSaveProjectedEpisodeIDs: [String] = []
  /// Bumped by every teardown so an outcome that lands after the presentation was cleared is
  /// dropped instead of resurrecting it. Views never read it.
  @ObservationIgnored var serverSavePresentationGeneration = 0
  @ObservationIgnored var batchServerSaveCancellation: NativeEpisodeServerSaveBatchCancellationToken?
  @ObservationIgnored var batchServerSavePendingEpisodeIDs: Set<String> = []
  @ObservationIgnored var batchServerSaveRequestedAttemptIDs: Set<Int64> = []
  @ObservationIgnored var batchServerSaveConfirmedAttemptIDs: Set<Int64> = []
  @ObservationIgnored var batchServerSaveResume: PodcastShowBatchServerSaveResume?
  @ObservationIgnored var batchServerSaveTally = NativeEpisodeServerSaveBatchCopy.Tally()
  @ObservationIgnored var batchServerSaveAppliedEpisodeIDs: Set<Int64> = []
  @ObservationIgnored var serverSaveStatusTask: Task<Void, Never>?
  @ObservationIgnored var serverSaveCredentialTask: Task<Void, Never>?
  @ObservationIgnored var serverSaveLifecycleTask: Task<Void, Never>?
  @ObservationIgnored var serverSaveAccountIdentityTask: Task<Void, Never>?

  /// The owning show's item id. The show changes it and this together, in one synchronous call, so
  /// every task's `itemID == self.itemID` check means what it would on the show.
  @ObservationIgnored var itemID: String
  @ObservationIgnored weak var host: (any PodcastShowServerSaveHost)?
  /// Single-episode Save and Remove. Batch and Save Show stay here: they key their own episodes
  /// and tally across a run, which no single-episode presenter owns.
  @ObservationIgnored let serverSavePresenter: NativeEpisodeServerSavePresenter

  let reading: any PodcastReading
  let nativeFeedManaging: any NativeFeedManaging
  let nativeEpisodeServerSaving: any NativeEpisodeServerSaving
  let nativeEpisodeServerSaveBatchSaving: any NativeEpisodeServerSaveBatchSaving
  let nativeEpisodeServerSaveRecovering: any NativeEpisodeServerSaveRecovering
  let nativeEpisodeServerSaveStatusReading: any NativeEpisodeServerSaveStatusReading
  let nativeEpisodeIDResolving: any NativeEpisodeIDResolving
  let serverPodcastMutationCapabilityReading: any ServerPodcastMutationCapabilityReading
  let nativePodcastSubscriptionsReading: any NativePodcastSubscriptionsReading
  let accountIdentityReading: any AccountIdentityReading
  let librarySyncRequester: any LibrarySyncRequesting

  init(
    itemID: String,
    reading: any PodcastReading,
    nativeFeedManaging: any NativeFeedManaging = NoOpNativeFeedManaging(),
    nativeEpisodeServerSaving: any NativeEpisodeServerSaving = NoOpNativeEpisodeServerSaving(),
    nativeEpisodeServerSaveBatchSaving: any NativeEpisodeServerSaveBatchSaving =
      NoOpNativeEpisodeServerSaveBatchSaving(),
    nativeEpisodeServerSaveRecovering: any NativeEpisodeServerSaveRecovering =
      NoOpNativeEpisodeServerSaveRecovering(),
    nativeEpisodeServerSaveStatusReading: any NativeEpisodeServerSaveStatusReading =
      NoOpNativeEpisodeServerSaveStatusReading(),
    nativeEpisodeIDResolving: any NativeEpisodeIDResolving = NoOpNativeEpisodeIDResolving(),
    serverPodcastMutationCapabilityReading: any ServerPodcastMutationCapabilityReading =
      NoOpServerPodcastMutationCapabilityReading(),
    nativePodcastSubscriptionsReading: any NativePodcastSubscriptionsReading =
      NoOpNativePodcastSubscriptionsReading(),
    accountIdentityReading: any AccountIdentityReading = NoOpAccountIdentityReading(),
    librarySyncRequester: any LibrarySyncRequesting = NoOpLibrarySyncRequester(),
    nativeShowsReading: any NativePodcastShowsReading = NoOpNativePodcastShowsReading(),
    serverPodcastAutomationSettingsWriting: any ServerPodcastAutomationSettingsWriting =
      NoOpServerPodcastAutomationSettingsWriting()
  ) {
    self.itemID = itemID
    self.reading = reading
    self.nativeFeedManaging = nativeFeedManaging
    self.nativeEpisodeServerSaving = nativeEpisodeServerSaving
    self.nativeEpisodeServerSaveBatchSaving = nativeEpisodeServerSaveBatchSaving
    self.nativeEpisodeServerSaveRecovering = nativeEpisodeServerSaveRecovering
    self.nativeEpisodeServerSaveStatusReading = nativeEpisodeServerSaveStatusReading
    self.nativeEpisodeIDResolving = nativeEpisodeIDResolving
    self.serverPodcastMutationCapabilityReading = serverPodcastMutationCapabilityReading
    self.nativePodcastSubscriptionsReading = nativePodcastSubscriptionsReading
    self.accountIdentityReading = accountIdentityReading
    self.librarySyncRequester = librarySyncRequester
    showSaveSupport = PodcastShowSaveSupport(
      shows: nativeShowsReading, writer: serverPodcastAutomationSettingsWriting)
    serverSavePresenter = NativeEpisodeServerSavePresenter(
      saving: nativeEpisodeServerSaving,
      resolving: nativeEpisodeIDResolving,
      librarySyncRequester: librarySyncRequester)
  }

  deinit {
    serverSaveStatusTask?.cancel()
    serverSaveCredentialTask?.cancel()
    serverSaveLifecycleTask?.cancel()
    serverSaveAccountIdentityTask?.cancel()
  }

  /// The feed id when this show is device-owned. ABS subscriptions remain server-managed.
  var nativeFeedID: Int64? {
    PodcastSourceIdentity(itemId: itemID)?.rssFeedId
  }

  var isNativeFeed: Bool { nativeFeedID != nil }

  /// The server item id when this show is server-owned. Such a show cannot save, but it can
  /// remove an episode a Whirr save put there, keyed by the server episode id that save confirmed.
  var serverItemID: String? {
    PodcastSourceIdentity(itemId: itemID)?.absItemId
  }

  /// Whether this show can identify a Whirr-saved server copy among its rows: a native feed by its
  /// own RSS rows, a server show by the server episode ids Whirr confirmed into it.
  public var hostsServerSaveRemoval: Bool { isNativeFeed || serverItemID != nil }
}
