import AppModel
import Foundation
import Persistence

/// Copy shared by a smart list's row, its swipe, and its screen. Referenced from
/// `PodcastEpisodeSwipeActionsModifier`, so it sits outside the SmartLists views.
nonisolated enum SmartListRowCopy {
  static let hide = "Hide"
  static let show = "Show Again"
}

/// What the smart-list surfaces say and when they draw. Pure, so the decisions are tested without
/// hosting a view.
nonisolated enum SmartListsPresentation {
  static let sectionTitle = "Smart Lists"
  static let sectionHint = "Shows all smart lists"
  static let manageTitle = "Smart Lists"
  static let newTitle = "New Smart List"
  static let newHint = "Start a new list, or start from a template"
  static let blankTemplateTitle = "New List"
  static let templatesHeading = "Start from"
  static let createTitle = "Create a Smart List"
  static let noListsTitle = "No Smart Lists"
  static let newListTitle = "New Smart List"

  /// A list screen's title. Its own model reads the store before it has the name, so until then
  /// the name comes from the shared lists the user just tapped it in.
  static func listTitle(loaded: String?, listID: Int64, lists: [SmartListSummary]) -> String {
    loaded ?? lists.first { $0.id == listID }?.name ?? ""
  }
  static let editListTitle = "Edit Smart List"
  static let emptyMessage = "A smart list lines up the episodes you choose."
  static let playingMark = "Playing"
  static let playTitle = "Play"
  static let pauseTitle = "Pause"
  static let resumeTitle = "Resume"
  static let editTitleShort = "Edit"
  static let rowHint = "Opens the list"
  static let hiddenNotice = "Episode hidden from this list"
  static let undoHidden = "Undo"
  static let updatingShows = "Updating shows…"
  static let emptyList = "Nothing matches this list right now."
  static let missingList = "This smart list no longer exists."
  static let errorTitle = "Smart List"
  static let loadingList = "Loading list…"
  static let deleteTitle = "Delete"
  static func deleteConfirmation(name: String) -> String { "Delete \(name)?" }
  static let unavailable = "Smart lists need a followed podcast or a signed-in server."

  static func templateTitle(_ template: SmartListTemplate) -> String {
    switch template {
    case .blank: blankTemplateTitle
    case .newEpisodesThisWeek, .shortEpisodes, .downloaded: template.name
    }
  }

  /// The starting points the New menu offers. Every rule stays editable afterwards.
  static let templates: [SmartListTemplate] = [.newEpisodesThisWeek, .shortEpisodes, .downloaded]

  /// The list screen's rules, one chip each. Chips stand alone, so each starts with a capital.
  static func ruleChips(for rules: SmartListRules) -> [String] {
    SmartListRuleSummary.parts(for: rules).map { $0.prefix(1).uppercased() + $0.dropFirst() }
  }

  /// The chips read as one control, the sentence form, since they share one action.
  static func rulesAccessibilityLabel(for rules: SmartListRules) -> String {
    "Rules: \(SmartListRuleSummary.text(for: rules))"
  }

  static let editRulesHint = "Edits the list's rules"

  static func matchCountText(_ count: Int?) -> String? {
    guard let count else { return nil }
    return count == 1 ? "1 episode" : "\(count) episodes"
  }

  /// One spoken element for the row's name and its line of detail.
  static func rowAccessibilityLabel(name: String, detail: String?, isActive: Bool) -> String {
    [name, isActive ? playingMark : nil, detail].compactMap { $0 }.joined(separator: ", ")
  }

  /// A list's play control, the episode card's three states. The list counts as loaded only while
  /// it holds the run and something is loaded: starting anything outside the list ends its run.
  static func playControl(
    isActive: Bool, hasLoadedEpisode: Bool, isPlaybackIntended: Bool
  ) -> PodcastEpisodeCardPlayControl {
    PodcastEpisodeCardPlayControl.resolve(
      isCurrentEpisode: isActive && hasLoadedEpisode, isPlaybackIntended: isPlaybackIntended)
  }

  /// The verb the control performs, as the episode card names its tap rather than the status.
  static func playControlTitle(_ control: PodcastEpisodeCardPlayControl) -> String {
    switch control {
    case .start: playTitle
    case .pause: pauseTitle
    case .resume: resumeTitle
    }
  }

  static func playControlLabel(_ control: PodcastEpisodeCardPlayControl, name: String) -> String {
    "\(playControlTitle(control)) \(name)"
  }

  /// The episode a list's Play button speaks for, and takes its colour from: the loaded episode
  /// when the list holds it, otherwise the next in line.
  static func playTarget<Episode>(
    in episodes: [Episode], isLoaded: (Episode) -> Bool
  ) -> (episode: Episode, isLoaded: Bool)? {
    if let loaded = episodes.first(where: isLoaded) { return (loaded, true) }
    return episodes.first.map { ($0, false) }
  }

  enum MosaicLayout: Equatable {
    case placeholder
    case single
    case grid
  }

  /// Four covers make a grid; fewer would leave holes in one, so the first stands alone.
  static func mosaicLayout(coverCount: Int) -> MosaicLayout {
    if coverCount >= 4 { return .grid }
    return coverCount > 0 ? .single : .placeholder
  }

  /// An episode card opened from a list starts a run of that list when Play begins a new session,
  /// which nothing visible on the card says; the hint carries it for VoiceOver. Once the run is
  /// going, the Up Next sheet shows it.
  static func playHint(listName: String?, startsRun: Bool) -> String? {
    guard startsRun, let listName else { return nil }
    return "Plays \(listName) from this episode."
  }

  /// The live count the editor announces politely as the rules change.
  static func announcement(matchCount: Int?) -> String? {
    guard let text = matchCountText(matchCount) else { return nil }
    return "\(text) match"
  }

  /// The section draws once smart lists are available and there is something for it to sit among:
  /// a list of its own, or the rest of the tab. An empty tab keeps its placeholder rather than a
  /// lone header.
  static func sectionIsDrawn(isAvailable: Bool, listCount: Int, hasOtherContent: Bool) -> Bool {
    guard isAvailable else { return false }
    return listCount > 0 || hasOtherContent
  }

  static func listSubtitleWhileUpdating(isUpdating: Bool) -> String? {
    isUpdating ? updatingShows : nil
  }

  /// The show picker's availability note for a followed or server show that cannot take part now.
  static func availabilityNote(_ availability: SmartListPickerShow.Availability) -> String? {
    switch availability {
    case .available: nil
    case .notFollowed: "Not followed"
    case .notOnServer: "Not available on this server"
    }
  }
}

