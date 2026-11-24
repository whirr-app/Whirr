import Foundation
import Testing

/// Each identifier named by an `*AccessibilityID` layout-order array (`expandedOrder`,
/// `sectionOrder`, `storageOrder`, `screenIdentifiers`) must be applied to something. Checked
/// against the source, since SwiftUI's rendered tree is not stable to assert against.
@Suite struct AccessibilityIDApplicationTests {

  // Every member named by an order array must be applied at an App source site. Runtime strings
  // do not keep the constant names after compilation.
  @Test("every identifier an order array names is applied by some screen")
  func orderedIdentifiersAreApplied() throws {
    let enums = try AccessibilityIDSource.declaringEnums()
    #expect(enums.isEmpty == false, "the scan found no *AccessibilityID enum to check")

    // NSString literal search. The app's source is megabytes, and `String.contains` walks it by
    // grapheme for each of several hundred needles.
    let appText =
      try ViewSourceScan.appSources()
      .map { try ViewSourceScan.executableText(of: $0) }
      .joined(separator: "\n") as NSString
    func applied(_ needle: String) -> Bool {
      appText.range(of: needle, options: .literal).location != NSNotFound
    }

    for declaration in enums {
      for (array, members) in declaration.orderArrays {
        #expect(members.isEmpty == false, "\(declaration.name).\(array) lists no identifier")
        for member in members {
          #expect(
            applied("\(declaration.name).\(member)") || applied("return \(member)") || applied(": \(member)"),
            """
            \(declaration.name).\(member) is listed in \(array) but never applied. \
            Either apply it with .accessibilityIdentifier, or drop it from \(array).
            """)
        }
      }
    }
  }

  @Test("order arrays name no identifier twice")
  func orderArraysDoNotRepeatAnIdentifier() throws {
    for declaration in try AccessibilityIDSource.declaringEnums() {
      for (array, members) in declaration.orderArrays {
        #expect(
          Set(members).count == members.count,
          "\(declaration.name).\(array) lists the same identifier more than once")
      }
    }
  }
}

/// Reads the `*AccessibilityID` enums as source. Order arrays hold resolved strings at runtime,
/// but a screen applies the constant, so membership is read before the compiler erases the names.
enum AccessibilityIDSource {
  struct Declaration {
    let name: String
    /// Order-array name to the constant names it lists.
    let orderArrays: [(String, [String])]
  }

  // Declarations are discovered from App source. Runtime strings do not keep the constant names
  // the policy checks.
  static func declaringEnums() throws -> [Declaration] {
    try ViewSourceScan.appSources()
      .filter { $0.lastPathComponent.hasSuffix("AccessibilityID.swift") }
      .sorted { $0.lastPathComponent < $1.lastPathComponent }
      .compactMap { source in
        let text = try ViewSourceScan.executableText(of: source)
        guard let name = enumName(in: text) else { return nil }
        let arrays = orderArrays(in: text)
        return arrays.isEmpty ? nil : Declaration(name: name, orderArrays: arrays)
      }
  }

  private static func enumName(in text: String) -> String? {
    for line in text.split(separator: "\n") where line.hasPrefix("enum ") {
      return String(line.dropFirst("enum ".count).prefix { $0.isLetter || $0.isNumber })
    }
    return nil
  }

  /// `static let someOrder: [String] = [ a, b, c ]`, plus `screenIdentifiers` under its own name.
  private static func orderArrays(in text: String) -> [(String, [String])] {
    var found: [(String, [String])] = []
    for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      guard trimmed.hasPrefix("static let"), trimmed.hasSuffix("["),
        let declared = trimmed.dropFirst("static let ".count).split(separator: " ").first
      else { continue }
      let name = String(declared.prefix { $0.isLetter || $0.isNumber })
      guard name.hasSuffix("Order") || name == "screenIdentifiers" else { continue }
      found.append((name, members(in: text, startingAfter: index)))
    }
    return found
  }

  private static func members(in text: String, startingAfter line: Int) -> [String] {
    var members: [String] = []
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
    for candidate in lines.dropFirst(line + 1) {
      let trimmed = candidate.trimmingCharacters(in: .whitespaces)
      if trimmed.hasPrefix("]") { break }
      // An array may list one identifier per line or several per line.
      for token in trimmed.split(separator: ",") {
        let member = token.trimmingCharacters(in: .whitespaces)
        guard member.isEmpty == false, member.hasPrefix("\"") == false else { continue }
        members.append(member)
      }
    }
    return members
  }
}
