import Foundation
import WatchPlayback
import WatchProtocol

#if os(watchOS)
  import WatchKit
#endif

#if DEBUG
  /// A DEBUG-only event log for the Watch's own RSS downloads. It exists because a background wake
  /// is the one path a device console does not show: the lines land in
  /// `Library/Application Support/WatchRSSDiagnostics.log` and survive the process.
  ///
  /// The logger is `nonisolated`: the URLSession delegate queue and WatchConnectivity's call it as
  /// well as the main actor. One serial queue appends and truncates, so a line is never interleaved.
  /// No URL, title, token, account hash or server name may be passed in a field; an episode is
  /// named by its feed, eight characters of its episode ID and its revision, and a task by its
  /// identifier, byte counts and state.
  nonisolated enum WatchRSSDiagnostics {
    /// The file is capped so a Watch that logs for days cannot fill its container: past the cap it
    /// keeps the newest half, starting at a whole line.
    private static let maxBytes = 512 * 1024
    private static let keptBytes = 256 * 1024
    private static let queue = DispatchQueue(label: "com.remoteconcern.whirr.watch-rss-diagnostics")

    static func log(_ event: String, _ fields: [String: String] = [:]) {
      // The app's state is read on the caller's thread: `WKApplication.shared()` is main-thread
      // only, and the delegate queues must not be made to hop for a log line.
      let line = render(event, fields, applicationState: applicationState())
      queue.sync { append(line) }
    }

    /// The same line with the episode's redacted identity already in it, so no call site can name
    /// an episode any other way.
    static func log(
      _ event: String, _ key: WatchRSSDownloadKey, taskIdentifier: Int? = nil,
      _ fields: [String: String] = [:]
    ) {
      var merged = key.diagnosticFields
      for (name, value) in fields { merged[name] = value }
      if let taskIdentifier { merged["taskIdentifier"] = String(taskIdentifier) }
      log(event, merged)
    }

    /// A failed transfer's description: its task, the error's domain and code, the system's
    /// cancellation reason and whether resume data came with it. The message itself may name a
    /// URL, so it is never logged.
    static func failureFields(
      _ token: WatchRSSCallbackToken, _ error: Error?
    ) -> [String: String] {
      var fields = token.key.diagnosticFields
      fields["taskIdentifier"] = String(token.taskIdentifier)
      guard let error else {
        fields["domain"] = "none"
        return fields
      }
      let nsError = error as NSError
      fields["domain"] = nsError.domain
      fields["code"] = String(nsError.code)
      if let reason = nsError.userInfo[NSURLErrorBackgroundTaskCancelledReasonKey] as? NSNumber {
        fields["cancelReason"] = reason.stringValue
      }
      fields["resumeData"] = nsError.userInfo[NSURLSessionDownloadTaskResumeData] == nil ? "no" : "yes"
      return fields
    }

    // MARK: Rendering

    private static func render(
      _ event: String, _ fields: [String: String], applicationState: String
    ) -> String {
      var parts = [
        Date().formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true)),
        "pid=\(ProcessInfo.processInfo.processIdentifier)",
        "app=\(applicationState)",
        "event=\(sanitize(event))",
      ]
      for key in fields.keys.sorted() {
        parts.append("\(sanitize(key))=\(sanitize(fields[key] ?? ""))")
      }
      return parts.joined(separator: " ") + "\n"
    }

    /// One line per event: a value a caller built from an error can carry spaces and newlines.
    private static func sanitize(_ value: String) -> String {
      let collapsed =
        value
        .replacingOccurrences(of: "\n", with: "_")
        .replacingOccurrences(of: "\r", with: "_")
        .replacingOccurrences(of: " ", with: "_")
      return collapsed.count > 160 ? String(collapsed.prefix(160)) : collapsed
    }

    private static func applicationState() -> String {
      guard Thread.isMainThread else { return "bg-queue" }
      #if os(watchOS)
        // `WKApplication` is main-actor isolated; the check above is what makes this call safe,
        // and `assumeIsolated` is what tells the compiler so.
        return MainActor.assumeIsolated { stateName(WKApplication.shared().applicationState) }
      #else
        return "host"
      #endif
    }

    #if os(watchOS)
      private static func stateName(_ state: WKApplicationState) -> String {
        switch state {
        case .active: return "active"
        case .inactive: return "inactive"
        case .background: return "background"
        @unknown default: return "unknown"
        }
      }
    #endif

    // MARK: File

    private static var logURL: URL {
      #if os(watchOS)
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
          .appendingPathComponent("WatchRSSDiagnostics.log")
      #else
        return FileManager.default.temporaryDirectory
          .appendingPathComponent("WatchRSSDiagnostics.log")
      #endif
    }

    private static func append(_ line: String) {
      let url = logURL
      let fileManager = FileManager.default
      do {
        try fileManager.createDirectory(
          at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      } catch { return }
      if !fileManager.fileExists(atPath: url.path) {
        var attributes: [FileAttributeKey: Any] = [:]
        #if os(watchOS)
          attributes[.protectionKey] = FileProtectionType.completeUntilFirstUserAuthentication
        #endif
        guard fileManager.createFile(atPath: url.path, contents: nil, attributes: attributes) else {
          return
        }
        excludeFromBackup(url)
      }
      guard let handle = try? FileHandle(forWritingTo: url) else { return }
      defer { try? handle.close() }
      do {
        let end = try handle.seekToEnd()
        try handle.write(contentsOf: Data(line.utf8))
        if Int(end) + line.utf8.count > maxBytes {
          truncate(url, fileManager: fileManager)
        }
      } catch {}
    }

    private static func truncate(_ url: URL, fileManager: FileManager) {
      guard let data = try? Data(contentsOf: url), data.count > maxBytes else { return }
      var kept = data.suffix(keptBytes)
      if let newline = kept.firstIndex(of: UInt8(ascii: "\n")) {
        kept = kept[kept.index(after: newline)...]
      }
      var options: Data.WritingOptions = [.atomic]
      #if os(watchOS)
        options.insert(.completeFileProtectionUntilFirstUserAuthentication)
      #endif
      guard (try? Data(kept).write(to: url, options: options)) != nil else { return }
      excludeFromBackup(url)
    }

    private static func excludeFromBackup(_ url: URL) {
      #if os(watchOS)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var url = url
        try? url.setResourceValues(values)
      #endif
    }
  }

  nonisolated extension WatchRSSDownloadKey {
    /// The identity a line may carry: the feed, eight characters of the episode ID, and the
    /// revision. Never the enclosure URL, the title or the show.
    var diagnosticFields: [String: String] {
      [
        "feedID": selection.feedID,
        "episodeID": String(selection.episodeID.prefix(8)),
        "revision": String(revision),
      ]
    }
  }
#else
  /// Release builds carry no log: the body is empty, so the call sites need no `#if` of their own.
  /// `@inline(__always)` makes the optimizer drop each call and the fields it was built from.
  nonisolated enum WatchRSSDiagnostics {
    @inline(__always)
    static func log(_ event: String, _ fields: [String: String] = [:]) {}

    @inline(__always)
    static func log(
      _ event: String, _ key: WatchRSSDownloadKey, taskIdentifier: Int? = nil,
      _ fields: [String: String] = [:]
    ) {}

    @inline(__always)
    static func failureFields(_ token: WatchRSSCallbackToken, _ error: Error?) -> [String: String] {
      [:]
    }
  }
#endif
