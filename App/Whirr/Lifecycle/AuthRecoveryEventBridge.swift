import ABSApi
import AppModel
import Persistence
import SyncEngine
import Synchronization

/// The account-lifetime bridge between the credential-free `AuthEventObserving` seam (ABSApi) the
/// shared `ABSClient` reports through, the process's one `AuthRecoveryModel` (AppModel), and the
/// `ResolutionCenter` (SyncEngine), which must resume paused-auth downloads and dead letters once
/// per recovery. In the App target as the lowest point seeing all three (ARCHITECTURE.md §1
/// forbids AppModel importing ABSApi). Cached with the client in
/// `PodcastBackgroundRefreshHardware.sharedServices`, so rebuilds and background wakes share one.
///
/// `resolutionCenter` is a settable `weak` slot: `AppEnvironment.init` needs this bridge to build
/// `ABSClient.production`, before `ResolutionCenter` exists (`PlaybackCoordinatorBox` ties the
/// same knot). `weak` so it never outlives its `AppEnvironment`. `ABSClient` delivers auth events
/// off the main actor, so both late-bound slots are read and written under one lock; a slot that
/// is still unset answers by doing nothing.
nonisolated final class AuthRecoveryEventBridge: AuthEventObserving {
  private struct LateBound {
    weak var resolutionCenter: ResolutionCenter?
    var requestDrainAfterRecovery: (@Sendable () async -> Void)?
  }

  let model: AuthRecoveryModel
  private let lateBound = Mutex(LateBound())
  private let diagnostics: any DiagnosticsRecording
  private let accountId: Int64?

  @MainActor
  init(
    accountLifecycle: any AccountLifecycle,
    diagnostics: any DiagnosticsRecording,
    accountId: Int64?
  ) {
    model = AuthRecoveryModel(accountLifecycle: accountLifecycle)
    self.diagnostics = diagnostics
    self.accountId = accountId
  }

  var resolutionCenter: ResolutionCenter? {
    get { lateBound.withLock { $0.resolutionCenter } }
    set { lateBound.withLock { $0.resolutionCenter = newValue } }
  }

  /// Threaded back in after the playback composition builds the outbox drainer, for the same
  /// reason as `resolutionCenter`. The drain rows a latched client retained as `pending` would
  /// otherwise wait for the next unrelated trigger. `nil` on the background composition.
  var requestDrainAfterRecovery: (@Sendable () async -> Void)? {
    get { lateBound.withLock { $0.requestDrainAfterRecovery } }
    set { lateBound.withLock { $0.requestDrainAfterRecovery = newValue } }
  }

  func authEvent(_ event: AuthEvent) async {
    if let accountId {
      let diagnostic: (DiagnosticsCategory, DiagnosticsStatusClass)
      switch event {
      case .refreshTransport:
        diagnostic = (.refreshTransport, .transportError)
      case .refreshRateLimited:
        diagnostic = (.refreshRateLimited, .clientError)
      case .refreshServerFailure:
        diagnostic = (.refreshServerFailure, .serverError)
      case .refreshDecoding:
        diagnostic = (.refreshDecoding, .clientError)
      case .reauthenticationRequired:
        diagnostic = (.reauthenticationRequired, .clientError)
      case .reauthenticationSucceeded:
        diagnostic = (.reauthenticationSucceeded, .success)
      }
      await diagnostics.record(
        DiagnosticsEvent(
          category: diagnostic.0,
          statusClass: diagnostic.1,
          durationMilliseconds: 0),
        accountId: accountId)
    }

    switch event {
    case .reauthenticationRequired:
      await MainActor.run {
        model.recoveryRequired()
      }
    case .reauthenticationSucceeded:
      // Idempotent. `nil` only on the cold-launch-safe background composition, which never
      // builds a `ResolutionCenter`.
      let (resolutionCenter, requestDrain) = lateBound.withLock {
        ($0.resolutionCenter, $0.requestDrainAfterRecovery)
      }
      try? await resolutionCenter?.handleSuccessfulReauthentication()
      await requestDrain?()
    case .refreshTransport, .refreshRateLimited, .refreshServerFailure, .refreshDecoding:
      break
    }
  }

  /// `ResolutionCenter`'s production `requestReauthentication` closure routes here. The user's
  /// "Reconnect" action and a latched definitive rejection both funnel into
  /// `AuthRecoveryModel.recoveryRequired()`, so there is one recovery state whichever path
  /// raised it.
  func requestReauthentication() async {
    await MainActor.run {
      model.recoveryRequired()
    }
  }
}
