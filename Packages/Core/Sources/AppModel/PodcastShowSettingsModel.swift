import Foundation
import Observation
import Persistence
import SyncEngine

/// One show's Show Settings destination: its tri-state overrides (for editing), the
/// already-resolved effective values (for display), and the server section. The server section
/// reuses `PodcastServerSettingsPresentation` rather than rederiving server copy.
///
/// For an account that may save to the server, the server section is an editor instead of read-only
/// rows (ADR 0017); its members live in `PodcastShowSettingsModel+ServerAutomation.swift`.
///
/// The two halves come from different observations and share no value: "Keep Latest" above is this
/// phone's retention, "Keeps" below the server's.
@MainActor
@Observable
public final class PodcastShowSettingsModel {
  public enum State: Sendable, Equatable {
    case loading
    case loaded
    case notFound
  }

  public let itemID: String
  public private(set) var state: State = .loading
  public private(set) var title: String = ""
  public private(set) var autoDownloadOverride: PodcastShowAutoDownloadOverride = .inherit
  public private(set) var keepLatestOverride: Int?
  public private(set) var deleteAfterPlayedOverride: Bool?
  public private(set) var effective = PodcastEffectiveSettings(
    isEnabled: false, keepLatestCount: 3, deleteAfterPlayed: false, floor: .distantPast)
  /// Where this show comes from, fixed by the item id. `nil` only for an id no source can own.
  public let source: PodcastShowSource?
  /// The read-only "Source" section: which kind of show this is and, for a feed, where it is
  /// followed from and when it was last checked. Present whenever `source` is.
  public private(set) var sourceSection: PodcastShowSourceSection?
  /// The read-only server section: the five facts the server sent about this show, already
  /// formatted by `PodcastServerSettingsPresentation`. `nil` when the server has supplied none of
  /// them, which the view renders as no section at all. For an RSS show it is fed only by the
  /// diagnostics of the feed's server copy (found by fingerprint,
  /// `PodcastShowSettingsModel+ServerCopy.swift`), never the feed's own, which would present a
  /// device fact under the "Audiobookshelf Server" header. `nil` with no single server copy.
  public private(set) var serverSettings: PodcastServerSettingsSection?
  /// The editable form of the same section, present only for an account that may save to the server
  /// and only while the server has supplied something to edit. The view shows it instead of
  /// `serverSettings`, never beside it. For an RSS show, only while exactly one server copy exists.
  public internal(set) var serverSettingsEditor: PodcastServerSettingsEditor?
  /// Shown under the server header, with no editor, when an RSS show's feed matches more than one
  /// show on the server. `nil` otherwise.
  public internal(set) var serverCopiesNotice: String?
  /// `true` while a server write and its confirming refresh are in flight. Controls are disabled
  /// for the duration and further intents are ignored.
  public internal(set) var isSavingServerSettings = false
  /// The change being written, or the last one the server confirmed, laid over the stored values
  /// so the control shows the choice at once instead of after the confirming refresh. Dropped when
  /// the write fails or is unconfirmed, and by the next stored snapshot after the write ends.
  @ObservationIgnored var serverChangeOverlay: PodcastAutomationSettingsRequest?
  /// The inline outcome of the last server write, shown in the section. Separate from
  /// `actionErrorMessage`, which raises an alert for this device's own edits.
  public internal(set) var serverSettingsMessage: String?
  public private(set) var includeInLatest: Bool?
  public private(set) var notificationOverride: RSSNotificationOverride?
  public private(set) var actionErrorMessage: String?
  /// A per-show “On” the system would not deliver on. The override is left unchanged.
  public private(set) var notificationRefusal: NotificationEnableRefusal?
  public var feedCredentialUsername = ""
  public var feedCredentialPassword = ""
  public private(set) var hasFeedCredential = false
  public let supportsFeedCredentials: Bool

  /// The show screen's one-line "what this will actually do" hint, present only once
  /// auto-download resolves effectively on. Independent of `serverSettings` (that section reports
  /// the server's settings; this reports the device's retention policy).
  public var stateHint: String? {
    guard effective.isEnabled else { return nil }
    return PodcastDownloadCopy.keepLatestStateHint(count: effective.keepLatestCount)
  }

