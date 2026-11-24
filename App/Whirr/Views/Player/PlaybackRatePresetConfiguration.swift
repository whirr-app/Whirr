import AppModel
import Foundation

/// Device-local shortcuts for playback speed. Rates are represented internally as twentieths so
/// persisted values, slider steps, and equality checks all use the same exact 0.05× increments.
nonisolated struct PlaybackRatePresetConfiguration: Equatable, Sendable {
  static let defaults: [Double] = [0.75, 1, 1.25, 1.5, 1.75, 2]
  static let allowedRange = 0.5...3.0
  static let customSpeedRange = 0.5...2.0
  static let maximumCount = 8

  let rates: [Double]

  init(rates: [Double]) {
    var seen = Set<Int>()
    let sanitized = rates.compactMap(Self.step(for:)).filter { seen.insert($0).inserted }
    let normalized = sanitized.sorted().prefix(Self.maximumCount).map { Double($0) / 20 }
    self.rates = normalized.isEmpty ? Self.defaults : normalized
  }

  var encoded: String {
    rates.map { PlaybackRateCopy.display($0, includesMultiplier: false) }.joined(separator: ",")
  }

  var isDefault: Bool { rates == Self.defaults }

  /// The reset confirmation's message, naming exactly what the shortcuts become.
  static var resetMessage: String {
    let names = defaults.map(display)
    let list = names.dropLast().joined(separator: ", ") + " and " + (names.last ?? "")
    return "Your speed shortcuts will go back to \(list)."
  }

  static func decode(_ encoded: String) -> Self {
    Self(rates: encoded.split(separator: ",").compactMap { Double($0) })
  }

  static func normalizedRate(_ rate: Double) -> Double? {
    step(for: rate).map { Double($0) / 20 }
  }

  /// A speed as typed: either a point or the locale's own separator (a decimal pad in a comma
  /// locale types a comma), with an optional trailing multiplier sign. Nil unless the text is one
  /// finite number.
  static func parsedRate(_ text: String, locale: Locale = .current) -> Double? {
    var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if let last = trimmed.last, "×xX".contains(last) {
      trimmed.removeLast()
      trimmed = trimmed.trimmingCharacters(in: .whitespaces)
    }
    var normalized = trimmed.replacingOccurrences(of: ",", with: ".")
    if let separator = locale.decimalSeparator, separator != "." {
      normalized = normalized.replacingOccurrences(of: separator, with: ".")
    }
    guard let value = Double(normalized), value.isFinite else { return nil }
    return value
  }

  /// Custom Speed's commit. Rounded to 0.05× and clamped to `customSpeedRange` rather than
  /// refused: an alert cannot disable its confirming button, and the speed label shows what was
  /// applied.
  static func customRate(fromInput text: String, locale: Locale = .current) -> Double? {
    guard let value = parsedRate(text, locale: locale) else { return nil }
    let clamped = min(max(value, customSpeedRange.lowerBound), customSpeedRange.upperBound)
    return normalizedRate(clamped)
  }

  /// The current speed as a field's starting text, in the locale's notation and without "×".
  static func inputText(_ rate: Double, locale: Locale = .current) -> String {
    rate.formatted(.number.precision(.fractionLength(0...2)).grouping(.never).locale(locale))
  }

  static func display(_ rate: Double) -> String {
    PlaybackRateCopy.display(rate)
  }

  /// Show the effective playback speed whenever it differs from 1×, regardless of whether it
  /// comes from the default or a saved book/show override. Match `display` rounding so a visible
  /// label can never read "1×".
  static func activeDisplay(_ rate: Double) -> String? {
    guard rate.isFinite else { return nil }
    guard Int((rate * 100).rounded()) != 100 else { return nil }
    return display(rate)
  }

  private static func step(for rate: Double) -> Int? {
    guard rate.isFinite, allowedRange.contains(rate) else { return nil }
    return Int((rate * 20).rounded())
  }
}
