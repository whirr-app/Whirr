import AppModel

/// Every row the show's options menu can contain. Admin-only routes (API-CONVENTIONS rule 26) must
/// not appear (`showMenuHasNoAdminActions`). `saveShow` only enters multi-select Save to
/// Audiobookshelf (ADR 0017 item 6), for a followed feed with no server copy.
enum PodcastShowMenuAction: String, Equatable, CaseIterable {
  case markAllPlayed = "mark-all-played"
  case markAllUnplayed = "mark-all-unplayed"
  /// A deep link into the Settings sheet, not server management.
  case openSettings = "open-settings"
  /// Opens selection with one episode pre-selected; nothing is sent until the user saves.
  case saveShow = "save-show-to-audiobookshelf"
  case downloadAll = "download-all"
  case removeAllDownloads = "remove-all-downloads"
  case unsubscribe = "unsubscribe"
}

nonisolated extension PodcastShowViewPresentation {
  /// One row of the show's options menu. `group` drives the dividers: a change of group is a
  /// separator.
  struct ShowMenuItem: Equatable, Identifiable {
    let id: String
    let label: String
    let systemImage: String?
    let hint: String
    let isEnabled: Bool
    let isDestructive: Bool
    let group: Int

    init(
      id: String,
      label: String,
      systemImage: String?,
      hint: String,
      isEnabled: Bool,
      isDestructive: Bool = false,
      group: Int
    ) {
      self.id = id
      self.label = label
      self.systemImage = systemImage
      self.hint = hint
      self.isEnabled = isEnabled
      self.isDestructive = isDestructive
      self.group = group
    }
  }

  /// The trailing toolbar control's contents: actions only, since server diagnostics belong to Show
  /// Settings. No Up Next row (player-owned; `showMenuOffersNoQueueDestination`). Feed-management
  /// rows are admin-only (rule 26; `showMenuHasNoAdminActions`). `offersSaveShow` only opens
  /// selection: the save is the user's own later action.
  static func showMenu(
    filter: PodcastEpisodeFilter,
    unplayedCount: Int,
    playedCount: Int,
    downloadableCount: Int,
    removableCount: Int,
    isSearchActive: Bool = false,
    isNativeFeed: Bool = false,
    offersSaveShow: Bool = false
  ) -> [ShowMenuItem] {
    var items: [ShowMenuItem] = []
    // Both rows always appear: a row that vanishes and reappears as the filter changes is harder
    // to find than one that greys out.
    items.append(
      ShowMenuItem(
        id: PodcastShowMenuAction.markAllPlayed.rawValue,
        label: markAllLabel(
          filter: filter, isFinished: true, isSearchActive: isSearchActive),
        systemImage: "checkmark.circle",
        hint: "Marks the episodes currently shown as played.",
        isEnabled: unplayedCount > 0,
        group: 1))
    items.append(
      ShowMenuItem(
        id: PodcastShowMenuAction.markAllUnplayed.rawValue,
        label: markAllLabel(
          filter: filter, isFinished: false, isSearchActive: isSearchActive),
        systemImage: "arrow.counterclockwise.circle",
        hint: "Returns the episodes currently shown to the beginning.",
        isEnabled: playedCount > 0,
        group: 1))
    // Navigation, not server management, so it sits above the destructive download group.
    items.append(
      ShowMenuItem(
        id: PodcastShowMenuAction.openSettings.rawValue,
        label: "Show Settings",
        systemImage: "gearshape",
        hint: "Opens this show's automatic download settings.",
        isEnabled: true,
        group: 2))
    if offersSaveShow {
      items.append(
        ShowMenuItem(
          id: PodcastShowMenuAction.saveShow.rawValue,
          label: NativeEpisodeServerSaveCopy.showSaveAction,
          systemImage: NativeEpisodeServerSaveCopy.saveSystemImage,
          hint: NativeEpisodeServerSaveCopy.showSaveHint,
          isEnabled: true,
          group: 2))
    }
    if isNativeFeed {
      // Unfollow alone: a device-owned feed has no bulk download rows, and the feed address has
      // nowhere to go inside the app (`nativeShowMenuOffersUnfollowOnly`).
      items.append(
        ShowMenuItem(
          id: PodcastShowMenuAction.unsubscribe.rawValue,
          label: "Unfollow Podcast", systemImage: "minus.circle",
          hint: "Removes this podcast from this device.", isEnabled: true,
          isDestructive: true, group: 3))
    } else {
      items.append(
        ShowMenuItem(
          id: PodcastShowMenuAction.downloadAll.rawValue,
          label: downloadAllLabel(filter: filter, isSearchActive: isSearchActive),
          systemImage: "arrow.down.circle",
          hint: "Downloads the episodes currently shown to this device.",
          isEnabled: downloadableCount > 0,
          group: 3))
      items.append(
        ShowMenuItem(
          id: PodcastShowMenuAction.removeAllDownloads.rawValue,
          label: isSearchActive ? "Remove Shown Downloads" : "Remove All Downloads",
          systemImage: "trash",
          hint: "Deletes the downloaded files for the episodes currently shown.",
          isEnabled: removableCount > 0,
          isDestructive: true,
          group: 3))
    }
    return items
  }

  /// Mark-all is bounded to the visible filter, so the label names that scope: "Mark All as
  /// Played" under the Unplayed filter would read as the whole show.
  static func markAllLabel(
    filter: PodcastEpisodeFilter, isFinished: Bool, isSearchActive: Bool = false
  ) -> String {
    let outcome = isFinished ? "Played" : "Unplayed"
    if isSearchActive { return "Mark Shown as \(outcome)" }
    switch filter {
    case .all: return "Mark All as \(outcome)"
    case .unplayed: return "Mark All Unplayed as \(outcome)"
    case .played: return "Mark All Played as \(outcome)"
    case .downloaded: return "Mark All Downloaded as \(outcome)"
    }
  }

  static func downloadAllLabel(
    filter: PodcastEpisodeFilter, isSearchActive: Bool = false
  ) -> String {
    if isSearchActive { return "Download All Shown" }
    switch filter {
    case .all: return "Download All"
    case .unplayed: return "Download All Unplayed"
    case .played: return "Download All Played"
    case .downloaded: return "Download All"
    }
  }

  /// Deleting files off the device is destructive and nothing here undoes it, so it always asks,
  /// unlike mark-all, which only asks past a bulk threshold. The copy follows `StorageCopy`:
  /// name what goes, and say it can come back.
  static func removeAllConfirmation(count: Int) -> String? {
    guard count > 0 else { return nil }
    return count == 1
      ? "This deletes 1 downloaded episode from this device. You can download them again later."
      : "This deletes \(count) downloaded episodes from this device. You can download them again later."
  }

  /// Downloading is not destructive: it costs bandwidth and disk, both of which the transfer cap
  /// and the cellular opt-in already govern (rules 24 and 25). No question needed.
  static func downloadAllConfirmation(count: Int) -> String? { nil }

  /// Presented as an alert, not a confirmation dialog: a dialog raised from a toolbar menu is
  /// anchored to that menu on regular-width, giving a popover bubble beside the menu with no
  /// Cancel. An alert is centred and keeps both buttons on every size class: a short title, the
  /// consequence in the message.
  static let unsubscribeConfirmationTitle = "Unfollow this podcast?"
  static let unsubscribeConfirmationMessage =
    "Its downloads and listening history will be deleted from this device."
  static let unsubscribeConfirmLabel = "Unfollow"

  /// Above this many rows a mark-all is worth a question: nothing on this screen undoes it in one
  /// gesture. Below it the confirmation is just friction.
  static let markAllConfirmationThreshold = 20

  static func markAllConfirmation(count: Int, isFinished: Bool) -> String? {
    guard count > markAllConfirmationThreshold else { return nil }
    return isFinished
      ? "Mark \(count) episodes as played?"
      : "Return \(count) episodes to the beginning?"
  }

  /// Where the overflow's "Show Settings" row goes: `[.podcastSettings,
  /// .podcastShowSettings(itemID:)]` on the `.settings` stack, one push deep so Back lands on
  /// Podcast Settings. `NavigationModel.navigate(to:)` raises this as the presented sheet rather
  /// than switching the visible section, so Done returns to the show the menu was opened from.
  static func showSettingsDestination(
    itemID: String, titleSeed: String? = nil
  ) -> NavigationModel.Destination {
    NavigationModel.Destination(
      section: .settings,
      path: [.podcastSettings, .podcastShowSettings(itemID: itemID, titleSeed: titleSeed)])
  }
}
