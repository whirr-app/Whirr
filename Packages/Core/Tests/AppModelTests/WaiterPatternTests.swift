import Foundation
import Testing

/// Keeps new unbounded waiting out of the test corpus.
///
/// The suite has two bounded waiters, `awaitCondition` and `awaitQuiescence`, that count a budget
/// in serviced one-millisecond sleeps and report a diagnostic when it runs out. Most patterns that
/// defeat them are plain-text bans and live in `Scripts/source-rules/core.toml` (`tests-never-…`):
/// swallowed sleep cancellation, `DispatchSemaphore`, wall-clock assertions, real-time UIKit
/// animation, and a fixed-sleep ratchet. Two need Swift structure and stay here:
///
/// - A `Task.yield()` loop is not a wait: a whole yield budget can elapse between two steps of the
///   awaited work, so the loop declares a still-running system settled. Found by a brace walk,
///   since the loop body spans lines and nests.
/// - A locally redeclared waiter is a second copy of a contract `TestSupport` holds once. Whether a
///   body delegates to the shared waiter needs the brace-balanced body.
@Suite("Waiter patterns")
struct WaiterPatternTests {
  @Test("no test source spins a loop of yields instead of waiting")
  func noYieldLoops() throws {
    try expectNoViolations(of: .yieldLoop)
  }

  @Test("no test source declares its own waiter")
  func noShadowedWaiters() throws {
    try expectNoViolations(of: .shadowedWaiter)
  }

  @Test("the scan reads the Watch host regressions as well as the test targets")
  func theHostRegressionsAreScanned() throws {
    let paths = Set(try WaiterPatternScan.scannedSources.get().map(\.relativePath))
    #expect(paths.contains("Scripts/watch-regressions/PlaybackPolicyRegression.swift"))
    #expect(paths.contains("App/WhirrTests/DeferredModelTests.swift"))
  }

  /// The scan is only worth anything if a broken root is loud. `#filePath` is baked in at compile
  /// time as an absolute path on the building machine, so a bundle executed from a different
  /// checkout would otherwise enumerate nothing and pass.
  @Test("the scan fails closed when its root is unreachable")
  func theScanFailsClosedWhenItsRootIsUnreachable() {
    #expect(throws: WaiterPatternScan.Failure.self) {
      _ = try WaiterPatternScan.sources(root: URL(fileURLWithPath: "/nonexistent-repository-root"))
    }
  }

  @Test("the scan fails closed when it finds implausibly few sources")
  func theScanFailsClosedOnAnImplausiblyLargeFloor() {
    #expect(throws: WaiterPatternScan.Failure.self) {
      _ = try WaiterPatternScan.sources(expectedAtLeast: .max)
    }
  }

  /// A stripper that is not string-aware truncates every line holding a URL, which would hide any
  /// violation written after one. That failure mode is silent, so it gets its own case.
  @Test("stripping comments keeps code that follows a URL inside a string literal")
  func strippingCommentsKeepsCodeAfterAURLLiteral() {
    let source = """
      let endpoint = "https://example.invalid/api"; let cache = Task.yield()
      """
    #expect(WaiterPatternScan.executableText(source).contains("Task.yield()"))
  }

  @Test("stripping removes a documented mention, and blanks string contents on request")
  func strippingRemovesMentionsAndBlanksStrings() {
    let source = """
      /// Never calls `Task.yield()`.
      // and neither does Task.yield()
      let fixture = "Task.yield() \\(x)"
      """
    let kept = WaiterPatternScan.executableText(source)
    #expect(kept.contains("// and") == false)
    #expect(kept.contains("Never calls") == false)
    #expect(kept.contains("\"Task.yield() "))
    let blanked = WaiterPatternScan.executableText(source, blankingStrings: true)
    #expect(blanked.contains("Task.yield()") == false)
    #expect(blanked.count == source.count)
  }

  @Test("the scan finds the yield loop it is meant to find")
  func theYieldLoopDetectorIsNotVacuous() {
    let text = """
      func wait() async {
        for _ in 0..<50 {
          await Task.yield()
        }
      }
      """
    #expect(WaiterPatternScan.violations(of: .yieldLoop, in: text).isEmpty == false)
  }

  @Test("a single yield outside a loop is not a violation")
  func aLoneYieldIsAllowed() {
    let text = """
      func start() async {
        task = Task { await work() }
        await Task.yield()
      }
      """
    #expect(WaiterPatternScan.violations(of: .yieldLoop, in: text).isEmpty)
  }

  @Test("a yield in a loop body reached through a nested closure still counts")
  func aNestedYieldCounts() {
    let text = """
      func wait() async {
        while running {
          await withCheckedContinuation { c in c.resume() }
          await Task.yield()
        }
      }
      """
    #expect(WaiterPatternScan.violations(of: .yieldLoop, in: text).isEmpty == false)
  }

  @Test("an overload that forwards to a shared waiter is not a second copy")
  func aForwardingOverloadIsAllowed() {
    let text = """
      private func waitUntil(_ condition: @escaping @Sendable () async -> Bool) async throws {
        guard await TestSupport.waitUntil(condition) else { throw Lost() }
      }
      """
    #expect(WaiterPatternScan.violations(of: .shadowedWaiter, in: text).isEmpty)
  }

  @Test("a waiter that polls on its own is a second copy")
  func aReimplementedWaiterIsAViolation() {
    let text = """
      private func waitUntil(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<100 {
          if condition() { return true }
          try? await Task.sleep(for: .milliseconds(1))
        }
        return false
      }
      """
    #expect(WaiterPatternScan.violations(of: .shadowedWaiter, in: text).isEmpty == false)
  }

  private func expectNoViolations(of pattern: WaiterPatternScan.Pattern) throws {
    var offenders: [String] = []

    for source in try WaiterPatternScan.scannedSources.get() {
      for line in WaiterPatternScan.violations(of: pattern, in: source.text) {
        offenders.append("\(source.relativePath):\(line)")
      }
    }

    #expect(
      offenders.isEmpty,
      "\(pattern.remedy)\n  \(offenders.joined(separator: "\n  "))")
  }
}

