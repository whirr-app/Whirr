import Foundation

/// Read side of the device-side podcast auto-download settings: the account's global defaults,
/// the ordered per-show override summary rows, and one show's full detail. Mirrors
/// `PodcastReading`'s boundary shape so AppModel never touches `PodcastSettingsStore`/GRDB
/// directly (ARCHITECTURE.md §2).
public protocol PodcastSettingsReading: Sendable {
  /// Synchronous cache read used only to seed a destination's first frame. The observation below
  /// remains authoritative for subsequent changes.
  func currentShowSettings(itemID: String) -> PodcastShowSettingsDetail?
  func observeGlobalSettings() -> AsyncStream<PodcastGlobalSettings>
  func observeShowSummaries() -> AsyncStream<[PodcastShowSettingsSummary]>
  /// `nil` once the show is absent, soft-deleted, or not yet synced. That is a value, not a
  /// failure, as in `PodcastSettingsStore.observeShowSettings`.
  func observeShowSettings(itemID: String) -> AsyncStream<PodcastShowSettingsDetail?>
}

extension PodcastSettingsReading {
  public func currentShowSettings(itemID: String) -> PodcastShowSettingsDetail? { nil }
}

/// Incremental-composition default: no database and no fabricated podcast settings state.
public struct NoOpPodcastSettingsReading: PodcastSettingsReading, Sendable {
  public init() {}
  public func observeGlobalSettings() -> AsyncStream<PodcastGlobalSettings> {
    AsyncStream { $0.finish() }
  }
  public func observeShowSummaries() -> AsyncStream<[PodcastShowSettingsSummary]> {
    AsyncStream { $0.finish() }
  }
  public func observeShowSettings(itemID: String) -> AsyncStream<PodcastShowSettingsDetail?> {
    AsyncStream { $0.finish() }
  }
}

/// Write side: the four global mutations, three inherited per-show overrides, and RSS-only inbox
/// membership that `PodcastSettingsStore` implements. AppModel only mutates through this
/// boundary.
public protocol PodcastSettingsWriting: Sendable {
  func setGlobalAutoDownloadEnabled(_ enabled: Bool) async throws
  func setGlobalKeepLatestCount(_ count: Int) async throws
  func setGlobalDeleteAfterPlayed(_ enabled: Bool) async throws
  func setGlobalAllowCellularAutoDownload(_ enabled: Bool) async throws
  func setShowAutoDownloadOverride(itemID: String, override: PodcastShowAutoDownloadOverride)
    async throws
  func setShowKeepLatestOverride(itemID: String, count: Int?) async throws
  func setShowDeleteAfterPlayedOverride(itemID: String, enabled: Bool?) async throws
  func setShowIncludeInLatest(itemID: String, enabled: Bool) async throws
  func setShowNotificationOverride(itemID: String, override: RSSNotificationOverride) async throws
}

extension PodcastSettingsWriting {
  public func setShowNotificationOverride(
    itemID: String, override: RSSNotificationOverride
  ) async throws {
    _ = itemID
    _ = override
  }
}

/// The default no-op `PodcastSettingsReading`/`PodcastSettingsWriting` conformance. Every stream
/// finishes immediately without yielding and every mutation does nothing, so `AppDependencies`
/// defaults work for callers that supply no real store.
public struct NoOpPodcastSettingsAccess: PodcastSettingsReading, PodcastSettingsWriting, Sendable {
  public init() {}
  public func observeGlobalSettings() -> AsyncStream<PodcastGlobalSettings> {
    AsyncStream { $0.finish() }
  }
  public func observeShowSummaries() -> AsyncStream<[PodcastShowSettingsSummary]> {
    AsyncStream { $0.finish() }
  }
  public func observeShowSettings(itemID: String) -> AsyncStream<PodcastShowSettingsDetail?> {
    AsyncStream { $0.finish() }
  }
  public func setGlobalAutoDownloadEnabled(_ enabled: Bool) async throws {}
  public func setGlobalKeepLatestCount(_ count: Int) async throws {}
  public func setGlobalDeleteAfterPlayed(_ enabled: Bool) async throws {}
  public func setGlobalAllowCellularAutoDownload(_ enabled: Bool) async throws {}
  public func setShowAutoDownloadOverride(itemID: String, override: PodcastShowAutoDownloadOverride)
    async throws
  {}
  public func setShowKeepLatestOverride(itemID: String, count: Int?) async throws {}
  public func setShowDeleteAfterPlayedOverride(itemID: String, enabled: Bool?) async throws {}
  public func setShowIncludeInLatest(itemID: String, enabled: Bool) async throws {}
  public func setShowNotificationOverride(
    itemID: String, override: RSSNotificationOverride
  ) async throws {}
}

/// `PodcastSettingsStore` already implements every method above with matching signatures, so this
/// structural conformance is the whole of the wiring.
extension PodcastSettingsStore: PodcastSettingsReading, PodcastSettingsWriting {}
