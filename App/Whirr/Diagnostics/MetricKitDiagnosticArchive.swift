import AppModel
import CoreSupport
import Foundation
import MetricKit
import os

/// Splits `MXDiagnosticPayload.jsonRepresentation()` into its crash and hang diagnostics. Like
/// `MemoryMetricPayloadParser`, the JSON is the only representation a test can construct, so the
/// parse lives here and the MetricKit adapter below stays a single line.
nonisolated enum MetricKitDiagnosticPayloadParser {
  struct Diagnostic: Equatable {
    let kind: StoredDiagnostic.Kind
    let json: Data
  }

  static func diagnostics(fromPayloadJSON data: Data) -> [Diagnostic] {
    guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
    let keyed: [(StoredDiagnostic.Kind, String)] = [(.crash, "crashDiagnostics"), (.hang, "hangDiagnostics")]
    return keyed.flatMap { kind, key -> [Diagnostic] in
      guard let entries = root[key] as? [[String: Any]] else { return [] }
      return entries.compactMap { entry in
        guard
          let json = try? JSONSerialization.data(
            withJSONObject: entry, options: [.prettyPrinted, .sortedKeys])
        else { return nil }
        return Diagnostic(kind: kind, json: json)
      }
    }
  }
}

/// Keeps the last few crash and hang diagnostics on disk so a shared problem report can carry
/// them. Nothing here transmits: MetricKit hands the payload to the app on the launch after the
/// event, and this writes it under `DiagnosticsLocations.metricKit`, oldest evicted beyond
/// `retainedFiles`. Stacks are unsymbolicated; the release archive's dSYMs symbolicate them.
nonisolated struct MetricKitDiagnosticArchive: StoredDiagnosticsReading, Sendable {
  static let retainedFiles = ProblemReportComposer.storedDiagnosticsLimit
  private static let fileExtension = "json"

  let directory: URL

  /// Writes each diagnostic in the payload as its own file, then evicts the oldest beyond the cap.
  func store(payloadJSON: Data, receivedAt: Date = Date()) throws {
    let diagnostics = MetricKitDiagnosticPayloadParser.diagnostics(fromPayloadJSON: payloadJSON)
    guard diagnostics.isEmpty == false else { return }
    try DiagnosticsLocations.prepare(directory)
    let stamp = Self.stampFormatter.string(from: receivedAt)
    // Two payloads in one second would otherwise share names; keep counting past what exists.
    var index = try storedFiles().filter { $0.lastPathComponent.hasPrefix(stamp) }.count
    for diagnostic in diagnostics {
      let name = "\(stamp)-\(diagnostic.kind.rawValue)-\(index).\(Self.fileExtension)"
      try diagnostic.json.write(to: directory.appendingPathComponent(name), options: .atomic)
      index += 1
    }
    try evictBeyondCap()
  }

  func recentDiagnostics(limit: Int) async throws -> [StoredDiagnostic] {
    try storedFiles().prefix(limit).compactMap { url in
      guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
      let parsed = Self.parse(filename: url.deletingPathExtension().lastPathComponent)
      return StoredDiagnostic(
        id: url.lastPathComponent, kind: parsed.kind, recordedAt: parsed.recordedAt, text: text)
    }
  }

  /// Newest payload first, and within one payload in the order MetricKit listed its diagnostics.
  /// Both facts are in the file name, so nothing has to be read to order them.
  private func storedFiles() throws -> [URL] {
    guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
    // Separately typed steps on purpose: written as one chain with a ternary sort, this expression
    // costs the type checker seconds rather than milliseconds.
    let files: [URL] = try FileManager.default.contentsOfDirectory(
      at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
    )
    let keyed: [(url: URL, key: (stamp: String, index: Int))] =
      files
      .filter { $0.pathExtension == Self.fileExtension }
      .map { url in (url: url, key: Self.sortKey(filename: url.deletingPathExtension().lastPathComponent)) }
    let ordered = keyed.sorted { lhs, rhs in
      if lhs.key.stamp != rhs.key.stamp { return lhs.key.stamp > rhs.key.stamp }
      return lhs.key.index < rhs.key.index
    }
    return ordered.map(\.url)
  }

  private static func sortKey(filename: String) -> (stamp: String, index: Int) {
    let parts = filename.split(separator: "-")
    let stamp = parts.prefix(2).joined(separator: "-")
    let index = parts.dropFirst(3).first.flatMap { Int($0) } ?? 0
    return (stamp, index)
  }

  private func evictBeyondCap() throws {
    for url in try storedFiles().dropFirst(Self.retainedFiles) {
      try FileManager.default.removeItem(at: url)
    }
  }

  private static func parse(filename: String) -> (kind: StoredDiagnostic.Kind, recordedAt: Date) {
    let parts = filename.split(separator: "-")
    let kind = parts.dropFirst(2).first.flatMap { StoredDiagnostic.Kind(rawValue: String($0)) } ?? .crash
    let recordedAt = parts.count >= 2 ? stampFormatter.date(from: parts[0...1].joined(separator: "-")) : nil
    return (kind, recordedAt ?? .distantPast)
  }

  private static var stampFormatter: DateFormatter {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyyMMdd-HHmmss"
    return formatter
  }
}

/// Process-lifetime home for the diagnostic subscriber, mirroring `MemoryMetricsHardware`. Unlike
/// memory metrics this is not opt-in (owner decision): a crash diagnostic is local-only, holds no
/// user content, and is worthless if nobody switched it on before the crash.
@MainActor
enum MetricKitDiagnosticsHardware {
  private static var subscriber: MetricKitDiagnosticSubscriber?

  static func start(
    archive: MetricKitDiagnosticArchive = MetricKitDiagnosticArchive(
      directory: DiagnosticsLocations.defaultMetricKit())
  ) {
    guard subscriber == nil else { return }
    let subscriber = MetricKitDiagnosticSubscriber(archive: archive)
    self.subscriber = subscriber
    subscriber.start()
  }
}

/// Receives MetricKit's diagnostic payloads and stores them. `nonisolated` for the reason
/// `MetricKitMemorySubscriber` gives: MetricKit calls back on its own queue.
nonisolated final class MetricKitDiagnosticSubscriber: NSObject, MXMetricManagerSubscriber {
  private static let log = CoreLogging.logger(category: "diagnostics")
  private let archive: MetricKitDiagnosticArchive

  init(archive: MetricKitDiagnosticArchive) {
    self.archive = archive
  }

  func start() {
    MXMetricManager.shared.add(self)
  }

  func stop() {
    MXMetricManager.shared.remove(self)
  }

  /// The one-line adapter over the tested seam; `MXDiagnosticPayload` has no public initializer.
  func didReceive(_ payloads: [MXDiagnosticPayload]) {
    receive(payloadJSON: payloads.map { $0.jsonRepresentation() })
  }

  func receive(payloadJSON payloads: [Data]) {
    for payload in payloads {
      do {
        try archive.store(payloadJSON: payload)
      } catch {
        Self.log.error("diagnostic payload not stored: \(String(describing: error), privacy: .public)")
      }
    }
  }
}
