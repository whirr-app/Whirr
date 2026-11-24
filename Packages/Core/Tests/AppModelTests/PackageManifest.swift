import Foundation

/// Reads the declared target graph straight out of `Package.swift`.
///
/// Not `swift package dump-package`: SwiftPM holds a build lock for the duration of
/// `swift test`, so a nested package invocation deadlocks. Parsing the manifest text keeps
/// these tests hermetic and instant.
enum PackageManifest {
  struct Target {
    let name: String
    let dependencies: Set<String>
    let isTest: Bool
  }

  /// `Packages/Core`, located from this file rather than the working directory, which
  /// `swift test` does not guarantee.
  static let packageRoot: URL = {
    URL(fileURLWithPath: #filePath)  // …/Tests/AppModelTests/PackageManifest.swift
      .deletingLastPathComponent()  // …/Tests/AppModelTests
      .deletingLastPathComponent()  // …/Tests
      .deletingLastPathComponent()  // …/Core
  }()

  /// Repository root, located two directories above `Packages/Core` for App and inventory checks.
  static let repoRoot: URL = {
    packageRoot
      .deletingLastPathComponent()  // …/Packages
      .deletingLastPathComponent()  // …/abs
  }()

  static func targets() throws -> [Target] {
    let source = try String(
      contentsOf: packageRoot.appendingPathComponent("Package.swift"), encoding: .utf8)
    var results: [Target] = []

    for (marker, isTest) in [(".target(", false), (".testTarget(", true)] {
      var searchStart = source.startIndex
      while let markerRange = source.range(of: marker, range: searchStart..<source.endIndex) {
        searchStart = markerRange.upperBound
        guard let body = balancedParenthesisBody(in: source, openAfter: markerRange.upperBound)
        else { continue }
        guard let name = firstQuotedString(after: "name:", in: body) else { continue }
        results.append(
          Target(
            name: name, dependencies: quotedStrings(inArrayAfter: "dependencies:", in: body),
            isTest: isTest))
      }
    }
    return results
  }

  /// Text between `.target(` and its matching close paren, so nested arrays and calls
  /// don't confuse the scan.
  private static func balancedParenthesisBody(
    in source: String, openAfter index: String.Index
  ) -> Substring? {
    var depth = 1
    var cursor = index
    while cursor < source.endIndex {
      let character = source[cursor]
      if character == "(" { depth += 1 }
      if character == ")" {
        depth -= 1
        if depth == 0 { return source[index..<cursor] }
      }
      cursor = source.index(after: cursor)
    }
    return nil
  }

  private static func firstQuotedString(after label: String, in body: Substring) -> String? {
    guard let labelRange = body.range(of: label) else { return nil }
    let remainder = body[labelRange.upperBound...]
    guard let open = remainder.firstIndex(of: "\""),
      let close = remainder[remainder.index(after: open)...].firstIndex(of: "\"")
    else { return nil }
    return String(remainder[remainder.index(after: open)..<close])
  }

  /// Target names inside the bracketed list following `label`. Each element is either a bare
  /// quoted string (an in-package target, e.g. `"ABSApi"`) or `.product(name: "X", package:
  /// "Y", …)` (an external dependency, e.g. GRDB). Only the `name:` value identifies the
  /// dependency in the layering graph. The `package:` value is the upstream package's own
  /// identity string (for GRDB, "GRDB.swift") and would leak in as a spurious second entry.
  private static func quotedStrings(inArrayAfter label: String, in body: Substring) -> Set<String> {
    guard let labelRange = body.range(of: label) else { return [] }
    let remainder = body[labelRange.upperBound...]
    guard let open = remainder.firstIndex(of: "[") else { return [] }

    var depth = 0
    var cursor = open
    var arrayEnd: Substring.Index?
    while cursor < remainder.endIndex {
      if remainder[cursor] == "[" { depth += 1 }
      if remainder[cursor] == "]" {
        depth -= 1
        if depth == 0 {
          arrayEnd = cursor
          break
        }
      }
      cursor = remainder.index(after: cursor)
    }
    guard let end = arrayEnd else { return [] }

    var names: Set<String> = []
    for element in topLevelElements(in: remainder[remainder.index(after: open)..<end]) {
      let trimmed = element.trimmingCharacters(in: .whitespacesAndNewlines)
      if trimmed.hasPrefix(".product(") {
        if let name = firstQuotedString(after: "name:", in: trimmed[...]) {
          names.insert(name)
        }
      } else if let open = trimmed.firstIndex(of: "\""),
        let close = trimmed[trimmed.index(after: open)...].firstIndex(of: "\"")
      {
        names.insert(String(trimmed[trimmed.index(after: open)..<close]))
      }
    }
    return names
  }

  /// Splits a comma-separated array body into its top-level elements, ignoring commas nested
  /// inside a `.product(...)` call's own parentheses.
  private static func topLevelElements(in body: Substring) -> [Substring] {
    var elements: [Substring] = []
    var depth = 0
    var elementStart = body.startIndex
    var cursor = body.startIndex
    while cursor < body.endIndex {
      let character = body[cursor]
      if character == "(" { depth += 1 }
      if character == ")" { depth -= 1 }
      if character == "," && depth == 0 {
        elements.append(body[elementStart..<cursor])
        elementStart = body.index(after: cursor)
      }
      cursor = body.index(after: cursor)
    }
    if elementStart < body.endIndex {
      elements.append(body[elementStart...])
    }
    return elements
  }

  /// Every `import` in a target's own sources, excluding system modules that are always
  /// available and are not part of the layering contract.
  static func imports(ofTarget name: String) throws -> Set<String> {
    let systemModules: Set<String> = [
      "Foundation", "Observation", "SwiftUI", "Security", "Combine", "OSLog", "Testing",
    ]
    let sources = packageRoot.appendingPathComponent("Sources/\(name)")
    return try imports(in: sources).subtracting(systemModules)
  }

  /// Every imported top-level module in Swift files below a directory. This is the same scan
  /// used by `imports(ofTarget:)`, extended for the App tree's release-audit checks.
  static func imports(in directory: URL) throws -> Set<String> {
    guard
      let walker = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil)
    else { return [] }

    var found: Set<String> = []
    for case let url as URL in walker where url.pathExtension == "swift" {
      let text = try String(contentsOf: url, encoding: .utf8)
      found.formUnion(importedModules(in: text))
    }
    return found
  }

  /// Parses import declarations from one source string so fixture text can exercise the same
  /// detector as the directory scan.
  static func importedModules(in source: String) -> Set<String> {
    var found: Set<String> = []
    for line in source.split(separator: "\n") {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      guard trimmed.hasPrefix("import ") || trimmed.hasPrefix("@testable import ") else {
        continue
      }
      guard let range = trimmed.range(of: "import ") else { continue }
      let module =
        trimmed[range.upperBound...]
        .split(separator: ".").first.map(String.init)?
        .trimmingCharacters(in: .whitespaces) ?? ""
      if !module.isEmpty {
        found.insert(module)
      }
    }
    return found
  }
}