/// Finds the waiting shapes that need Swift structure to see, in comment-stripped Swift whose
/// string literals are blanked.
enum WaiterPatternScan {
  enum Pattern: CaseIterable, Hashable {
    case yieldLoop
    case shadowedWaiter

    var remedy: String {
      switch self {
      case .yieldLoop:
        return
          "A loop of `Task.yield()` measures nothing: a yield costs no time, so the whole budget can "
          + "elapse between two steps of the work being awaited. Use `awaitCondition` for a state "
          + "you can name, or `awaitQuiescence` for one you can only watch settle."
      case .shadowedWaiter:
        return
          "A third copy of the waiter contract cannot be held in sync. Call the shared "
          + "`awaitCondition`/`awaitQuiescence`/`waitUntil` instead of redeclaring one."
      }
    }
  }

  struct Source {
    let relativePath: String
    let text: String
  }

  enum Failure: Error, CustomStringConvertible {
    case rootUnreachable(String)
    case implausiblyFewSources(found: Int, expectedAtLeast: Int)

    var description: String {
      switch self {
      case .rootUnreachable(let path):
        return
          "waiter-pattern scan root is unreachable at \(path); the bundle was probably built on a "
          + "different checkout path, so this scan cannot be trusted"
      case .implausiblyFewSources(let found, let expected):
        return
          "waiter-pattern scan found only \(found) sources, expected at least \(expected); "
          + "treating a near-empty scan as a pass would delete this coverage silently"
      }
    }
  }

  /// Well below today's count, high enough that an empty or partial enumeration is caught. Raise it
  /// when the suite grows; never lower it to make a broken root pass.
  static let minimumSources = 400

  static let testDirectories = [
    "Packages/Core/Tests",
    "App/WhirrTests",
    "App/WhirrPerformanceTests",
  ]

  /// The Watch host regressions run in the gates as standalone programs outside every test target,
  /// so they cannot call the shared waiters; their own bounded copy is `HostWaiting.swift` there.
  static let hostRegressionDirectory = "Scripts/watch-regressions"

  /// The test corpus and the host regressions, comment-stripped with string literals blanked, read
  /// once per process.
  static let scannedSources = Result<[Source], any Error> {
    try sources().map {
      Source(
        relativePath: $0.relativePath,
        text: executableText($0.text, blankingStrings: true))
    }
  }

  /// Raw text of every Swift source under the test directories and the host regressions. Fails
  /// closed: an unreachable directory, or fewer than `expectedAtLeast` files, throws.
  static func sources(
    root: URL = PackageManifest.repoRoot,
    expectedAtLeast: Int = minimumSources
  ) throws -> [Source] {
    var found: [Source] = []

    for directory in testDirectories + [hostRegressionDirectory] {
      let directoryURL = root.appendingPathComponent(directory)
      var isDirectory: ObjCBool = false
      guard
        FileManager.default.fileExists(atPath: directoryURL.path, isDirectory: &isDirectory),
        isDirectory.boolValue,
        let enumerator = FileManager.default.enumerator(
          at: directoryURL, includingPropertiesForKeys: nil)
      else {
        throw Failure.rootUnreachable(directoryURL.path)
      }

      for case let fileURL as URL in enumerator where fileURL.pathExtension == "swift" {
        // SwiftPM's checkout and build directories live under the package, not under Tests, but
        // guard anyway: scanning a dependency's sources would produce noise, not coverage.
        if fileURL.pathComponents.contains(".build") { continue }
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { continue }
        let relativePath =
          fileURL.path.hasPrefix(root.path)
          ? String(fileURL.path.dropFirst(root.path.count + 1))
          : fileURL.path
        found.append(Source(relativePath: relativePath, text: text))
      }
    }

    guard found.count >= expectedAtLeast else {
      throw Failure.implausiblyFewSources(found: found.count, expectedAtLeast: expectedAtLeast)
    }
    return found
  }

