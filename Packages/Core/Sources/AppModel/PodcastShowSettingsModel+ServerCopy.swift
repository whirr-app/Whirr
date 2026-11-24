import Foundation
import Persistence

/// The server section of a followed RSS show.
///
/// A feed's settings belong to this device; the server section describes another machine. So the
/// section is built only from the diagnostics of the feed's server copy (the server item whose feed
/// fingerprint equals the feed's), never the feed's own. The copy is found by a local read, so one
/// the last library sync has not seen yet means no section.
///
/// A feed with a device-held credential never reads the fingerprint at all (ADR 0006, SECURITY
/// rule 19), and a credential state that is still pending or failed to load counts as held.
extension PodcastShowSettingsModel {
  /// Starts, restarts or stops the copy observation so it matches the current fingerprint and
  /// credential state. Called whenever either may have changed; cheap when nothing did.
  func reconcileServerCopyObservation() {
    guard supportsFeedCredentials else { return }
    let desired: String? =
      feedCredentialStateKnown && hasFeedCredential == false ? nativeFeedFingerprint : nil
    guard desired != observedCopyFingerprint else { return }
    observedCopyFingerprint = desired
    serverCopyTask?.cancel()
    serverCopyTask = nil
    applyServerCopies([])
    guard let desired else { return }
    let stream = podcastReading.observeServerCopyItemIDs(podcastFeedFingerprint: desired)
    serverCopyTask = Task { [weak self] in
      for await ids in stream {
        guard let self, self.observedCopyFingerprint == desired else { return }
        self.applyServerCopies(ids)
      }
    }
  }

  private func applyServerCopies(_ ids: [String]) {
    switch ids.count {
    case 0:
      serverCopiesNotice = nil
      retargetServerCopy(nil)
    case 1:
      serverCopiesNotice = nil
      retargetServerCopy(ids[0])
    default:
      serverCopiesNotice = PodcastServerSettingsMessage.severalCopies
      retargetServerCopy(nil)
    }
  }

  private func retargetServerCopy(_ target: String?) {
    guard target != serverTargetItemID else { return }
    serverCopyDiagnosticsTask?.cancel()
    serverCopyDiagnosticsTask = nil
    serverTargetItemID = target
    serverDiagnostics = nil
    serverSettingsMessage = nil
    refreshServerSection()
    guard let target else { return }
    requestServerCapabilityOnce()
    let stream = podcastReading.observeShowDiagnostics(itemId: target)
    serverCopyDiagnosticsTask = Task { [weak self] in
      for await diagnostics in stream {
        guard let self, self.serverTargetItemID == target else { return }
        self.serverDiagnostics = diagnostics
        self.refreshServerSection()
        if self.serverSettings == nil { self.requestServerFill() }
      }
    }
  }
}
