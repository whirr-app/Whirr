import Foundation
import Testing

/// `RootView.body` is the root of the whole app. Anything it reads through Observation makes the
/// root a dependent, and a root invalidation rebuilds `LibraryShellView`, re-roots every tab's
/// hosting view and re-runs Home. Play and pause must therefore not be read there. The intent
/// observer lives in its own modifier, whose body is the only node that depends on it.
@Suite("The root view does not depend on playback state")
struct RootViewPlaybackIsolationTests {
  /// A source-level check, because body invalidation cannot be observed from a unit test. It reads
  /// only the `RootView` declaration (up to its closing brace at column zero), so a modifier
  /// declared later in the same file may read the player.
  @Test("RootView's own declaration reads nothing from the player")
  func rootViewDoesNotReadThePlayer() throws {
    let file = ViewSourceScan.repositoryRoot().appending(path: "App/Whirr/RootView.swift")
    let lines = try ViewSourceScan.executableText(of: file)
      .split(separator: "\n", omittingEmptySubsequences: false)
    let start = try #require(lines.firstIndex { $0.hasPrefix("struct RootView: View {") })
    let end = try #require(lines[start...].firstIndex { $0 == "}" })
    let declaration = lines[start...end].joined(separator: "\n")

    #expect(declaration.contains("hardware.player.") == false)
    #expect(declaration.contains("isPlaybackIntended") == false)
  }
}
