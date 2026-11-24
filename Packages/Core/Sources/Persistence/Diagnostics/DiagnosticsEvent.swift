import GRDB

/// The structured event kinds `DiagnosticsRecording` accepts. A closed enum, not a free-text
/// string, so no payload or token content can be smuggled through this field.
public enum DiagnosticsCategory: String, Sendable, Equatable, Codable, CaseIterable,
  DatabaseValueConvertible
{
  case syncRun
  case outboxTransition
  case decodeDiagnostic
  case clockSkew
  /// A live session's server-side loss (`/sync`/`/close` 404, classified ahead of the generic
  /// permanent-error path) discarded its unacknowledged listening delta. Recorded once per loss,
  /// as category/timing/endpoint-class only (no ids, position, delta or URL; see SECURITY.md).
  case sessionLostDelta
  /// An ebook-position PATCH attempt. Holds only the operation class, outcome, timing and endpoint
  /// template, never the locator, fraction, item id, or token.
  case ebookProgress
  /// The shared item-wide ebook finish PATCH attempt. Separate from position attempts so
  /// diagnostics can tell the two durable outbox legs apart without carrying their payloads.
  case ebookFinish
  /// A download-lifecycle event worth recording locally, such as a planning rejection (metadata
  /// validation) or an auth challenge escalating to durable `pausedAuth`. Category/timing only,
  /// never the item/file identity (see SECURITY.md).
  case download
  /// Unused: nothing writes it. The case stays because its raw value is persisted, so a store that
  /// recorded a warm-up session must still decode.
  case artworkWarmup
  /// Credential-free auth-recovery outcomes. Separate closed cases rather than a payload-bearing
  /// auth event, so tokens, usernames, and raw responses cannot reach the diagnostics store.
  case refreshTransport
  case refreshRateLimited
  case refreshServerFailure
  case refreshDecoding
  case reauthenticationRequired
  case reauthenticationSucceeded
}

/// A coarse outcome bucket, never the raw status code or error message. Closed for the same
/// reason as `DiagnosticsCategory`.
public enum DiagnosticsStatusClass: String, Sendable, Equatable, Codable, CaseIterable,
  DatabaseValueConvertible
{
  case success
  case clientError
  case serverError
  case transportError
  case cancelled
}

/// One diagnostics event as a caller reports it, before `DiagnosticsStore` stamps an account and
/// timestamp on it. Every field is already privacy-safe by construction: `category` and
/// `statusClass` are closed enums, `durationMilliseconds` is numeric, and `endpointTemplate` (the
/// only free-text field) can only hold a validated `EndpointTemplate`.
public struct DiagnosticsEvent: Sendable, Equatable {
  public let category: DiagnosticsCategory
  public let statusClass: DiagnosticsStatusClass
  public let durationMilliseconds: Double
  public let endpointTemplate: EndpointTemplate?

  public init(
    category: DiagnosticsCategory,
    statusClass: DiagnosticsStatusClass,
    durationMilliseconds: Double,
    endpointTemplate: EndpointTemplate? = nil
  ) {
    self.category = category
    self.statusClass = statusClass
    self.durationMilliseconds = durationMilliseconds
    self.endpointTemplate = endpointTemplate
  }
}
