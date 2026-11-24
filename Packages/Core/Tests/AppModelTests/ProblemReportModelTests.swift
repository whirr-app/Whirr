import Foundation
import TestSupport
import Testing

@testable import AppModel

@MainActor
@Suite("Problem report model")
struct ProblemReportModelTests {
  struct Environment: ProblemReportEnvironmentReading {
    func readEnvironment() async -> ProblemReportEnvironment {
      ProblemReportEnvironment(
        appVersion: "1.0", buildNumber: "3", systemName: "iOS", systemVersion: "26.0",
        deviceModel: "iPad16,3", localeIdentifier: "en_GB", isLowPowerModeEnabled: false,
        freeDiskBytes: nil, serverVersion: "2.35.1")
    }
  }

  struct Events: DiagnosticsEventsExporting {
    var text: String?
    var fails = false
    var stalls = false
    var stallReached: Locked<Bool>?
    func exportEvents() async throws -> String? {
      if stalls {
        stallReached?.value = true
        try await Task.sleep(for: .seconds(30))
      }
      if fails { throw CocoaError(.fileReadUnknown) }
      return text
    }
  }

  struct Log: SessionLogReading {
    var lines: [String] = []
    var fails = false
    func recentEntries(limit: Int) async throws -> [String] {
      if fails { throw CocoaError(.fileReadUnknown) }
      return Array(lines.suffix(limit))
    }
  }

  struct Stored: StoredDiagnosticsReading {
    var diagnostics: [StoredDiagnostic] = []
    func recentDiagnostics(limit: Int) async throws -> [StoredDiagnostic] {
      Array(diagnostics.prefix(limit))
    }
  }

  struct Redaction: ProblemReportRedactionReading {
    var redaction: ProblemReportRedaction = .none
    func readRedaction() async -> ProblemReportRedaction { redaction }
  }

  static func sources(
    events: Events = Events(text: "event line"), log: Log = Log(lines: ["log line"]),
    stored: Stored = Stored(), redaction: Redaction = Redaction()
  ) -> ProblemReportSources {
    ProblemReportSources(
      environment: Environment(), events: events, sessionLog: log, storedDiagnostics: stored,
      redaction: redaction)
  }

  final class TickClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date
    init(_ date: Date) { self.date = date }
    func now() -> Date { lock.withLock { date } }
    func advance(by seconds: TimeInterval) { lock.withLock { date = date.addingTimeInterval(seconds) } }
  }

  static func scratchDirectory() -> URL {
    FileManager.default.temporaryDirectory.appending(path: "ProblemReportModelTests-\(UUID().uuidString)")
  }

  @Test("loading the environment makes the issue URL available")
  func issueURLAfterLoad() async {
    let model = ProblemReportModel(sources: Self.sources(), exportDirectory: Self.scratchDirectory())
    #expect(model.issueURL == nil)
    await model.loadEnvironment()
    #expect(model.issueURL?.absoluteString.contains("server-version=2.35.1") == true)
  }

  @Test("preparing writes the bundle to the export directory and exposes its text as the preview")
  func prepareWritesTheBundle() async throws {
    let directory = Self.scratchDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let generatedAt = Date(timeIntervalSince1970: 1_788_000_000)
    let model = ProblemReportModel(
      sources: Self.sources(
        redaction: Redaction(
          redaction: ProblemReportRedaction(serverBaseURL: "https://abs.home.arpa", serverUserId: nil))),
      exportDirectory: directory, now: { generatedAt })

    await model.prepareExport()

    let url = try #require(model.exportURL)
    #expect(url.lastPathComponent == "Whirr-diagnostics-20260829-104000.txt")
    #expect(url.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL)
    let written = try String(contentsOf: url, encoding: .utf8)
    #expect(written == model.preview)
    #expect(written.contains("event line"))
    #expect(written.contains("log line"))
    #expect(written.contains("Device: iPad16,3"))
    #expect(model.exportError == false)
    #expect(model.isPreparing == false)
    let values = try directory.resourceValues(forKeys: [.isExcludedFromBackupKey])
    #expect(values.isExcludedFromBackup == true)
  }

  @Test("a cancelled prepare writes nothing, so a torn-down screen cannot resurrect the directory")
  func cancelledPrepareWritesNothing() async throws {
    let directory = Self.scratchDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let stallReached = Locked(false)
    let model = ProblemReportModel(
      sources: Self.sources(events: Events(stalls: true, stallReached: stallReached)),
      exportDirectory: directory)

    let task = Task { await model.prepareExport() }
    await waitUntil("the prepare reaches its stalled source") { stallReached.value }
    task.cancel()
    await task.value

    #expect(model.exportURL == nil)
    #expect(model.preview == nil)
    #expect(model.exportError == false)
    #expect(FileManager.default.fileExists(atPath: directory.path) == false)
  }

  @Test("a failing source becomes a note in the file rather than a failed export")
  func degradedSources() async throws {
    let directory = Self.scratchDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let model = ProblemReportModel(
      sources: Self.sources(events: Events(fails: true), log: Log(fails: true)),
      exportDirectory: directory)

    await model.prepareExport()

    let text = try #require(model.preview)
    #expect(model.exportError == false)
    #expect(text.components(separatedBy: "(unavailable)").count == 3)
    #expect(text.contains("== Environment =="))
  }

  @Test("a write failure reports exportError and leaves no export URL")
  func writeFailure() async throws {
    let blocker = Self.scratchDirectory()
    try Data("not a directory".utf8).write(to: blocker)
    defer { try? FileManager.default.removeItem(at: blocker) }
    let model = ProblemReportModel(
      sources: Self.sources(), exportDirectory: blocker.appending(path: "Exports"))

    await model.prepareExport()

    #expect(model.exportError)
    #expect(model.exportURL == nil)
    #expect(model.preview == nil)
  }

  @Test("preparing again replaces the earlier file, and discarding removes the current one")
  func replaceAndDiscard() async throws {
    let directory = Self.scratchDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let clock = TickClock(Date(timeIntervalSince1970: 1_788_000_000))
    let model = ProblemReportModel(sources: Self.sources(), exportDirectory: directory, now: { clock.now() })

    await model.prepareExport()
    let first = try #require(model.exportURL)
    clock.advance(by: 60)
    await model.prepareExport()
    let second = try #require(model.exportURL)

    #expect(first != second)
    #expect(FileManager.default.fileExists(atPath: first.path) == false)
    #expect(FileManager.default.fileExists(atPath: second.path))

    model.discardExport()
    #expect(model.exportURL == nil)
    #expect(model.preview == nil)
    #expect(FileManager.default.fileExists(atPath: second.path) == false)
  }
}