  public var autoDownloadOverrideLabel: String {
    PodcastDownloadCopy.autoDownloadOverrideLabel(
      autoDownloadOverride, effectiveIsEnabled: effective.isEnabled)
  }

  public var keepLatestOverrideLabel: String {
    PodcastDownloadCopy.keepLatestOverrideLabel(
      keepLatestOverride, effectiveCount: effective.keepLatestCount)
  }

  public var deleteAfterPlayedOverrideLabel: String {
    PodcastDownloadCopy.deleteAfterPlayedOverrideLabel(
      deleteAfterPlayedOverride, effectiveValue: effective.deleteAfterPlayed)
  }

  private let reading: any PodcastSettingsReading
  private let writing: any PodcastSettingsWriting
  let podcastReading: any PodcastReading
  private let refreshing: any PodcastRefreshing
  private let nativeFeedManaging: any NativeFeedManaging
  private let nativeShowsReading: any NativePodcastShowsReading
  private let notificationSettings: PodcastNotificationSettingsModel?
  private let nativeFeedID: Int64?
  private let now: @Sendable () -> Date
  let serverCapabilityReading: any ServerPodcastMutationCapabilityReading
  let automationSettingsWriting: any ServerPodcastAutomationSettingsWriting
  /// Raw server values, kept so the editor can be rebuilt when the capability resolves.
  var serverDiagnostics: PodcastShowDiagnostics?
  var serverCapability: ServerPodcastMutationCapability = .none
  /// The server item the section describes and the editor writes to: the show itself for a server
  /// show, the single matching server copy for a followed feed, and `nil` for a feed with none.
  var serverTargetItemID: String?
  /// The followed feed's fingerprint, from its own row. Never read while a credential is held.
  var nativeFeedFingerprint: String?
  /// `false` until the credential state has actually been read, so a pending or failed read can
  /// never be mistaken for "no credential".
  var feedCredentialStateKnown = false
  var observedCopyFingerprint: String?
  var hasRequestedServerCapability = false
  private var nativeFeedURL: URL?
  private var nativeLastChecked: Date?
  @ObservationIgnored private var detailTask: Task<Void, Never>?
  @ObservationIgnored private var diagnosticsTask: Task<Void, Never>?
  @ObservationIgnored private var nativeShowTask: Task<Void, Never>?
  @ObservationIgnored var serverCopyTask: Task<Void, Never>?
  @ObservationIgnored var serverCopyDiagnosticsTask: Task<Void, Never>?
  @ObservationIgnored private var credentialLoadTask: Task<Void, Never>?
  @ObservationIgnored private var credentialMutationTask: Task<Void, Never>?
  @ObservationIgnored private var notificationOverrideTask: Task<Void, Never>?
  @ObservationIgnored private var hasRequestedServerFill = false
  private var credentialGeneration: UInt64 = 0
  private var notificationOverrideGeneration: UInt64 = 0

