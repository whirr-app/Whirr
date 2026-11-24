import Foundation

/// Which shelf items the Continue Listening widgets draw and how their times read, kept out of the
/// extension so it can be tested.
public struct WidgetShelfPresentation: Sendable, Equatable {
  /// The item playing now when it is on the shelf, otherwise the most recent one.
  public let current: WidgetItem
  /// The remaining items in shelf order.
  public let others: [WidgetItem]
  /// Whether playback is intended for `current`. Only the current row ever shows pause.
  public let isCurrentPlaying: Bool

  /// `nil` when the shelf is empty.
  public init?(snapshot: WidgetSnapshot) {
    let shelf = snapshot.continueListening
    let nowPlayingToken = snapshot.nowPlaying?.token
    let index = nowPlayingToken.flatMap { token in shelf.firstIndex { $0.token == token } } ?? 0
    guard shelf.indices.contains(index) else { return nil }
    self.current = shelf[index]
    self.others = shelf.enumerated().filter { $0.offset != index }.map(\.element)
    let isCurrentNowPlaying = nowPlayingToken != nil && shelf[index].token == nowPlayingToken
    self.isCurrentPlaying = isCurrentNowPlaying && snapshot.nowPlaying?.isPlaying == true
  }

  /// Whether the row for `item` offers pause rather than play.
  public func showsPause(for item: WidgetItem) -> Bool {
    isCurrentPlaying && item.token == current.token
  }

  /// "3h 12m left", "12m left" or "<1m left"; `nil` when the duration is unknown. Rounds to the
  /// nearest minute, matching `AppModel.DurationText.compact`, which the dependency-free
  /// WidgetProtocol target cannot import; zero keeps the "<1m left" the widget has always shown.
  public static func timeLeft(remainingSeconds: Double?) -> String? {
    guard let remainingSeconds, remainingSeconds.isFinite, remainingSeconds >= 0 else { return nil }
    guard remainingSeconds >= 60 else { return "<1m left" }
    let minutes = Int((min(remainingSeconds, 1e9) / 60).rounded())
    let hours = minutes / 60
    let rest = minutes % 60
    if hours == 0 { return "\(rest)m left" }
    return rest == 0 ? "\(hours)h left" : "\(hours)h \(rest)m left"
  }

  /// "Ch 7", when the item is a book with chapters.
  public static func chapterLabel(for item: WidgetItem) -> String? {
    item.chapterNumber.map { "Ch \($0)" }
  }

  /// The Lock Screen line: chapter and time left, with no title. `nil` when neither is known.
  public static func accessorySummary(for item: WidgetItem) -> String? {
    let parts = [chapterLabel(for: item), timeLeft(remainingSeconds: item.remainingSeconds)]
    let present = parts.compactMap { $0 }
    return present.isEmpty ? nil : present.joined(separator: " · ")
  }
}
