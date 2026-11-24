import Foundation

// MARK: - Inputs

/// Non-secret facts about the install that a bug report needs. No device name, no
/// identifiers, and no server address: `deviceModel` is the hardware identifier (`iPhone18,1`),
/// which names a product line and nothing about its owner.
public struct ProblemReportEnvironment: Sendable, Equatable {
  public var appVersion: String?
  public var buildNumber: String?
  public var systemName: String
  public var systemVersion: String
  public var deviceModel: String
  public var localeIdentifier: String
  public var isLowPowerModeEnabled: Bool
  public var freeDiskBytes: Int64?
  /// The signed-in server's reported version; `nil` when signed out. A version string only.
  public var serverVersion: String?

  public init(
    appVersion: String?,
    buildNumber: String?,
    systemName: String,
    systemVersion: String,
    deviceModel: String,
    localeIdentifier: String,
    isLowPowerModeEnabled: Bool,
    freeDiskBytes: Int64?,
    serverVersion: String?
  ) {
    self.appVersion = appVersion
    self.buildNumber = buildNumber
    self.systemName = systemName
    self.systemVersion = systemVersion
    self.deviceModel = deviceModel
    self.localeIdentifier = localeIdentifier
    self.isLowPowerModeEnabled = isLowPowerModeEnabled
    self.freeDiskBytes = freeDiskBytes
    self.serverVersion = serverVersion
  }

  /// Matches the About footer: `1.0 (3)`, a bare version when the build is unknown, and
  /// `Development` when neither is set (an unpackaged test host).
  public var versionDescription: String {
    switch (appVersion, buildNumber) {
    case (.some(let version), .some(let build)): return "\(version) (\(build))"
    case (.some(let version), .none): return version
    default: return "Development"
    }
  }

  /// The issue form's "iOS version and device" field, e.g. `iOS 26.0, iPhone18,1`.
  public var systemDescription: String {
    "\(systemName) \(systemVersion), \(deviceModel)"
  }
}

/// One MetricKit crash or hang diagnostic that the app stored locally on a previous launch.
public struct StoredDiagnostic: Sendable, Equatable, Identifiable {
  public enum Kind: String, Sendable, Equatable {
    case crash
    case hang
  }

  public let id: String
  public let kind: Kind
  public let recordedAt: Date
  public let text: String

  public init(id: String, kind: Kind, recordedAt: Date, text: String) {
    self.id = id
    self.kind = kind
    self.recordedAt = recordedAt
    self.text = text
  }
}

// MARK: - Redaction

/// Defence in depth behind `ProblemReportCopy.footer`. Every input to the bundle is already meant
/// to be privacy-safe by construction (closed diagnostics enums, the redacting HTTP logger), so
/// this should never find anything; when it does, it drops the whole line rather than trusting a
/// partial rewrite. Terms are matched case-insensitively and anything under three characters is
/// ignored so a short user id cannot blank the entire file.
public struct ProblemReportRedaction: Sendable, Equatable {
  public static let removedLineMarker = "[line removed: contained account details]"
  static let minimumTermLength = 3

  public let terms: [String]

  public init(terms: [String]) {
    var seen: Set<String> = []
    self.terms = terms.compactMap { raw in
      let term = raw.trimmingCharacters(in: .whitespacesAndNewlines)
      guard term.count >= Self.minimumTermLength else { return nil }
      let key = term.lowercased()
      guard seen.insert(key).inserted else { return nil }
      return term
    }
  }

  /// Derives every spelling of the account that could appear in free text: the base URL as
  /// stored, its host, and the user id. Nothing here is a secret, but all of it identifies the
  /// person, and the footer promises none of it is in the file.
  public init(serverBaseURL: String?, serverUserId: String?, endpointURLs: [String] = []) {
    var terms: [String] = []
    for endpointURL in endpointURLs {
      Self.appendURLTerms(endpointURL, to: &terms)
    }
    if let serverBaseURL, serverBaseURL.isEmpty == false {
      Self.appendURLTerms(serverBaseURL, to: &terms)
    }
    if let serverUserId { terms.append(serverUserId) }
    self.init(terms: terms)
  }

  /// Compatibility overload for callers that already have derived terms. New callers should pass
  /// endpoint URLs so host and host:port variants are derived in one place.
  public init(serverBaseURL: String?, serverUserId: String?, additionalTerms: [String]) {
    var terms = additionalTerms
    if let serverBaseURL, serverBaseURL.isEmpty == false {
      Self.appendURLTerms(serverBaseURL, to: &terms)
    }
    if let serverUserId { terms.append(serverUserId) }
    self.init(terms: terms)
  }

