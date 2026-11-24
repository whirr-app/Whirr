import AppModel
import Foundation
import Persistence
import WatchConnectivity
import WatchProtocol

/// The two reports the Watch publishes in its application context — playing and status — and the
/// native-progress payloads held in memory until the store can open. Ingress routing and the
/// command endpoints stay in the primary declaration.
extension WatchPhoneBridge {
  /// The Watch publishes its playing report in its application context, which carries no reply.
  /// A report for another account, or one that arrives before an account is bound, is dropped; the
  /// Watch republishes on its next transition and the reader treats an old one as expired.
  func receivePlayingReport(_ data: Data) {
    ensureBootstrapped()
    guard didBootstrap else { return }
    acceptPlayingReport(data)
  }

  /// Re-reads the context WatchConnectivity already delivered to an earlier process or before the
  /// account was bound. It does not bootstrap: the caller is the account's own composition.
  func replayReceivedPlayingReport() {
    guard let data = session?.receivedApplicationContext[WatchPlayingReport.transportKey] as? Data else { return }
    acceptPlayingReport(data)
  }

  func acceptPlayingReport(_ data: Data) {
    guard data.count <= WatchPlayingReport.maxWireBytes, let stamp = authenticatedStamp(),
      let report = try? WatchWireCodec.decode(WatchPlayingReport.self, from: data),
      report.accountStamp == stamp
    else { return }
    storePlayingReport(report)
  }

  /// The Watch publishes its status in the same application context, with no reply of its own. A
  /// report for another account, a signed-out one and one that cannot decode are dropped; the
  /// record ignores anything older than the confirmation it already holds.
  func receiveStatusReport(_ data: Data) {
    ensureBootstrapped()
    guard didBootstrap else { return }
    acceptStatusReport(data)
  }

  /// Re-reads the status WatchConnectivity already delivered to an earlier process or before the
  /// account was bound. Like the playing report's replay, it does not bootstrap.
  func replayReceivedStatusReport() {
    guard let data = session?.receivedApplicationContext[WatchStatusReport.transportKey] as? Data else { return }
    acceptStatusReport(data)
  }

  func acceptStatusReport(_ data: Data) {
    guard data.count <= WatchStatusReport.maxWireBytes, let stamp = authenticatedStamp(),
      let report = try? WatchWireCodec.decode(WatchStatusReport.self, from: data),
      report.accountStamp == stamp
    else { return }
    storeStatusReport(report)
  }

  /// Keeps at most the newest few payloads; each one is already capped at
  /// `WatchNativeProgressReport.maxWireBytes`.
  func holdNativeProgress(_ data: Data) {
    heldNativeProgress.append(data)
    if heldNativeProgress.count > Self.heldNativeProgressLimit {
      heldNativeProgress.removeFirst(heldNativeProgress.count - Self.heldNativeProgressLimit)
    }
  }

  /// Applies held reports in arrival order: the inbox rejects a sequence at or below the last one
  /// it accepted, so a later report delivered first would hide the earlier ones. A payload that
  /// arrives during a drain stays held and this loop picks it up.
  func deliverHeldNativeProgress() async {
    guard isDeliveringHeldNativeProgress == false else { return }
    ensureBootstrapped()
    guard didBootstrap, let inbox = nativeProgressInbox() else { return }
    isDeliveringHeldNativeProgress = true
    defer { isDeliveringHeldNativeProgress = false }
    while heldNativeProgress.isEmpty == false {
      let pending = heldNativeProgress
      heldNativeProgress.removeAll(keepingCapacity: true)
      for data in pending { await inbox.receive(data) }
    }
  }
}
