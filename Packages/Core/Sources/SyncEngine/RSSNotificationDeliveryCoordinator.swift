import Foundation
import Persistence

public enum RSSLocalNotificationAuthorizationStatus: Sendable, Equatable {
  case notDetermined
  case allowed
  case denied
}

public struct RSSNotificationRequest: Sendable, Equatable {
  public static let maximumCopyLength = 120
  private static let emptyCopyFallback = "New podcast episodes"

  public let identifier: String
  public let title: String
  public let body: String
  public let route: RSSNotificationRoute
  /// One background pass can deliver several requests at once; only the first is audible.
  public let playsSound: Bool

  public init(
    identifier: String, title: String, body: String, route: RSSNotificationRoute,
    playsSound: Bool = true
  ) {
    self.identifier = identifier
    self.title = Self.normalizedCopy(title)
    self.body = Self.normalizedCopy(body)
    self.route = route
    self.playsSound = playsSound
  }

  /// ZWJ composes emoji sequences and ZWNJ controls Persian, Arabic and Indic shaping. Dropping
  /// the whole `.format` category would mangle legitimate titles, so these two are kept while
  /// bidirectional overrides, isolates and invisible padding are removed.
  private static let preservedFormatScalars: Set<Unicode.Scalar> = ["\u{200C}", "\u{200D}"]

  /// Copy that normalises to nothing visible (whitespace, or only the joiners kept above) cannot
  /// be displayed, so the generic string stands in for it.
  private static func isVisuallyEmpty(_ value: String) -> Bool {
    value.unicodeScalars.allSatisfy { $0.properties.generalCategory == .format }
  }

  private static func normalized(_ value: String) -> String {
    var result = String.UnicodeScalarView()
    var pendingWhitespace = false

    for scalar in value.unicodeScalars {
      let category = scalar.properties.generalCategory
      if category == .format, Self.preservedFormatScalars.contains(scalar) == false {
        continue
      }
      if scalar.properties.isWhitespace || category == .control || category == .lineSeparator
        || category == .paragraphSeparator
      {
        pendingWhitespace = result.isEmpty == false
        continue
      }
      if pendingWhitespace {
        result.append(" ")
        pendingWhitespace = false
      }
      result.append(scalar)
    }
    return String(result)
  }

  private static func normalizedCopy(_ value: String) -> String {
    let normalized = Self.normalized(value)
    return Self.bounded(Self.isVisuallyEmpty(normalized) ? Self.emptyCopyFallback : normalized)
  }

  private static func bounded(_ value: String) -> String {
    String(value.prefix(maximumCopyLength))
  }
}

public protocol RSSNotificationIntentReading: Sendable {
  func isNewEpisodeNotificationEnabled() async -> Bool
}

public protocol RSSNotificationIntentWriting: Sendable {
  func setNewEpisodeNotificationEnabled(_ enabled: Bool) async
}

public struct DisabledRSSNotificationIntent: RSSNotificationIntentReading,
  RSSNotificationIntentWriting
{
  public init() {}
  public func isNewEpisodeNotificationEnabled() async -> Bool { false }
  public func setNewEpisodeNotificationEnabled(_ enabled: Bool) async { _ = enabled }
}

public struct NoOpRSSLocalNotificationScheduler: RSSLocalNotificationScheduling {
  public init() {}
  public func authorizationStatus() async -> RSSLocalNotificationAuthorizationStatus { .denied }
  public func schedule(_ request: RSSNotificationRequest) async throws { _ = request }
  public func cancel(requestIDs: [String]) async { _ = requestIDs }
}

/// Task-local classification bridges the delivery coordinator to `RSSPodcastRefreshing` without
/// widening the general-purpose `PodcastRefreshing` protocol used by ABS and foreground UI.
public enum RSSNotificationDiscoveryScope {
  @TaskLocal public static var context: RSSNotificationDiscoveryContext?
}

public protocol RSSLocalNotificationScheduling: Sendable {
  func authorizationStatus() async -> RSSLocalNotificationAuthorizationStatus
  func schedule(_ request: RSSNotificationRequest) async throws
  func cancel(requestIDs: [String]) async
}

public protocol RSSNotificationLedgerAccess: Sendable {
  func eligibleCandidates(globalEnabled: Bool, now: Date, limit: Int) async throws
    -> [RSSNotificationCandidate]
  /// Must transition the batch all-or-nothing: the returned count is either `candidates.count` or
  /// zero. The scheduled request describes every candidate, so a conformance that let part of a
  /// batch through would deliver a notification naming a feed the ledger had already silenced.
  func markScheduled(_ candidates: [RSSNotificationCandidate], requestID: String) async throws -> Int
}

extension RSSNotificationLedgerStore: RSSNotificationLedgerAccess {}

public protocol RSSNotificationLifecycleHandling: Sendable {
  func disarm(feedID: Int64?) async
}

public struct NoOpRSSNotificationLifecycle: RSSNotificationLifecycleHandling {
  public init() {}
  public func disarm(feedID: Int64?) async { _ = feedID }
}

public actor RSSNotificationLifecycleCoordinator: RSSNotificationLifecycleHandling {
  private let ledger: RSSNotificationLedgerStore
  private let scheduler: any RSSLocalNotificationScheduling
  public init(ledger: RSSNotificationLedgerStore, scheduler: any RSSLocalNotificationScheduling) {
    self.ledger = ledger
    self.scheduler = scheduler
  }
  public func disarm(feedID: Int64?) async {
    let requestIDs = (try? await ledger.disarm(feedID: feedID)) ?? []
    await scheduler.cancel(requestIDs: requestIDs)
  }
}

