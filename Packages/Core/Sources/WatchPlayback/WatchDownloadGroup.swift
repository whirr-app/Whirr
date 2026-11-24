import Foundation
import WatchProtocol

/// One Audiobookshelf download as the listener sees it: a book of many files, or one episode. The
/// Watch's own row and its inventory entry for the phone both read this fold, so they cannot
/// disagree, and its completeness rule is `WatchDownloadManifest.indicesCoverPlan`, the rule
/// `WatchDownloadStore.isGroupComplete` applies before playback.
public struct WatchDownloadGroup: Identifiable, Equatable, Sendable {
  public enum State: Equatable, Sendable {
    /// Fewer files are enqueued than the plan expects: the plan is still being enqueued, or a
    /// launch ended before it finished. Not a failure; the next fetch or retry enqueues the rest.
    case enqueuing
    case waiting
    /// Held by the Watch's Wi-Fi-only policy.
    case waitingForNetwork
    case downloading
    case failed
    /// A file was refused for want of space.
    case declined
    case ready
  }

  public let id: String
  public let accountStamp: WatchAccountStamp
  public let selection: WatchSelection
  public let origin: WatchABSOrigin
  /// The phone's revision for a phone-origin group; `nil` for the wrist's own.
  public let phoneRevision: UInt64?
  public let manifestIDs: [UUID]
  public let expectedTrackCount: Int
  public let completedTrackCount: Int
  public let receivedBytes: Int64
  public let expectedBytes: Int64?
  /// The first failed file's reason, in file order, when the group is `failed` or `declined`.
  public let failureReason: WatchDownloadFailureReason?
  /// When the group's oldest file was enqueued. A removal the phone sent before this cannot mean
  /// this download.
  public let createdAt: Date
  public let state: State

  public var progress: Double? {
    guard let expectedBytes, expectedBytes > 0, receivedBytes >= 0 else { return nil }
    return min(1, Double(receivedBytes) / Double(expectedBytes))
  }

  public var isReady: Bool { state == .ready }

  public static func groups(from manifests: [WatchDownloadManifest]) -> [WatchDownloadGroup] {
    let grouped = Dictionary(grouping: manifests) { GroupKey(accountStamp: $0.accountStamp, selection: $0.selection) }
    return grouped.values.compactMap { make($0) }.sorted { $0.id < $1.id }
  }

  private struct GroupKey: Hashable {
    let accountStamp: WatchAccountStamp
    let selection: WatchSelection
  }

  /// Folds one selection's manifests. Precedence runs from what the listener most needs to know:
  /// a plan that can never complete, then ready, then a refusal for space, a failure, an unfinished
  /// plan, and finally transfer progress.
  public static func make(_ unordered: [WatchDownloadManifest]) -> WatchDownloadGroup? {
    let manifests = unordered.sorted { ($0.fileIndex, $0.id.uuidString) < ($1.fileIndex, $1.id.uuidString) }
    guard let first = manifests.first else { return nil }
    let expectedCount = max(1, first.expectedTrackCount)
    let sameGroup = manifests.allSatisfy {
      $0.expectedTrackCount == expectedCount && $0.downloadGroupID == first.downloadGroupID
        && $0.accountStamp == first.accountStamp && $0.selection == first.selection
    }
    let indices = manifests.map(\.fileIndex)
    // A plan that names a file twice or holds more files than it expects can never complete.
    let consistent =
      sameGroup && first.expectedTrackCount > 0 && manifests.count <= expectedCount
      && Set(indices).count == indices.count && expectedCount <= WatchDownloadManifest.maxPlanTracks
    let completePlan = consistent && WatchDownloadManifest.indicesCoverPlan(indices, expectedCount: expectedCount)
    let failures = manifests.filter { $0.state == .failed }
    let state: State
    if completePlan && manifests.allSatisfy(\.isPlayable) {
      state = .ready
    } else if consistent && failures.contains(where: { $0.failureReason == .storage || $0.failureReason == .quota }) {
      state = .declined
    } else if !consistent || !failures.isEmpty {
      state = .failed
    } else if !completePlan {
      state = .enqueuing
    } else if manifests.contains(where: { $0.state == .downloading }) {
      state = .downloading
    } else if manifests.contains(where: { $0.state == .queued && $0.failureReason == .waitingForWiFi }) {
      state = .waitingForNetwork
    } else {
      state = .waiting
    }
    let bytesKnown = completePlan && manifests.allSatisfy { $0.expectedBytes.map { $0 > 0 } ?? false }
    let phone = manifests.filter { $0.origin == .phone && ($0.phoneRevision ?? 0) > 0 }
    return WatchDownloadGroup(
      id: identity(first), accountStamp: first.accountStamp, selection: first.selection,
      origin: phone.isEmpty ? .watch : .phone, phoneRevision: phone.compactMap(\.phoneRevision).max(),
      manifestIDs: manifests.map(\.id).sorted { $0.uuidString < $1.uuidString },
      expectedTrackCount: expectedCount, completedTrackCount: manifests.filter(\.isPlayable).count,
      receivedBytes: checkedSum(manifests.map { max(0, $0.receivedBytes) }) ?? Int64.max,
      expectedBytes: bytesKnown ? checkedSum(manifests.compactMap(\.expectedBytes)) : nil,
      failureReason: failures.first?.failureReason, createdAt: manifests.map(\.createdAt).min() ?? first.createdAt,
      state: state)
  }

  static func checkedSum(_ values: [Int64]) -> Int64? {
    var result: Int64 = 0
    for value in values {
      let sum = result.addingReportingOverflow(value)
      guard !sum.overflow else { return nil }
      result = sum.partialValue
    }
    return result
  }

  private static func identity(_ manifest: WatchDownloadManifest) -> String {
    let parts: [String]
    switch manifest.selection {
    case .audiobookshelf(let itemID, let episodeID): parts = ["abs", itemID, episodeID ?? ""]
    case .nativeFeed(let feedID, let episodeID): parts = ["rss", feedID, episodeID]
    }
    return ([manifest.accountStamp.accountIdentityHash, manifest.accountStamp.serverIdentityHash] + parts)
      .map { "\($0.utf8.count):\($0)" }.joined()
  }
}
