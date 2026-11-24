import AppModel
import Foundation
import Persistence

/// Binds the Report a Problem sources to the account row. Each adapter re-reads the row when
/// asked, so a report made after login or logout describes the account as it is then.
nonisolated enum ProblemReportComposition {
  static func sources(
    accountDAO: AccountDAO, accountEndpointDAO: AccountEndpointDAO? = nil,
    diagnosticsStore: DiagnosticsStore, metricKitDirectory: URL
  ) -> ProblemReportSources {
    ProblemReportSources(
      environment: DeviceEnvironmentReader(serverVersion: { (try? accountDAO.fetch())?.serverVersion }),
      events: AccountDiagnosticsEventsExporter(store: diagnosticsStore, accountDAO: accountDAO),
      sessionLog: OSLogSessionReader(),
      storedDiagnostics: MetricKitDiagnosticArchive(directory: metricKitDirectory),
      redaction: AccountRedactionReader(
        accountDAO: accountDAO, accountEndpointDAO: accountEndpointDAO))
  }
}

/// `DiagnosticsStore.export` for whichever account is signed in; `nil` when none is.
nonisolated struct AccountDiagnosticsEventsExporter: DiagnosticsEventsExporting, Sendable {
  let store: DiagnosticsStore
  let accountDAO: AccountDAO

  func exportEvents() async throws -> String? {
    guard let accountId = try accountDAO.fetch()?.id else { return nil }
    return try store.export(accountId: accountId)
  }
}

/// The account's server address and user id, so the bundle can prove it carries neither.
nonisolated struct AccountRedactionReader: ProblemReportRedactionReading, Sendable {
  let accountDAO: AccountDAO
  let accountEndpointDAO: AccountEndpointDAO?

  init(accountDAO: AccountDAO, accountEndpointDAO: AccountEndpointDAO? = nil) {
    self.accountDAO = accountDAO
    self.accountEndpointDAO = accountEndpointDAO
  }

  func readRedaction() async -> ProblemReportRedaction {
    guard let account = try? accountDAO.fetch() else { return .none }
    let endpointURLs: [String]
    if let accountID = account.id, let accountEndpointDAO {
      endpointURLs = (try? accountEndpointDAO.fetchAll(accountId: accountID))?.map(\.normalizedURL) ?? []
    } else {
      endpointURLs = []
    }
    return ProblemReportRedaction(
      serverBaseURL: account.serverBaseURL,
      serverUserId: account.serverUserId,
      endpointURLs: endpointURLs)
  }
}