public protocol RSSBackgroundRefreshCompleting: Sendable {
  func completeBackgroundRefresh(now: Date) async
}

public struct NoOpRSSBackgroundRefreshCompletion: RSSBackgroundRefreshCompleting {
  public init() {}
  public func completeBackgroundRefresh(now: Date) async { _ = now }
}

/// Consumes at most one bounded candidate set after the background feed walk, announcing each
/// episode on its own. It has no timer or detached retry: a later system-granted refresh is the
/// only retry opportunity.
public actor RSSNotificationDeliveryCoordinator: RSSBackgroundRefreshCompleting {
  public static let maximumCandidatesPerPass = 12
  /// A show that lands this many episodes in one pass is a back-catalogue dump rather than a
  /// release, so it is announced once as a show instead of once per episode.
  static let showSummaryThreshold = 3

  private let ledger: any RSSNotificationLedgerAccess
  private let intent: any RSSNotificationIntentReading
  private let scheduler: any RSSLocalNotificationScheduling

  public init(
    ledger: any RSSNotificationLedgerAccess,
    intent: any RSSNotificationIntentReading,
    scheduler: any RSSLocalNotificationScheduling
  ) {
    self.ledger = ledger
    self.intent = intent
    self.scheduler = scheduler
  }

  public func completeBackgroundRefresh(now: Date) async {
    let globalEnabled = await intent.isNewEpisodeNotificationEnabled()
    guard Task.isCancelled == false,
      await scheduler.authorizationStatus() == .allowed,
      let candidates = try? await ledger.eligibleCandidates(
        globalEnabled: globalEnabled, now: now, limit: Self.maximumCandidatesPerPass),
      candidates.isEmpty == false
    else { return }

    var soundPending = true
    for batch in Self.batches(for: candidates) {
      guard Task.isCancelled == false else { return }
      let request = Self.request(for: batch, playsSound: soundPending)
      do {
        try await scheduler.schedule(request)
        soundPending = false
        try Task.checkCancellation()
        // Zero means a disarm beat this pass to the ledger: the rows are no longer ours to
        // announce, so take back the request the scheduler just accepted. The transition is
        // all-or-nothing, so any shortfall arrives here as zero rather than as a half-announced
        // batch.
        let updatedCount = try await ledger.markScheduled(batch, requestID: request.identifier)
        if updatedCount < batch.count {
          await scheduler.cancel(requestIDs: [request.identifier])
        }
      } catch is CancellationError {
        // A scheduler that ignores task cancellation can accept this request after the background
        // pass has already expired. Its stable id makes that late side effect compensatable.
        await scheduler.cancel(requestIDs: [request.identifier])
        return
      } catch {
        // Keep pending rows retryable. Production logging records only the pass outcome/count.
      }
    }
  }

  /// Splits a pass into the groups that each become one request: every episode alone, except a
  /// show at or past `showSummaryThreshold`, whose episodes share one. Groups are ordered oldest
  /// first because the system stacks the most recently delivered notification on top.
  static func batches(for candidates: [RSSNotificationCandidate]) -> [[RSSNotificationCandidate]] {
    var batches: [[RSSNotificationCandidate]] = []
    for group in Dictionary(grouping: candidates, by: \.feedID).values {
      if group.count >= showSummaryThreshold {
        batches.append(group)
      } else {
        batches.append(contentsOf: group.map { [$0] })
      }
    }
    func sortKey(_ batch: [RSSNotificationCandidate]) -> (Date, Int64, String) {
      (
        batch.map(\.publishedAt).max() ?? .distantPast, batch[0].feedID,
        batch.map(\.identityKey).min() ?? ""
      )
    }
    return batches.sorted { sortKey($0) < sortKey($1) }
  }

  /// Builds the request for one group from `batches(for:)`: a single episode, or several episodes
  /// of the same show.
  static func request(
    for candidates: [RSSNotificationCandidate], playsSound: Bool = true
  ) -> RSSNotificationRequest {
    let ordered = candidates.sorted {
      ($0.feedID, $0.identityKey) < ($1.feedID, $1.identityKey)
    }
    let route: RSSNotificationRoute
    let body: String
    if ordered.count == 1 {
      route = .episode(feedID: ordered[0].feedID, identityKey: ordered[0].identityKey)
      body = ordered[0].episodeTitle
    } else {
      route = .show(feedID: ordered[0].feedID)
      body = "\(ordered.count) new episodes"
    }
    let material = ordered.map { "\($0.feedID):\($0.identityKey)" }.joined(separator: "|")
    return RSSNotificationRequest(
      identifier: "rss.new-episodes.\(stableHash(material))", title: ordered[0].showTitle,
      body: body, route: route, playsSound: playsSound)
  }

  /// Deterministic FNV-1a is sufficient here: this is an idempotency key, not a security digest.
  private static func stableHash(_ value: String) -> String {
    var hash: UInt64 = 14_695_981_039_346_656_037
    for byte in value.utf8 {
      hash ^= UInt64(byte)
      hash &*= 1_099_511_628_211
    }
    return String(hash, radix: 16)
  }
}
