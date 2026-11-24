import Foundation
import Persistence

/// The one line a list shows under its name: what the rules select and how they sort, as a single
/// phrase. Defaults say nothing, so a plain list reads as "All shows, newest first".
public enum SmartListRuleSummary {
  public static func text(for rules: SmartListRules) -> String {
    parts(for: rules).joined(separator: ", ")
  }

  /// The same phrases, one per rule, for a screen that sets each apart rather than in a sentence.
  public static func parts(for rules: SmartListRules) -> [String] {
    var parts: [String] = []
    parts.append(scope(rules.showScope))
    if let status = statuses(rules) { parts.append(status) }
    if rules.includeDownloaded == false {
      parts.append("not downloaded")
    } else if rules.includeNotDownloaded == false {
      parts.append("downloaded")
    }
    if rules.savedOnly { parts.append("saved for later") }
    if let window = rules.releaseWindow { parts.append(releaseWindow(window)) }
    if rules.durationFilter { parts.append(duration(rules)) }
    parts.append(sort(rules.sortOrder))
    return parts
  }

  private static func scope(_ scope: SmartListShowScope) -> String {
    switch scope {
    case .all: "All shows"
    case .allExcept: "All shows except some"
    case .only: "Chosen shows"
    }
  }

  /// Nil for the default (unplayed and in progress), which needs no words.
  private static func statuses(_ rules: SmartListRules) -> String? {
    if rules.includePlayed == false, rules.includeUnplayed, rules.includeInProgress { return nil }
    var names: [String] = []
    if rules.includeUnplayed { names.append("unplayed") }
    if rules.includeInProgress { names.append("in progress") }
    if rules.includePlayed { names.append("played") }
    guard let last = names.popLast() else { return nil }
    return names.isEmpty ? last : "\(names.joined(separator: ", ")) and \(last)"
  }

  private static func releaseWindow(_ window: SmartListReleaseWindow) -> String {
    switch window {
    case .day: "from the last 24 hours"
    case .threeDays: "from the last 3 days"
    case .week: "from the last week"
    case .twoWeeks: "from the last 2 weeks"
    case .month: "from the last month"
    }
  }

  private static func duration(_ rules: SmartListRules) -> String {
    if rules.longerThanMinutes <= 0 { return "under \(rules.shorterThanMinutes) min" }
    return "\(rules.longerThanMinutes) to \(rules.shorterThanMinutes) min"
  }

  private static func sort(_ order: SmartListSortOrder) -> String {
    switch order {
    case .newest: "newest first"
    case .oldest: "oldest first"
    case .shortest: "shortest first"
    case .longest: "longest first"
    }
  }
}
