import ABSApi
import SyncEngine

/// `NativeEpisodeServerSavePodcastWriting`'s fake. Every call is recorded and then succeeds: a
/// create answers `"created-show"`, an enqueue and a remove return. A test stubs a result per
/// operation (`stubCreate`, `stubEnqueue`, `stubRemove`) or a sequence of enqueue results
/// (`stubEnqueueSequence`), and holds a call in flight with that operation's gate. `stubBeforeCall`
/// runs first on every call, for a trace or a mutation made while the request is "in flight".
public final class FakeNativeEpisodeServerSavePodcastWriting:
  NativeEpisodeServerSavePodcastWriting, @unchecked Sendable
{
  public enum Call: Sendable, Equatable {
    case create(account: TokenAccount, request: PodcastCreateRequest)
    case enqueue(account: TokenAccount, itemID: String, episode: PodcastEpisodeDownloadRequest)
    case remove(account: TokenAccount, itemID: String, episodeID: String)
  }

  private struct State {
    var create: Result<String, any Error> = .success("created-show")
    var enqueue: Result<Void, any Error> = .success(())
    var enqueueSequence: [Result<Void, any Error>] = []
    var remove: Result<Void, any Error> = .success(())
    var beforeCall: (@Sendable (Call) async -> Void)?
  }

  private let state = Locked(State())

  /// Every call, in order.
  public let recorder = CallRecorder<Call>(label: "FakeNativeEpisodeServerSavePodcastWriting")
  public var calls: [Call] { recorder.calls }
  public var createCount: Int { count(where: { if case .create = $0 { true } else { false } }) }
  public var enqueueCount: Int { count(where: { if case .enqueue = $0 { true } else { false } }) }
  public var removeCount: Int { count(where: { if case .remove = $0 { true } else { false } }) }

  /// Hold one to park that operation after it is recorded. All open by default.
  public let createGate = TestGate<Void>(label: "FakePodcastWriting.create")
  public let enqueueGate = TestGate<Void>(label: "FakePodcastWriting.enqueue")
  public let removeGate = TestGate<Void>(label: "FakePodcastWriting.remove")

  public init() {}

  /// What every `createPodcast` returns or throws (default: `.success("created-show")`).
  public func stubCreate(_ result: Result<String, any Error>) {
    state.withValue { $0.create = result }
  }

  /// What every `enqueuePodcastEpisode` returns or throws once any sequence is used up.
  public func stubEnqueue(_ result: Result<Void, any Error>) {
    state.withValue { $0.enqueue = result }
  }

  /// Answers the next enqueues with `results` in order, then falls back to `stubEnqueue`'s result.
  public func stubEnqueueSequence(_ results: [Result<Void, any Error>]) {
    state.withValue { $0.enqueueSequence = results }
  }

  /// What every `removePodcastEpisode` returns or throws.
  public func stubRemove(_ result: Result<Void, any Error>) {
    state.withValue { $0.remove = result }
  }

  /// Runs before each call is recorded; `nil` removes it.
  public func stubBeforeCall(_ hook: (@Sendable (Call) async -> Void)?) {
    state.withValue { $0.beforeCall = hook }
  }

  public func createPodcast(
    account: TokenAccount,
    request: PodcastCreateRequest,
    diagnostics: DecodeDiagnostics?
  ) async throws -> String {
    await begin(.create(account: account, request: request), gate: createGate)
    return try state.value.create.get()
  }

  public func enqueuePodcastEpisode(
    account: TokenAccount,
    itemID: String,
    episode: PodcastEpisodeDownloadRequest
  ) async throws {
    await begin(.enqueue(account: account, itemID: itemID, episode: episode), gate: enqueueGate)
    let result = state.withValue { state -> Result<Void, any Error> in
      state.enqueueSequence.isEmpty ? state.enqueue : state.enqueueSequence.removeFirst()
    }
    try result.get()
  }

  public func removePodcastEpisode(
    account: TokenAccount,
    itemID: String,
    episodeID: String
  ) async throws {
    await begin(.remove(account: account, itemID: itemID, episodeID: episodeID), gate: removeGate)
    try state.value.remove.get()
  }

  private func count(where isMatch: (Call) -> Bool) -> Int {
    recorder.calls.filter(isMatch).count
  }

  private func begin(_ call: Call, gate: TestGate<Void>) async {
    if let hook = state.value.beforeCall { await hook(call) }
    recorder.record(call)
    await gate.pass()
  }
}
