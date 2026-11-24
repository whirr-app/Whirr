import Foundation
import Persistence

/// Live `AsyncStream`s grouped by key, which replay the latest value to a new subscriber. The
/// podcast fakes share it; it is internal to TestSupport.
///
/// A push with a key reaches every live subscription of that key and becomes the value a later
/// subscriber starts with. A push without one reaches every live subscription and becomes the
/// value a later subscriber of any key starts with. A push at a `generation` (the nth subscription
/// of the key, in creation order) reaches that subscription alone, terminated or not, and is not
/// replayed: it reproduces a superseded subscription delivering late.
final class KeyedObservationHub<Key: Hashable & Sendable, Value: Sendable>: @unchecked Sendable {
  private struct Subscription {
    let key: Key
    let continuation: AsyncStream<Value>.Continuation
    var isTerminated = false
  }

  private struct State {
    var latest: [Key: Value] = [:]
    var fallback: Value?
    var subscriptions: [Subscription] = []
  }

  private let state: Locked<State>

  /// - Parameter fallback: what a subscriber of a key with no pushed value starts with. `nil`
  ///   starts it silent.
  init(fallback: Value? = nil) {
    state = Locked(State(fallback: fallback))
  }

  var subscriptionCount: Int { state.withValue { $0.subscriptions.count } }

  /// The key of every subscription whose consumer has gone away.
  var terminatedKeys: [Key] {
    state.withValue { $0.subscriptions.filter(\.isTerminated).map(\.key) }
  }

  func stream(for key: Key) -> AsyncStream<Value> {
    AsyncStream { continuation in
      let index = state.withValue { state -> Int in
        state.subscriptions.append(Subscription(key: key, continuation: continuation))
        if let replay = state.latest[key] {
          continuation.yield(replay)
        } else if let replay = state.fallback {
          continuation.yield(replay)
        }
        return state.subscriptions.count - 1
      }
      continuation.onTermination = { [weak self] _ in
        self?.state.withValue { $0.subscriptions[index].isTerminated = true }
      }
    }
  }

  func push(_ value: Value, for key: Key? = nil, generation: Int? = nil) {
    state.withValue { state in
      if generation == nil {
        if let key {
          state.latest[key] = value
        } else {
          state.latest.removeAll()
          state.fallback = value
        }
      }
      let targets = state.subscriptions.filter { key == nil || $0.key == key }
      if let generation {
        guard targets.indices.contains(generation) else { return }
        targets[generation].continuation.yield(value)
      } else {
        for target in targets where target.isTerminated == false {
          target.continuation.yield(value)
        }
      }
    }
  }
}

/// `PodcastReading`'s fake. Every observation is live and keyed by show: `pushEpisodes`,
/// `pushDiagnostics`, `pushDownloadProgress` and `pushServerCopies` reach the subscriptions of that
/// show (every show when `itemID` is omitted), and the latest pushed value is replayed to a later
/// subscriber, as a database observation yields its current value on subscription. Nothing is
/// emitted until a test pushes, or seeds `episodes` at init. No stream ever finishes.
///
/// `episode(itemID:episodeID:)` can be held with `episodeReadGate`; the synchronous
/// `episodePrefix` answers only what `stubEpisodePrefix` set, like a reader with no baseline.
public final class FakePodcastReading: PodcastReading, @unchecked Sendable {
  public enum Call: Sendable, Equatable {
    case observeEpisodes(itemID: String)
    case episodePrefix(itemID: String, limit: Int)
    case observeShowDiagnostics(itemID: String)
    case episode(itemID: String, episodeID: String)
    case observeEpisodeDownloadProgress(itemID: String)
    case recentEpisodeDescriptions(itemID: String, limit: Int)
    case observeServerCopyItemIDs(fingerprint: String)
  }

  /// One observation, for `terminatedObservations`.
  public enum Observation: Sendable, Hashable {
    case episodes(itemID: String)
    case diagnostics(itemID: String)
    case downloadProgress(itemID: String)
    case serverCopies(fingerprint: String)
  }

  /// Every call in order.
  public let recorder = CallRecorder<Call>(label: "FakePodcastReading")
  public var calls: [Call] { recorder.calls }

  /// Holds `episode(itemID:episodeID:)` after `hold()`; `parkedCount` says whether a read waits.
  public let episodeReadGate = TestGate<Void>(label: "FakePodcastReading.episode")

  private struct EpisodeKey: Hashable {
    let itemID: String?
    let episodeID: String
  }

  private struct Stubs {
    var prefixes: [String: PodcastEpisodePrefix] = [:]
    var defaultPrefix: PodcastEpisodePrefix?
    var contexts: [EpisodeKey: PodcastEpisodeContext] = [:]
    var descriptions: [String] = []
    var descriptionsError: (any Error)?
  }

