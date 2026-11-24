import Foundation
import GRDB

/// A show's own Trim Silences setting. Raw values match the `trimSilencesOverride` column's
/// `CHECK` on both show-settings tables.
public enum TrimSilencesShowOverride: String, Codable, Sendable, Equatable, CaseIterable,
  DatabaseValueConvertible
{
  case inherit
  case off
  case moderate
  case maximum

  /// The column's `CHECK` admits only the four cases, so an unknown value can come only from a
  /// transport; it reads as the default rather than as a setting nobody chose.
  public static func parse(_ rawValue: String?) -> Self {
    rawValue.flatMap(Self.init(rawValue:)) ?? .inherit
  }
}

/// A show's own Voice Boost setting. The column arrives with Trim Silences' in v92.
public enum VoiceBoostShowOverride: String, Codable, Sendable, Equatable, CaseIterable,
  DatabaseValueConvertible
{
  case inherit
  case on
  case off

  public static func parse(_ rawValue: String?) -> Self {
    rawValue.flatMap(Self.init(rawValue:)) ?? .inherit
  }
}

/// The per-show override columns v92 added to both show-settings tables. Raw values are the
/// column names.
enum ShowOverrideColumn: String, Sendable {
  case trimSilences = "trimSilencesOverride"
  case voiceBoost = "voiceBoostOverride"
}

/// Every show's Trim Silences override that is not `inherit`, keyed by item id. Playback resolves
/// the loaded show from it, and the analysis queue decides what to analyse.
public protocol TrimSilencesShowSettingsReading: Sendable {
  func fetchTrimSilencesOverrides() async throws -> [String: TrimSilencesShowOverride]
  func observeTrimSilencesOverrides() -> AsyncStream<[String: TrimSilencesShowOverride]>
}

public protocol TrimSilencesShowSettingsWriting: Sendable {
  func setTrimSilencesOverride(itemID: String, override: TrimSilencesShowOverride) async throws
}

/// Every show's Voice Boost override that is not `inherit`, keyed by item id.
public protocol VoiceBoostShowSettingsReading: Sendable {
  func fetchVoiceBoostOverrides() async throws -> [String: VoiceBoostShowOverride]
  func observeVoiceBoostOverrides() -> AsyncStream<[String: VoiceBoostShowOverride]>
}

public protocol VoiceBoostShowSettingsWriting: Sendable {
  func setVoiceBoostOverride(itemID: String, override: VoiceBoostShowOverride) async throws
}

extension PodcastSettingsStore: TrimSilencesShowSettingsReading, TrimSilencesShowSettingsWriting,
  VoiceBoostShowSettingsReading, VoiceBoostShowSettingsWriting
{}

/// Sends each item id to its spine's table and merges both into one item-id dictionary, in the
/// shape of `RoutingItemPlaybackSettingsAccess`.
public struct RoutingTrimSilencesShowSettingsAccess: TrimSilencesShowSettingsReading,
  TrimSilencesShowSettingsWriting, Sendable
{
  private let abs: any (TrimSilencesShowSettingsReading & TrimSilencesShowSettingsWriting)
  private let rss: RSSFeedSettingsStore

  public init(
    abs: any (TrimSilencesShowSettingsReading & TrimSilencesShowSettingsWriting),
    rss: RSSFeedSettingsStore
  ) {
    self.abs = abs
    self.rss = rss
  }

  public func fetchTrimSilencesOverrides() async throws -> [String: TrimSilencesShowOverride] {
    async let absOverrides = abs.fetchTrimSilencesOverrides()
    async let rssOverrides = rss.fetchTrimSilencesOverrides()
    return mergeShowOverrides(abs: try await absOverrides, rss: try await rssOverrides)
  }

  public func observeTrimSilencesOverrides() -> AsyncStream<[String: TrimSilencesShowOverride]> {
    mergedShowOverrideStream(
      abs: abs.observeTrimSilencesOverrides(), rss: rss.observeTrimSilencesOverrides())
  }

  public func setTrimSilencesOverride(
    itemID: String, override: TrimSilencesShowOverride
  ) async throws {
    try await routeShowOverride(
      itemID: itemID,
      rss: { try await rss.setTrimSilencesOverride(feedId: $0, override: override) },
      abs: { try await abs.setTrimSilencesOverride(itemID: itemID, override: override) })
  }
}

