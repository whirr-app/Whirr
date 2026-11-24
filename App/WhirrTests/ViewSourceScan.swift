import Foundation
import Synchronization

/// Shared plumbing for the source-level suites that gate composition rules the type system cannot.
///
/// SwiftUI's rendered modifier tree is not a stable semantic value, so "this row was composed
/// without the treatment every other list gives it" is only checkable as a fact about the source.
///
/// Fails closed. The root comes from `#filePath`, an absolute path baked in on the building
/// machine, so a bundle run elsewhere (another runner, a cache restored at a different path, a
/// shard without the checkout) finds no directory. An empty list would make every call site
/// iterate nothing and report green, so an unreachable or implausibly small source set is an error.
enum ViewSourceScan {

  enum Failure: Error, CustomStringConvertible, Equatable {
    case rootUnreachable(path: String)
    case implausiblyFewSources(path: String, found: Int, expectedAtLeast: Int)
    case viewNotFound(name: String)
    case declarationNotFound(symbol: String)
    case ambiguousDeclaration(symbol: String, fileNames: [String])
    case sourceNotFound(fileName: String)
    case ambiguousFileName(fileName: String, paths: [String])

    var description: String {
      switch self {
      case .rootUnreachable(let path):
        """
        source scan root is unreachable: \(path)
        The root is baked in at compile time from #filePath, so this usually means the test bundle \
        is running on a machine or at a path where the repository is not present. Every scan-based \
        assertion is void until it is.
        """
      case .implausiblyFewSources(let path, let found, let expectedAtLeast):
        """
        source scan found only \(found) Swift files under \(path), expected at least \
        \(expectedAtLeast). Either the root is wrong or the app has shrunk dramatically; the scans \
        prove nothing until this is explained.
        """
      case .viewNotFound(let name):
        "no view source named \(name).swift; a scan of its parts would read nothing"
      case .declarationNotFound(let symbol):
        """
        no app source declares \(symbol). If the type was renamed, update the scan's symbol; a \
        missing file name would otherwise make the scan read nothing.
        """
      case .ambiguousDeclaration(let symbol, let fileNames):
        """
        \(symbol) is declared in more than one source (\(fileNames.joined(separator: ", "))). A \
        symbol lookup needs one owner; scan the specific part by file name instead.
        """
      case .sourceNotFound(let fileName):
        "no app source named \(fileName); a scan of it would read nothing"
      case .ambiguousFileName(let fileName, let paths):
        """
        more than one app source is named \(fileName) (\(paths.joined(separator: ", "))); look the \
        scan's subject up by the type it declares instead.
        """
      }
    }
  }

  /// Floors, not exact counts: an exact count would be a gate someone has to update on every file
  /// move, which is the kind of check people delete. These only have to be low enough that ordinary
  /// refactoring never trips them and high enough that a wrong root always does.
  static let minimumViewSources = 80
  static let minimumAppSources = 120

  /// Every SwiftUI view source in the app.
  static func sources() throws -> [URL] {
    try swiftFiles(
      under: repositoryRoot().appending(path: "App/Whirr/Views"),
      expectedAtLeast: minimumViewSources)
  }

  /// Every app source, not just the view layer: an identifier or marker can be applied from a
  /// screen that does not live under `Views` (`ReaderView.swift`, `RootView.swift`).
  static func appSources() throws -> [URL] {
    try swiftFiles(
      under: repositoryRoot().appending(path: "App/Whirr"),
      expectedAtLeast: minimumAppSources)
  }

  // The sources cannot change while the tests run, and some two hundred call sites walk the same
  // directories and strip the same files, all on the main thread the hosted-layout suites are
  // waiting for. Each root is walked and each file stripped once per process. Only successes are
  // kept, so an unreachable root or an unreadable file throws on every call.
  private static let fileLists = Mutex<[String: [URL]]>([:])
  private static let executableTexts = Mutex<[String: String]>([:])

  private static func memoized<Value: Sendable>(
    _ key: String, in cache: borrowing Mutex<[String: Value]>, _ make: () throws -> Value
  ) throws -> Value {
    if let cached = cache.withLock({ $0[key] }) { return cached }
    let made = try make()
    cache.withLock { $0[key] = made }
    return made
  }

