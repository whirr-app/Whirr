import Foundation
import SyncEngine

/// The fake behind both halves of the new-episode notification preference:
/// `RSSNotificationIntentReading` and `RSSNotificationIntentWriting`. It holds one live value, so a
/// write changes what the next read returns, and it records every read and write in order.
///
/// Two gates park a call mid-flight: `readGate` suspends a read before it answers, and
/// `writeGate` suspends a write before it takes effect, so a test can queue another operation
/// behind the held one.
public final class FakeRSSNotificationIntentReading: RSSNotificationIntentReading,
  RSSNotificationIntentWriting, @unchecked Sendable
{
  /// One protocol call.
  public enum Call: Sendable, Equatable {
    case read
    case write(Bool)
  }

  /// Every read and write, in order, recorded before the call is gated.
  public let recorder = CallRecorder<Call>(label: "FakeRSSNotificationIntentReading calls")

  /// Hold it (`hold()`) to park each read until the test releases it. The read then answers the
  /// value current at that moment. Open by default.
  public let readGate = TestGate<Void>(
    label: "FakeRSSNotificationIntentReading.isNewEpisodeNotificationEnabled")

  /// Hold it (`hold()`) to park each write until the test releases it. The write takes effect
  /// only on release. Open by default.
  public let writeGate = TestGate<Void>(
    label: "FakeRSSNotificationIntentReading.setNewEpisodeNotificationEnabled")

  private let value: Locked<Bool>

  /// - Parameter enabled: the preference's starting value.
  public init(enabled: Bool = false) {
    value = Locked(enabled)
  }

  /// The preference's current value.
  public var enabled: Bool { value.value }

  /// The values written so far, in order, including writes still parked on `writeGate`.
  public var writes: [Bool] {
    recorder.calls.compactMap { call -> Bool? in
      if case .write(let enabled) = call { return enabled }
      return nil
    }
  }

  /// Sets the preference without recording a write.
  public func stubEnabled(_ enabled: Bool) {
    value.value = enabled
  }

  public func isNewEpisodeNotificationEnabled() async -> Bool {
    recorder.record(.read)
    await readGate.pass()
    return value.value
  }

  public func setNewEpisodeNotificationEnabled(_ enabled: Bool) async {
    recorder.record(.write(enabled))
    await writeGate.pass()
    value.value = enabled
  }
}
