import Foundation
import Persistence

/// Persistence for the Library's filter. A device preference, like `HomeSectionVisibility`: one
/// string in `UserDefaults`, with the unfiltered default stored as no key. Nothing reaches the
/// database.
///
/// Pure string transforms with a thin `UserDefaults` surface, so the encoding is testable without
/// a defaults suite. Every decode path degrades to an unfiltered library: the filter outlives the
/// launch that set it, so a string from a future version, or a corrupt one, must not crash or
/// leave an invisible filter.
/// The two operations this storage needs from a preferences store, so tests can inject an in-memory
/// double: `UserDefaults(suiteName:)` writes a real plist and registers with `cfprefsd`. It does
/// not own the key; `BrowseFilterStorage` is the only place that knows it.
public protocol BrowseFilterDefaults: AnyObject {
  func filterString(forKey key: String) -> String?
  /// `nil` removes the key, so the unfiltered case stores nothing at all.
  func setFilterString(_ value: String?, forKey key: String)
}

extension UserDefaults: BrowseFilterDefaults {
  public func filterString(forKey key: String) -> String? { string(forKey: key) }

  public func setFilterString(_ value: String?, forKey key: String) {
    if let value {
      set(value, forKey: key)
    } else {
      removeObject(forKey: key)
    }
  }
}

public enum BrowseFilterStorage {
  /// Which screen's filter a load/save is for. Library and Search share one control over
  /// `BrowseFilters` but keep separate values, so a narrowed Library does not narrow the next
  /// search. `library`'s key must not change: renaming it would unfilter existing installs.
  public enum Screen: Sendable, CaseIterable {
    case library
    case search

    public var storageKey: String {
      switch self {
      case .library: return "library.filters"
      case .search: return "search.filters"
      }
    }
  }

  private static let fieldSeparator: Character = ";"
  private static let listSeparator: Character = ","
  private static let categoriesField = "categories"
  private static let downloadedField = "downloaded"
  private static let playbackField = "playback"

  /// Emits only the engaged dimensions, in a fixed field order, with categories in
  /// `ItemMediaCategory.allCases` order, so the stored value depends on the filter alone and never
  /// on the order the reader flipped the controls in.
  public static func stored(filters: BrowseFilters) -> String {
    var fields: [String] = []
    if let categories = filters.categories {
      let names = ItemMediaCategory.allCases.filter(categories.contains).map(\.rawValue)
      if names.isEmpty == false {
        fields.append("\(categoriesField)=\(names.joined(separator: String(listSeparator)))")
      }
    }
    if filters.downloadedOnly {
      fields.append("\(downloadedField)=1")
    }
    if filters.playback != .any {
      fields.append("\(playbackField)=\(filters.playback.rawValue)")
    }
    return fields.joined(separator: String(fieldSeparator))
  }

  public static func filters(in stored: String) -> BrowseFilters {
    var categories: Set<ItemMediaCategory> = []
    var downloadedOnly = false
    var playback = PlaybackFilter.any

    for field in stored.split(separator: fieldSeparator) {
      let parts = field.split(separator: "=", maxSplits: 1).map {
        $0.trimmingCharacters(in: .whitespaces)
      }
      guard parts.count == 2 else { continue }
      switch parts[0] {
      case categoriesField:
        // Unknown names are dropped rather than failing the whole field. A category this version
        // does not know about must not take the reader's other dimensions down with it.
        categories.formUnion(
          parts[1]
            .split(separator: listSeparator)
            .compactMap { ItemMediaCategory(rawValue: $0.trimmingCharacters(in: .whitespaces)) })
      case downloadedField:
        downloadedOnly = parts[1] == "1"
      case playbackField:
        playback = PlaybackFilter(rawValue: parts[1]) ?? .any
      default:
        continue
      }
    }

    return BrowseFilters(
      categories: categories, downloadedOnly: downloadedOnly, playback: playback)
  }

  public static func load(
    _ screen: Screen, from defaults: any BrowseFilterDefaults
  ) -> BrowseFilters {
    filters(in: defaults.filterString(forKey: screen.storageKey) ?? "")
  }

  /// Stores nothing for the unfiltered case, so a fresh install and a cleared filter are the same
  /// state on disk.
  public static func save(
    _ filters: BrowseFilters, for screen: Screen, to defaults: any BrowseFilterDefaults
  ) {
    let encoded = stored(filters: filters)
    defaults.setFilterString(encoded.isEmpty ? nil : encoded, forKey: screen.storageKey)
  }
}
