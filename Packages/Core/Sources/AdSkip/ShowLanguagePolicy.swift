import Foundation

/// Which shows are analysed: an English language tag, or none. The rules and model were
/// tuned on English transcripts only.
public enum ShowLanguagePolicy {
  /// True for nil, `en`, or `en` followed by `-` or `_` and a subtag, case-insensitive, after
  /// trimming whitespace; a tag empty after trimming counts as none. False for
  /// every other tag.
  public static func isAnalysable(languageTag: String?) -> Bool {
    guard let raw = languageTag else { return true }
    let tag = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if tag.isEmpty || tag == "en" { return true }
    guard tag.hasPrefix("en-") || tag.hasPrefix("en_") else { return false }
    return tag.count > 3
  }
}
