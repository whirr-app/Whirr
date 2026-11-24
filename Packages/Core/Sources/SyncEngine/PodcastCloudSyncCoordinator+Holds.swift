import Foundation
import Persistence

/// Held records: taking one, trying a held send again, and the status that follows the table.
///
/// `needsAttention` is derived, not remembered: it holds while the current namespace has a held
/// record, so an outside fix (schema deployed, record rewritten by another device) clears it.
extension PodcastCloudSyncCoordinator {
  /// Holds a record as needing attention. An outbox record is held at the generation that failed,
  /// read from the outbox when the send is no longer in the ledger, so a newer local mutation is
  /// still eligible to send.
  func hold(
    _ recordName: String, send: PodcastCloudPendingSend?, category: PodcastCloudHoldCategory,
    outbox: Bool = true, serviceCode: Int? = nil
  ) async throws {
    guard let namespace else { return }
    let observedAt = now()
    let sentGeneration = send?.generation
    try await database.writeAsync { db in
      var generation: Int64?
      if outbox {
        generation =
          try sentGeneration
          ?? PodcastCloudTransportStore.pendingSend(
            in: db, namespace: namespace, recordName: recordName)?.generation
      }
      try PodcastCloudTransportStore.hold(
        in: db, namespace: namespace, recordName: recordName, generation: generation,
        category: category.rawValue, observedAt: observedAt)
    }
    let kind = Self.recordKind(of: recordName)
    let code = serviceCode.map(String.init) ?? "none"
    Self.log.error(
      "Podcast sync held a record: \(category.rawValue, privacy: .public), kind \(kind, privacy: .public), service code \(code, privacy: .public)"
    )
    await setStatus(.needsAttention)
  }

  /// The kind component of a record name (`v1.settings.<keyed id>` is `settings`), which says what
  /// sort of record was held without saying which.
  static func recordKind(of recordName: String) -> String {
    let parts = recordName.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count >= 2, parts[0].first == "v", parts[0].dropFirst().allSatisfy(\.isNumber),
      parts[0].count > 1, parts[1].isEmpty == false, parts[1].allSatisfy(\.isLetter)
    else { return "unknown" }
    return String(parts[1])
  }

  /// At the start of a converging session: forgets the holds of namespaces that can no longer
  /// sync, and lets every held send be offered once more. A send the service still refuses is
  /// held again, so the cost of a rejection that persists is one failed save per launch.
  func releaseHoldsForNewSession() async {
    guard let namespace else { return }
    do {
      try await transport.pruneHeldRecords(keeping: namespace)
      _ = try await transport.releaseOutboxHolds(namespace: namespace)
    } catch {
      Self.log.error("Podcast sync could not release held sends: \(Self.describe(error), privacy: .public)")
    }
  }

  /// Try Again's share of a retry: the held sends go back on offer and the engine is told.
  func retryHeldSends() async {
    guard phase == .running, let namespace else { return }
    guard let released = try? await transport.releaseOutboxHolds(namespace: namespace), released > 0
    else { return }
    await settleAttention()
    await outboxDidChange()
  }

  func hasHeldRecords() async -> Bool {
    guard let namespace else { return false }
    // A read that fails must not turn a hold into "up to date".
    return (try? await transport.hasHeldRecords(namespace: namespace)) ?? true
  }

  /// Clears `needsAttention` once nothing is held. Every other status is left alone: each has its
  /// own way out.
  func settleAttention() async {
    guard status == .needsAttention, await hasHeldRecords() == false else { return }
    await setStatus(.upToDate)
  }
}