  /// One-based line numbers of every occurrence of `pattern` in prepared `text`.
  static func violations(of pattern: Pattern, in text: String) -> [Int] {
    switch pattern {
    case .shadowedWaiter:
      return reimplementedWaiterLines(in: text)
    case .yieldLoop:
      return yieldLoopLines(in: text)
    }
  }

  /// Lines declaring a function named like a waiter whose body never reaches a shared one.
  ///
  /// A thin overload forwarding to `awaitCondition` or `TestSupport.waitUntil` is only a call site
  /// with a convenient name (a `throws` variant, or a wrapper binding a model). This catches a
  /// reimplementation: a body that polls on its own, with unreviewed timeout and cancellation.
  private static func reimplementedWaiterLines(in text: String) -> [Int] {
    let declarations = ["func waitUntil(", "func awaitCondition(", "func awaitQuiescence("]
    let delegations = [
      "TestSupport.waitUntil", "TestSupport.awaitCondition", "TestSupport.awaitQuiescence",
      "awaitCondition(", "awaitQuiescence(", "waitUntil(",
    ]
    // Almost no file declares a waiter, and the character array is the expensive part.
    guard declarations.contains(where: { text.contains($0) }) else { return [] }
    let characters = Array(text)
    var found: [Int] = []

    for (offset, line) in text.components(separatedBy: "\n").enumerated() {
      guard declarations.contains(where: { line.contains($0) }) else { continue }
      guard let start = index(ofLine: offset + 1, in: characters) else { continue }
      let body = bodyText(from: start, in: characters)
      if delegations.contains(where: { body.contains($0) }) == false {
        found.append(offset + 1)
      }
    }
    return found
  }

  /// Character offset where the one-based `line` begins.
  private static func index(ofLine line: Int, in characters: [Character]) -> Int? {
    guard line > 1 else { return characters.isEmpty ? nil : 0 }
    var current = 1
    for (offset, character) in characters.enumerated() where character == "\n" {
      current += 1
      if current == line { return offset + 1 }
    }
    return nil
  }

  /// The brace-balanced body that follows `start`, beginning at the first `{` outside a parameter
  /// list. Returns everything to the end of the file when the braces do not balance, which fails
  /// safe: an unparseable declaration is judged on more text, not less.
  private static func bodyText(from start: Int, in characters: [Character]) -> String {
    var parenDepth = 0
    var braceDepth = 0
    var bodyStart: Int?
    var index = start

    while index < characters.count {
      switch characters[index] {
      case "(": parenDepth += 1
      case ")": parenDepth = max(0, parenDepth - 1)
      case "{" where parenDepth == 0:
        if bodyStart == nil { bodyStart = index }
        braceDepth += 1
      case "}" where parenDepth == 0:
        braceDepth -= 1
        if braceDepth == 0, let bodyStart {
          return String(characters[bodyStart...index])
        }
      default: break
      }
      index += 1
    }
    return bodyStart.map { String(characters[$0...]) } ?? ""
  }

  /// Lines holding a `Task.yield()` that is lexically inside a `for`, `while`, or `repeat` body.
  ///
  /// A brace walk, as the shape spans lines and nests: a yield inside a closure in the loop is
  /// still driven by it. Only a brace opened at paren depth zero starts a loop body, so
  /// `for x in list.map({ … }) {` does not mistake the closure for the body, and a closure's
  /// closing brace must not cancel the pending loop in `while lock.withLock({ held }) { … }`.
  private static func yieldLoopLines(in text: String) -> [Int] {
    // Only a yield is ever reported, so a file without one needs no walk.
    guard text.contains("Task.yield") else { return [] }
    let characters = Array(text)
    var lineNumber = 1
    var parenDepth = 0
    var loopBodyDepths: [Int] = []
    var braceDepth = 0
    var pendingLoop = false
    var found: [Int] = []
    var index = 0

    func matchesKeyword(_ keyword: String) -> Bool {
      guard index + keyword.count <= characters.count else { return false }
      guard String(characters[index..<(index + keyword.count)]) == keyword else { return false }
      let before = index > 0 ? characters[index - 1] : " "
      let after =
        index + keyword.count < characters.count ? characters[index + keyword.count] : " "
      return before.isLetter == false && before != "_" && (after == " " || after == "(")
    }

    while index < characters.count {
      let character = characters[index]
      switch character {
      case "\n":
        lineNumber += 1
      case "(":
        parenDepth += 1
      case ")":
        parenDepth = max(0, parenDepth - 1)
      case "{":
        braceDepth += 1
        if pendingLoop, parenDepth == 0 {
          loopBodyDepths.append(braceDepth)
          pendingLoop = false
        }
      case "}":
        if loopBodyDepths.last == braceDepth { loopBodyDepths.removeLast() }
        braceDepth = max(0, braceDepth - 1)
      case ";":
        pendingLoop = false
      default:
        if parenDepth == 0,
          matchesKeyword("for") || matchesKeyword("while") || matchesKeyword("repeat")
        {
          pendingLoop = true
        }
        if loopBodyDepths.isEmpty == false, matchesKeyword("Task.yield") {
          found.append(lineNumber)
        }
      }
      index += 1
    }

    return found
  }

