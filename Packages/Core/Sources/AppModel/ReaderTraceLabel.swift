import Foundation
import Persistence

/// The `WHIRRRDR` vocabulary for the reader's two state machines. Labels omit payloads that change
/// continuously (progress above all) so a ticking bar is not mistaken for a transition. Payloads
/// travel as their own fields.
enum ReaderTraceLabel {
  static func label(for state: ReaderState) -> String {
    switch state {
    case .noEpubAdvertised: "no-epub"
    case .ebookIdentityNotFetched: "identity-not-fetched"
    case .advertisedButUnavailable: "advertised-unavailable"
    case .availableNotDownloaded: "not-downloaded"
    case .downloading: "downloading"
    case .downloadHeld(let reason, _): "held-\(label(for: reason))"
    case .downloadedReady: "ready"
    case .downloadedButFileMissing: "file-missing"
    case .downloadFailed: "download-failed"
    case .downloadRejected: "download-rejected"
    }
  }

  static func label(for state: ReaderModel.State) -> String {
    switch state {
    case .idle: "idle"
    case .downloading: "downloading"
    case .downloadHeld(let reason): "held-\(label(for: reason))"
    case .opening: "opening"
    case .reading: "reading"
    case .unavailable: "unavailable"
    case .drmProtected: "drm"
    case .recoverableError: "recoverable-error"
    case .unopenable: "unopenable"
    case .publicationServerFailure: "server-failure"
    }
  }

  static func label(for reason: ReaderDownloadHold) -> String {
    switch reason {
    case .waitingForWiFi: "wifi"
    case .paused: "paused"
    case .pausedAuth: "auth"
    }
  }
}
