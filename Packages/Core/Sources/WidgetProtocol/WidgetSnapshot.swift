import Foundation

/// What the app writes into the App Group for the widget extension to draw. It is the extension's
/// only input (it never opens the database, network or Keychain), so everything a widget shows
/// must be here and nothing more.
///
/// A snapshot without an account stamp is the signed-out state and carries nothing else. Values
/// are validated on construction and after decoding, so a readable file is a drawable one.
public struct WidgetSnapshot: Codable, Sendable, Equatable {
  public static let currentSchemaVersion = 1

  public let schemaVersion: Int
  public let generatedAt: Date
  public let accountStamp: WidgetAccountStamp?
  public let nowPlaying: WidgetNowPlaying?
  /// The listener's configured skip-back interval, so the control shows the right number.
  /// `nil` only when signed out.
  public let skipBackSeconds: Int?
  /// Most recent first, at most `WidgetSnapshotLimits.maxItemsPerShelf`.
  public let continueListening: [WidgetItem]
  /// Newest first, at most `WidgetSnapshotLimits.maxItemsPerShelf`.
  public let latestEpisodes: [WidgetItem]
  /// Cached listening-stats figures.
  public let stats: WidgetStats?

  public init(
    generatedAt: Date,
    accountStamp: WidgetAccountStamp?,
    nowPlaying: WidgetNowPlaying? = nil,
    skipBackSeconds: Int? = nil,
    continueListening: [WidgetItem] = [],
    latestEpisodes: [WidgetItem] = [],
    stats: WidgetStats? = nil
  ) throws {
    self.schemaVersion = Self.currentSchemaVersion
    self.generatedAt = generatedAt
    self.accountStamp = accountStamp
    self.nowPlaying = nowPlaying
    self.skipBackSeconds = skipBackSeconds
    self.continueListening = continueListening
    self.latestEpisodes = latestEpisodes
    self.stats = stats
    try validate()
  }

  /// The state written on logout, account removal and before any account resolves.
  public static func signedOut(generatedAt: Date) -> WidgetSnapshot {
    WidgetSnapshot(signedOutAt: generatedAt)
  }

  /// The signed-out shape needs no validation beyond the date, which the encoder re-checks.
  private init(signedOutAt generatedAt: Date) {
    self.schemaVersion = Self.currentSchemaVersion
    self.generatedAt = generatedAt
    self.accountStamp = nil
    self.nowPlaying = nil
    self.skipBackSeconds = nil
    self.continueListening = []
    self.latestEpisodes = []
    self.stats = nil
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let version = try container.decode(Int.self, forKey: .schemaVersion)
    guard version == Self.currentSchemaVersion else {
      throw WidgetProtocolError.unsupportedVersion(version)
    }
    self.schemaVersion = version
    self.generatedAt = try container.decode(Date.self, forKey: .generatedAt)
    self.accountStamp = try container.decodeIfPresent(WidgetAccountStamp.self, forKey: .accountStamp)
    self.nowPlaying = try container.decodeIfPresent(WidgetNowPlaying.self, forKey: .nowPlaying)
    self.skipBackSeconds = try container.decodeIfPresent(Int.self, forKey: .skipBackSeconds)
    self.continueListening = try container.decode([WidgetItem].self, forKey: .continueListening)
    self.latestEpisodes = try container.decode([WidgetItem].self, forKey: .latestEpisodes)
    self.stats = try container.decodeIfPresent(WidgetStats.self, forKey: .stats)
    try validate()
  }

  public func validate() throws {
    guard schemaVersion == Self.currentSchemaVersion else {
      throw WidgetProtocolError.unsupportedVersion(schemaVersion)
    }
    guard generatedAt.timeIntervalSinceReferenceDate.isFinite else {
      throw WidgetProtocolError.invalidValue
    }
    guard let accountStamp else {
      // Signed out: nothing about the previous account may survive into the file.
      guard nowPlaying == nil, skipBackSeconds == nil, continueListening.isEmpty,
        latestEpisodes.isEmpty, stats == nil
      else { throw WidgetProtocolError.invalidValue }
      return
    }
    try accountStamp.validate()
    try nowPlaying?.validate()
    guard let skipBackSeconds, WidgetSnapshotLimits.skipIntervals.contains(skipBackSeconds) else {
      throw WidgetProtocolError.invalidValue
    }
    for shelf in [continueListening, latestEpisodes] {
      guard shelf.count <= WidgetSnapshotLimits.maxItemsPerShelf else {
        throw WidgetProtocolError.tooManyItems
      }
      guard Set(shelf.map(\.token)).count == shelf.count else {
        throw WidgetProtocolError.invalidValue
      }
      for item in shelf { try item.validate() }
    }
    try stats?.validate()
  }

