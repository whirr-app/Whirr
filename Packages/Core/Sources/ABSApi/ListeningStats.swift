import Foundation

/// The account's listening totals from `GET /api/me/listening-stats` (shape confirmed on 2.35.1).
///
/// The server builds this by reading every playback session the user has, on every call, and
/// credits a session's whole `timeListening` to the date it started, in the server's time zone.
/// `recentSessions` is not decoded: the per-item History sheet already covers it.
public struct ListeningStatsResponse: Sendable, Equatable {
  /// Seconds listened across every session.
  public let totalSeconds: Double
  /// Seconds per server date, oldest first, one entry per date.
  public let days: [ListeningStatsDay]
  public let weekdays: [ListeningStatsWeekday: Double]
  /// Seconds per library item (a podcast's episodes aggregate under the show), largest first.
  public let items: [ListeningStatsItem]

  public init(
    totalSeconds: Double,
    days: [ListeningStatsDay],
    weekdays: [ListeningStatsWeekday: Double],
    items: [ListeningStatsItem]
  ) {
    self.totalSeconds = totalSeconds
    self.days = days
    self.weekdays = weekdays
    self.items = items
  }
}

/// One `days` entry. `date` is the server's `YYYY-MM-DD` key, validated as a real Gregorian date
/// and otherwise left as the server wrote it: it names the server's calendar day, not an instant.
public struct ListeningStatsDay: Sendable, Equatable {
  public let date: String
  public let seconds: Double

  public init(date: String, seconds: Double) {
    self.date = date
    self.seconds = seconds
  }
}

/// The server's `dayOfWeek` keys, which are English day names (`date.format(..., 'dddd')`).
public enum ListeningStatsWeekday: String, Sendable, CaseIterable {
  case sunday = "Sunday"
  case monday = "Monday"
  case tuesday = "Tuesday"
  case wednesday = "Wednesday"
  case thursday = "Thursday"
  case friday = "Friday"
  case saturday = "Saturday"

  /// `Calendar`'s weekday number: Sunday is 1.
  public var calendarWeekday: Int {
    switch self {
    case .sunday: 1
    case .monday: 2
    case .tuesday: 3
    case .wednesday: 4
    case .thursday: 5
    case .friday: 6
    case .saturday: 7
    }
  }
}

public struct ListeningStatsItem: Sendable, Equatable {
  public let id: String
  public let title: String?
  public let author: String?
  public let seconds: Double

  public init(id: String, title: String?, author: String?, seconds: Double) {
    self.id = id
    self.title = title
    self.author = author
    self.seconds = seconds
  }
}

/// Admission bounds for the one unpaged per-user route (API-CONVENTIONS rule 21). Twenty-seven
/// years of daily listening and twenty thousand titles are far beyond a real account; past them
/// the decoder keeps the most recent days and the largest items.
enum ListeningStatsBounds {
  static let maximumDays = 10_000
  static let maximumItems = 20_000
  static let maximumTextLength = 512
}

extension ABSClient {
  /// `GET /api/me/listening-stats`. The route is expensive server-side, so callers throttle it
  /// (`SyncEngine`'s `ListeningStatsCoordinator`); this is a single fetch with no retry policy.
  public func fetchListeningStats(
    account: TokenAccount,
    diagnostics: DecodeDiagnostics? = nil
  ) async throws -> ListeningStatsResponse {
    let tokens = try loadTokens(for: account)
    let routeTemplate = "/api/me/listening-stats"
    let request = try requestBuilder.makeRequest(
      method: .get, path: routeTemplate, routeTemplate: routeTemplate)
    let response = try await authenticatedSend(request, account: account, initialTokens: tokens)
    try validateSuccess(response)

    let wire = try decoder.decode(
      ListeningStatsDTO.self, from: response.body, endpoint: routeTemplate, diagnostics: diagnostics)
    return wire.response()
  }
}

/// A non-negative, finite number of seconds. The server coerces string `timeListening` values with
/// `Number(...)`, so a numeric string is accepted too.
private struct WireSeconds: Decodable {
  let value: Double

  init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    let parsed: Double?
    if let number = try? container.decode(Double.self) {
      parsed = number
    } else if let text = try? container.decode(String.self) {
      parsed = Double(text.trimmingCharacters(in: .whitespaces))
    } else {
      parsed = nil
    }
    guard let parsed, parsed.isFinite, parsed >= 0 else {
      throw DecodingError.dataCorruptedError(
        in: container, debugDescription: "not a non-negative number of seconds")
    }
    value = parsed
  }
}

private struct ListeningStatsDTO: Decodable {
  let totalTime: WireSeconds?
  let days: [String: LossyOptional<WireSeconds>]
  let dayOfWeek: [String: LossyOptional<WireSeconds>]
  let items: [String: LossyOptional<ItemDTO>]