  public init(
    itemID: String,
    reading: any PodcastSettingsReading,
    writing: any PodcastSettingsWriting = NoOpPodcastSettingsAccess(),
    podcastReading: any PodcastReading = NoOpPodcastReading(),
    refreshing: any PodcastRefreshing = NoOpPodcastRefreshing(),
    nativeFeedManaging: any NativeFeedManaging = NoOpNativeFeedManaging(),
    nativeShowsReading: any NativePodcastShowsReading = NoOpNativePodcastShowsReading(),
    notificationSettings: PodcastNotificationSettingsModel? = nil,
    serverMutationCapability: any ServerPodcastMutationCapabilityReading =
      NoOpServerPodcastMutationCapabilityReading(),
    automationSettingsWriting: any ServerPodcastAutomationSettingsWriting =
      NoOpServerPodcastAutomationSettingsWriting(),
    titleSeed: String? = nil,
    now: @escaping @Sendable () -> Date = Date.init
  ) {
    self.itemID = itemID
    self.reading = reading
    self.writing = writing
    self.podcastReading = podcastReading
    self.refreshing = refreshing
    self.nativeFeedManaging = nativeFeedManaging
    self.nativeShowsReading = nativeShowsReading
    self.notificationSettings = notificationSettings
    serverCapabilityReading = serverMutationCapability
    self.automationSettingsWriting = automationSettingsWriting
    let nativeFeedID = PodcastSourceIdentity(itemId: itemID)?.rssFeedId
    self.nativeFeedID = nativeFeedID
    supportsFeedCredentials = nativeFeedID != nil
    self.now = now
    source = PodcastShowSourcePresentation.source(itemID: itemID)
    serverTargetItemID = nativeFeedID == nil ? itemID : nil
    if let titleSeed, titleSeed.isEmpty == false {
      title = titleSeed
    }
    refreshSourceSection()
    subscribe()
    loadFeedCredentialState()
    loadServerCapability()
  }

  deinit {
    detailTask?.cancel()
    diagnosticsTask?.cancel()
    nativeShowTask?.cancel()
    credentialLoadTask?.cancel()
    serverCopyTask?.cancel()
    serverCopyDiagnosticsTask?.cancel()
  }

  public func setAutoDownloadOverride(_ override: PodcastShowAutoDownloadOverride) async {
    await perform {
      try await writing.setShowAutoDownloadOverride(itemID: itemID, override: override)
    }
  }

  /// `nil` means "inherit"; `0` means "keep all". Both are distinct from every positive count.
  public func setKeepLatestOverride(_ count: Int?) async {
    await perform { try await writing.setShowKeepLatestOverride(itemID: itemID, count: count) }
  }

  public func setDeleteAfterPlayedOverride(_ enabled: Bool?) async {
    await perform {
      try await writing.setShowDeleteAfterPlayedOverride(itemID: itemID, enabled: enabled)
    }
  }

  public func setIncludeInLatest(_ enabled: Bool) async {
    await perform { try await writing.setShowIncludeInLatest(itemID: itemID, enabled: enabled) }
  }

  /// Enqueues the complete authorization-and-write operation synchronously from a SwiftUI
  /// binding, preserving invocation order even when the executor starts its tasks out of order.
  @discardableResult
  public func requestNotificationOverride(
    _ override: RSSNotificationOverride
  ) -> Task<Void, Never> {
    notificationOverrideGeneration &+= 1
    let generation = notificationOverrideGeneration
    let preceding = notificationOverrideTask
    let task = Task { @MainActor [self, preceding] in
      await preceding?.value
      if override == .enabled, let notificationSettings {
        switch await notificationSettings.authorizeExplicitFeedEnableIfNeeded() {
        case .permitted: break
        case .declined: return
        case .refused(let refusal):
          if notificationOverrideGeneration == generation { notificationRefusal = refusal }
          return
        }
      }
      do {
        try await writing.setShowNotificationOverride(itemID: itemID, override: override)
        guard notificationOverrideGeneration == generation else { return }
        actionErrorMessage = nil
      } catch {
        guard notificationOverrideGeneration == generation else { return }
        actionErrorMessage = PodcastDownloadCopy.actionFailed
      }
    }
    notificationOverrideTask = task
    return task
  }

  public func dismissActionError() {
    actionErrorMessage = nil
  }

  public func dismissNotificationRefusal() {
    notificationRefusal = nil
  }

  public func saveFeedCredential() async {
    await requestSaveFeedCredential()?.value
  }

  /// Captures both fields and joins the serial mutation chain before returning to the caller.
  @discardableResult
  public func requestSaveFeedCredential() -> Task<Void, Never>? {
    guard let nativeFeedID else { return nil }
    let username = feedCredentialUsername
    let password = feedCredentialPassword
    feedCredentialPassword = ""
    return requestCredentialMutation(successfulState: true, feedID: nativeFeedID) {
      managing, feedID in
      try await managing.saveBasicCredential(
        username: username, password: password, feedId: feedID)
    }
  }