  /// Swift source with comments replaced by spaces, preserving line structure so reported line
  /// numbers still match the file.
  ///
  /// String-aware: `"https://example.com"` holds a `//` that does not start a comment, and
  /// treating it as one would silently drop the rest of the line.
  ///
  /// Walks UTF-8 bytes, not Characters: every delimiter is ASCII and no byte of a multi-byte
  /// scalar is, so the result is the same, and the whole corpus is stripped several times faster.
  /// A non-ASCII scalar inside a comment becomes one space per byte, which keeps lines intact.
  ///
  /// With `blankingStrings`, string contents become spaces too (quotes and newlines stay), so a
  /// detector's own fixtures, held in string literals, are not mistaken for code.
  static func executableText(_ source: String, blankingStrings: Bool = false) -> String {
    enum Mode {
      case code
      case lineComment
      case blockComment(depth: Int)
      case string(multiline: Bool)
    }

    var mode = Mode.code
    let characters = Array(source.utf8)
    var output: [UInt8] = []
    output.reserveCapacity(characters.count)
    var index = 0

    func peek(_ offset: Int) -> UInt8? {
      let target = index + offset
      return target < characters.count ? characters[target] : nil
    }

    func emit(_ character: UInt8) {
      output.append(character)
    }

    let slash = UInt8(ascii: "/")
    let star = UInt8(ascii: "*")
    let quote = UInt8(ascii: "\"")
    let backslash = UInt8(ascii: "\\")
    let newline = UInt8(ascii: "\n")
    let space = UInt8(ascii: " ")

    while index < characters.count {
      let character = characters[index]

      switch mode {
      case .code:
        if character == slash, peek(1) == slash {
          mode = .lineComment
          emit(space)
          emit(space)
          index += 2
          continue
        }
        if character == slash, peek(1) == star {
          mode = .blockComment(depth: 1)
          emit(space)
          emit(space)
          index += 2
          continue
        }
        if character == quote {
          let isMultiline = peek(1) == quote && peek(2) == quote
          mode = .string(multiline: isMultiline)
          if isMultiline {
            emit(quote)
            emit(quote)
            emit(quote)
            index += 3
          } else {
            emit(quote)
            index += 1
          }
          continue
        }
        emit(character)
        index += 1

      case .lineComment:
        if character == newline {
          mode = .code
          emit(newline)
        } else {
          emit(space)
        }
        index += 1

      case .blockComment(let depth):
        // Swift block comments nest, so a naive search for the first `*/` closes too early.
        if character == slash, peek(1) == star {
          mode = .blockComment(depth: depth + 1)
          emit(space)
          emit(space)
          index += 2
          continue
        }
        if character == star, peek(1) == slash {
          mode = depth == 1 ? .code : .blockComment(depth: depth - 1)
          emit(space)
          emit(space)
          index += 2
          continue
        }
        emit(character == newline ? newline : space)
        index += 1

      case .string(let multiline):
        if character == backslash, peek(1) != nil {
          emit(blankingStrings ? space : character)
          let escaped = characters[index + 1]
          emit(blankingStrings && escaped != newline ? space : escaped)
          index += 2
          continue
        }
        if character == quote {
          if multiline, peek(1) == quote, peek(2) == quote {
            mode = .code
            emit(quote)
            emit(quote)
            emit(quote)
            index += 3
            continue
          }
          if multiline == false {
            mode = .code
          }
          emit(quote)
          index += 1
          continue
        }
        // An unterminated single-line string cannot outlive its line; recovering at the newline
        // keeps one malformed line from swallowing the rest of the file.
        if character == newline, multiline == false {
          mode = .code
        }
        emit(blankingStrings && character != newline ? space : character)
        index += 1
      }
    }

    return String(decoding: output, as: UTF8.self)
  }
}
