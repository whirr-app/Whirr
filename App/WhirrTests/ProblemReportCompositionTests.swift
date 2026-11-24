import AppModel
import Foundation
import Persistence
import Testing

@testable import Whirr

/// Report a Problem composition. The Settings About order is a source-level fact: it is wiring with no observable value to assert from a test
/// host. The redaction reader is exercised on an in-memory database.
@Suite("Problem report composition")
struct ProblemReportCompositionTests {
  static func source(named name: String) throws -> String {
    let url = try #require(try ViewSourceScan.appSources().first { $0.lastPathComponent == name })
    return try ViewSourceScan.executableText(of: url)
  }

  @Test("Settings › About pushes Report a Problem above Acknowledgements")
  func aboutSectionOrder() throws {
    let text = try Self.source(named: "SettingsView.swift")
    let report = try #require(text.range(of: "ProblemReportView("))
    let acknowledgements = try #require(text.range(of: "AcknowledgementsView()"))
    #expect(report.lowerBound < acknowledgements.lowerBound)
  }

  @Test("the diagnostics locations nest under one removable root")
  func locations() {
    let root = DiagnosticsLocations.root(applicationSupportDirectory: URL(fileURLWithPath: "/tmp/Whirr"))
    #expect(root.path == "/tmp/Whirr/Diagnostics")
    #expect(DiagnosticsLocations.metricKit(root: root).path == "/tmp/Whirr/Diagnostics/MetricKit")
    #expect(DiagnosticsLocations.exports(root: root).path == "/tmp/Whirr/Diagnostics/Exports")
  }

  @Test("the redaction reader returns every saved endpoint of the account, not only its base URL")
  func redactionCoversEverySavedEndpoint() async throws {
    let database = try AppDatabase.inMemory()
    let accountDAO = AccountDAO(database: database)
    let account = try accountDAO.save(
      AccountRecord(
        clientUUID: "problem-report-redaction",
        serverBaseURL: "https://home.example",
        serverUserId: "problem-report-user",
        serverVersion: "2.35.1"))
    let endpointDAO = AccountEndpointDAO(database: database)
    _ = try endpointDAO.insert(
      accountId: try #require(account.id), normalizedURL: "https://away.example:8443",
      preferred: false)

    let redaction = await AccountRedactionReader(
      accountDAO: accountDAO, accountEndpointDAO: endpointDAO
    ).readRedaction()

    #expect(redaction.terms.contains("home.example"))
    #expect(redaction.terms.contains("away.example"))
    #expect(redaction.terms.contains("away.example:8443"))
    #expect(redaction.terms.contains("problem-report-user"))
  }

  @Test("the redaction reader has nothing to redact before an account exists")
  func redactionIsEmptyWithoutAnAccount() async throws {
    let database = try AppDatabase.inMemory()

    let redaction = await AccountRedactionReader(
      accountDAO: AccountDAO(database: database),
      accountEndpointDAO: AccountEndpointDAO(database: database)
    ).readRedaction()

    #expect(redaction.terms.isEmpty)
  }
}
