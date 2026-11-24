import Persistence

/// The media-kind filter behind the segmented control on both Home and Library, hence the
/// tab-neutral name. A superset of `ItemMediaCategory` (`.all` imposes no filter), kept as its own
/// type so the view layer has a `CaseIterable` list of segments instead of an `Optional`.
public enum MediaFilter: String, Sendable, Equatable, Hashable, CaseIterable {
  case all
  case audiobooks
  case podcasts
  case ebooks

  /// The category `HomeReading`/`LibraryReading`'s `observe*` methods filter on; `nil` for `.all`.
  public var category: ItemMediaCategory? {
    switch self {
    case .all: return nil
    case .audiobooks: return .audiobook
    case .podcasts: return .podcast
    case .ebooks: return .ebook
    }
  }
}
