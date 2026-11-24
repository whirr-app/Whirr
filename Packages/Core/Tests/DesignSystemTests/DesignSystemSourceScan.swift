import Foundation

/// The Swift sources the editorial chrome rules read: the app's views and the design system itself.
///
/// Fails closed. `#filePath` is baked in at compile time as an absolute path on the building
/// machine, so a bundle run from another checkout would otherwise enumerate nothing and pass, and a
/// scan that finds a handful of files has lost its root. Text is returned with comments blanked
/// (line structure kept), so a comment naming a banned modifier is not a violation.
enum DesignSystemSourceScan {
  struct Source {
    let name: String
    let text: String
  }

  enum Failure: Error, CustomStringConvertible {
    case rootUnreachable(String)
    case implausiblyFewSources(found: Int, expectedAtLeast: Int)

    var description: String {
      switch self {
      case .rootUnreachable(let path):
        return "source scan root is unreachable at \(path); the bundle was probably built on a different checkout path"
      case .implausiblyFewSources(let found, let expected):
        return
          "source scan found only \(found) files, expected at least \(expected); a near-empty scan would pass forever"
      }
    }
  }

  /// Well below today's count (about 690), high enough that a partial enumeration is caught.
  static let minimumSources = 300

  static let relativeRoots = ["App/Whirr", "Packages/Core/Sources/DesignSystem"]

  /// Read once per process and shared by every suite that scans.
  static let all = Result<[Source], any Error> { try sources() }

  static func sources(
    root: URL = repositoryRoot(),
    expectedAtLeast: Int = minimumSources
  ) throws -> [Source] {
    var found: [Source] = []
    for relativeRoot in relativeRoots {
      let directory = root.appending(path: relativeRoot)
      var isDirectory: ObjCBool = false
      guard
        FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
        isDirectory.boolValue,
        let files = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil)
      else { throw Failure.rootUnreachable(directory.path) }
      for case let url as URL in files where url.pathExtension == "swift" {
        let text = try String(contentsOf: url, encoding: .utf8)
        found.append(Source(name: url.lastPathComponent, text: strippingComments(from: text)))
      }
    }
    guard found.count >= expectedAtLeast else {
      throw Failure.implausiblyFewSources(found: found.count, expectedAtLeast: expectedAtLeast)
    }
    return found
  }

  /// Derived from `#filePath` rather than the working directory, which the test runner does not
  /// control: `<root>/Packages/Core/Tests/DesignSystemTests/<this file>`.
  static func repositoryRoot(filePath: String = #filePath) -> URL {
    URL(fileURLWithPath: filePath)
      .deletingLastPathComponent()  // DesignSystemTests
      .deletingLastPathComponent()  // Tests
      .deletingLastPathComponent()  // Core
      .deletingLastPathComponent()  // Packages
      .deletingLastPathComponent()  // repository root
  }

  /// Comments replaced by spaces, newlines kept. String-aware, so `"https://…"` does not start a
  /// comment; block comments nest.
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
