import Foundation
import Testing

@testable import AppModel

/// Settings › About › Report a Problem: the GitHub prefill URL, the diagnostics bundle, and the
/// redaction that keeps `ProblemReportCopy.footer` honest.
@Suite("Problem report composer")
struct ProblemReportComposerTests {
  static let signedIn = ProblemReportEnvironment(
    appVersion: "1.0", buildNumber: "3", systemName: "iOS", systemVersion: "26.0",
    deviceModel: "iPhone18,1", localeIdentifier: "en_GB", isLowPowerModeEnabled: true,
    freeDiskBytes: 40_400_000_000, serverVersion: "2.35.1")

  static var signedOut: ProblemReportEnvironment {
    var environment = signedIn
    environment.serverVersion = nil
    return environment
  }

  static let repositoryRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()  // AppModelTests
    .deletingLastPathComponent()  // Tests
    .deletingLastPathComponent()  // Core
    .deletingLastPathComponent()  // Packages
    .deletingLastPathComponent()  // repository root

  /// The issue forms are public-only files: this repository keeps them under
  /// `Scripts/public-export/`, and the export copies them to `.github/` at the public repository's
  /// root, where this suite also runs. Neither copy existing fails the reads below; it never skips.
  static let issueTemplateDirectory: URL = {
    let exportSource = repositoryRoot.appending(path: "Scripts/public-export/.github/ISSUE_TEMPLATE")
    let publicLocation = repositoryRoot.appending(path: ".github/ISSUE_TEMPLATE")
    let exists = FileManager.default.fileExists(atPath: exportSource.path(percentEncoded: false))
    return exists ? exportSource : publicLocation
  }()

  // MARK: - Issue URL

