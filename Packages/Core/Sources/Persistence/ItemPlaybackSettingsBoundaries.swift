import Foundation

/// The account-scoped playback-rate override read surface. ABS item ids and twentieth-based rate
/// steps are the domain contract; database records and GRDB types remain inside Persistence.
public protocol ItemPlaybackSettingsReading: Sendable {
  func fetchOverride(itemID: String) async throws -> Int?
  func fetchOverrides() async throws -> [String: Int]
  func observeOverrides() -> AsyncStream<[String: Int]>
}

/// The account-scoped playback-rate override write surface. The coordinator owns this raw
/// persistence boundary so every App mutation uses one serialization policy.
public protocol ItemPlaybackSettingsWriting: Sendable {
  func upsertOverride(itemID: String, rateStep: Int) async throws
  func deleteOverride(itemID: String) async throws
  func deleteAllOverrides() async throws
}

/// Incremental-composition default for callers that have no account database yet.
public struct NoOpItemPlaybackSettingsReading: ItemPlaybackSettingsReading, Sendable {
  public init() {}

  public func fetchOverride(itemID: String) async throws -> Int? { nil }

  public func fetchOverrides() async throws -> [String: Int] { [:] }

  public func observeOverrides() -> AsyncStream<[String: Int]> {
    AsyncStream { $0.finish() }
  }
}

/// Incremental-composition default for callers that have no account database yet.
public struct NoOpItemPlaybackSettingsWriting: ItemPlaybackSettingsWriting, Sendable {
  public init() {}

  public func upsertOverride(itemID: String, rateStep: Int) async throws {}

  public func deleteOverride(itemID: String) async throws {}

  public func deleteAllOverrides() async throws {}
}

/// The combined no-op access used by dependency containers that are not account-bound.
public struct NoOpItemPlaybackSettingsAccess: ItemPlaybackSettingsReading,
  ItemPlaybackSettingsWriting, Sendable
{
  public init() {}

  public func fetchOverride(itemID: String) async throws -> Int? { nil }

  public func fetchOverrides() async throws -> [String: Int] { [:] }

  public func observeOverrides() -> AsyncStream<[String: Int]> {
    AsyncStream { $0.finish() }
  }

  public func upsertOverride(itemID: String, rateStep: Int) async throws {}

  public func deleteOverride(itemID: String) async throws {}

  public func deleteAllOverrides() async throws {}
}

extension ItemPlaybackSettingsStore: ItemPlaybackSettingsReading, ItemPlaybackSettingsWriting {}

/// The device-owned equivalent of `ItemPlaybackSettingsReading`. RSS rates are keyed by feed
/// rather than an ABS item row, and take no account parameter because native subscriptions
/// survive logout.
public protocol RSSPlaybackRateSettingsReading: Sendable {
  func fetchRateOverride(feedId: Int64) async throws -> Int?
  func fetchRateOverrides() async throws -> [Int64: Int]
  func observeRateOverrides() -> AsyncStream<[Int64: Int]>
}

/// The device-owned equivalent of `ItemPlaybackSettingsWriting`. Clearing a rate only clears the
/// rate column; other RSS feed settings remain intact.
public protocol RSSPlaybackRateSettingsWriting: Sendable {
  func setRateOverride(feedId: Int64, rateStep: Int) async throws
  func clearRateOverride(feedId: Int64) async throws
  func clearAllRateOverrides() async throws
}

extension RSSFeedSettingsStore: RSSPlaybackRateSettingsReading, RSSPlaybackRateSettingsWriting {}

