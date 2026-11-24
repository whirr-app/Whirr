import Foundation

/// Which Home shelves the reader wants to see. A device preference in `UserDefaults` behind
/// `storageKey`: a comma-separated list of the hidden sections, so the default (everything
/// visible) is the empty string.
///
/// Pure string transforms, so `HomeSettingsView`'s checklist (writing through `@AppStorage`) and
/// `HomeView`'s section filter (reading through `HomeSectionPreferencesStore`) share one value.
public enum HomeSectionVisibility {
  public static let storageKey = "home.hiddenSections"
  /// Whether a tap on a Continue Listening or Continue Reading card enters the content (playback
  /// or the reader) instead of opening the details surface. The key string names Continue
  /// Listening only, but the preference covers both shelves.
  public static let continueCardOpenOnTapStorageKey = "home.continueListening.playOnTap"

  public static func hidden(in stored: String) -> Set<HomeMoreSection> {
    Set(
      stored
        .split(separator: ",")
        .compactMap { HomeMoreSection(rawValue: $0.trimmingCharacters(in: .whitespaces)) })
  }

  /// Serialised in `HomeMoreSection.allCases` order so the stored value is stable whatever order
  /// the toggles were flipped in.
  public static func stored(hidden: Set<HomeMoreSection>) -> String {
    HomeMoreSection.allCases.filter(hidden.contains).map(\.rawValue).joined(separator: ",")
  }

  public static func isVisible(_ section: HomeMoreSection, in stored: String) -> Bool {
    hidden(in: stored).contains(section) == false
  }

  public static func updating(
    _ stored: String,
    section: HomeMoreSection,
    isVisible: Bool
  ) -> String {
    var hidden = self.hidden(in: stored)
    if isVisible {
      hidden.remove(section)
    } else {
      hidden.insert(section)
    }
    return self.stored(hidden: hidden)
  }
}
