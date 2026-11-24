import Foundation

/// App-wide quick choices for the sleep timer. The compact comma-separated representation is
/// stable and human-readable because it lives in `AppStorage` and may be mirrored through iCloud,
/// rather than entering the Audiobookshelf preference model.
nonisolated struct SleepTimerPresetConfiguration: Equatable, Sendable {
  static let defaults = [15, 30, 45, 60]
  static let allowedRange = 1...240
  static let maximumCount = 6

  let minutes: [Int]

  init(minutes: [Int]) {
    var seen = Set<Int>()
    let sanitized = minutes.filter { minute in
      Self.allowedRange.contains(minute) && seen.insert(minute).inserted
    }
    let normalized = Array(sanitized.sorted().prefix(Self.maximumCount))
    self.minutes = normalized.isEmpty ? Self.defaults : normalized
  }

  var encoded: String {
    minutes.map(String.init).joined(separator: ",")
  }

  var isDefault: Bool { minutes == Self.defaults }

  /// The reset confirmation's message, naming exactly what the shortcuts become.
  static var resetMessage: String {
    let names = defaults.map(String.init)
    let list = names.dropLast().joined(separator: ", ") + " and " + (names.last ?? "")
    return "Your timer shortcuts will go back to \(list) minutes."
  }

  static func decode(_ encoded: String) -> Self {
    let values = encoded.split(separator: ",").compactMap { Int($0) }
    return Self(minutes: values)
  }
}
