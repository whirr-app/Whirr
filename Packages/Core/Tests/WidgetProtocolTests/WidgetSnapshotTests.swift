import Foundation
import Testing

@testable import WidgetProtocol

@Suite struct WidgetSnapshotTests {

  @Test func signedOutSnapshotCarriesNothingAndIsValid() throws {
    let snapshot = WidgetSnapshot.signedOut(generatedAt: WidgetFixtures.generatedAt)
    try snapshot.validate()
    #expect(snapshot.accountStamp == nil)
    #expect(snapshot.continueListening.isEmpty && snapshot.latestEpisodes.isEmpty)
    #expect(snapshot.nowPlaying == nil && snapshot.skipBackSeconds == nil && snapshot.stats == nil)
  }

  /// Logout writes the signed-out shape; any of the previous account's values in it would be
  /// drawn on a Lock Screen that no longer belongs to that account.
  @Test func signedOutSnapshotRefusesEveryAccountValue() throws {
    let at = WidgetFixtures.generatedAt
    let attempts: [() throws -> WidgetSnapshot] = [
      { try WidgetSnapshot(generatedAt: at, accountStamp: nil, continueListening: [WidgetFixtures.item()]) },
      { try WidgetSnapshot(generatedAt: at, accountStamp: nil, latestEpisodes: [WidgetFixtures.item()]) },
      { try WidgetSnapshot(generatedAt: at, accountStamp: nil, skipBackSeconds: 15) },
      {
        try WidgetSnapshot(
          generatedAt: at, accountStamp: nil, nowPlaying: WidgetNowPlaying(token: nil, isPlaying: false))
      },
      { try WidgetSnapshot(generatedAt: at, accountStamp: nil, stats: WidgetFixtures.stats()) },
    ]
    for attempt in attempts {
      #expect(throws: WidgetProtocolError.invalidValue) { try attempt() }
    }
  }