  private static func appendURLTerms(_ urlString: String, to terms: inout [String]) {
    guard urlString.isEmpty == false else { return }
    terms.append(urlString)
    terms.append(urlString.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
    if let components = URLComponents(string: urlString), let host = components.host {
      terms.append(host)
      if let port = components.port { terms.append("\(host):\(port)") }
    }
  }

  public static let none = ProblemReportRedaction(terms: [])

  public func contains(_ line: String) -> Bool {
    terms.contains { line.range(of: $0, options: [.caseInsensitive]) != nil }
  }

  public func redact(_ text: String) -> String {
    guard terms.isEmpty == false else { return text }
    return
      text
      .split(separator: "\n", omittingEmptySubsequences: false)
      .map { line in contains(String(line)) ? Self.removedLineMarker : String(line) }
      .joined(separator: "\n")
  }
}

// MARK: - Composer

/// Pure text and URL assembly for the Report a Problem screen. Nothing here reads a device or
/// touches the file system; `ProblemReportModel` gathers the inputs and writes the result.
public enum ProblemReportComposer {
  /// The public repository's new-issue endpoint. The repository is a squashed mirror of each
  /// App Store release; this URL is the only outbound
  /// first-party link in the app and carries version strings only.
  public static let issueBaseURL = URL(string: "https://github.com/whirr-app/Whirr/issues/new")!
  /// Must match the file name under `Scripts/public-export/.github/ISSUE_TEMPLATE/`.
  public static let issueTemplate = "bug_report.yml"
  public static let issueLabels = "bug"

  /// The issue form fields the app prefills. Raw values are the form's field `id`s, which
  /// `ProblemReportComposerTests` checks against the YAML so a renamed field fails a test rather
  /// than silently arriving blank.
  public enum IssueField: String, CaseIterable, Sendable {
    case appVersion = "app-version"
    case systemVersion = "ios-version"
    case serverVersion = "server-version"
  }

  public static let storedDiagnosticsLimit = 5
  public static let sessionLogLineLimit = 500
  public static let exportFilenamePrefix = "Whirr-diagnostics"

  public static func issueURL(environment: ProblemReportEnvironment) -> URL {
    var components = URLComponents(url: issueBaseURL, resolvingAgainstBaseURL: false)!
    var items = [
      URLQueryItem(name: "template", value: issueTemplate),
      URLQueryItem(name: "labels", value: issueLabels),
      URLQueryItem(name: IssueField.appVersion.rawValue, value: environment.versionDescription),
      URLQueryItem(name: IssueField.systemVersion.rawValue, value: environment.systemDescription),
    ]
    if let serverVersion = environment.serverVersion, serverVersion.isEmpty == false {
      items.append(URLQueryItem(name: IssueField.serverVersion.rawValue, value: serverVersion))
    }
    components.queryItems = items
    return components.url ?? issueBaseURL
  }

  public static func exportFilename(generatedAt: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyyMMdd-HHmmss"
    return "\(exportFilenamePrefix)-\(formatter.string(from: generatedAt)).txt"
  }

  /// One section of the bundle. `nil` content means the source was unavailable, which the file
  /// says explicitly so an empty section is never mistaken for "nothing happened".
  public struct Section: Sendable, Equatable {
    public let title: String
    public let content: String?

    public init(title: String, content: String?) {
      self.title = title
      self.content = content
    }
  }

  public static func environmentSection(_ environment: ProblemReportEnvironment) -> String {
    var lines = [
      "Whirr version: \(environment.versionDescription)",
      "System: \(environment.systemName) \(environment.systemVersion)",
      "Device: \(environment.deviceModel)",
      "Locale: \(environment.localeIdentifier)",
      "Low Power Mode: \(environment.isLowPowerModeEnabled ? "on" : "off")",
    ]
    if let freeDiskBytes = environment.freeDiskBytes {
      let gigabytes = Int((Double(freeDiskBytes) / 1_000_000_000).rounded())
      lines.append("Free space: about \(gigabytes) GB")
    }
    lines.append("Server version: \(environment.serverVersion ?? "not signed in")")
    return lines.joined(separator: "\n")
  }

  public static func diagnosticsSection(_ diagnostics: [StoredDiagnostic]) -> String? {
    guard diagnostics.isEmpty == false else { return "(none recorded)" }
    let formatter = ISO8601DateFormatter()
    return
      diagnostics
      .sorted { $0.recordedAt > $1.recordedAt }
      .prefix(storedDiagnosticsLimit)
      .map { diagnostic in
        "--- \(diagnostic.kind.rawValue) \(formatter.string(from: diagnostic.recordedAt)) ---\n"
          + diagnostic.text
      }
      .joined(separator: "\n\n")
  }

