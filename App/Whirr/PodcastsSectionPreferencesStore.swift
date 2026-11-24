import AppModel
import Foundation
import Observation

/// The Podcasts root's device preferences (which sections show, and in what order), republished
/// once per change rather than once per `UserDefaults` write. Separate from
/// `HomeSectionPreferencesStore` so a Home reorder never invalidates this tab root, and the other
/// way round. See that type for why this is not `@AppStorage`.
@MainActor
@Observable
final class PodcastsSectionPreferencesStore {
  static let shared = PodcastsSectionPreferencesStore()

  @ObservationIgnored private let defaults: UserDefaults
  @ObservationIgnored private var observer: NSObjectProtocol?

  /// The comma-separated list of hidden sections; empty means everything shows.
  private(set) var hiddenSections: String
  private(set) var sectionOrder: String

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    self.hiddenSections = Self.string(PodcastsRootSectionVisibility.storageKey, in: defaults)
    self.sectionOrder = Self.string(PodcastsRootSectionOrder.storageKey, in: defaults)
    observer = NotificationCenter.default.addObserver(
      forName: UserDefaults.didChangeNotification, object: defaults, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated {
        self?.reread()
      }
    }
  }

  deinit {
    if let observer { NotificationCenter.default.removeObserver(observer) }
  }

  private func reread() {
    let hidden = Self.string(PodcastsRootSectionVisibility.storageKey, in: defaults)
    if hidden != hiddenSections { hiddenSections = hidden }
    let order = Self.string(PodcastsRootSectionOrder.storageKey, in: defaults)
    if order != sectionOrder { sectionOrder = order }
  }

  private static func string(_ key: String, in defaults: UserDefaults) -> String {
    defaults.string(forKey: key) ?? ""
  }
}