  @Test("the issue URL targets the public repository's bug form with the three fields prefilled")
  func issueURLPrefillsTheForm() throws {
    let url = ProblemReportComposer.issueURL(environment: Self.signedIn)
    let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))

    #expect(components.scheme == "https")
    #expect(components.host == "github.com")
    #expect(components.path == "/whirr-app/Whirr/issues/new")
    let query = Dictionary(
      uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
    #expect(
      query == [
        "template": "bug_report.yml",
        "labels": "bug",
        "app-version": "1.0 (3)",
        "ios-version": "iOS 26.0, iPhone18,1",
        "server-version": "2.35.1",
      ])
  }

  @Test("signed out, the server-version field is left for the person to fill")
  func issueURLOmitsServerVersionWhenSignedOut() throws {
    let url = ProblemReportComposer.issueURL(environment: Self.signedOut)
    let names = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
      .map(\.name)

    #expect(names.contains("server-version") == false)
    #expect(names.contains("app-version"))
  }

  @Test("every prefilled key is a field id in the exported bug-report form")
  func issueFieldsMatchTheExportedForm() throws {
    let template = Self.issueTemplateDirectory.appending(path: ProblemReportComposer.issueTemplate)
    let yaml = try String(contentsOf: template, encoding: .utf8)
    let ids = Set(
      yaml.split(separator: "\n").compactMap { line -> String? in
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("id:") else { return nil }
        return trimmed.dropFirst("id:".count).trimmingCharacters(in: .whitespaces)
      })

    for field in ProblemReportComposer.IssueField.allCases {
      #expect(ids.contains(field.rawValue), "\(field.rawValue) is not a field in \(template.lastPathComponent)")
    }
  }

  @Test("blank issues stay disabled so reports arrive through the form the app prefills")
  func blankIssuesAreDisabled() throws {
    let config = try String(
      contentsOf: Self.issueTemplateDirectory.appending(path: "config.yml"), encoding: .utf8)
    #expect(config.contains("blank_issues_enabled: false"))
  }

  // MARK: - Environment

  @Test("version and system descriptions match the About footer and the form placeholder")
  func descriptions() {
    #expect(Self.signedIn.versionDescription == "1.0 (3)")
    #expect(Self.signedIn.systemDescription == "iOS 26.0, iPhone18,1")

    var partial = Self.signedIn
    partial.buildNumber = nil
    #expect(partial.versionDescription == "1.0")
    partial.appVersion = nil
    #expect(partial.versionDescription == "Development")
  }

  @Test("the environment section rounds free space to whole gigabytes and names a signed-out state")
  func environmentSection() {
    let section = ProblemReportComposer.environmentSection(Self.signedIn)
    #expect(section.contains("Whirr version: 1.0 (3)"))
    #expect(section.contains("Device: iPhone18,1"))
    #expect(section.contains("Low Power Mode: on"))
    #expect(section.contains("Free space: about 40 GB"))
    #expect(section.contains("Server version: 2.35.1"))

    #expect(ProblemReportComposer.environmentSection(Self.signedOut).contains("Server version: not signed in"))
  }

  @Test("the export file name is date-stamped and ends in .txt")
  func exportFilename() {
    let date = Date(timeIntervalSince1970: 1_788_000_000)  // 2026-08-29 10:40:00 UTC
    #expect(ProblemReportComposer.exportFilename(generatedAt: date) == "Whirr-diagnostics-20260829-104000.txt")
  }

  // MARK: - Bundle

  @Test("the bundle carries its four sections in order and names an unavailable source")
  func bundleSectionsAndUnavailability() {
    let text = ProblemReportComposer.bundle(
      environment: Self.signedIn,
      events: "2026-09-06T10:00:00Z\tsyncRun\tsuccess\t120ms\t/api/libraries/:id/items",
      diagnostics: nil,
      sessionLog: ["10:00:01 [download] planned"],
      redaction: .none,
      generatedAt: Date(timeIntervalSince1970: 1_788_000_000))

    let markers = [
      "Whirr diagnostics", "Generated: 2026-08-29T10:40:00Z", "== Environment ==",
      "== Recent events (oldest first) ==", "syncRun",
      "== Crash and hang diagnostics (5 most recent) ==", "(unavailable)",
      "== Current session log (last 500 lines) ==", "[download] planned",
    ]
    var cursor = text.startIndex
    for marker in markers {
      let range = text.range(of: marker, range: cursor..<text.endIndex)
      #expect(range != nil, "\(marker) missing or out of order")
      if let range { cursor = range.upperBound }
    }
    #expect(text.hasSuffix("\n"))
  }

  @Test("empty sources say so rather than leaving a blank section")
  func bundleNamesEmptySources() {
    let text = ProblemReportComposer.bundle(
      environment: Self.signedOut, events: "", diagnostics: [], sessionLog: [],
      redaction: .none, generatedAt: Date())
    #expect(text.components(separatedBy: "(none recorded)").count == 3)
    #expect(text.contains("(no entries)"))
    #expect(text.contains("(unavailable)") == false)
  }

  @Test("diagnostics are newest first and capped at five; the log keeps its last 500 lines")
  func bundleCaps() {
    let diagnostics = (0..<8).map { index in
      StoredDiagnostic(
        id: "d\(index)", kind: index.isMultiple(of: 2) ? .crash : .hang,
        recordedAt: Date(timeIntervalSince1970: Double(index) * 3600), text: "payload-\(index)")
    }
    let log = (0..<620).map { "line-\($0)" }
    let text = ProblemReportComposer.bundle(
      environment: Self.signedIn, events: nil, diagnostics: diagnostics, sessionLog: log,
      redaction: .none, generatedAt: Date())

    #expect(text.contains("payload-7"))
    #expect(text.contains("payload-3"))
    #expect(text.contains("payload-2") == false)
    let seven = text.range(of: "payload-7")!.lowerBound
    let three = text.range(of: "payload-3")!.lowerBound
    #expect(seven < three)
    #expect(text.contains("--- hang "))
    #expect(text.contains("--- crash "))

    #expect(text.contains("line-619\n"))
    #expect(text.contains("line-120\n"))
    #expect(text.contains("line-119\n") == false)
  }

  // MARK: - Redaction

  @Test("account terms are derived from the stored base URL and user id, case-insensitively")
  func redactionTerms() {
    let redaction = ProblemReportRedaction(
      serverBaseURL: "https://Books.Example.ts.net:13378/", serverUserId: "usr_9f3a")

    #expect(redaction.contains("GET https://books.example.ts.net:13378/api/me"))
    #expect(redaction.contains("host books.example.ts.net unreachable"))
    #expect(redaction.contains("user USR_9F3A"))
    #expect(redaction.contains("syncRun success 120ms /api/libraries/:id/items") == false)
  }

  @Test("every saved endpoint's URL, host, and host:port are terms, not only the active address")
  func redactionCoversEveryEndpoint() {
    let redaction = ProblemReportRedaction(
      serverBaseURL: "http://192.168.1.20:13378", serverUserId: "usr_9f3a",
      endpointURLs: ["http://192.168.1.20:13378", "https://nas.tail1234.ts.net", "http://nas.local:13378"])

    #expect(redaction.contains("probe https://nas.tail1234.ts.net/status"))
    #expect(redaction.contains("host nas.tail1234.ts.net answered"))
    #expect(redaction.contains("host nas.local:13378 unreachable"))
    #expect(redaction.contains("active 192.168.1.20:13378"))
    #expect(redaction.contains("syncRun success 120ms /api/libraries/:id/items") == false)
  }

  @Test("terms under three characters are ignored so a short id cannot blank the file")
  func redactionIgnoresShortTerms() {
    let redaction = ProblemReportRedaction(serverBaseURL: nil, serverUserId: "ab")
    #expect(redaction.terms.isEmpty)
    #expect(redaction.redact("abc\nxyz") == "abc\nxyz")
    #expect(ProblemReportRedaction.none.redact("anything") == "anything")
  }

  @Test("a bundle fed the account's host, URL, and user id in every source contains none of them")
  func bundleIsRedacted() {
    let host = "books.example.ts.net"
    let baseURL = "https://\(host):13378"
    let userId = "usr_9f3a"
    let redaction = ProblemReportRedaction(serverBaseURL: baseURL, serverUserId: userId)

    var environment = Self.signedIn
    environment.localeIdentifier = "en_GB"
    let text = ProblemReportComposer.bundle(
      environment: environment,
      events: "2026-09-06T10:00:00Z\tsyncRun\tsuccess\t120ms\t\(baseURL)/api/me\nclean event line",
      diagnostics: [
        StoredDiagnostic(
          id: "1", kind: .crash, recordedAt: Date(), text: "{\"host\":\"\(host)\"}\n{\"frame\":\"main\"}")
      ],
      sessionLog: ["[account] \(userId) refreshed", "[download] planned"],
      redaction: redaction,
      generatedAt: Date())

    #expect(text.range(of: host, options: .caseInsensitive) == nil)
    #expect(text.range(of: userId, options: .caseInsensitive) == nil)
    #expect(text.contains(ProblemReportRedaction.removedLineMarker))
    #expect(text.contains("clean event line"))
    #expect(text.contains("{\"frame\":\"main\"}"))
    #expect(text.contains("[download] planned"))
  }
}