/// The editor's one download-status choice over the two stored switches. Neither switch on is not a
/// list the editor can make, so it reads as `any`.
nonisolated enum SmartListDownloadChoice: Hashable, CaseIterable {
  case any
  case downloaded
  case notDownloaded

  init(_ rules: SmartListRules) {
    switch (rules.includeDownloaded, rules.includeNotDownloaded) {
    case (true, false): self = .downloaded
    case (false, true): self = .notDownloaded
    default: self = .any
    }
  }

  func apply(to rules: inout SmartListRules) {
    rules.includeDownloaded = self != .notDownloaded
    rules.includeNotDownloaded = self != .downloaded
  }
}

/// How the shows picker reads and changes a show's role. A show holds one role; which ones count
/// as chosen depends on the scope, and a priority show is always an included one.
nonisolated enum SmartListShowChoice {
  /// Whether the row carries the scope's mark: chosen under `only`, left out under `allExcept`.
  static func isMarked(_ role: SmartListShowRole?, scope: SmartListShowScope) -> Bool {
    switch scope {
    case .all: false
    case .only: role == .included || role == .priority
    case .allExcept: role == .excluded
    }
  }

  /// The role after tapping the row.
  static func toggled(_ role: SmartListShowRole?, scope: SmartListShowScope) -> SmartListShowRole? {
    switch scope {
    case .all: role
    case .only: isMarked(role, scope: scope) ? nil : .included
    case .allExcept: role == .excluded ? nil : .excluded
    }
  }

  /// The role after tapping the star. Starring chooses the show; unstarring keeps it chosen.
  static func priorityToggled(_ role: SmartListShowRole?, scope: SmartListShowScope)
    -> SmartListShowRole?
  {
    guard role == .priority else { return .priority }
    return scope == .only ? .included : nil
  }

  /// The editor row's value: what the scope and the marked shows come to.
  static func summary(scope: SmartListShowScope, roles: [SmartListShowRole?]) -> String {
    let marked = roles.count(where: { isMarked($0, scope: scope) })
    switch scope {
    case .all: return "All shows"
    case .only:
      if marked == 0 { return "None chosen" }
      return marked == 1 ? "1 show" : "\(marked) shows"
    case .allExcept: return marked == 0 ? "All shows" : "All except \(marked)"
    }
  }
}

