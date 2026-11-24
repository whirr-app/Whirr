import SyncEngine

/// `NativeEpisodeServerSaving`'s fake. Saves and removes answer from queued outcomes, in order; an
/// empty queue answers a failed outcome with category `.unknown`, as the real coordinator does for
/// an error it cannot name. Hold `saveGate` to park a save until the test releases it.
public final class FakeNativeEpisodeServerSaving: NativeEpisodeServerSaving, @unchecked Sendable {
  public enum Call: Sendable, Equatable {
    case save(feedID: Int64, episodeID: Int64, choice: ServerPodcastSaveChoice?)
    case remove(attemptID: Int64)
  }

  private struct State {
    var saveOutcomes: [NativeEpisodeServerSaveOutcome]
    var removeOutcomes: [NativeEpisodeServerSaveOutcome]
  }

  private let state: Locked<State>

  /// Every `save` and `remove`, in order. A save is recorded before it parks on `saveGate`.
  public let recorder = CallRecorder<Call>(label: "FakeNativeEpisodeServerSaving")
  public var calls: [Call] { recorder.calls }

  /// Hold it (`hold()`) to park every `save` after it is recorded. Open by default.
  public let saveGate = TestGate<Void>(label: "FakeNativeEpisodeServerSaving.save")

  public init(
    saveOutcomes: [NativeEpisodeServerSaveOutcome] = [],
    removeOutcomes: [NativeEpisodeServerSaveOutcome] = []
  ) {
    state = Locked(State(saveOutcomes: saveOutcomes, removeOutcomes: removeOutcomes))
  }

  /// Queues `outcomes` behind any not yet used.
  public func enqueueSaveOutcomes(_ outcomes: [NativeEpisodeServerSaveOutcome]) {
    state.withValue { $0.saveOutcomes.append(contentsOf: outcomes) }
  }

  /// Queues `outcomes` behind any not yet used.
  public func enqueueRemoveOutcomes(_ outcomes: [NativeEpisodeServerSaveOutcome]) {
    state.withValue { $0.removeOutcomes.append(contentsOf: outcomes) }
  }

  public func save(
    feedId: Int64,
    episodeId: Int64,
    choice: ServerPodcastSaveChoice?
  ) async -> NativeEpisodeServerSaveOutcome {
    recorder.record(.save(feedID: feedId, episodeID: episodeId, choice: choice))
    await saveGate.pass()
    return state.withValue { state -> NativeEpisodeServerSaveOutcome in
      state.saveOutcomes.isEmpty
        ? .failed(attemptID: nil, state: .failed, category: .unknown)
        : state.saveOutcomes.removeFirst()
    }
  }

  public func remove(attemptID: Int64) async -> NativeEpisodeServerSaveOutcome {
    recorder.record(.remove(attemptID: attemptID))
    return state.withValue { state -> NativeEpisodeServerSaveOutcome in
      state.removeOutcomes.isEmpty
        ? .failed(attemptID: attemptID, state: .deleteFailed, category: .unknown)
        : state.removeOutcomes.removeFirst()
    }
  }
}