  private enum CodingKeys: String, CodingKey {
    case schemaVersion, generatedAt, accountStamp, nowPlaying, skipBackSeconds, continueListening,
      latestEpisodes, stats
  }
}

public enum WidgetSnapshotLimits {
  public static let maxItemsPerShelf = 4
  /// Titles and subtitles are drawn on at most two lines; anything longer is a mapping fault.
  public static let maxTextBytes = 256
  /// The skip intervals the app offers, as `WatchCatalogueSnapshot` accepts them.
  public static let skipIntervals: Set<Int> = [10, 15, 30, 45, 60, 75, 90]
  /// Comfortably above the largest valid snapshot (eight items of maximum-length text plus
  /// stats, about 7 KB), so the bound only catches a file that is not a snapshot at all.
  public static let maxEncodedBytes = 16 * 1024
}

/// The account a snapshot belongs to, as one-way hashes. The publisher fills it from the same
/// recipe the Watch catalogue uses; the extension only compares it, so it can tell a snapshot left
/// by a previous account from the current one's.
public struct WidgetAccountStamp: Codable, Sendable, Equatable, Hashable {
  public let accountIdentityHash: String
  public let serverIdentityHash: String

  public init(accountIdentityHash: String, serverIdentityHash: String) throws {
    self.accountIdentityHash = accountIdentityHash
    self.serverIdentityHash = serverIdentityHash
    try validate()
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.accountIdentityHash = try container.decode(String.self, forKey: .accountIdentityHash)
    self.serverIdentityHash = try container.decode(String.self, forKey: .serverIdentityHash)
    try validate()
  }

  public func validate() throws {
    guard WidgetValidation.isLowercaseHex(accountIdentityHash, length: 64),
      WidgetValidation.isLowercaseHex(serverIdentityHash, length: 64)
    else { throw WidgetProtocolError.invalidValue }
  }

  private enum CodingKeys: String, CodingKey { case accountIdentityHash, serverIdentityHash }
}

/// What is playing, for the play/pause control and the row marked as current. `isPlaying` is the
/// listener's intent (`PlayerController.isPlaybackIntended`), not the engine's phase, so a buffer
/// or a seek does not flip the control.
public struct WidgetNowPlaying: Codable, Sendable, Equatable {
  /// The current item's token when it is on a shelf in this snapshot; otherwise `nil`.
  public let token: String?
  public let isPlaying: Bool

  public init(token: String?, isPlaying: Bool) throws {
    self.token = token
    self.isPlaying = isPlaying
    try validate()
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.token = try container.decodeIfPresent(String.self, forKey: .token)
    self.isPlaying = try container.decode(Bool.self, forKey: .isPlaying)
    try validate()
  }

  public func validate() throws {
    if let token { try WidgetValidation.validateToken(token) }
  }

  private enum CodingKeys: String, CodingKey { case token, isPlaying }
}

public enum WidgetItemKind: String, Codable, Sendable, Equatable {
  case book
  /// An Audiobookshelf-hosted podcast episode.
  case serverEpisode
  /// A native RSS episode (ADR 0004).
  case feedEpisode
}

/// One row on a shelf. The token is opaque and per publication: the app resolves it through a
/// map it keeps in its own container, so no server identifier reaches the App Group, Siri or the
/// intent's parameters.
public struct WidgetItem: Codable, Sendable, Equatable {
  public let token: String
  public let kind: WidgetItemKind
  public let title: String
  /// Author for a book, show for an episode.
  public let subtitle: String?
  public let progressFraction: Double
  /// Media seconds left in the item, before any playback-rate adjustment; `nil` when the duration
  /// is unknown.
  public let remainingSeconds: Double?
  /// The one-based chapter number, for a book with chapters only.
  public let chapterNumber: Int?
  /// A file in the App Group's covers folder; `nil` when no cover has been exported.
  public let coverFileName: String?
  public let isDownloaded: Bool