  public static func sessionLogSection(_ lines: [String]) -> String? {
    guard lines.isEmpty == false else { return "(no entries)" }
    return lines.suffix(sessionLogLineLimit).joined(separator: "\n")
  }

  /// Assembles and redacts the whole file. Sections arrive already reduced to text so the model
  /// can degrade one unavailable source to a note instead of failing the export.
  public static func bundle(
    environment: ProblemReportEnvironment,
    events: String?,
    diagnostics: [StoredDiagnostic]?,
    sessionLog: [String]?,
    redaction: ProblemReportRedaction,
    generatedAt: Date
  ) -> String {
    let sections = [
      Section(title: "Environment", content: environmentSection(environment)),
      Section(
        title: "Recent events (oldest first)",
        content: events.map { $0.isEmpty ? "(none recorded)" : $0 }),
      Section(
        title: "Crash and hang diagnostics (\(storedDiagnosticsLimit) most recent)",
        content: diagnostics.flatMap(diagnosticsSection)),
      Section(
        title: "Current session log (last \(sessionLogLineLimit) lines)",
        content: sessionLog.flatMap(sessionLogSection)),
    ]
    let header = "Whirr diagnostics\nGenerated: \(ISO8601DateFormatter().string(from: generatedAt))"
    let body = sections.map { section in
      "== \(section.title) ==\n" + (section.content ?? "(unavailable)")
    }
    return redaction.redact(([header] + body).joined(separator: "\n\n")) + "\n"
  }
}

// MARK: - Sources the App satisfies

public protocol ProblemReportEnvironmentReading: Sendable {
  func readEnvironment() async -> ProblemReportEnvironment
}

/// `DiagnosticsStore.export(accountId:)` bound to the signed-in account. `nil` when signed out.
public protocol DiagnosticsEventsExporting: Sendable {
  func exportEvents() async throws -> String?
}

/// The current process's unified-log entries for `CoreLogging.subsystem`, oldest first.
public protocol SessionLogReading: Sendable {
  func recentEntries(limit: Int) async throws -> [String]
}

public protocol StoredDiagnosticsReading: Sendable {
  func recentDiagnostics(limit: Int) async throws -> [StoredDiagnostic]
}

public protocol ProblemReportRedactionReading: Sendable {
  func readRedaction() async -> ProblemReportRedaction
}

/// Everything the Report a Problem screen reads, in one value so `SettingsView` gains one
/// parameter rather than five.
public struct ProblemReportSources: Sendable {
  public let environment: any ProblemReportEnvironmentReading
  public let events: any DiagnosticsEventsExporting
  public let sessionLog: any SessionLogReading
  public let storedDiagnostics: any StoredDiagnosticsReading
  public let redaction: any ProblemReportRedactionReading

  public init(
    environment: any ProblemReportEnvironmentReading,
    events: any DiagnosticsEventsExporting,
    sessionLog: any SessionLogReading,
    storedDiagnostics: any StoredDiagnosticsReading,
    redaction: any ProblemReportRedactionReading
  ) {
    self.environment = environment
    self.events = events
    self.sessionLog = sessionLog
    self.storedDiagnostics = storedDiagnostics
    self.redaction = redaction
  }

  /// Setup-only, harness, and test compositions: a development environment and empty sources.
  public static let noOp = ProblemReportSources(
    environment: NoOpProblemReportEnvironmentReading(),
    events: NoOpDiagnosticsEventsExporting(),
    sessionLog: NoOpSessionLogReading(),
    storedDiagnostics: NoOpStoredDiagnosticsReading(),
    redaction: NoOpProblemReportRedactionReading())
}

public struct NoOpProblemReportEnvironmentReading: ProblemReportEnvironmentReading {
  public init() {}
  public func readEnvironment() async -> ProblemReportEnvironment {
    ProblemReportEnvironment(
      appVersion: nil, buildNumber: nil, systemName: "iOS", systemVersion: "0",
      deviceModel: "unknown", localeIdentifier: "en", isLowPowerModeEnabled: false,
      freeDiskBytes: nil, serverVersion: nil)
  }
}

public struct NoOpDiagnosticsEventsExporting: DiagnosticsEventsExporting {
  public init() {}
  public func exportEvents() async throws -> String? { nil }
}

public struct NoOpSessionLogReading: SessionLogReading {
  public init() {}
  public func recentEntries(limit: Int) async throws -> [String] { [] }
}

public struct NoOpStoredDiagnosticsReading: StoredDiagnosticsReading {
  public init() {}
  public func recentDiagnostics(limit: Int) async throws -> [StoredDiagnostic] { [] }
}

public struct NoOpProblemReportRedactionReading: ProblemReportRedactionReading {
  public init() {}
  public func readRedaction() async -> ProblemReportRedaction { .none }
}