/// The Voice Boost counterpart of `RoutingTrimSilencesShowSettingsAccess`.
public struct RoutingVoiceBoostShowSettingsAccess: VoiceBoostShowSettingsReading,
  VoiceBoostShowSettingsWriting, Sendable
{
  private let abs: any (VoiceBoostShowSettingsReading & VoiceBoostShowSettingsWriting)
  private let rss: RSSFeedSettingsStore

  public init(
    abs: any (VoiceBoostShowSettingsReading & VoiceBoostShowSettingsWriting),
    rss: RSSFeedSettingsStore
  ) {
    self.abs = abs
    self.rss = rss
  }

  public func fetchVoiceBoostOverrides() async throws -> [String: VoiceBoostShowOverride] {
    async let absOverrides = abs.fetchVoiceBoostOverrides()
    async let rssOverrides = rss.fetchVoiceBoostOverrides()
    return mergeShowOverrides(abs: try await absOverrides, rss: try await rssOverrides)
  }

  public func observeVoiceBoostOverrides() -> AsyncStream<[String: VoiceBoostShowOverride]> {
    mergedShowOverrideStream(
      abs: abs.observeVoiceBoostOverrides(), rss: rss.observeVoiceBoostOverrides())
  }

  public func setVoiceBoostOverride(
    itemID: String, override: VoiceBoostShowOverride
  ) async throws {
    try await routeShowOverride(
      itemID: itemID,
      rss: { try await rss.setVoiceBoostOverride(feedId: $0, override: override) },
      abs: { try await abs.setVoiceBoostOverride(itemID: itemID, override: override) })
  }
}

private func routeShowOverride(
  itemID: String, rss: (Int64) async throws -> Void, abs: () async throws -> Void
) async throws {
  switch PodcastSourceIdentity(itemId: itemID)?.source {
  case .rss(let feedId):
    do {
      try await rss(feedId)
    } catch RSSFeedSettingsStoreError.feedNotFound {
      throw PodcastSettingsStoreError.itemNotFound
    }
  case .abs:
    try await abs()
  case nil:
    throw PodcastSettingsStoreError.itemNotFound
  }
}

/// Both spines' streams as one: each emission replaces that spine's half and yields the merge.
func mergedShowOverrideStream<Value: Sendable>(
  abs absStream: AsyncStream<[String: Value]>, rss rssStream: AsyncStream<[Int64: Value]>
) -> AsyncStream<[String: Value]> {
  AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
    let state = ShowOverrideMergeState<Value>(continuation: continuation)
    let task = Task {
      await withTaskGroup(of: Void.self) { group in
        group.addTask {
          for await overrides in absStream {
            await state.updateABS(overrides)
          }
        }
        group.addTask {
          for await overrides in rssStream {
            await state.updateRSS(overrides)
          }
        }
        await group.waitForAll()
      }
      continuation.finish()
    }
    continuation.onTermination = { _ in task.cancel() }
  }
}

/// Yields inside the actor, so each merge is published before the next one is computed. Yielding
/// after the call returns would let a later merge publish first, and `bufferingNewest(1)` would
/// then keep the stale one.
private actor ShowOverrideMergeState<Value: Sendable> {
  private let continuation: AsyncStream<[String: Value]>.Continuation
  private var abs: [String: Value] = [:]
  private var rss: [Int64: Value] = [:]

  init(continuation: AsyncStream<[String: Value]>.Continuation) {
    self.continuation = continuation
  }

  func updateABS(_ values: [String: Value]) {
    abs = values
    continuation.yield(mergeShowOverrides(abs: abs, rss: rss))
  }

  func updateRSS(_ values: [Int64: Value]) {
    rss = values
    continuation.yield(mergeShowOverrides(abs: abs, rss: rss))
  }
}

private func mergeShowOverrides<Value>(
  abs: [String: Value], rss: [Int64: Value]
) -> [String: Value] {
  var merged = abs
  for (feedId, value) in rss {
    guard let itemId = PodcastSourceIdentity.rss(feedId: feedId)?.itemId else { continue }
    merged[itemId] = value
  }
  return merged
}
