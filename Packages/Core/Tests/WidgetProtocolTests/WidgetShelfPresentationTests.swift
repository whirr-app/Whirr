import Foundation
import Testing

@testable import WidgetProtocol

@Suite struct WidgetShelfPresentationTests {
  private func token(_ index: Int) -> String { "tok-\(index)" }

  private func snapshot(
    count: Int, nowPlaying: (token: String?, isPlaying: Bool)? = nil
  ) throws -> WidgetSnapshot {
    let items = try (0..<count).map {
      try WidgetFixtures.item(token: token($0), coverFileName: nil)
    }
    return try WidgetSnapshot(
      generatedAt: WidgetFixtures.generatedAt, accountStamp: WidgetFixtures.stamp(),
      nowPlaying: nowPlaying.map { try WidgetNowPlaying(token: $0.token, isPlaying: $0.isPlaying) },
      skipBackSeconds: 15, continueListening: items)
  }

  @Test func emptyShelfHasNoPresentation() throws {
    #expect(WidgetShelfPresentation(snapshot: try snapshot(count: 0)) == nil)
  }

  @Test func currentDefaultsToTheMostRecentItem() throws {
    let presentation = try #require(WidgetShelfPresentation(snapshot: snapshot(count: 3)))
    #expect(presentation.current.token == token(0))
    #expect(presentation.others.map(\.token) == [token(1), token(2)])
    #expect(!presentation.isCurrentPlaying)
  }

  @Test func nowPlayingItemIsCurrentAndTheRestKeepTheirOrder() throws {
    let presentation = try #require(
      WidgetShelfPresentation(snapshot: snapshot(count: 4, nowPlaying: (token(2), true))))
    #expect(presentation.current.token == token(2))
    #expect(presentation.others.map(\.token) == [token(0), token(1), token(3)])
    #expect(presentation.showsPause(for: presentation.current))
    #expect(!presentation.showsPause(for: presentation.others[0]))
  }

  @Test func nowPlayingOffTheShelfFallsBackToTheFirstItem() throws {
    let noToken = try #require(
      WidgetShelfPresentation(snapshot: snapshot(count: 2, nowPlaying: (nil, true))))
    #expect(noToken.current.token == token(0))
    #expect(!noToken.isCurrentPlaying)
    let unknown = try #require(
      WidgetShelfPresentation(snapshot: snapshot(count: 2, nowPlaying: ("missing", true))))
    #expect(unknown.current.token == token(0))
    #expect(!unknown.isCurrentPlaying)
  }

  @Test func pausedNowPlayingOffersPlay() throws {
    let presentation = try #require(
      WidgetShelfPresentation(snapshot: snapshot(count: 2, nowPlaying: (token(1), false))))
    #expect(presentation.current.token == token(1))
    #expect(!presentation.showsPause(for: presentation.current))
  }

  @Test(arguments: [
    (0.0, "<1m left"), (59.9, "<1m left"), (60.0, "1m left"), (90.0, "2m left"),
    (749.0, "12m left"), (3_540.0, "59m left"), (3_600.0, "1h left"), (11_520.0, "3h 12m left"),
  ])
  func timeLeftFormatting(seconds: Double, expected: String) {
    #expect(WidgetShelfPresentation.timeLeft(remainingSeconds: seconds) == expected)
  }

  @Test func timeLeftIsAbsentWhenUnknownOrInvalid() {
    #expect(WidgetShelfPresentation.timeLeft(remainingSeconds: nil) == nil)
    #expect(WidgetShelfPresentation.timeLeft(remainingSeconds: -1) == nil)
    #expect(WidgetShelfPresentation.timeLeft(remainingSeconds: .nan) == nil)
  }

  @Test func accessorySummaryNeverIncludesTitleOrSubtitle() throws {
    let withChapter = try WidgetFixtures.item(chapterNumber: 7)
    let summary = try #require(WidgetShelfPresentation.accessorySummary(for: withChapter))
    #expect(summary == "Ch 7 · 6h left")
    #expect(!summary.contains(withChapter.title))

    let without = try WidgetFixtures.item(chapterNumber: nil)
    #expect(WidgetShelfPresentation.accessorySummary(for: without) == "6h left")

    let unknown = try WidgetItem(
      token: "t", kind: .feedEpisode, title: "Episode", progressFraction: 0.1)
    #expect(WidgetShelfPresentation.accessorySummary(for: unknown) == nil)
  }
}
