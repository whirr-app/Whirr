import Foundation

@testable import WidgetProtocol

enum WidgetFixtures {
  static let accountHash = String(repeating: "a1", count: 32)
  static let serverHash = String(repeating: "0f", count: 32)
  static let generatedAt = Date(timeIntervalSinceReferenceDate: 815_000_000)

  static func stamp() throws -> WidgetAccountStamp {
    try WidgetAccountStamp(accountIdentityHash: accountHash, serverIdentityHash: serverHash)
  }

  static func item(
    token: String = "4F1C2B8A-3E1D-4A6B-9C0D-2E5F7A8B9C01",
    kind: WidgetItemKind = .book,
    title: String = "The Left Hand of Darkness",
    subtitle: String? = "Ursula K. Le Guin",
    chapterNumber: Int? = 7,
    coverFileName: String? = "4F1C2B8A-3E1D-4A6B-9C0D-2E5F7A8B9C01.jpg"
  ) throws -> WidgetItem {
    try WidgetItem(
      token: token, kind: kind, title: title, subtitle: subtitle, progressFraction: 0.42,
      remainingSeconds: 21_600, chapterNumber: chapterNumber, coverFileName: coverFileName,
      isDownloaded: true)
  }

  static func stats() throws -> WidgetStats {
    try WidgetStats(
      days: [
        .init(date: "2026-10-30", seconds: 0),
        .init(date: "2026-10-31", seconds: 1_800),
        .init(date: "2026-11-01", seconds: 3_600),
      ],
      streakDaysBeforeWindow: 12, totalSeconds: 1_234_567, fetchedAt: generatedAt)
  }

  /// A signed-in snapshot at every bound: two full shelves of maximum-length text and stats.
  static func largest() throws -> WidgetSnapshot {
    let longTitle = String(repeating: "é", count: WidgetSnapshotLimits.maxTextBytes / 2)
    func shelf(_ prefix: String) throws -> [WidgetItem] {
      try (0..<WidgetSnapshotLimits.maxItemsPerShelf).map { index in
        let token = "\(prefix)\(String(repeating: "0", count: 63 - prefix.count))\(index)"
        return try item(
          token: token, title: longTitle, subtitle: longTitle, coverFileName: "\(token).jpg")
      }
    }
    let days = try (1...WidgetStats.maxDays).map {
      try WidgetStats.Day(date: String(format: "2026-11-%02d", $0), seconds: 86_400)
    }
    return try WidgetSnapshot(
      generatedAt: generatedAt, accountStamp: stamp(),
      nowPlaying: WidgetNowPlaying(token: nil, isPlaying: true), skipBackSeconds: 90,
      continueListening: shelf("c"), latestEpisodes: shelf("l"),
      stats: WidgetStats(
        days: days, streakDaysBeforeWindow: Int.max, totalSeconds: 1e12, fetchedAt: generatedAt))
  }
}