  public init(
    token: String,
    kind: WidgetItemKind,
    title: String,
    subtitle: String? = nil,
    progressFraction: Double,
    remainingSeconds: Double? = nil,
    chapterNumber: Int? = nil,
    coverFileName: String? = nil,
    isDownloaded: Bool = false
  ) throws {
    self.token = token
    self.kind = kind
    self.title = title
    self.subtitle = subtitle
    self.progressFraction = progressFraction
    self.remainingSeconds = remainingSeconds
    self.chapterNumber = chapterNumber
    self.coverFileName = coverFileName
    self.isDownloaded = isDownloaded
    try validate()
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.token = try container.decode(String.self, forKey: .token)
    self.kind = try container.decode(WidgetItemKind.self, forKey: .kind)
    self.title = try container.decode(String.self, forKey: .title)
    self.subtitle = try container.decodeIfPresent(String.self, forKey: .subtitle)
    self.progressFraction = try container.decode(Double.self, forKey: .progressFraction)
    self.remainingSeconds = try container.decodeIfPresent(Double.self, forKey: .remainingSeconds)
    self.chapterNumber = try container.decodeIfPresent(Int.self, forKey: .chapterNumber)
    self.coverFileName = try container.decodeIfPresent(String.self, forKey: .coverFileName)
    self.isDownloaded = try container.decode(Bool.self, forKey: .isDownloaded)
    try validate()
  }

  public func validate() throws {
    try WidgetValidation.validateToken(token)
    try WidgetValidation.validateText(title)
    if let subtitle { try WidgetValidation.validateText(subtitle) }
    guard progressFraction.isFinite, (0...1).contains(progressFraction) else {
      throw WidgetProtocolError.invalidValue
    }
    if let remainingSeconds {
      guard remainingSeconds.isFinite, remainingSeconds >= 0 else {
        throw WidgetProtocolError.invalidValue
      }
    }
    if let chapterNumber {
      guard kind == .book, chapterNumber >= 1 else { throw WidgetProtocolError.invalidValue }
    }
    if let coverFileName { try WidgetStorageLayout.validateCoverFileName(coverFileName) }
  }

  private enum CodingKeys: String, CodingKey {
    case token, kind, title, subtitle, progressFraction, remainingSeconds, chapterNumber,
      coverFileName, isDownloaded
  }
}

/// The cached listening-stats figures. The extension derives today's total and the
/// streak at render time, so the widget stays right across midnight without a fetch.
///
/// Eight days cannot express a longer streak, so the snapshot also carries how many qualifying
/// days ran consecutively up to the day before the window's first.
public struct WidgetStats: Codable, Sendable, Equatable {
  /// One server calendar day, keyed `YYYY-MM-DD` as `ListeningStatsSnapshot.Day` keys it.
  public struct Day: Codable, Sendable, Equatable {
    public let date: String
    public let seconds: Double

    public init(date: String, seconds: Double) throws {
      self.date = date
      self.seconds = seconds
      try validate()
    }

    public init(from decoder: Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      self.date = try container.decode(String.self, forKey: .date)
      self.seconds = try container.decode(Double.self, forKey: .seconds)
      try validate()
    }

    public func validate() throws {
      guard WidgetValidation.dayNumber(date) != nil, seconds.isFinite, seconds >= 0 else {
        throw WidgetProtocolError.invalidValue
      }
    }

    private enum CodingKeys: String, CodingKey { case date, seconds }
  }

  public static let maxDays = 8

  /// Oldest first, consecutive calendar days, at most `maxDays`. The publisher fills a day the
  /// server has no entry for with zero seconds, so a gap is never mistaken for a broken streak.
  public let days: [Day]
  public let streakDaysBeforeWindow: Int
  public let totalSeconds: Double
  public let fetchedAt: Date

