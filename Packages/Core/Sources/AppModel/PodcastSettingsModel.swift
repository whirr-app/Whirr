import Observation
import Persistence

/// The Settings > Podcasts destination: the account's global device-side auto-download defaults,
/// and the ordered show-override summary rows that let a show list render "Default (Off)"/"On"/
/// "Off" without a second query per row.
///
/// Global values and show rows are two independent `PodcastSettingsReading` streams that must
/// settle together. `FilterObservationCoordinator` (shared with `HomeModel` and
/// `LibraryBrowseModel`) owns the readiness barrier and discards values from a superseded
/// subscription (after `reload()` starts a fresh one).
@MainActor
@Observable
public final class PodcastSettingsModel {
  public enum State: Sendable, Equatable {
    case loading
    case loaded
  }

  public private(set) var state: State = .loading
  public private(set) var global: PodcastGlobalSettings = .defaults
  public private(set) var showRows: [PodcastShowSettingsSummary] = []
  public private(set) var actionErrorMessage: String?

  private let reading: any PodcastSettingsReading
  private let writing: any PodcastSettingsWriting

  // Per-source trackers for the current subscription generation only. `nil` until this
  // generation's stream has emitted, so `recomputeState` holds the previous snapshot (or
  // `.loading` on the first subscribe) until both sources have reported.
  private var latestGlobal: PodcastGlobalSettings?
  private var latestShowRows: [PodcastShowSettingsSummary]?

  @ObservationIgnored private var observations = FilterObservationCoordinator()

  public init(
    reading: any PodcastSettingsReading,
    writing: any PodcastSettingsWriting = NoOpPodcastSettingsAccess()
  ) {
    self.reading = reading
    self.writing = writing
    subscribe()
  }

  /// Cancels the current subscription and starts a fresh one. Not needed in normal operation, as
  /// `PodcastSettingsReading`'s streams push every mutation. It lets a screen recover from a
  /// structural observation failure without risking a late value from the replaced subscription.
  public func reload() {
    subscribe()
  }

  public func setAutoDownloadEnabled(_ enabled: Bool) async {
    await perform { try await writing.setGlobalAutoDownloadEnabled(enabled) }
  }

  public func setKeepLatestCount(_ count: Int) async {
    await perform { try await writing.setGlobalKeepLatestCount(count) }
  }

  public func setDeleteAfterPlayed(_ enabled: Bool) async {
    await perform { try await writing.setGlobalDeleteAfterPlayed(enabled) }
  }

  public func setAllowCellularAutoDownload(_ enabled: Bool) async {
    await perform { try await writing.setGlobalAllowCellularAutoDownload(enabled) }
  }

  public func dismissActionError() {
    actionErrorMessage = nil
  }

  private func subscribe() {
    latestGlobal = nil
    latestShowRows = nil

    let generation = observations.begin(sourceCount: 2)
    let globalStream = reading.observeGlobalSettings()
    let showsStream = reading.observeShowSummaries()

    observations.observe(globalStream, sourceID: 0, in: generation) { [weak self] value, ready in
      guard let self else { return }
      self.latestGlobal = value
      if ready { self.recomputeState() }
    }
    observations.observe(showsStream, sourceID: 1, in: generation) { [weak self] value, ready in
      guard let self else { return }
      self.latestShowRows = value
      if ready { self.recomputeState() }
    }
  }

  private func recomputeState() {
    guard let global = latestGlobal, let showRows = latestShowRows else { return }
    self.global = global
    self.showRows = showRows
    state = .loaded
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