  private enum CodingKeys: String, CodingKey { case totalTime, days, dayOfWeek, items }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    totalTime = try container.decode(LossyOptional<WireSeconds>.self, forKey: .totalTime).wrappedValue
    days =
      try container.decode(LossyOptional<[String: LossyOptional<WireSeconds>]>.self, forKey: .days)
      .wrappedValue ?? [:]
    dayOfWeek =
      try container.decode(
        LossyOptional<[String: LossyOptional<WireSeconds>]>.self, forKey: .dayOfWeek
      ).wrappedValue ?? [:]
    items =
      try container.decode(LossyOptional<[String: LossyOptional<ItemDTO>]>.self, forKey: .items)
      .wrappedValue ?? [:]
  }

  func response() -> ListeningStatsResponse {
    // `YYYY-MM-DD` sorts chronologically as text, so the newest days are the last ones.
    let keptDays =
      days
      .compactMap { key, value -> ListeningStatsDay? in
        guard let seconds = value.wrappedValue?.value, seconds > 0, Self.isValidDayKey(key) else {
          return nil
        }
        return ListeningStatsDay(date: key, seconds: seconds)
      }
      .sorted { $0.date < $1.date }
      .suffix(ListeningStatsBounds.maximumDays)

    var weekdays: [ListeningStatsWeekday: Double] = [:]
    for (key, value) in dayOfWeek {
      guard let weekday = ListeningStatsWeekday(rawValue: key), let seconds = value.wrappedValue?.value
      else { continue }
      weekdays[weekday] = seconds
    }

    let keptItems =
      items.values
      .compactMap { $0.wrappedValue?.item() }
      .sorted { $0.seconds != $1.seconds ? $0.seconds > $1.seconds : $0.id < $1.id }
      .prefix(ListeningStatsBounds.maximumItems)

    let total = totalTime?.value ?? keptDays.reduce(0) { $0 + $1.seconds }
    return ListeningStatsResponse(
      totalSeconds: total, days: Array(keptDays), weekdays: weekdays, items: Array(keptItems))
  }

  private static let keyCalendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
  }()

  /// `YYYY-MM-DD` naming a real Gregorian date: the server's `date.format(..., 'YYYY-MM-DD')`.
  static func isValidDayKey(_ key: String) -> Bool {
    let parts = key.split(separator: "-", omittingEmptySubsequences: false)
    guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
      parts.allSatisfy({ $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }),
      let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2])
    else { return false }
    let components = DateComponents(calendar: keyCalendar, year: year, month: month, day: day)
    return components.isValidDate
  }
}

private struct ItemDTO: Decodable {
  let id: String?
  let timeListening: WireSeconds?
  let metadata: MetadataDTO?

  private enum CodingKeys: String, CodingKey { case id, timeListening, mediaMetadata }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(LossyOptional<String>.self, forKey: .id).wrappedValue
    timeListening = try container.decode(LossyOptional<WireSeconds>.self, forKey: .timeListening)
      .wrappedValue
    metadata = try container.decode(LossyOptional<MetadataDTO>.self, forKey: .mediaMetadata).wrappedValue
  }

  func item() -> ListeningStatsItem? {
    guard let id, id.isEmpty == false, id.count <= ListeningStatsBounds.maximumTextLength,
      let seconds = timeListening?.value
    else { return nil }
    return ListeningStatsItem(
      id: id, title: metadata?.title, author: metadata?.authorLine, seconds: seconds)
  }
}

/// The session's copy of the item's metadata. A book carries `authors: [{id, name}]`; a podcast
/// carries a plain `author` string.
private struct MetadataDTO: Decodable {
  let title: String?
  let authorLine: String?

  private enum CodingKeys: String, CodingKey { case title, authors, author }
  private struct AuthorDTO: Decodable { let name: String? }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    title = Self.bounded(try container.decode(LossyOptional<String>.self, forKey: .title).wrappedValue)
    let names =
      (try container.decode(LossyOptional<[LossyOptional<AuthorDTO>]>.self, forKey: .authors)
      .wrappedValue ?? [])
      .compactMap { $0.wrappedValue?.name }
      .filter { $0.isEmpty == false }
    if names.isEmpty == false {
      authorLine = Self.bounded(names.joined(separator: ", "))
    } else {
      authorLine = Self.bounded(try container.decode(LossyOptional<String>.self, forKey: .author).wrappedValue)
    }
  }

  private static func bounded(_ text: String?) -> String? {
    guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), text.isEmpty == false else {
      return nil
    }
    return String(text.prefix(ListeningStatsBounds.maximumTextLength))
  }
}
