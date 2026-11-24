import SyncEngine

/// `ServerPodcastMutationCapabilityReading`'s fake: answers one stubbed capability (default
/// `.none`, as a failed profile read does) and records every read and invalidation. Hold `gate` to
/// park a read until the test releases it; the capability it returns is the one stubbed when the
/// read resumes.
public final class FakeServerPodcastMutationCapabilityReading:
  ServerPodcastMutationCapabilityReading, @unchecked Sendable
{
  public enum Call: Sendable, Equatable {
    case capability
    case invalidate
  }

  private let value: Locked<ServerPodcastMutationCapability>

  /// Every `capability()` and `invalidate()`, in order. A read is recorded before it parks.
  public let recorder = CallRecorder<Call>(label: "FakeServerPodcastMutationCapabilityReading")
  public var calls: [Call] { recorder.calls }
  public var readCount: Int { recorder.calls.filter { $0 == .capability }.count }
  public var invalidationCount: Int { recorder.calls.filter { $0 == .invalidate }.count }

  /// Hold it (`hold()`) to park every `capability()` read. Open by default.
  public let gate = TestGate<Void>(label: "FakeServerPodcastMutationCapabilityReading.capability")

  public init(_ capability: ServerPodcastMutationCapability = .none) {
    value = Locked(capability)
  }

  public convenience init(canSave: Bool, canRemove: Bool) {
    self.init(ServerPodcastMutationCapability(canSave: canSave, canRemove: canRemove))
  }

  /// What `capability()` returns from now on, including for a read already parked.
  public func stubCapability(_ capability: ServerPodcastMutationCapability) {
    value.value = capability
  }

  public func capability() async -> ServerPodcastMutationCapability {
    recorder.record(.capability)
    await gate.pass()
    return value.value
  }

  public func invalidate() async {
    recorder.record(.invalidate)
  }
}