  public init(days: [Day], streakDaysBeforeWindow: Int, totalSeconds: Double, fetchedAt: Date) throws {
    self.days = days
    self.streakDaysBeforeWindow = streakDaysBeforeWindow
    self.totalSeconds = totalSeconds
    self.fetchedAt = fetchedAt
    try validate()
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.days = try container.decode([Day].self, forKey: .days)
    self.streakDaysBeforeWindow = try container.decode(Int.self, forKey: .streakDaysBeforeWindow)
    self.totalSeconds = try container.decode(Double.self, forKey: .totalSeconds)
    self.fetchedAt = try container.decode(Date.self, forKey: .fetchedAt)
    try validate()
  }

  public func validate() throws {
    guard days.count <= Self.maxDays, streakDaysBeforeWindow >= 0, totalSeconds.isFinite,
      totalSeconds >= 0, fetchedAt.timeIntervalSinceReferenceDate.isFinite
    else { throw WidgetProtocolError.invalidValue }
    for day in days { try day.validate() }
    // The extension counts the streak back from the newest day, so the window must have no gaps.
    let dayNumbers = days.compactMap { WidgetValidation.dayNumber($0.date) }
    guard zip(dayNumbers, dayNumbers.dropFirst()).allSatisfy({ $1 == $0 + 1 }) else {
      throw WidgetProtocolError.invalidValue
    }
  }

  private enum CodingKeys: String, CodingKey { case days, streakDaysBeforeWindow, totalSeconds, fetchedAt }
}

public enum WidgetProtocolError: Error, Equatable, Sendable {
  case unsupportedVersion(Int)
  case invalidValue
  case forbiddenText
  case oversizedText
  case tooManyItems
  case tooLarge
}

enum WidgetValidation {
  /// Tokens are generated by the app (a UUID string today); anything outside this alphabet is a
  /// value that did not come from the publisher.
  static func validateToken(_ value: String) throws {
    guard (1...64).contains(value.utf8.count),
      value.utf8.allSatisfy({ isASCIIAlphanumeric($0) || $0 == UInt8(ascii: "-") })
    else { throw WidgetProtocolError.invalidValue }
  }

  /// Drawn text only: no control characters, and nothing shaped like a URL or a path, which is
  /// what a server identifier or a cover source would look like if a mapping leaked one.
  static func validateText(_ value: String) throws {
    guard !value.isEmpty,
      !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    else { throw WidgetProtocolError.invalidValue }
    guard !value.contains("://"), !value.lowercased().hasPrefix("file:"), !value.hasPrefix("/") else {
      throw WidgetProtocolError.forbiddenText
    }
    guard value.utf8.count <= WidgetSnapshotLimits.maxTextBytes else {
      throw WidgetProtocolError.oversizedText
    }
  }

  static func isLowercaseHex(_ value: String, length: Int) -> Bool {
    value.utf8.count == length
      && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
  }

  /// The day count since 1970-01-01 for a `YYYY-MM-DD` key naming a real Gregorian date, or `nil`.
  /// Plain arithmetic rather than `Calendar`, which would silently roll 2026-02-30 into March.
  static func dayNumber(_ value: String) -> Int? {
    let parts = value.split(separator: "-", omittingEmptySubsequences: false)
    guard value.utf8.count == 10, parts.count == 3, parts[0].count == 4, parts[1].count == 2,
      parts[2].count == 2, parts.allSatisfy({ $0.utf8.allSatisfy { (48...57).contains($0) } }),
      let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]),
      year >= 1, (1...12).contains(month)
    else { return nil }
    let isLeap = year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
    let monthLengths = [31, isLeap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
    guard (1...monthLengths[month - 1]).contains(day) else { return nil }
    // Days from civil (H. Hinnant); the year is at least 1, so nothing here goes negative.
    let shiftedYear = month <= 2 ? year - 1 : year
    let era = shiftedYear / 400
    let yearOfEra = shiftedYear - era * 400
    let dayOfYear = (153 * (month > 2 ? month - 3 : month + 9) + 2) / 5 + day - 1
    let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
    return era * 146_097 + dayOfEra - 719_468
  }

  static func isASCIIAlphanumeric(_ byte: UInt8) -> Bool {
    (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
  }
}
