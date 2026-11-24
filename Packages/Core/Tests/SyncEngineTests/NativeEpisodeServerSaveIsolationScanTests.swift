import Foundation
import Testing

/// The fencer and the removal pipeline are values, so an `async` member without an `isolated`
/// coordinator parameter would run on the generic executor: save and removal could then execute
/// simultaneously instead of interleaving only at `await`s. Nothing else catches that — it
/// compiles cleanly and no outcome test observes the executor — so the rule is pinned on source.
@Suite("Native episode server-save collaborator isolation")
struct NativeEpisodeServerSaveIsolationScanTests {
  static let collaboratorFiles = [
    "NativeEpisodeServerSaveFencer.swift",
    "NativeEpisodeServerSaveRemovalPipeline.swift",
    "NativeEpisodeServerSaveRemovalPipeline+Outcomes.swift",
  ]

  @Test("every async collaborator member runs on the coordinator's executor")
  func everyAsyncMemberTakesTheIsolatedCoordinator() throws {
    var asyncMembers = 0
    for file in Self.collaboratorFiles {
      // A missing file throws here rather than reading as no members.
      let source = Self.strippingComments(from: try String(contentsOf: Self.sourceURL(file), encoding: .utf8))
      for signature in Self.functionSignatures(in: source) where signature.contains(" async") {
        asyncMembers += 1
        #expect(
          signature.contains("isolated NativeEpisodeServerSaveCoordinator"),
          "\(file): \(signature.prefix(80))… must take `on coordinator: isolated NativeEpisodeServerSaveCoordinator`"
        )
      }
    }
    // Fails closed: a renamed file or a parser that finds nothing must not pass vacuously.
    #expect(asyncMembers >= 20)
  }

  @Test("a signature named only in a comment is not a member")
  func commentsAreNotMembers() {
    let stripped = Self.strippingComments(
      from: """
        /// func fake() async {
        func real(on coordinator: isolated NativeEpisodeServerSaveCoordinator) async {}  // func other() async {
        """)
    #expect(Self.functionSignatures(in: stripped).count == 1)
  }

  @Test("a missing collaborator file fails the check rather than passing it")
  func aMissingFileFailsClosed() {
    #expect(throws: (any Error).self) {
      _ = try String(contentsOf: Self.sourceURL("NoSuchCollaborator.swift"), encoding: .utf8)
    }
  }

  private static func sourceURL(_ file: String) -> URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Sources/SyncEngine/\(file)")
  }

  /// Each `func` declaration's text from `func` up to its body's opening brace, so parameters
  /// spread over several lines are read as one signature.
  private static func functionSignatures(in source: String) -> [String] {
    var signatures: [String] = []
    var remainder = source[...]
    while let start = remainder.range(of: "func ") {
      let tail = remainder[start.lowerBound...]
      guard let brace = tail.firstIndex(of: "{") else { break }
      signatures.append(String(tail[..<brace]))
      remainder = tail[brace...]
    }
    return signatures
  }

  /// Comments replaced by spaces, newlines kept, so a signature named in a comment is not read.
  /// String-aware, so `"https://…"` does not start a comment; block comments nest.
  static func strippingComments(from source: String) -> String {
    let bytes = Array(source.utf8)
    let slash = UInt8(ascii: "/")
    let star = UInt8(ascii: "*")
    let quote = UInt8(ascii: "\"")
    let backslash = UInt8(ascii: "\\")
    let newline = UInt8(ascii: "\n")
    let space = UInt8(ascii: " ")
    var output: [UInt8] = []
    output.reserveCapacity(bytes.count)
    var index = 0
    var inLineComment = false
    var blockDepth = 0
    var string: (multiline: Bool, open: Bool) = (false, false)

    func byte(at offset: Int) -> UInt8 { offset < bytes.count ? bytes[offset] : 0 }

    while index < bytes.count {
      let current = bytes[index]
      let next = byte(at: index + 1)
      if inLineComment {
        if current == newline { inLineComment = false }
        output.append(current == newline ? newline : space)
        index += 1
      } else if blockDepth > 0 {
        if current == slash, next == star {
          blockDepth += 1
          output += [space, space]
          index += 2
        } else if current == star, next == slash {
          blockDepth -= 1
          output += [space, space]
          index += 2
        } else {
          output.append(current == newline ? newline : space)
          index += 1
        }
      } else if string.open {
        if current == backslash {
          output += [current, next]
          index += 2
        } else if current == quote, string.multiline {
          let closes = next == quote && byte(at: index + 2) == quote
          output += closes ? [quote, quote, quote] : [quote]
          index += closes ? 3 : 1
          if closes { string.open = false }
        } else {
          if current == quote || (current == newline && !string.multiline) { string.open = false }
          output.append(current)
          index += 1
        }
      } else if current == slash, next == slash {
        inLineComment = true
        output += [space, space]
        index += 2
      } else if current == slash, next == star {
        blockDepth = 1
        output += [space, space]
        index += 2
      } else if current == quote {
        let multiline = next == quote && byte(at: index + 2) == quote
        string = (multiline, true)
        output += multiline ? [quote, quote, quote] : [quote]
        index += multiline ? 3 : 1
      } else {
        output.append(current)
        index += 1
      }
    }
    return String(decoding: output, as: UTF8.self)
  }
}
