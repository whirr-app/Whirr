import Foundation
import Observation

/// State behind Settings › About › Report a Problem. Mirrors `PodcastSubscriptionOPMLModel`'s
/// export half: the file is written into a directory the model owns, offered through
/// `exportURL`, and unlinked when superseded or when the model goes away. The directory itself is
/// the `exportedDiagnosticsRootURL` that account removal deletes (SECURITY.md rule 8).
///
/// Each source degrades independently: an unavailable log or diagnostics store becomes a note in
/// the file, not a failed export, as the sections that loaded are what a report needs. Only a
/// write failure sets `exportError`.
@MainActor
@Observable
public final class ProblemReportModel {
  public private(set) var environment: ProblemReportEnvironment?
  public private(set) var exportURL: URL?
  public private(set) var exportError = false
  public private(set) var isPreparing = false
  /// The exact text of the file at `exportURL`, for the What's Included disclosure.
  public private(set) var preview: String?

  /// `nil` until `loadEnvironment()` has run; the view keeps the row disabled until then.
  public var issueURL: URL? {
    environment.map(ProblemReportComposer.issueURL(environment:))
  }

  private let sources: ProblemReportSources
  private let exportDirectory: URL
  private let now: @Sendable () -> Date
  @ObservationIgnored private var exportGeneration: UInt64 = 0
  @ObservationIgnored private var managedExportURLs: Set<URL> = []

  public init(
    sources: ProblemReportSources,
    exportDirectory: URL,
    now: @escaping @Sendable () -> Date = Date.init
  ) {
    self.sources = sources
    self.exportDirectory = exportDirectory
    self.now = now
  }

  public func loadEnvironment() async {
    environment = await sources.environment.readEnvironment()
  }

  public func prepareExport() async {
    exportGeneration &+= 1
    let generation = exportGeneration
    isPreparing = true
    exportError = false
    defer { if generation == exportGeneration { isPreparing = false } }

    let environment = await sources.environment.readEnvironment()
    self.environment = environment
    let events = try? await sources.events.exportEvents()
    let diagnostics = try? await sources.storedDiagnostics.recentDiagnostics(
      limit: ProblemReportComposer.storedDiagnosticsLimit)
    let sessionLog = try? await sources.sessionLog.recentEntries(
      limit: ProblemReportComposer.sessionLogLineLimit)
    let redaction = await sources.redaction.readRedaction()
    // A cancelled task (the screen was left, or the shell was torn down for logout) must not
    // write. Account removal deletes this directory and verifies it is gone; a late write here
    // would put an old account's bundle back after that verification.
    guard generation == exportGeneration, Task.isCancelled == false else { return }

    let generatedAt = now()
    let text = ProblemReportComposer.bundle(
      environment: environment,
      events: events ?? nil,
      diagnostics: diagnostics,
      sessionLog: sessionLog,
      redaction: redaction,
      generatedAt: generatedAt)

    let url = exportDirectory.appendingPathComponent(
      ProblemReportComposer.exportFilename(generatedAt: generatedAt), isDirectory: false)
    do {
      try Self.prepareDirectory(exportDirectory)
      try Task.checkCancellation()
      try Data(text.utf8).write(to: url, options: .atomic)
      managedExportURLs.insert(url)
      let previousURL = exportURL
      exportURL = url
      preview = text
      if let previousURL, previousURL != url { removeManagedExport(at: previousURL) }
    } catch {
      removeManagedExport(at: url)
      if let exportURL { removeManagedExport(at: exportURL) }
      exportURL = nil
      preview = nil
      exportError = true
    }
  }

  /// Drops the current file, for a screen that is being left. The next `prepareExport()` writes a
  /// fresh one; a stale bundle must never be what gets shared.
  public func discardExport() {
    exportGeneration &+= 1
    if let exportURL { removeManagedExport(at: exportURL) }
    exportURL = nil
    preview = nil
    exportError = false
    isPreparing = false
  }

  deinit {
    for url in managedExportURLs {
      try? FileManager.default.removeItem(at: url)
    }
  }

  /// Creates the directory and keeps it out of backups: a diagnostics file is only useful on the
  /// device that produced it. Best-effort on the resource value, which not every volume supports.
  private static func prepareDirectory(_ directory: URL) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    var mutable = directory
    try? mutable.setResourceValues(values)
  }

  private func removeManagedExport(at url: URL) {
    do {
      try FileManager.default.removeItem(at: url)
      managedExportURLs.remove(url)
    } catch CocoaError.fileNoSuchFile {
      managedExportURLs.remove(url)
    } catch {
      // Keep ownership so deinit can retry a transient unlink failure.
    }
  }
}
