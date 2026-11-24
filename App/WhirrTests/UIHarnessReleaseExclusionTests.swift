import Foundation
import Testing

/// The UI harness is compiled out of Release. Nothing that ships may name its entry points, and
/// every harness source must sit inside the gate.
///
/// `WhirrApp.swift` is the only shipping file allowed to mention them, and only inside its
/// `#if DEBUG || PERF_INVESTIGATION` branches: the launch swap to `UIHarnessRootView`. A reference
/// in the `#else` branch would be a Release build error, which is what this scan would otherwise
/// leave to a Release build someone has to remember to run.
@Suite("UI harness release exclusion")
struct UIHarnessReleaseExclusionTests {
  /// Symbols the harness alone defines. `UIHarness` itself is not here: `WhirrApp` also reads
  /// `UIHarness.isActive` and that is inside the same gate.
  private static let entryPoints = ["UIHarnessRootView", "UIHarnessScenario"]

  @Test("no shipping source names the harness entry points")
  func shippingSourcesDoNotReferenceTheHarness() throws {
    var leaks: [String] = []
    for source in try ViewSourceScan.appSources() {
      let text = try ViewSourceScan.commentFreeText(of: source)
      let shipping = Self.withoutHarnessGates(text)
      let named = Self.entryPoints.filter { shipping.contains($0) }
      guard named.isEmpty == false else { continue }
      leaks.append("\(source.lastPathComponent): \(named.joined(separator: ", "))")
    }
    #expect(
      leaks.isEmpty,
      """
      shipping source names the Release-excluded UI harness: \(leaks.joined(separator: "; ")). \
      Put the reference inside `#if DEBUG || PERF_INVESTIGATION`, or use the production path.
      """)
  }

  @Test("every harness source is declarations inside the Release gate")
  func harnessSourcesAreGated() throws {
    let harness = try ViewSourceScan.appSources().filter {
      $0.lastPathComponent.hasPrefix("UIHarness")
    }
    // A floor, not a count: the split moves files, and an exact number would be a gate to update on
    // every move. A wrong root or a renamed prefix must still fail loudly.
    #expect(harness.count >= 10, "found \(harness.count) harness sources; the scan is reading nothing")

    var ungated: [String] = []
    for source in harness {
      let text = try ViewSourceScan.commentFreeText(of: source)
      let outside = Self.withoutHarnessGates(text)
        .components(separatedBy: "\n")
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { line in
          line.isEmpty == false && line.hasPrefix("import ") == false
            && line.hasPrefix("//") == false && line.hasPrefix("///") == false
            && line.hasPrefix("/*") == false && line.hasPrefix("*") == false
        }
      guard outside.isEmpty == false else { continue }
      ungated.append("\(source.lastPathComponent): \(outside.first ?? "")")
    }
    #expect(
      ungated.isEmpty,
      """
      harness source outside `#if DEBUG || PERF_INVESTIGATION`, so it would ship: \
      \(ungated.joined(separator: "; "))
      """)
  }

  @Test("the scan finds the launch swap it is meant to allow")
  func theLaunchSwapIsInsideTheGate() throws {
    // Guards the stripper itself: if it dropped too much, the checks above would pass vacuously.
    let text = try ViewSourceScan.commentFreeText(of: ViewSourceScan.source(named: "WhirrApp.swift"))
    #expect(text.contains("UIHarnessRootView"), "the harness launch swap moved; update this scan")
    #expect(Self.withoutHarnessGates(text).contains("UIHarnessRootView") == false)
  }

  /// The source with the true branch of every gate that compiles the harness out of Release removed.
  ///
  /// Only the true branch: an `#else` is the shipping branch, so a harness reference there is a real
  /// leak and stays in the text the scan reads. A line is dropped while any enclosing frame is a
  /// dropped branch, so nesting cannot smuggle one through.
  private static func withoutHarnessGates(_ text: String) -> String {
    struct Frame {
      var dropsTrueBranch: Bool
      var inElseBranch: Bool
    }
    var frames: [Frame] = []
    var kept: [String] = []
    for line in text.components(separatedBy: "\n") {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if trimmed.hasPrefix("#if") {
        // Inside an already-dropped branch the nested condition is irrelevant.
        if frames.contains(where: { $0.dropsTrueBranch && $0.inElseBranch == false }) {
          frames.append(Frame(dropsTrueBranch: false, inElseBranch: false))
        } else {
          frames.append(Frame(dropsTrueBranch: compilesHarnessOut(trimmed), inElseBranch: false))
        }
        continue
      }
      if trimmed.hasPrefix("#else"), var top = frames.popLast() {
        top.inElseBranch = true
        frames.append(top)
        continue
      }
      if trimmed.hasPrefix("#endif") {
        if frames.isEmpty == false { frames.removeLast() }
        continue
      }
      if frames.contains(where: { $0.dropsTrueBranch && $0.inElseBranch == false }) { continue }
      kept.append(line)
    }
    return kept.joined(separator: "\n")
  }

  /// Whether a `#if` condition removes its branch from Release. `#if !DEBUG` is a Release branch and
  /// is deliberately not one of these.
  private static func compilesHarnessOut(_ directive: String) -> Bool {
    let condition = directive.dropFirst(3)
    guard condition.trimmingCharacters(in: .whitespaces).hasPrefix("!") == false else {
      return false
    }
    return condition.contains("DEBUG") || condition.contains("PERF_INVESTIGATION")
  }
}