  private static func walkedSwiftFiles(under root: URL) throws -> [URL] {
    var isDirectory: ObjCBool = false
    guard
      FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory),
      isDirectory.boolValue,
      let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
    else {
      throw Failure.rootUnreachable(path: root.path)
    }
    return walker.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
  }

  /// Internal rather than private so `ViewSourceScanTests` can point it at a root that is not
  /// there and prove the failure is loud.
  static func swiftFiles(under root: URL, expectedAtLeast: Int) throws -> [URL] {
    let found = try memoized(root.path, in: fileLists) { try walkedSwiftFiles(under: root) }
    guard found.count >= expectedAtLeast else {
      throw Failure.implausiblyFewSources(
        path: root.path, found: found.count, expectedAtLeast: expectedAtLeast)
    }
    return found
  }

  /// The source without comments or the `PERF_INVESTIGATION` branch, so a doc comment naming a
  /// marker cannot satisfy, or inflate, the count that stands in for a real call. Lines that held
  /// only a comment or a measurement probe are dropped; the rest keep their layout.
  static func executableText(of source: URL) throws -> String {
    try memoized(source.path, in: executableTexts) {
      let original = try String(contentsOf: source, encoding: .utf8)
      return executableText(ofSource: original)
    }
  }

  /// `executableText(of:)` for text already in hand. Internal so `ViewSourceScanTests` can pin the
  /// stripper against literals.
  static func executableText(ofSource original: String) -> String {
    let originalLines = original.split(separator: "\n", omittingEmptySubsequences: false)
    let blankedLines = blankingComments(in: original)
      .split(separator: "\n", omittingEmptySubsequences: false)
    let kept = zip(originalLines, blankedLines).compactMap { original, blanked -> Substring? in
      let emptied = blanked.allSatisfy(\.isWhitespace) && original.allSatisfy(\.isWhitespace) == false
      return emptied ? nil : blanked
    }
    return strippingPerfInvestigationBlocks(kept).joined(separator: "\n")
  }

  /// The source with every comment blanked to spaces and nothing else touched, line for line. For a
  /// scan that interprets compilation conditions itself, which `executableText` would pre-empt.
  static func commentFreeText(of source: URL) throws -> String {
    blankingComments(in: try String(contentsOf: source, encoding: .utf8))
  }

  /// Blanks `//` and nested `/* */` comments, leaving string literals (multi-line, raw, and with
  /// interpolations that hold strings of their own) as written. The same lexer as
  /// `Scripts/check-source-rules.py`, so the lint and the scans agree on what a comment is.
  static func blankingComments(in text: String) -> String {
    let bytes = Array(text.utf8)
    var out = bytes
    let count = bytes.count
    let slash = UInt8(ascii: "/")
    let star = UInt8(ascii: "*")
    let quote = UInt8(ascii: "\"")
    let hash = UInt8(ascii: "#")
    let backslash = UInt8(ascii: "\\")
    let newline = UInt8(ascii: "\n")
    let open = UInt8(ascii: "(")
    let close = UInt8(ascii: ")")
    let space = UInt8(ascii: " ")
    struct Literal {
      var hashes: Int
      var multiline: Bool
    }
    var literal: Literal?
    var interpolations: [(parens: Int, literal: Literal)] = []
    var index = 0

    func at(_ offset: Int) -> UInt8? { offset < count ? bytes[offset] : nil }
    func blank(_ range: Range<Int>) {
      for offset in range where out[offset] != newline { out[offset] = space }
    }
    func hashes(from offset: Int) -> Int {
      var end = offset
      while at(end) == hash { end += 1 }
      return end - offset
    }
    func isTripleQuote(_ offset: Int) -> Bool {
      at(offset) == quote && at(offset + 1) == quote && at(offset + 2) == quote
    }

    while index < count {
      let byte = bytes[index]
      if let current = literal {
        if byte == backslash, hashes(from: index + 1) >= current.hashes {
          let after = index + 1 + current.hashes
          if at(after) == open {
            interpolations.append((parens: 1, literal: current))
            literal = nil
            index = after + 1
          } else {
            index = after + 1
          }
        } else if byte == quote {
          let closerLength = current.multiline ? 3 : 1
          if current.multiline == false || isTripleQuote(index),
            hashes(from: index + closerLength) >= current.hashes
          {
            literal = nil
            index += closerLength + current.hashes
          } else {
            index += 1
          }
        } else if byte == newline, current.multiline == false {
          literal = nil
          index += 1
        } else {
          index += 1
        }
        continue
      }
      if byte == slash, at(index + 1) == slash {
        var end = index
        while end < count, bytes[end] != newline { end += 1 }
        blank(index..<end)
        index = end
      } else if byte == slash, at(index + 1) == star {
        var depth = 0
        var end = index
        while end < count {
          if bytes[end] == slash, at(end + 1) == star {
            depth += 1
            end += 2
          } else if bytes[end] == star, at(end + 1) == slash {
            depth -= 1
            end += 2
            if depth == 0 { break }
          } else {
            end += 1
          }
        }
        blank(index..<min(end, count))
        index = end
      } else if byte == hash || byte == quote {
        let leading = hashes(from: index)
        let opener = index + leading
        if at(opener) == quote {
          let multiline = isTripleQuote(opener)
          literal = Literal(hashes: leading, multiline: multiline)
          index = opener + (multiline ? 3 : 1)
        } else {
          index = opener
        }
      } else if byte == open, interpolations.isEmpty == false {
        interpolations[interpolations.count - 1].parens += 1
        index += 1
      } else if byte == close, interpolations.isEmpty == false {
        interpolations[interpolations.count - 1].parens -= 1
        index += 1
        if interpolations[interpolations.count - 1].parens == 0 {
          literal = interpolations.removeLast().literal
        }
      } else {
        index += 1
      }
    }
    return String(decoding: out, as: UTF8.self)
  }

  /// The one app source that declares `symbol`, found by its declaration rather than its file name.
  ///
  /// A view split moves code between `Name.swift` and `Name+Part.swift`; a scan keyed on the file
  /// name then fails in every unrelated suite that names the old file. Keyed on the declaration,
  /// the scan follows the type unless the type itself is renamed or has more than one owner.
  static func source(declaring symbol: String) throws -> URL {
    try memoized(symbol, in: declaringSources) {
      let declaration = try NSRegularExpression(pattern: declarationPattern(for: symbol))
      let owners = try appSources().filter { source in
        let text = try executableText(of: source)
        return declaration.firstMatch(
          in: text, range: NSRange(text.startIndex..<text.endIndex, in: text)) != nil
      }
      guard owners.isEmpty == false else { throw Failure.declarationNotFound(symbol: symbol) }
      guard owners.count == 1 else {
        throw Failure.ambiguousDeclaration(
          symbol: symbol, fileNames: owners.map(\.lastPathComponent).sorted())
      }
      return owners[0]
    }
  }

  /// The one app source with this file name, for a scan whose subject is a file rather than one
  /// type: a `Type+Part.swift` split, or a file holding several views. Prefer `source(declaring:)`
  /// when a type is the subject, since it survives the type moving to another file.
  static func source(named fileName: String) throws -> URL {
    let matches = try appSources().filter { $0.lastPathComponent == fileName }
    guard let only = matches.first else { throw Failure.sourceNotFound(fileName: fileName) }
    guard matches.count == 1 else {
      throw Failure.ambiguousFileName(fileName: fileName, paths: matches.map(\.path).sorted())
    }
    return only
  }

  /// `executableText(of:)` for the one app source with this file name.
  static func executableText(ofFileNamed fileName: String) throws -> String {
    try executableText(of: source(named: fileName))
  }

  /// The declaring file's executable text, for a scan whose subject is one member.
  static func executableText(declaring symbol: String) throws -> String {
    try executableText(of: source(declaring: symbol))
  }

  private static func declarationPattern(for symbol: String) -> String {
    // `final class` is listed before `class`; both alternatives match the same source line, so the
    // order only affects which branch the regex engine reports.
    "\\b(?:struct|final class|class|enum|actor|protocol)\\s+\(NSRegularExpression.escapedPattern(for: symbol))\\b"
  }

  private static let declaringSources = Mutex<[String: URL]>([:])

  /// A view's executable text across `Name.swift` and its `Name+Part.swift` extension files, for a
  /// marker that should follow a member when it moves out of the main file. The prefix is `Name+`,
  /// not `Name`, because the looser match would also read `NamePresentation.swift` and satisfy, or
  /// silently weaken, the checks meant for the view itself.
  static func executableText(ofViewNamed name: String) throws -> String {
    let parts = try sources().filter { source in
      source.lastPathComponent == "\(name).swift" || source.lastPathComponent.hasPrefix("\(name)+")
    }
    guard parts.contains(where: { $0.lastPathComponent == "\(name).swift" }) else {
      throw Failure.viewNotFound(name: name)
    }
    return try parts.sorted { $0.lastPathComponent < $1.lastPathComponent }
      .map { try executableText(of: $0) }
      .joined(separator: "\n")
  }

  /// Drops the `#if PERF_INVESTIGATION` branch of each conditional, keeping its `#else`. Every scan
  /// asks what the shipping view is made of, and that branch compiles to nothing without the
  /// measurement flag, while its `#else` is exactly what ships. Leaving the probe branch in would let
  /// a probe label answer a question about production composition.
  private static func strippingPerfInvestigationBlocks(
    _ lines: [Substring]
  ) -> [Substring] {
    var kept: [Substring] = []
    var dropping = false
    var depth = 0
    for line in lines {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      guard dropping else {
        if trimmed == "#if PERF_INVESTIGATION" {
          dropping = true
          depth = 0
        } else {
          kept.append(line)
        }
        continue
      }
      if trimmed.hasPrefix("#if") {
        depth += 1
      } else if trimmed.hasPrefix("#endif") {
        if depth == 0 { dropping = false } else { depth -= 1 }
      } else if depth == 0, trimmed.hasPrefix("#else") || trimmed.hasPrefix("#elseif") {
        dropping = false
      }
    }
    return kept
  }

  static func occurrences(of markers: [String], in text: String) -> Int {
    markers.reduce(into: 0) { total, marker in
      total += text.components(separatedBy: marker).count - 1
    }
  }

  /// The files that construct any of `markers`, by file name.
  static func sourcesContaining(_ markers: [String]) throws -> [String] {
    try sources().filter { source in
      occurrences(of: markers, in: try executableText(of: source)) > 0
    }.map(\.lastPathComponent).sorted()
  }

  static func repositoryRoot() -> URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()  // App/WhirrTests
      .deletingLastPathComponent()  // App
      .deletingLastPathComponent()  // the repository root
  }
}
