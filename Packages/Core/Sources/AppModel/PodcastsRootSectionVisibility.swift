import Foundation

/// Which Podcasts root sections the reader wants to see. A device preference in `UserDefaults`
/// behind `storageKey`: a comma-separated list of the hidden sections, so the default (everything
/// visible) is the empty string. Pure string transforms, as `HomeSectionVisibility`.
public enum PodcastsRootSectionVisibility {
  public static let storageKey = "podcasts.hiddenSections"

  public static func hidden(in stored: String) -> Set<PodcastsRootSection> {
    Set(
      stored
        .split(separator: ",")
        .compactMap { PodcastsRootSection(rawValue: $0.trimmingCharacters(in: .whitespaces)) })
  }

  /// Serialised in `PodcastsRootSection.allCases` order so the stored value is stable whatever
  /// order the toggles were flipped in.
  public static func stored(hidden: Set<PodcastsRootSection>) -> String {
    PodcastsRootSection.allCases.filter(hidden.contains).map(\.rawValue).joined(separator: ",")
  }

  public static func isVisible(_ section: PodcastsRootSection, in stored: String) -> Bool {
    hidden(in: stored).contains(section) == false
  }

  public static func updating(
    _ stored: String,
    section: PodcastsRootSection,
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