  public func removeFeedCredential() async {
    await requestRemoveFeedCredential()?.value
  }

  @discardableResult
  public func requestRemoveFeedCredential() -> Task<Void, Never>? {
    guard let nativeFeedID else { return nil }
    feedCredentialPassword = ""
    return requestCredentialMutation(successfulState: false, feedID: nativeFeedID) {
      managing, feedID in
      try await managing.clearCredential(feedId: feedID)
    }
  }

  /// Call when the settings destination is dismissed, even without a save, so an unsaved password
  /// does not outlive its sheet. Not done from `deinit`: assigning `""` to a Swift `String`
  /// releases the buffer without zeroing it, and a nonisolated `deinit` cannot reach the property
  /// (an Observation computed accessor) while opting it out would stop the view observing it.
  public func clearTransientCredentialInput() {
    feedCredentialPassword = ""
  }

  private func loadFeedCredentialState() {
    guard let nativeFeedID else { return }
    let nativeFeedManaging = self.nativeFeedManaging
    let generation = credentialGeneration
    credentialLoadTask = Task { @MainActor [weak self, nativeFeedManaging] in
      guard let configured = try? await nativeFeedManaging.hasCredential(feedId: nativeFeedID) else {
        return
      }
      guard let self, self.credentialGeneration == generation else { return }
      self.hasFeedCredential = configured
      self.feedCredentialStateKnown = true
      self.reconcileServerCopyObservation()
    }
  }

  /// Credential mutations must all reach Keychain in invocation order. Generation fencing alone
  /// would keep the UI fresh while still allowing an older slow save to become the durable final
  /// value after a newer remove.
  private func requestCredentialMutation(
    successfulState: Bool,
    feedID: Int64,
    operation: @escaping @Sendable (any NativeFeedManaging, Int64) async throws -> Void
  ) -> Task<Void, Never> {
    credentialGeneration &+= 1
    let generation = credentialGeneration
    credentialLoadTask?.cancel()
    let preceding = credentialMutationTask
    let task = Task { @MainActor [self, preceding] in
      await preceding?.value
      do {
        try await operation(nativeFeedManaging, feedID)
        guard credentialGeneration == generation else { return }
        hasFeedCredential = successfulState
        feedCredentialStateKnown = true
        reconcileServerCopyObservation()
        actionErrorMessage = nil
      } catch {
        guard credentialGeneration == generation else { return }
        let configured = try? await nativeFeedManaging.hasCredential(feedId: feedID)
        guard credentialGeneration == generation else { return }
        if let configured {
          hasFeedCredential = configured
          feedCredentialStateKnown = true
          reconcileServerCopyObservation()
        }
        actionErrorMessage = PodcastDownloadCopy.actionFailed
      }
    }
    credentialMutationTask = task
    return task
  }

  private func subscribe() {
    let detailStream = reading.observeShowSettings(itemID: itemID)
    let diagnosticsStream = podcastReading.observeShowDiagnostics(itemId: itemID)
    let itemID = self.itemID

    detailTask = Task { [weak self] in
      for await detail in detailStream {
        guard let self, itemID == self.itemID else { return }
        guard let detail else {
          self.state = .notFound
          continue
        }
        self.apply(detail)
      }
    }
    if nativeFeedID != nil {
      // An RSS show's own diagnostics are this device's feed settings and refresh time, so they
      // feed the Source section and never the server one. The server section of a followed feed
      // comes from its server copy's diagnostics alone (`reconcileServerCopyObservation`).
      diagnosticsTask = Task { [weak self] in
        for await diagnostics in diagnosticsStream {
          guard let self, itemID == self.itemID else { return }
          self.nativeLastChecked = diagnostics?.lastEpisodeCheck
          self.refreshSourceSection()
        }
      }
      let showStream = nativeShowsReading.observeShow(itemId: itemID)
      nativeShowTask = Task { [weak self] in
        for await show in showStream {
          guard let self, itemID == self.itemID else { return }
          self.nativeFeedURL = show?.artworkFeedURL
          self.refreshSourceSection()
          self.nativeFeedFingerprint = show?.podcastFeedFingerprint
          self.reconcileServerCopyObservation()
        }
      }
      return
    }
    diagnosticsTask = Task { [weak self] in
      for await diagnostics in diagnosticsStream {
        guard let self, itemID == self.itemID else { return }
        self.serverDiagnostics = diagnostics
        if self.isSavingServerSettings == false { self.serverChangeOverlay = nil }
        self.refreshServerSection()
        if self.serverSettings == nil { self.requestServerFill() }
      }
    }
  }

