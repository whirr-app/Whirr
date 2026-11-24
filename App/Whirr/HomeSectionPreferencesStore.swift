import AppModel
import Foundation
import Observation

/// Home's device preferences (which shelves show, in what order, and what a tap on a continuation
/// card does), republished once per change rather than once per `UserDefaults` write.
///
/// `@AppStorage` invalidates on any `UserDefaults` write in the process, which would rebuild the
/// tab roots `HomeView` and `PodcastsView`. Separate properties, not a struct: Observation tracks
/// per property, so `PodcastsView` (continuation-card preference only) ignores shelf reorders.
@MainActor
@Observable
final class HomeSectionPreferencesStore {
  static let shared = HomeSectionPreferencesStore()

  @ObservationIgnored private let defaults: UserDefaults
  @ObservationIgnored private var observer: NSObjectProtocol?

  /// The comma-separated list of hidden sections; empty means a fresh install showing everything.
  private(set) var hiddenSections: String
  private(set) var sectionOrder: String
  private(set) var opensContinueCardImmediately: Bool

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    self.hiddenSections = Self.string(HomeSectionVisibility.storageKey, in: defaults)
    self.sectionOrder = Self.string(HomeSectionOrder.storageKey, in: defaults)
    self.opensContinueCardImmediately = Self.opensContinueCardImmediately(in: defaults)
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
    let hidden = Self.string(HomeSectionVisibility.storageKey, in: defaults)
    if hidden != hiddenSections { hiddenSections = hidden }
    let order = Self.string(HomeSectionOrder.storageKey, in: defaults)
    if order != sectionOrder { sectionOrder = order }
    let opensImmediately = Self.opensContinueCardImmediately(in: defaults)
    if opensImmediately != opensContinueCardImmediately {
      opensContinueCardImmediately = opensImmediately
    }
  }

  private static func string(_ key: String, in defaults: UserDefaults) -> String {
    defaults.string(forKey: key) ?? ""
  }

  /// Absent means on. `bool(forKey:)` would read an untouched install as off and flip the
  /// behaviour for everyone who never visited the setting.
  private static func opensContinueCardImmediately(in defaults: UserDefaults) -> Bool {
    defaults.object(forKey: HomeSectionVisibility.continueCardOpenOnTapStorageKey) as? Bool ?? true
  }
}
