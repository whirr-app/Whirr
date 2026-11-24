import AppModel
import Foundation
import Network
import Observation

/// What the Reduce Ads setting needs from the speech asset.
nonisolated protocol SpeechAssetInstalling: Sendable {
  func state() async -> SpeechAssetState
  func install(progress: @Sendable (Progress) -> Void) async throws
}

extension SpeechAssetInstaller: SpeechAssetInstalling {}

/// Whether the phone is on a network the listener has not asked us to spare: Wi-Fi or wired,
/// neither expensive nor in Low Data Mode.
nonisolated protocol UnmeteredNetworkWaiting: Sendable {
  /// Returns once such a network is up, at once when it already is. Throws on cancellation.
  func waitForUnmeteredNetwork() async throws
}

/// The Reduce Ads setting: the toggle, consent before the speech model downloads, waiting for
/// Wi-Fi unless the listener chooses otherwise, progress, retry, Forget learned ads, and how far
/// analysis has got through the downloads. The setting itself lives in `UserDefaults`, which the
/// coordinator observes. Production uses one model for the process, so a download outlives the
/// settings screen that started it.
@MainActor
@Observable
final class AdSkipSettingsModel {
  enum Asset: Equatable {
    /// Not yet read; the section stays hidden rather than flash a toggle that may go.
    case checking
    /// No English recogniser on this phone or OS: the setting is never shown.
    case unavailable
    case notInstalled
    case waitingForWiFi
    /// The fraction done, once the system reports one.
    case downloading(Double?)
    case failed
    case installed
  }

  private(set) var asset: Asset = .checking
  private(set) var isEnabled: Bool
  /// The download consent prompt is up; the toggle reads as on while it is.
  var isConfirmingDownload = false
  var isConfirmingForget = false
  /// The coordinator's latest count; nil while the setting is off or not yet heard.
  private(set) var progress: AdSkipProgress?
  /// Analyse only on external power (on by default).
  private(set) var isOnlyWhileCharging: Bool
  /// Why analysis is held back, read with each progress update.
  private(set) var pauseReason: AdSkipPauseReason?

  private let installer: any SpeechAssetInstalling
  private let network: any UnmeteredNetworkWaiting
  private let defaults: UserDefaults
  private let systemDownloadPollInterval: Duration
  private let progressUpdates: @MainActor () -> AsyncStream<AdSkipProgress?>
  private let currentPauseReason: @MainActor () -> AdSkipPauseReason?
  private let onInstalled: @MainActor () -> Void
  private let onForget: @MainActor () -> Void
  @ObservationIgnored private var download: Task<Void, Never>?
  /// The download whose outcome still counts; a cancelled one finds it changed and stays quiet.
  @ObservationIgnored private var downloadID: UUID?
  @ObservationIgnored private var lastAllowedCellular = false

  init(
    installer: any SpeechAssetInstalling, network: any UnmeteredNetworkWaiting,
    defaults: UserDefaults = .standard, systemDownloadPollInterval: Duration = .seconds(1),
    progressUpdates: @escaping @MainActor () -> AsyncStream<AdSkipProgress?> = {
      AsyncStream { $0.finish() }
    },
    pauseReason: @escaping @MainActor () -> AdSkipPauseReason? = { nil },
    onInstalled: @escaping @MainActor () -> Void, onForget: @escaping @MainActor () -> Void
  ) {
    self.installer = installer
    self.network = network
    self.defaults = defaults
    self.systemDownloadPollInterval = systemDownloadPollInterval
    self.progressUpdates = progressUpdates
    currentPauseReason = pauseReason
    self.onInstalled = onInstalled
    self.onForget = onForget
    isEnabled = AdSkipPreference.isEnabled(in: defaults)
    isOnlyWhileCharging = AdSkipPreference.isOnlyWhileCharging(in: defaults)
  }

  var isVisible: Bool {
    asset != .checking && asset != .unavailable
  }

  /// The toggle's value: on while the listener is being asked about the download, so it does not
  /// snap back under the prompt.
  var isToggleOn: Bool {
    isEnabled || isConfirmingDownload
  }

  /// Reads the asset's state and the setting. Called when the settings screen appears and when
  /// the defaults change underneath it.
  func refresh() async {
    isEnabled = AdSkipPreference.isEnabled(in: defaults)
    isOnlyWhileCharging = AdSkipPreference.isOnlyWhileCharging(in: defaults)
    guard download == nil else { return }
    let state = await installer.state()
    guard download == nil else { return }
    switch state {
    case .unavailable: asset = .unavailable
    case .notInstalled: asset = asset == .failed ? .failed : .notInstalled
    case .downloading: followSystemDownload()
    case .installed: asset = .installed
    }
  }

  func setToggle(_ on: Bool) {
    guard on else {
      download?.cancel()
      download = nil
      downloadID = nil
      // A download stopped part way is offered again from the start next time.
      if isVisible, asset != .installed { asset = .notInstalled }
      isConfirmingDownload = false
      write(false)
      return
    }
    switch asset {
    case .installed, .downloading, .waitingForWiFi:
      write(true)
    case .notInstalled, .failed:
      isConfirmingDownload = true
    case .checking, .unavailable:
      break
    }
  }

  /// The coordinator observes the write through `AdSkipAnalysisConditions.changes()`.
  func setOnlyWhileCharging(_ on: Bool) {
    isOnlyWhileCharging = on
    defaults.set(on, forKey: AdSkipPreference.onlyWhileChargingKey)
  }

