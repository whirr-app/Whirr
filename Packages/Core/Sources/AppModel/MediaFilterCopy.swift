/// User-facing copy for `MediaFilter`, owned and tested in AppModel like `HomeCopy` and
/// `SettingsCopy`. Kept apart from `HomeCopy` because Home and Library both render the filter.
public enum MediaFilterCopy {
  /// The filter's label. Not drawn beside the segmented control, but VoiceOver announces it for
  /// the control as a whole, so it reads as a noun, not an action.
  public static let title = "Media type"

  /// The label on each segment.
  public static func label(for filter: MediaFilter) -> String {
    switch filter {
    case .all: return "All"
    case .audiobooks: return "Audiobooks"
    case .podcasts: return "Podcasts"
    case .ebooks: return "eBooks"
    }
  }

  /// What to call this filter's contents mid-sentence. `.all` is "titles" rather than "books":
  /// the Library tab merges every library, so an unfiltered list may well be podcasts.
  public static func pluralNoun(for filter: MediaFilter) -> String {
    switch filter {
    case .all: return "titles"
    case .audiobooks: return "audiobooks"
    case .podcasts: return "podcasts"
    case .ebooks: return "eBooks"
    }
  }

  /// The heading over an empty filtered list, built from `label(for:)` so it names the tapped
  /// segment.
  public static func emptyTitle(for filter: MediaFilter) -> String {
    filter == .all ? "Your Library Is Empty" : "No \(label(for: filter)) Yet"
  }
}