  /// Rebuilds both forms of the server section from the raw diagnostics and the account's
  /// capability. Nothing else may assign either, so they cannot disagree about what the server
  /// said.
  func refreshServerSection() {
    let now = self.now()
    serverSettings = PodcastServerSettingsPresentation.section(
      diagnostics: serverDiagnostics, now: now)
    serverSettingsEditor =
      serverCapability.canSave
      ? PodcastServerSettingsPresentation.editor(
        diagnostics: serverDiagnostics.map { Self.diagnostics($0, applying: serverChangeOverlay) },
        now: now) : nil
  }

  private static func diagnostics(
    _ stored: PodcastShowDiagnostics, applying change: PodcastAutomationSettingsRequest?
  ) -> PodcastShowDiagnostics {
    guard let change else { return stored }
    return PodcastShowDiagnostics(
      autoDownloadEpisodes: change.autoDownloadEpisodes ?? stored.autoDownloadEpisodes,
      autoDownloadSchedule: change.autoDownloadSchedule?.cronExpression
        ?? stored.autoDownloadSchedule,
      lastEpisodeCheck: stored.lastEpisodeCheck,
      maxEpisodesToKeep: change.maxEpisodesToKeep ?? stored.maxEpisodesToKeep,
      maxNewEpisodesToDownload: change.maxNewEpisodesToDownload
        ?? stored.maxNewEpisodesToDownload)
  }

  private func refreshSourceSection() {
    guard let source else {
      sourceSection = nil
      return
    }
    sourceSection = PodcastShowSourcePresentation.section(
      source: source, feedURL: nativeFeedURL, lastChecked: nativeLastChecked, now: now())
  }

  private func apply(_ detail: PodcastShowSettingsDetail) {
    title = detail.title
    autoDownloadOverride = detail.autoDownloadOverride
    keepLatestOverride = detail.keepLatestOverride
    deleteAfterPlayedOverride = detail.deleteAfterPlayedOverride
    effective = detail.effective
    includeInLatest = detail.includeInLatest
    notificationOverride = detail.notificationOverride
    state = .loaded
  }

  /// The five server fields arrive only on the item detail `PodcastRefreshCoordinator` fetches,
  /// which only the show screen also asks for, so reaching Show Settings from Settings > Podcasts
  /// finds them unwritten. One on-demand fetch (`expanded=1`) fills them, and the open observation
  /// shows the section when it lands.
  ///
  /// Once per model, never scheduled: a show the server knows nothing about keeps yielding
  /// nothing, so re-asking would be a retry loop. A failed fetch stays silent, as
  /// `actionErrorMessage` belongs to the user's own edits.
  ///
  /// The task is unowned and not cancelled on `deinit`: the fetch is a durable write, not a screen
  /// update, and SwiftUI builds a navigation destination's model more than once.
  /// `PodcastRefreshCoordinator` cancels the request when its last waiter goes, so a fill tied to a
  /// discarded model would write nothing. The model still on screen sees it by observation.
  func requestServerFill() {
    guard hasRequestedServerFill == false, let itemID = serverTargetItemID else { return }
    hasRequestedServerFill = true
    let refreshing = self.refreshing
    Task { _ = try? await refreshing.refresh(itemID: itemID) }
  }

  private func perform(_ action: () async throws -> Void) async {
    do {
      try await action()
      actionErrorMessage = nil
    } catch {
      actionErrorMessage = PodcastDownloadCopy.actionFailed
    }
  }
}
