import Foundation

/// Parsers for common untyped values found in RSS and iTunes podcast feeds.
public enum FeedValueParsing {
  private static let dateFormatters: [DateFormatter] = {
    let formats = [
      // Weekday forms are the dominant RFC 822/2822 feed representation.
      "EEE, d MMM yy HH:mm:ss z", "EEE, d MMM yy HH:mm z",
      "EEE, d MMM yyyy HH:mm:ss z", "EEE, d MMM yyyy HH:mm z",
      // Some feeds omit the weekday while retaining the full date and zone.
      "d MMM yy HH:mm:ss z", "d MMM yy HH:mm z",
      "d MMM yyyy HH:mm:ss z", "d MMM yyyy HH:mm z",
      // These forms omit the zone; the formatter's GMT is the RFC default here.
      "EEE, d MMM yy HH:mm:ss", "EEE, d MMM yy HH:mm",
      "EEE, d MMM yyyy HH:mm:ss", "EEE, d MMM yyyy HH:mm",
      "d MMM yy HH:mm:ss", "d MMM yy HH:mm",
      "d MMM yyyy HH:mm:ss", "d MMM yyyy HH:mm",
    ]
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let pivot = calendar.date(from: DateComponents(year: 1950, month: 1, day: 1))!
    return formats.map { format in
      let formatter = DateFormatter()
      formatter.locale = Locale(identifier: "en_US_POSIX")
      formatter.timeZone = TimeZone(secondsFromGMT: 0)
      formatter.calendar = calendar
      formatter.dateFormat = format
      formatter.isLenient = false
      formatter.twoDigitStartDate = pivot
      return formatter
    }
  }()

  // ISO8601DateFormatter is documented thread-safe; both instances are configured once
  // here and only ever read afterwards.
  nonisolated(unsafe) private static let iso8601Formatter: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter
  }()

  nonisolated(unsafe) private static let iso8601FractionalFormatter: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
  }()

  /// Parses the RFC 822/2822 date variants emitted by real podcast feeds.
  public static func pubDate(_ value: String) -> Date? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.isEmpty == false else { return nil }
    return dateFormatters.lazy.compactMap { $0.date(from: trimmed) }.first
      ?? iso8601FractionalFormatter.date(from: trimmed)
      ?? iso8601Formatter.date(from: trimmed)
  }

  /// Parses bare seconds or colon-separated minutes and hours into total seconds.
  public static func duration(_ value: String) -> TimeInterval? {
    let fields = value.trimmingCharacters(in: .whitespacesAndNewlines).split(
      separator: ":", omittingEmptySubsequences: false)
    guard (1...3).contains(fields.count), fields.allSatisfy({ $0.isEmpty == false }) else { return nil }

    if fields.count == 1 {
      let text = String(fields[0])
      let components = text.split(separator: ".", omittingEmptySubsequences: false)
      guard components.count == 1 || components.count == 2, components.allSatisfy({ $0.isEmpty == false }),
        components.allSatisfy({ $0.allSatisfy(\.isNumber) })
      else { return nil }
      let seconds = Double(text)
      return seconds?.isFinite == true && seconds! >= 0 ? seconds : nil
    }

    guard fields.allSatisfy({ $0.allSatisfy(\.isNumber) }) else { return nil }
    let numbers = fields.compactMap { Double($0) }
    guard numbers.count == fields.count, numbers.allSatisfy({ $0.isFinite }) else {
      return nil
    }
    let seconds: Double
    switch numbers.count {
    case 2: seconds = numbers[0] * 60 + numbers[1]
    case 3: seconds = numbers[0] * 3_600 + numbers[1] * 60 + numbers[2]
    default: return nil
    }
    return seconds.isFinite ? seconds : nil
  }
}