  @Test func signedInSnapshotNeedsAnOfferedSkipInterval() throws {
    let stamp = try WidgetFixtures.stamp()
    #expect(throws: WidgetProtocolError.invalidValue) {
      try WidgetSnapshot(generatedAt: WidgetFixtures.generatedAt, accountStamp: stamp)
    }
    #expect(throws: WidgetProtocolError.invalidValue) {
      try WidgetSnapshot(generatedAt: WidgetFixtures.generatedAt, accountStamp: stamp, skipBackSeconds: 20)
    }
    for interval in WidgetSnapshotLimits.skipIntervals {
      _ = try WidgetSnapshot(
        generatedAt: WidgetFixtures.generatedAt, accountStamp: stamp, skipBackSeconds: interval)
    }
  }

  @Test func shelvesAreBoundedAndTokensUniqueWithinEach() throws {
    let stamp = try WidgetFixtures.stamp()
    let five = try (0..<5).map { try WidgetFixtures.item(token: "token-\($0)", coverFileName: nil) }
    #expect(throws: WidgetProtocolError.tooManyItems) {
      try WidgetSnapshot(
        generatedAt: WidgetFixtures.generatedAt, accountStamp: stamp, skipBackSeconds: 15,
        continueListening: five)
    }
    let item = try WidgetFixtures.item()
    #expect(throws: WidgetProtocolError.invalidValue) {
      try WidgetSnapshot(
        generatedAt: WidgetFixtures.generatedAt, accountStamp: stamp, skipBackSeconds: 15,
        latestEpisodes: [item, item])
    }
    // The same episode can be both in progress and among the latest: one token on two shelves.
    _ = try WidgetSnapshot(
      generatedAt: WidgetFixtures.generatedAt, accountStamp: stamp, skipBackSeconds: 15,
      continueListening: [item], latestEpisodes: [item])
  }

  @Test func accountStampMustBeTheSHA256HexTheBuilderProduces() {
    for (account, server) in [
      (WidgetFixtures.accountHash, ""),
      (String(WidgetFixtures.accountHash.dropLast()), WidgetFixtures.serverHash),
      (WidgetFixtures.accountHash.uppercased(), WidgetFixtures.serverHash),
      ("user@example.com", WidgetFixtures.serverHash),
      (WidgetFixtures.accountHash, "https://abs.example.com"),
    ] {
      #expect(throws: WidgetProtocolError.invalidValue) {
        try WidgetAccountStamp(accountIdentityHash: account, serverIdentityHash: server)
      }
    }
  }

  @Test func itemTextRefusesWhatALeakedIdentifierWouldLookLike() {
    let cases: [(String, WidgetProtocolError)] = [
      ("", .invalidValue),
      ("Line\nbreak", .invalidValue),
      ("https://abs.example.com/api/items/li_123", .forbiddenText),
      ("file:///var/mobile/Containers/cover.jpg", .forbiddenText),
      ("/private/var/mobile", .forbiddenText),
      (String(repeating: "a", count: WidgetSnapshotLimits.maxTextBytes + 1), .oversizedText),
    ]
    for (title, error) in cases {
      #expect(throws: error) { try WidgetFixtures.item(title: title) }
      #expect(throws: error) { try WidgetFixtures.item(subtitle: title) }
    }
    // Ordinary punctuation, including a colon and slashes in a title, is fine.
    #expect(throws: Never.self) { try WidgetFixtures.item(title: "Episode 12: Ask/Answer") }
  }

  @Test func tokensAreOpaqueGeneratedValuesOnly() {
    for token in ["", String(repeating: "a", count: 65), "li_0123", "a b", "../x", "é"] {
      #expect(throws: WidgetProtocolError.invalidValue) { try WidgetFixtures.item(token: token) }
      #expect(throws: WidgetProtocolError.invalidValue) {
        try WidgetNowPlaying(token: token, isPlaying: true)
      }
    }
  }

  @Test func itemNumbersStayInRange() {
    for fraction in [-0.01, 1.01, .nan, .infinity] {
      #expect(throws: WidgetProtocolError.invalidValue) {
        try WidgetItem(token: "t", kind: .book, title: "T", progressFraction: fraction)
      }
    }
    for remaining in [-1, Double.nan, .infinity] {
      #expect(throws: WidgetProtocolError.invalidValue) {
        try WidgetItem(
          token: "t", kind: .book, title: "T", progressFraction: 0, remainingSeconds: remaining)
      }
    }
  }

  /// A chapter number is the book's own; an episode has none to show.
  @Test func onlyABookCarriesAChapterNumber() {
    #expect(throws: WidgetProtocolError.invalidValue) { try WidgetFixtures.item(chapterNumber: 0) }
    for kind in [WidgetItemKind.serverEpisode, .feedEpisode] {
      #expect(throws: WidgetProtocolError.invalidValue) {
        try WidgetFixtures.item(kind: kind, chapterNumber: 3)
      }
      #expect(throws: Never.self) { try WidgetFixtures.item(kind: kind, chapterNumber: nil) }
    }
  }

  @Test func statsDayKeysNameRealCalendarDays() throws {
    for date in [
      "2026-11-1", "2026/11/01", "2026-13-01", "2026-11-00", "26-11-01", "2026-1a-01", "0000-01-01",
      "2026-02-29", "2026-04-31", "2026-11-01T00:00",
    ] {
      #expect(throws: WidgetProtocolError.invalidValue) { try WidgetStats.Day(date: date, seconds: 0) }
    }
    #expect(throws: WidgetProtocolError.invalidValue) {
      try WidgetStats.Day(date: "2026-11-01", seconds: -1)
    }
    for date in ["2028-02-29", "2000-02-29", "2026-12-31"] {
      #expect(throws: Never.self) { try WidgetStats.Day(date: date, seconds: 0) }
    }
    #expect(throws: WidgetProtocolError.invalidValue) { try WidgetStats.Day(date: "2100-02-29", seconds: 0) }
  }

  /// The extension counts the streak back from the newest day, so the window is consecutive days,
  /// oldest first, with no gap that would read as a missed day.
  @Test func statsDaysAreConsecutiveOldestFirst() throws {
    func stats(_ dates: [String]) throws -> WidgetStats {
      try WidgetStats(
        days: dates.map { try WidgetStats.Day(date: $0, seconds: 60) }, streakDaysBeforeWindow: 0,
        totalSeconds: 0, fetchedAt: WidgetFixtures.generatedAt)
    }
    for dates in [
      ["2026-11-02", "2026-11-01"],
      ["2026-11-01", "2026-11-01"],
      ["2026-11-01", "2026-11-03"],
      ["2026-02-28", "2026-03-02"],
    ] {
      #expect(throws: WidgetProtocolError.invalidValue) { try stats(dates) }
    }
    for dates in [
      [], ["2026-11-01"], ["2026-10-31", "2026-11-01"], ["2026-12-31", "2027-01-01"],
      ["2028-02-28", "2028-02-29", "2028-03-01"], ["2026-02-28", "2026-03-01"],
    ] {
      #expect(throws: Never.self) { try stats(dates) }
    }
    let nine = (1...9).map { String(format: "2026-11-%02d", $0) }
    #expect(throws: WidgetProtocolError.invalidValue) { try stats(nine) }
    #expect(throws: WidgetProtocolError.invalidValue) {
      try WidgetStats(
        days: [], streakDaysBeforeWindow: -1, totalSeconds: 0, fetchedAt: WidgetFixtures.generatedAt)
    }
  }
}