/// The editor's picker and toggle labels.
nonisolated enum SmartListEditorLabels {
  static let nameField = "Name"
  static let namePrompt = "Name"
  static let emptyName = "Give the list a name."
  static let longName = "Names can be up to 60 characters."
  static let showsSection = "Shows"
  static let scopePicker = "Include"
  static let prioritySection = "Starred shows play first."
  static let star = "Play first"
  static let episodesSection = "Episodes"
  static let statusPicker = "Status"
  static let noStatus = "None"
  static let downloadPicker = "Downloads"
  static let noMinimum = "No minimum"
  static let hours = "Hours"
  static let minutesColumn = "Minutes"
  static let unplayed = "Unplayed"
  static let inProgress = "In progress"
  static let played = "Played"
  static let savedOnly = "Saved for Later only"
  static let releasePicker = "Released"
  static let durationToggle = "Filter by length"
  static let longerThan = "Longer than"
  static let shorterThan = "Shorter than"
  static let orderPicker = "Order"
  static let autoDownload = "Download automatically"
  static let autoDownloadLimit = "Keep the first"
  static let autoDownloadFooter = "Keeps the first episodes of this list downloaded."
  static let autoDownloadNeedsBothStatesFooter =
    "Auto-download needs the list to show both downloaded and not downloaded episodes."
  static let rulesSection = "Rules"
  static let cancel = "Cancel"
  static let save = "Save"
  static let noShows = "Follow a podcast to choose shows."

  static func scope(_ scope: SmartListShowScope) -> String {
    switch scope {
    case .all: "All"
    case .only: "Only chosen"
    case .allExcept: "All except"
    }
  }

  /// The order the scope control offers: everything, then the two that name shows.
  static let scopes: [SmartListShowScope] = [.all, .only, .allExcept]

  static func scopeFooter(_ scope: SmartListShowScope) -> String {
    switch scope {
    case .all: "Every show you follow is in this list."
    case .only: "Only the shows you tick are in this list."
    case .allExcept: "Every show is in this list except the ones you tick."
    }
  }

  /// The Status row's value: the statuses in, in a fixed order.
  static func statusSummary(_ rules: SmartListRules) -> String {
    var names: [String] = []
    if rules.includeUnplayed { names.append(unplayed) }
    if rules.includeInProgress { names.append(inProgress) }
    if rules.includePlayed { names.append(played) }
    return names.isEmpty ? noStatus : names.joined(separator: ", ")
  }

  static func download(_ choice: SmartListDownloadChoice) -> String {
    switch choice {
    case .any: "Any"
    case .downloaded: "Downloaded"
    case .notDownloaded: "Not downloaded"
    }
  }

  /// A length as its row shows it: "45 min", "1 hr", "1 hr 30 min".
  static func length(minutes: Int) -> String {
    let hours = minutes / 60
    let rest = minutes % 60
    if hours == 0 { return "\(rest) min" }
    return rest == 0 ? "\(hours) hr" : "\(hours) hr \(rest) min"
  }

  /// The minutes a wheel's two columns come to, held inside what the rule allows.
  static func clampedMinutes(hours: Int, minutes: Int, in range: ClosedRange<Int>) -> Int {
    min(max(hours * 60 + minutes, range.lowerBound), range.upperBound)
  }

  static func release(_ window: SmartListReleaseWindow?) -> String {
    switch window {
    case nil: "Any time"
    case .day?: "24 hours"
    case .threeDays?: "3 days"
    case .week?: "1 week"
    case .twoWeeks?: "2 weeks"
    case .month?: "1 month"
    }
  }

  static func order(_ order: SmartListSortOrder) -> String {
    switch order {
    case .newest: "Newest first"
    case .oldest: "Oldest first"
    case .shortest: "Shortest first"
    case .longest: "Longest first"
    }
  }

  static func limit(_ limit: SmartListAutoDownloadLimit) -> String { "\(limit.rawValue) episodes" }

  static func rulesError(_ error: SmartListRulesError) -> String {
    switch error {
    case .noEpisodeStatus: "Choose at least one episode status."
    case .noDownloadStatus: "Choose which downloads to include."
    case .invalidDurationRange: "The longer-than length must be shorter than the shorter-than length."
    }
  }
}
