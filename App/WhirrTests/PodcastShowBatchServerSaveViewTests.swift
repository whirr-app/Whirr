import Foundation
import Testing

@testable import Whirr

/// Where the show's server-save state is read. The wiring rules around batch save are source rules
/// in `Scripts/source-rules/podcasts.toml`.
@Suite struct PodcastShowBatchServerSaveViewTests {
  /// A batch save writes the show's status maps on every attempt transition. Those reads must
  /// live in the row view's own `body`: read from the content view, each write rebuilt the whole
  /// section and its `List` diff, which is what made a multi-episode save stall the screen.
  @Test func serverSaveStateIsReadByTheRowNotTheList() throws {
    let content = try Self.viewSource(named: "PodcastShowContentView.swift")
    let marker = "private struct PodcastShowEpisodeRow: View"
    let parts = content.components(separatedBy: marker)
    #expect(parts.count == 2)
    let list = try #require(parts.first)
    let row = try #require(parts.last)
    for read in [
      "isBatchServerSaveMember(", "serverSaveStatus(for:", "serverSavePreflightPresence(for:",
      "serverMutationCapability", "isCredentialedNativeFeed", "downloadProgressFraction(for:",
    ] {
      #expect(list.contains(read) == false, "\(read) is read above the row")
      #expect(row.contains(read), "\(read) is not read by the row")
    }
  }

  private static func viewSource(named name: String) throws -> String {
    let source = try #require(ViewSourceScan.appSources().first { $0.lastPathComponent == name })
    return try ViewSourceScan.executableText(of: source)
  }
}
