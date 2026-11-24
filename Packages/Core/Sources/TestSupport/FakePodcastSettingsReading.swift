import Foundation
import Persistence

/// `PodcastSettingsReading`'s fake. All three observations are live: `pushGlobal`,
/// `pushShowRows` and `pushShowSettings` reach the open subscriptions and the latest value is
/// replayed to a later subscriber, as the store's observations yield their current value on
/// subscription. Seed `global` or `showSummaries` at init for a test that only needs the value;
/// nothing is emitted until a value is seeded or pushed, and no stream finishes.
///
/// A push with a `generation` reaches only the nth subscription of that observation, in creation
/// order, and is not replayed. A model that resubscribes (a reload) leaves its first
/// subscription's continuation here, so a test can deliver a late value through it and prove the
/// model ignores it.
public final class FakePodcastSettingsReading: PodcastSettingsReading, @unchecked Sendable {
  public enum Call: Sendable, Equatable {
    case currentShowSettings(itemID: String)
    case observeGlobalSettings
    case observeShowSummaries
    case observeShowSettings(itemID: String)
  }

  /// Every call in order.
  public let recorder = CallRecorder<Call>(label: "FakePodcastSettingsReading")
  public var calls: [Call] { recorder.calls }

  private let globalHub: KeyedObservationHub<String, PodcastGlobalSettings>
  private let summariesHub: KeyedObservationHub<String, [PodcastShowSettingsSummary]>
  private let detailHub = KeyedObservationHub<String, PodcastShowSettingsDetail?>()
  private let currentDetails = Locked<[String: PodcastShowSettingsDetail]>([:])
  private static let onlyKey = ""

  /// - Parameters:
  ///   - global: what `observeGlobalSettings` starts with. `nil` leaves it silent until pushed.
  ///   - showSummaries: what `observeShowSummaries` starts with. `nil` leaves it silent.
  public init(
    global: PodcastGlobalSettings? = nil, showSummaries: [PodcastShowSettingsSummary]? = nil
  ) {
    globalHub = KeyedObservationHub(fallback: global)
    summariesHub = KeyedObservationHub(fallback: showSummaries)
  }

  /// How many `currentShowSettings` reads have been made.
  public var currentReadCount: Int {
    calls.filter { call in
      if case .currentShowSettings = call { return true }
      return false
    }.count
  }

  /// The item id of every `observeShowSettings` call, in order.
  public var observedShowSettingsItemIDs: [String] {
    calls.compactMap { call -> String? in
      if case .observeShowSettings(let itemID) = call { return itemID }
      return nil
    }
  }

  /// What the synchronous `currentShowSettings(itemID:)` answers for `itemID`; `nil` removes it.
  public func stubCurrentShowSettings(_ detail: PodcastShowSettingsDetail?, itemID: String) {
    currentDetails.withValue { $0[itemID] = detail }
  }

  public func pushGlobal(_ value: PodcastGlobalSettings, generation: Int? = nil) {
    globalHub.push(value, for: Self.onlyKey, generation: generation)
  }

  public func pushShowRows(_ value: [PodcastShowSettingsSummary], generation: Int? = nil) {
    summariesHub.push(value, for: Self.onlyKey, generation: generation)
  }

  /// Simulates the observation of `itemID` firing again (every show when omitted); `nil` is an
  /// absent show.
  public func pushShowSettings(
    _ detail: PodcastShowSettingsDetail?, itemID: String? = nil, generation: Int? = nil
  ) {
    detailHub.push(detail, for: itemID, generation: generation)
  }

  public func currentShowSettings(itemID: String) -> PodcastShowSettingsDetail? {
    recorder.record(.currentShowSettings(itemID: itemID))
    return currentDetails.withValue { $0[itemID] }
  }

  public func observeGlobalSettings() -> AsyncStream<PodcastGlobalSettings> {
    recorder.record(.observeGlobalSettings)
    return globalHub.stream(for: Self.onlyKey)
  }

  public func observeShowSummaries() -> AsyncStream<[PodcastShowSettingsSummary]> {
    recorder.record(.observeShowSummaries)
    return summariesHub.stream(for: Self.onlyKey)
  }

  public func observeShowSettings(itemID: String) -> AsyncStream<PodcastShowSettingsDetail?> {
    recorder.record(.observeShowSettings(itemID: itemID))
    return detailHub.stream(for: itemID)
  }
}