  private let stubs = Locked(Stubs())
  private let episodeHub: KeyedObservationHub<String, [PodcastEpisodeSummary]>
  private let diagnosticsHub = KeyedObservationHub<String, PodcastShowDiagnostics?>()
  private let progressHub = KeyedObservationHub<String, [String: Double]>()
  private let copiesHub = KeyedObservationHub<String, [String]>()

  /// - Parameter episodes: the list every show starts with. `nil` leaves `observeEpisodes` silent
  ///   until a test pushes.
  public init(episodes: [PodcastEpisodeSummary]? = nil) {
    episodeHub = KeyedObservationHub(fallback: episodes)
  }

  /// Every observation whose consumer has gone away.
  public var terminatedObservations: Set<Observation> {
    Set(episodeHub.terminatedKeys.map(Observation.episodes(itemID:)))
      .union(diagnosticsHub.terminatedKeys.map(Observation.diagnostics(itemID:)))
      .union(progressHub.terminatedKeys.map(Observation.downloadProgress(itemID:)))
      .union(copiesHub.terminatedKeys.map(Observation.serverCopies(fingerprint:)))
  }

  /// What `episodePrefix` answers for `itemID`, or for every show without its own when `itemID` is
  /// omitted. `nil` removes the answer.
  public func stubEpisodePrefix(_ prefix: PodcastEpisodePrefix?, itemID: String? = nil) {
    stubs.withValue { stubs in
      if let itemID {
        stubs.prefixes[itemID] = prefix
      } else {
        stubs.defaultPrefix = prefix
      }
    }
  }

  /// What `episode(itemID:episodeID:)` answers for the context's episode in `itemID`, or in any
  /// show without its own answer when `itemID` is omitted.
  public func stubEpisode(_ context: PodcastEpisodeContext, itemID: String? = nil) {
    let key = EpisodeKey(itemID: itemID, episodeID: context.episode.id)
    stubs.withValue { $0.contexts[key] = context }
  }

  /// What `recentEpisodeDescriptions` answers (cut to `limit`), or the error it throws.
  public func stubRecentDescriptions(_ descriptions: [String], error: (any Error)? = nil) {
    stubs.withValue {
      $0.descriptions = descriptions
      $0.descriptionsError = error
    }
  }

  public func pushEpisodes(_ episodes: [PodcastEpisodeSummary], itemID: String? = nil) {
    episodeHub.push(episodes, for: itemID)
  }

  public func pushDiagnostics(_ diagnostics: PodcastShowDiagnostics?, itemID: String? = nil) {
    diagnosticsHub.push(diagnostics, for: itemID)
  }

  public func pushDownloadProgress(_ progress: [String: Double], itemID: String? = nil) {
    progressHub.push(progress, for: itemID)
  }

  public func pushServerCopies(_ itemIDs: [String], fingerprint: String) {
    copiesHub.push(itemIDs, for: fingerprint)
  }

  public func observeEpisodes(itemId: String) -> AsyncStream<[PodcastEpisodeSummary]> {
    recorder.record(.observeEpisodes(itemID: itemId))
    return episodeHub.stream(for: itemId)
  }

  public func episodePrefix(itemId: String, limit: Int) -> PodcastEpisodePrefix? {
    recorder.record(.episodePrefix(itemID: itemId, limit: limit))
    return stubs.withValue { $0.prefixes[itemId] ?? $0.defaultPrefix }
  }

  public func observeShowDiagnostics(itemId: String) -> AsyncStream<PodcastShowDiagnostics?> {
    recorder.record(.observeShowDiagnostics(itemID: itemId))
    return diagnosticsHub.stream(for: itemId)
  }

  public func episode(itemID: String, episodeID: String) async throws -> PodcastEpisodeContext? {
    recorder.record(.episode(itemID: itemID, episodeID: episodeID))
    await episodeReadGate.pass()
    return stubs.withValue {
      $0.contexts[EpisodeKey(itemID: itemID, episodeID: episodeID)]
        ?? $0.contexts[EpisodeKey(itemID: nil, episodeID: episodeID)]
    }
  }

  public func observeEpisodeDownloadProgress(itemId: String) -> AsyncStream<[String: Double]> {
    recorder.record(.observeEpisodeDownloadProgress(itemID: itemId))
    return progressHub.stream(for: itemId)
  }

  public func recentEpisodeDescriptions(itemId: String, limit: Int) async throws -> [String] {
    recorder.record(.recentEpisodeDescriptions(itemID: itemId, limit: limit))
    let (descriptions, error) = stubs.withValue { ($0.descriptions, $0.descriptionsError) }
    if let error { throw error }
    return Array(descriptions.prefix(limit))
  }

  public func observeServerCopyItemIDs(podcastFeedFingerprint: String) -> AsyncStream<[String]> {
    recorder.record(.observeServerCopyItemIDs(fingerprint: podcastFeedFingerprint))
    return copiesHub.stream(for: podcastFeedFingerprint)
  }
}
