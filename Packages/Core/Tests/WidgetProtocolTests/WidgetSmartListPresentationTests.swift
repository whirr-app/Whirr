import Foundation
import Testing

@testable import WidgetProtocol

@Suite struct WidgetSmartListPresentationTests {

  private static func row(_ suffix: String) throws -> WidgetItem {
    try WidgetFixtures.item(
      token: "row-\(suffix)", kind: .feedEpisode, title: "Episode \(suffix)", chapterNumber: nil,
      coverFileName: nil)
  }

  private static func snapshot(stamp: WidgetAccountStamp?) throws -> WidgetSnapshot {
    guard let stamp else { return .signedOut(generatedAt: WidgetFixtures.generatedAt) }
    return try WidgetSnapshot(generatedAt: WidgetFixtures.generatedAt, accountStamp: stamp, skipBackSeconds: 15)
  }

  private static func lists(
    stamp: WidgetAccountStamp, isPlaying: Bool = false, _ lists: [WidgetSmartList]
  ) throws -> WidgetSmartLists {
    try WidgetSmartLists(
      generatedAt: WidgetFixtures.generatedAt, accountStamp: stamp, isPlaying: isPlaying, lists: lists)
  }

  @Test func withoutASnapshotOrListFileNothingIsDrawn() throws {
    let stamp = try WidgetFixtures.stamp()
    let file = try Self.lists(stamp: stamp, [])
    #expect(WidgetSmartListPresentation(snapshot: nil, lists: file, configuredListID: nil) == .unavailable)
    #expect(
      WidgetSmartListPresentation(snapshot: try Self.snapshot(stamp: stamp), lists: nil, configuredListID: nil)
        == .unavailable)
  }

  @Test func signedOutWinsOverAnyListFile() throws {
    let file = try Self.lists(
      stamp: WidgetFixtures.stamp(), [WidgetSmartList(id: 1, name: "A", matchCount: 0, items: [])])
    #expect(
      WidgetSmartListPresentation(snapshot: try Self.snapshot(stamp: nil), lists: file, configuredListID: 1)
        == .signedOut)
  }

  /// The snapshot and the list file are written separately; a list file left by the previous
  /// account must not draw under the next one's snapshot.
  @Test func aListFileFromAnotherAccountIsNotDrawn() throws {
    let other = try WidgetAccountStamp(
      accountIdentityHash: String(repeating: "b2", count: 32), serverIdentityHash: WidgetFixtures.serverHash)
    let file = try Self.lists(stamp: other, [WidgetSmartList(id: 1, name: "A", matchCount: 0, items: [])])
    let presentation = WidgetSmartListPresentation(
      snapshot: try Self.snapshot(stamp: WidgetFixtures.stamp()), lists: file, configuredListID: 1)
    #expect(presentation == .unavailable)
  }

  @Test func anUnconfiguredWidgetShowsTheFirstList() throws {
    let stamp = try WidgetFixtures.stamp()
    let first = try WidgetSmartList(id: 9, name: "First", matchCount: 0, items: [])
    let second = try WidgetSmartList(id: 3, name: "Second", matchCount: 0, items: [])
    let file = try Self.lists(stamp: stamp, [first, second])
    let snapshot = try Self.snapshot(stamp: stamp)
    #expect(
      WidgetSmartListPresentation(snapshot: snapshot, lists: file, configuredListID: nil)
        == .list(first, isPlaying: false))
    #expect(
      WidgetSmartListPresentation(snapshot: snapshot, lists: file, configuredListID: 3)
        == .list(second, isPlaying: false))
  }

  @Test func aDeletedListAndNoListsAreTold() throws {
    let stamp = try WidgetFixtures.stamp()
    let snapshot = try Self.snapshot(stamp: stamp)
    let one = try Self.lists(stamp: stamp, [WidgetSmartList(id: 1, name: "A", matchCount: 0, items: [])])
    let none = try Self.lists(stamp: stamp, [])
    #expect(WidgetSmartListPresentation(snapshot: snapshot, lists: one, configuredListID: 2) == .deleted)
    #expect(WidgetSmartListPresentation(snapshot: snapshot, lists: none, configuredListID: 2) == .noLists)
    #expect(WidgetSmartListPresentation(snapshot: snapshot, lists: none, configuredListID: nil) == .noLists)
  }

  @Test func theListButtonPlaysFromTheTopAndPausesOnlyWhileAListRowPlays() throws {
    let stamp = try WidgetFixtures.stamp()
    let top = try Self.row("a")
    let loaded = try Self.row("b")
    let list = try WidgetSmartList(id: 1, name: "A", matchCount: 2, items: [top, loaded], loadedToken: loaded.token)
    let idle = try WidgetSmartList(id: 2, name: "B", matchCount: 1, items: [try Self.row("c")])
    let empty = try WidgetSmartList(id: 3, name: "C", matchCount: 0, items: [])
    let snapshot = try Self.snapshot(stamp: stamp)

    let playing = WidgetSmartListPresentation(
      snapshot: snapshot, lists: try Self.lists(stamp: stamp, isPlaying: true, [list, idle, empty]),
      configuredListID: 1)
    #expect(playing.showsListPause)
    #expect(playing.playFromTop == top)

    let paused = WidgetSmartListPresentation(
      snapshot: snapshot, lists: try Self.lists(stamp: stamp, isPlaying: false, [list]), configuredListID: 1)
    #expect(!paused.showsListPause)

    let otherList = WidgetSmartListPresentation(
      snapshot: snapshot, lists: try Self.lists(stamp: stamp, isPlaying: true, [list, idle]), configuredListID: 2)
    #expect(!otherList.showsListPause, "playback from another list leaves this one offering play")

    let nothing = WidgetSmartListPresentation(
      snapshot: snapshot, lists: try Self.lists(stamp: stamp, isPlaying: true, [empty]), configuredListID: 3)
    #expect(nothing.playFromTop == nil)
    #expect(!nothing.showsListPause)
  }

  @Test func countsReadNaturally() {
    #expect(WidgetSmartListPresentation.countText(nil) == nil)
    #expect(WidgetSmartListPresentation.countText(0) == "No episodes")
    #expect(WidgetSmartListPresentation.countText(1) == "1 episode")
    #expect(WidgetSmartListPresentation.countText(12) == "12 episodes")
  }
}
