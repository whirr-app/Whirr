import AppModel
import Foundation
import Testing

@testable import Whirr

/// The stored-diagnostics half of Settings › Report a Problem. `MXDiagnosticPayload` cannot be
/// constructed by a test, so, as with `MetricKitMemoryReportingTests`, everything with logic
/// runs over the payload's documented JSON representation.
@Suite("MetricKit diagnostic archive")
struct MetricKitDiagnosticArchiveTests {
  static func payload(crashes: Int, hangs: Int) -> Data {
    let crash = (0..<crashes).map { ["diagnosticMetaData": ["appVersion": "1.0"], "callStackTree": ["frame": $0]] }
    let hang = (0..<hangs).map { ["diagnosticMetaData": ["hangDuration": "\($0) sec"]] }
    return try! JSONSerialization.data(withJSONObject: ["crashDiagnostics": crash, "hangDiagnostics": hang])
  }

  static func scratch() -> URL {
    FileManager.default.temporaryDirectory.appending(path: "MetricKitDiagnosticArchiveTests-\(UUID().uuidString)")
  }

  @Test("the parser splits a payload into crash and hang diagnostics and drops unrelated payloads")
  func parserSplitsPayload() {
    let diagnostics = MetricKitDiagnosticPayloadParser.diagnostics(
      fromPayloadJSON: Self.payload(crashes: 2, hangs: 1))
    #expect(diagnostics.map(\.kind) == [.crash, .crash, .hang])
    #expect(String(decoding: diagnostics[0].json, as: UTF8.self).contains("callStackTree"))

    #expect(MetricKitDiagnosticPayloadParser.diagnostics(fromPayloadJSON: Data("{}".utf8)).isEmpty)
    #expect(MetricKitDiagnosticPayloadParser.diagnostics(fromPayloadJSON: Data("nope".utf8)).isEmpty)
  }

  @Test("storing writes one file per diagnostic, newest first on read, and marks the directory backup-excluded")
  func storeAndRead() async throws {
    let directory = Self.scratch()
    defer { try? FileManager.default.removeItem(at: directory) }
    let archive = MetricKitDiagnosticArchive(directory: directory)

    try archive.store(
      payloadJSON: Self.payload(crashes: 1, hangs: 1), receivedAt: Date(timeIntervalSince1970: 1_788_000_000))
    try archive.store(
      payloadJSON: Self.payload(crashes: 1, hangs: 0), receivedAt: Date(timeIntervalSince1970: 1_788_003_600))

    let stored = try await archive.recentDiagnostics(limit: 10)
    #expect(stored.count == 3)
    #expect(stored.first?.recordedAt == Date(timeIntervalSince1970: 1_788_003_600))
    #expect(stored.map(\.kind) == [.crash, .crash, .hang])
    #expect(stored.allSatisfy { $0.text.contains("diagnosticMetaData") })

    let values = try directory.resourceValues(forKeys: [.isExcludedFromBackupKey])
    #expect(values.isExcludedFromBackup == true)
  }

  @Test("only the five newest files are kept")
  func eviction() async throws {
    let directory = Self.scratch()
    defer { try? FileManager.default.removeItem(at: directory) }
    let archive = MetricKitDiagnosticArchive(directory: directory)

    for index in 0..<8 {
      try archive.store(
        payloadJSON: Self.payload(crashes: 1, hangs: 0),
        receivedAt: Date(timeIntervalSince1970: 1_788_000_000 + Double(index) * 60))
    }

    let stored = try await archive.recentDiagnostics(limit: 10)
    #expect(stored.count == MetricKitDiagnosticArchive.retainedFiles)
    #expect(stored.first?.recordedAt == Date(timeIntervalSince1970: 1_788_000_000 + 7 * 60))
    #expect(stored.last?.recordedAt == Date(timeIntervalSince1970: 1_788_000_000 + 3 * 60))
  }

  @Test("two payloads received in the same second both survive")
  func sameSecondPayloads() async throws {
    let directory = Self.scratch()
    defer { try? FileManager.default.removeItem(at: directory) }
    let archive = MetricKitDiagnosticArchive(directory: directory)
    let receivedAt = Date(timeIntervalSince1970: 1_788_000_000)

    try archive.store(payloadJSON: Self.payload(crashes: 1, hangs: 0), receivedAt: receivedAt)
    try archive.store(payloadJSON: Self.payload(crashes: 1, hangs: 1), receivedAt: receivedAt)

    let stored = try await archive.recentDiagnostics(limit: 10)
    #expect(stored.count == 3)
    #expect(Set(stored.map(\.id)).count == 3)
  }

  @Test("the session log reader drops debug levels and the DEBUG device-trace category")
  func sessionLogFilter() {
    #expect(OSLogSessionReader.includes(category: "trace") == false)
    #expect(OSLogSessionReader.includes(category: "diagnostics"))
    #expect(OSLogSessionReader.name(for: .debug) == nil)
    #expect(OSLogSessionReader.name(for: .info) == "info")
  }

  @Test("an empty payload stores nothing and a missing directory reads as empty")
  func emptyCases() async throws {
    let directory = Self.scratch()
    let archive = MetricKitDiagnosticArchive(directory: directory)
    try archive.store(payloadJSON: Data("{}".utf8))
    #expect(FileManager.default.fileExists(atPath: directory.path) == false)
    #expect(try await archive.recentDiagnostics(limit: 5).isEmpty)
  }

  @Test("the simulator's model identifier comes from its environment, hardware from uname")
  func modelIdentifier() {
    #expect(
      DeviceEnvironmentReader.modelIdentifier(environment: ["SIMULATOR_MODEL_IDENTIFIER": "iPhone18,1"]) == "iPhone18,1"
    )
    #expect(DeviceEnvironmentReader.modelIdentifier(environment: [:]).isEmpty == false)
  }
}
