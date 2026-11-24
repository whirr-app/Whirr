import AppModel
import Persistence

/// `PodcastEpisodeIntents`' fake. Every intent is recorded as a `Call` and succeeds;
/// `saveForLater` answers the stubbed outcome (default `.saved`). `stubBeforeCall` runs before the
/// call is recorded and may suspend (a gate) or throw (a failing intent), so a throwing call is
/// not recorded, as a refused intent would not be.
public final class FakePodcastEpisodeIntents: PodcastEpisodeIntents, @unchecked Sendable {
  public enum Call: Sendable, Equatable {
    case play(String, String)
    case playNext(String, String)
    case addToUpNext(String, String)
    case saveForLater(String, String)
    case removeFromSaved(String, String)
    case download(String, String)
    case pauseDownload(String, String)
    case resumeDownload(String, String)
    case removeDownload(String, String)
    case markAsFinished(String, String, Double?)
    case resetProgress(String, String)
    case removeFromContinueListening(String, String)
    case markAll(String, [EpisodeProgressChange], Bool)
  }

  public typealias BeforeCall = @Sendable (Call) async throws -> Void

  private struct State {
    var saveOutcome: SavedShelfSaveOutcome
    var beforeCall: BeforeCall?
  }

  private let state: Locked<State>

  /// Every recorded intent, in order.
  public let recorder = CallRecorder<Call>(label: "FakePodcastEpisodeIntents")
  public var calls: [Call] { recorder.calls }

  public init(saveOutcome: SavedShelfSaveOutcome = .saved) {
    state = Locked(State(saveOutcome: saveOutcome))
  }

  /// What `saveForLater` returns from the next call on.
  public func stubSaveOutcome(_ outcome: SavedShelfSaveOutcome) {
    state.withValue { $0.saveOutcome = outcome }
  }

  /// Runs before each call is recorded; `nil` removes it.
  public func stubBeforeCall(_ hook: BeforeCall?) {
    state.withValue { $0.beforeCall = hook }
  }

  /// Forgets the recorded calls.
  public func reset() { recorder.removeAll() }

  public func play(itemID: String, episodeID: String) async throws {
    try await perform(.play(itemID, episodeID))
  }

  public func playNext(itemID: String, episodeID: String) async throws {
    try await perform(.playNext(itemID, episodeID))
  }

  public func addToUpNext(itemID: String, episodeID: String) async throws {
    try await perform(.addToUpNext(itemID, episodeID))
  }

  @discardableResult
  public func saveForLater(
    itemID: String, episodeID: String
  ) async throws -> SavedShelfSaveOutcome {
    try await perform(.saveForLater(itemID, episodeID))
    return state.value.saveOutcome
  }

  public func removeFromSaved(itemID: String, episodeID: String) async throws {
    try await perform(.removeFromSaved(itemID, episodeID))
  }

  public func download(itemID: String, episodeID: String) async throws {
    try await perform(.download(itemID, episodeID))
  }

  public func pauseDownload(itemID: String, episodeID: String) async throws {
    try await perform(.pauseDownload(itemID, episodeID))
  }

  public func resumeDownload(itemID: String, episodeID: String) async throws {
    try await perform(.resumeDownload(itemID, episodeID))
  }

  public func removeDownload(itemID: String, episodeID: String) async throws {
    try await perform(.removeDownload(itemID, episodeID))
  }

  public func markAsFinished(itemID: String, episodeID: String, duration: Double?) async throws {
    try await perform(.markAsFinished(itemID, episodeID, duration))
  }

  public func resetProgress(itemID: String, episodeID: String) async throws {
    try await perform(.resetProgress(itemID, episodeID))
  }

  public func removeFromContinueListening(itemID: String, episodeID: String) async throws {
    try await perform(.removeFromContinueListening(itemID, episodeID))
  }

  public func markAll(
    itemID: String, episodes: [EpisodeProgressChange], isFinished: Bool
  ) async throws {
    try await perform(.markAll(itemID, episodes, isFinished))
  }

  private func perform(_ call: Call) async throws {
    if let hook = state.value.beforeCall { try await hook(call) }
    recorder.record(call)
  }
}
