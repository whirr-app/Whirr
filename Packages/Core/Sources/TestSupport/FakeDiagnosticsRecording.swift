import Persistence

public final class FakeDiagnosticsRecording: DiagnosticsRecording, @unchecked Sendable {
  private let events = Locked<[DiagnosticsEvent]>([])
  /// Structured events only, so tests can assert that no payload is recorded.
  public var recorded: [DiagnosticsEvent] { events.value }
  public func record(_ event: DiagnosticsEvent, accountId: Int64) async { events.value.append(event) }
  public init() {}
}
