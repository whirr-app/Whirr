import ABSApi
import CoreSupport
import Foundation
import Persistence

extension PodcastRefreshCoordinator {
  static let detailEndpointTemplate = EndpointTemplate("/api/items/:id")
  static let progressEndpointTemplate = EndpointTemplate("/api/me")

  static func recordDiagnostic(
    _ diagnostics: any DiagnosticsRecording,
    accountID: Int64,
    category: DiagnosticsCategory,
    statusClass: DiagnosticsStatusClass,
    startedAt: Date,
    now: @Sendable () -> Date,
    endpointTemplate: EndpointTemplate? = nil
  ) async {
    await diagnostics.record(
      DiagnosticsEvent(
        category: category,
        statusClass: statusClass,
        durationMilliseconds: SyncEngine.durationMilliseconds(
          startedAt: startedAt, endedAt: now()),
        endpointTemplate: endpointTemplate ?? detailEndpointTemplate),
      accountId: accountID)
  }

  /// DEBUG-only failure trace, mirroring `WHIRRENG`/`WHIRRPERF`: capture with
  /// `log stream --predicate 'eventMessage CONTAINS "WHIRRPOD"'`. A refresh failure reaches the
  /// user as one generic sentence and nothing surfaces `DiagnosticsRecording` yet, so on a device
  /// this alone names the refusing stage. Item ids are non-sensitive; the message is built from
  /// closed status metadata, never an error's free-form description (see SECURITY.md).
  static func logFailure(itemID: String, stage: String, error: any Error) {
    #if DEBUG
      DeviceTraceLog.emit(failureMessage(itemID: itemID, stage: stage, error: error))
    #endif
  }

  /// Builds the bounded DEBUG failure trace. `NSError` domain/code are stable error metadata;
  /// API errors contribute only their case name, never an associated status or payload.
  static func failureMessage(itemID: String, stage: String, error: any Error) -> String {
    let nsError = error as NSError
    let apiCase = (error as? APIError).map(apiErrorCaseName) ?? "none"
    return "WHIRRPOD failure stage=\(stage) item=\(itemID) "
      + "statusClass=\(statusClass(for: error).rawValue) "
      + "domain=\(nsError.domain) code=\(nsError.code) apiError=\(apiCase)"
  }

  static func apiErrorCaseName(_ error: APIError) -> String {
    switch error {
    case .transport: return "transport"
    case .badRequest: return "badRequest"
    case .unauthorized: return "unauthorized"
    case .forbidden: return "forbidden"
    case .notFound: return "notFound"
    case .payloadTooLarge: return "payloadTooLarge"
    case .rateLimited: return "rateLimited"
    case .serverFailure: return "serverFailure"
    case .unexpectedStatus: return "unexpectedStatus"
    case .decoding: return "decoding"
    case .ambiguousLocalSessionResponse: return "ambiguousLocalSessionResponse"
    case .incompatibleServer: return "incompatibleServer"
    case .invalidServerConfiguration: return "invalidServerConfiguration"
    case .cancelled: return "cancelled"
    }
  }

  static func statusClass(for error: any Error) -> DiagnosticsStatusClass {
    if error is CancellationError { return .cancelled }
    guard let apiError = error as? APIError else { return .clientError }
    switch apiError {
    case .cancelled:
      return .cancelled
    case .transport:
      return .transportError
    case .serverFailure, .rateLimited:
      return .serverError
    default:
      return .clientError
    }
  }
}