  /// The listener agreed to the download. Without `allowingCellular` it waits for Wi-Fi.
  func confirmDownload(allowingCellular: Bool) {
    isConfirmingDownload = false
    lastAllowedCellular = allowingCellular
    write(true)
    startDownload(allowingCellular: allowingCellular)
  }

  func cancelDownloadConfirmation() {
    isConfirmingDownload = false
  }

  /// Offered after a failure, under the same choice of network as before.
  func retry() {
    startDownload(allowingCellular: lastAllowedCellular)
  }

  func confirmForget() {
    isConfirmingForget = false
    onForget()
  }

  /// Shows the coordinator's progress until the caller's task ends. Run while the page is open.
  func followProgress() async {
    for await update in progressUpdates() {
      // Every change of condition reaches the coordinator first, so its update is the moment
      // the reason can have changed.
      pauseReason = currentPauseReason()
      progress = update
    }
  }

  /// Returns once the current download, if any, has finished. For tests.
  func waitForDownload() async {
    await download?.value
  }

  private func write(_ enabled: Bool) {
    isEnabled = enabled
    defaults.set(enabled, forKey: AdSkipPreference.key)
  }

  private func startDownload(allowingCellular: Bool) {
    download?.cancel()
    let id = UUID()
    downloadID = id
    asset = allowingCellular ? .downloading(nil) : .waitingForWiFi
    let installer = installer
    let network = network
    // The progress callback is `@Sendable`, so it reaches the model through an immutable box
    // rather than the task's captured `self`.
    let reference = WeakReference(self)
    download = Task { [weak self] in
      do {
        if allowingCellular == false {
          try await network.waitForUnmeteredNetwork()
          self?.update(.downloading(nil), for: id)
        }
        try await installer.install { progress in
          Task { @MainActor in reference.model?.follow(progress, for: id) }
        }
        self?.finish(.installed, for: id)
      } catch {
        // Only the outcome is shown; the error's text is the system's and not for the listener.
        self?.finish(.failed, for: id)
      }
    }
  }

  private func update(_ state: Asset, for id: UUID) {
    guard downloadID == id else { return }
    asset = state
  }

  private func finish(_ outcome: Asset, for id: UUID) {
    guard downloadID == id else { return }
    downloadID = nil
    download = nil
    asset = outcome
    if outcome == .installed { onInstalled() }
  }

  /// Samples the system's progress twice a second while the download runs.
  private func follow(_ progress: Progress, for id: UUID) {
    Task { [weak self] in
      while let self, self.downloadID == id, case .downloading(let shown) = self.asset {
        let fraction = progress.fractionCompleted
        if shown != fraction { self.asset = .downloading(fraction) }
        try? await Task.sleep(for: .milliseconds(500))
      }
    }
  }

  /// A download the system reports without this model owning it, such as one still finishing
  /// from before the app was last quit. It has no progress to show, so the system is asked
  /// until it ends.
  private func followSystemDownload() {
    let id = UUID()
    downloadID = id
    asset = .downloading(nil)
    let installer = installer
    let interval = systemDownloadPollInterval
    download = Task { [weak self] in
      while Task.isCancelled == false {
        try? await Task.sleep(for: interval)
        let state = await installer.state()
        guard state == .downloading else {
          self?.finish(state == .installed ? .installed : .notInstalled, for: id)
          return
        }
      }
    }
  }
}

/// A weak reference that can cross into `@Sendable` code; main-actor isolated, so `Sendable`.
private final class WeakReference {
  weak var model: AdSkipSettingsModel?

  init(_ model: AdSkipSettingsModel) { self.model = model }
}

extension AdSkipSettingsModel {
  /// The production model. Without a coordinator (its store or classifier failed to load) the
  /// setting is hidden, as on a phone without a recogniser.
  static let shared = live()

  private static func live() -> AdSkipSettingsModel {
    let hasCoordinator = AdSkipComposition.coordinator != nil
    return AdSkipSettingsModel(
      installer: hasCoordinator ? SpeechAssetInstaller() : UnavailableSpeechAsset(),
      network: PathMonitorUnmeteredNetwork(),
      progressUpdates: {
        AdSkipComposition.coordinator?.progressUpdates() ?? AsyncStream { $0.finish() }
      },
      pauseReason: { AdSkipAnalysisConditions.currentPauseReason() },
      onInstalled: {
        // Analysis deferred for want of the model resumes now rather than at the next activation.
        let allowed = AdSkipAnalysisConditions.isAllowed()
        Task { await AdSkipComposition.coordinator?.setAllowed(allowed) }
      },
      onForget: {
        Task { await AdSkipComposition.coordinator?.forgetLearnedAds() }
      })
  }
}

nonisolated struct UnavailableSpeechAsset: SpeechAssetInstalling {
  func state() async -> SpeechAssetState { .unavailable }
  func install(progress: @Sendable (Progress) -> Void) async throws {}
}

/// Production `UnmeteredNetworkWaiting` over `NWPathMonitor`.
nonisolated struct PathMonitorUnmeteredNetwork: UnmeteredNetworkWaiting {
  func waitForUnmeteredNetwork() async throws {
    let monitor = NWPathMonitor()
    defer { monitor.cancel() }
    let paths = AsyncStream<NWPath> { continuation in
      monitor.pathUpdateHandler = { continuation.yield($0) }
      monitor.start(queue: DispatchQueue(label: "com.remoteconcern.whirr.adskip-network"))
    }
    for await path in paths {
      if path.status == .satisfied, path.isExpensive == false, path.isConstrained == false {
        return
      }
    }
    try Task.checkCancellation()
  }
}
