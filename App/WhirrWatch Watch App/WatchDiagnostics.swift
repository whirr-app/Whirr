import OSLog

/// Only fixed event names enter system logs; account names, media IDs, URLs and credentials cannot
/// be passed through this API. Detailed errors remain inside the owning framework.
nonisolated enum WatchDiagnostics {
  enum Event: String {
    case signInFailed = "sign_in_failed"
    case playbackFailed = "playback_failed"
    case progressPersistenceFailed = "progress_persistence_failed"
    case downloadUnavailable = "download_unavailable"
    case offlineWatchNewer = "offline_progress_watch_newer"
    case offlineSharedNewer = "offline_progress_shared_newer"
    case offlineTieFurther = "offline_progress_tie_further"
    case offlineFutureClock = "offline_progress_future_clock"
    case offlineNearZeroKept = "offline_progress_near_zero_kept"
    case libraryLoadFailed = "library_load_failed"
    case downloadTransferStarted = "download_transfer_started"
    case downloadCompleted = "download_completed"
    case downloadFailedInterrupted = "download_failed_interrupted"
    case downloadFailedTransport = "download_failed_transport"
    case downloadFailedUnauthorized = "download_failed_unauthorized"
    case downloadFailedValidation = "download_failed_validation"
    case downloadFailedStorage = "download_failed_storage"
    case downloadFailedOther = "download_failed_other"
    case downloadHTTPStatus = "download_http_status"
    case downloadRedirectRefused = "download_redirect_refused"
    case downloadTransportError = "download_transport_error"
    case downloadFinishDropped = "download_finish_dropped"
    case downloadFailureDropped = "download_failure_dropped"
    case protectedStateWriteFailed = "protected_state_write_failed"
  }
  private static let logger = Logger(subsystem: "com.remoteconcern.whirr.watchkitapp", category: "playback")
  static func record(_ event: Event) { logger.notice("\(event.rawValue, privacy: .public)") }
  /// A numeric detail only, such as an HTTP status or an error code, which names nothing.
  static func record(_ event: Event, code: Int) {
    logger.notice("\(event.rawValue, privacy: .public) code=\(code, privacy: .public)")
  }
}