/// Composition-time facade for the two playback-rate stores. The coordinator can retain its
/// existing account-scoped item boundary while this type dispatches RSS identities to the
/// device-owned `rssFeedSettings` table and projects both caches as one item-id dictionary.
public struct RoutingItemPlaybackSettingsAccess: ItemPlaybackSettingsReading,
  ItemPlaybackSettingsWriting, Sendable
{
  private let abs: any (ItemPlaybackSettingsReading & ItemPlaybackSettingsWriting)
  private let rss: any (RSSPlaybackRateSettingsReading & RSSPlaybackRateSettingsWriting)

  public init(
    abs: any (ItemPlaybackSettingsReading & ItemPlaybackSettingsWriting),
    rss: any (RSSPlaybackRateSettingsReading & RSSPlaybackRateSettingsWriting)
  ) {
    self.abs = abs
    self.rss = rss
  }

  public func fetchOverride(itemID: String) async throws -> Int? {
    switch PodcastSourceIdentity(itemId: itemID)?.source {
    case .rss(let feedId):
      return try await rss.fetchRateOverride(feedId: feedId)
    case .abs:
      return try await abs.fetchOverride(itemID: itemID)
    case nil:
      return nil
    }
  }

  public func fetchOverrides() async throws -> [String: Int] {
    async let absOverrides = abs.fetchOverrides()
    async let rssOverrides = rss.fetchRateOverrides()
    let absValues = try await absOverrides
    let rssValues = try await rssOverrides
    return mergePlaybackRateOverrides(
      abs: absValues, rss: rssValues)
  }

  public func observeOverrides() -> AsyncStream<[String: Int]> {
    let absStream = abs.observeOverrides()
    let rssStream = rss.observeRateOverrides()
    let state = PlaybackRateOverrideMergeState()

    return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
      let task = Task {
        await withTaskGroup(of: Void.self) { group in
          group.addTask {
            for await overrides in absStream {
              continuation.yield(await state.updateABS(overrides))
            }
          }
          group.addTask {
            for await overrides in rssStream {
              continuation.yield(await state.updateRSS(overrides))
            }
          }
          await group.waitForAll()
        }
        continuation.finish()
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }

  public func upsertOverride(itemID: String, rateStep: Int) async throws {
    switch PodcastSourceIdentity(itemId: itemID)?.source {
    case .rss(let feedId):
      try await rss.setRateOverride(feedId: feedId, rateStep: rateStep)
    case .abs:
      try await abs.upsertOverride(itemID: itemID, rateStep: rateStep)
    case nil:
      throw ItemPlaybackSettingsStoreError.itemNotFound
    }
  }

  public func deleteOverride(itemID: String) async throws {
    switch PodcastSourceIdentity(itemId: itemID)?.source {
    case .rss(let feedId):
      try await rss.clearRateOverride(feedId: feedId)
    case .abs:
      try await abs.deleteOverride(itemID: itemID)
    case nil:
      throw ItemPlaybackSettingsStoreError.itemNotFound
    }
  }

  /// Account teardown calls this facade. RSS rows remain device-owned, but their playback-rate
  /// override is cleared alongside the account's ABS override so a new account cannot inherit a
  /// stale composed cache.
  public func deleteAllOverrides() async throws {
    var firstError: Error?
    do {
      try await abs.deleteAllOverrides()
    } catch {
      firstError = error
    }
    do {
      try await rss.clearAllRateOverrides()
    } catch {
      firstError = firstError ?? error
    }
    if let firstError {
      throw firstError
    }
  }
}

private actor PlaybackRateOverrideMergeState {
  private var abs: [String: Int] = [:]
  private var rss: [Int64: Int] = [:]

  func updateABS(_ values: [String: Int]) -> [String: Int] {
    abs = values
    return merged()
  }

  func updateRSS(_ values: [Int64: Int]) -> [String: Int] {
    rss = values
    return merged()
  }

  private func merged() -> [String: Int] {
    mergePlaybackRateOverrides(abs: abs, rss: rss)
  }
}

private func mergePlaybackRateOverrides(
  abs: [String: Int], rss: [Int64: Int]
) -> [String: Int] {
  var merged = abs
  for (feedId, rateStep) in rss {
    guard let itemId = PodcastSourceIdentity.rss(feedId: feedId)?.itemId else { continue }
    merged[itemId] = rateStep
  }
  return merged
}
