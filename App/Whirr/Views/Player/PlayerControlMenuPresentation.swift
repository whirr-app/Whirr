import AppModel
import Persistence
import PlayerCore

/// Which of the player's secondary affordances a given scope shows at all. Both decisions turn on
/// whether the player is showing a podcast episode rather than a whole item, so they live
/// together rather than as two `episodeID == nil` checks buried in the view.
nonisolated enum PlayerQuickActionsPresentation {
  /// Chapters is hidden for an episode, not shown disabled. An ABS podcast episode carries no
  /// chapter map, so the control would be permanently inert, and a disabled control still
  /// claims its slot in the quick-action row.
  static func showsChapters(episodeID: String?) -> Bool {
    episodeID == nil
  }

  /// Listening history is hidden for an episode for a different reason: the per-item
  /// listening-sessions route answers for an item, and for a podcast that answer is an empty
  /// list unless an episode id is part of the query. Offering it would open a sheet that can
  /// only ever say "No Listening History".
  static func showsHistory(episodeID: String?) -> Bool {
    episodeID == nil
  }

  /// The overflow menu is offered for every scope the player can show. Download and progress
  /// intents have an episode-scoped path (`ItemActionsModel`'s `episodeID` parameter), so an
  /// episode gets the same three actions.
  static func showsOverflowMenu(episodeID: String?) -> Bool {
    _ = episodeID
    return true
  }

  /// The bottom quick-action row's contents, all unconditional (the queue is universal, so Up Next
  /// suits audiobooks too). Chapters lives on the metadata chapter row. `episodeID` keeps the
  /// inventory a function of the player's scope, for a future media-specific action. More has no
  /// case: the row holds playback controls that report state, while the overflow menu's item
  /// actions sit beside the title (`PlayerOverflowMenuPresentation.placement`).
  enum BottomAction: Sendable, Equatable {
    case sleepTimer
    case playbackRate
    case audioRoute
    case upNext
  }

  static func bottomActions(episodeID: String?) -> [BottomAction] {
    _ = episodeID
    return [.sleepTimer, .playbackRate, .audioRoute, .upNext]
  }
}

nonisolated enum PlayerOverflowMenuPresentation {
  /// Where the trigger lives: beside the byline, trailing. Against a leading-aligned block the
  /// trailing edge is space the column never used, as Apple Music seats the same control, and
  /// the quick-action row stays four playback controls that each report their state. In a
  /// centred column the bubble read as an isolated mark and forced a gutter on each side.
  enum Placement: Sendable, Equatable {
    case metadataTrailing
  }

  enum Action: Sendable, Equatable, Hashable {
    /// Saves an Audiobookshelf bookmark at the playhead. First, in a group of its own: a listener
    /// reaches for it mid-sentence, and it is the only entry that acts on the position.
    case addBookmark
    /// The item's own detail page: blurb, series, narrator, chapter list, and file details. A
    /// Continue Listening tap starts playback without visiting it, so the player needs its own
    /// route; History stays a direct entry too.
    case viewDetails
    /// The episode's on-device transcript. Something to read, so
    /// it joins View Details' group directly after it. Offered only for an episode the transcript
    /// coordinator reports eligible: downloaded, of an English show.
    case transcript
    /// Look Back: the minutes before the playhead of an audiobook as text, to find a lost place. Offered for every audiobook, after View Details; the
    /// sheet explains when the book is not downloaded. Never beside Transcript, which is
    /// episodes-only.
    case lookBack
    /// Past listening sessions, which live on the item-detail History tab that a Continue
    /// Listening tap does not visit. In the menu, not the quick-action row: an occasional "where
    /// did I leave off", not a per-session control.
    case history
    /// The book's companion PDF, or a list of them. "About this book" and non-destructive, so it
    /// sits with Details and History, ahead of the storage group.
    case viewSupplement
    case download
    case deleteDownload
    case deletingDownload
    case markAsFinished
    case resetProgress
  }

  /// Which family an action belongs to, and therefore where the menu's separators fall: a surface
  /// to look at, the download this device holds, the progress the server records, and the removal,
  /// which sits last as it does in every item menu.
  enum Group: Sendable, Equatable {
    case bookmark
    case surface
    case storage
    case progress
    case destructive
  }

  /// One drawn row: an action, or the shared progress submenu (`MediaItemMenuLayout`) holding
  /// several. The surfaces (Details, Transcript, Look Back, History) never fold.
  enum Entry: Sendable, Equatable, Hashable {
    case action(Action)
    case submenu(MediaItemMenuLayout.Submenu, [Action])
  }

  static let placement: Placement = .metadataTrailing

  /// The trigger is the glyph alone; a "More" label added little and the row is short of width.
  /// `PlayerOverflowMenu` still names the control for VoiceOver.
  static let symbol = "ellipsis"

  static func actions(
    downloadAction: ItemContextMenuDownloadAction,
    includesHistory: Bool,
    supplementCount: Int = 0,
    includesAddBookmark: Bool = false,
    includesTranscript: Bool = false,
    includesLookBack: Bool = false,
    playbackStatus: ItemPlaybackStatus?
  ) -> [Action] {
    let download: [Action] = downloadAction == .download ? [.download] : []
    let removal: [Action] =
      switch downloadAction {
      case .download: []
      case .remove: [.deleteDownload]
      case .unavailable: [.deletingDownload]
      }
    // The entries that change nothing lead and the removal comes last, keeping the destructive
    // end of the menu away from the finger that just opened it. Details precedes History because History is one tab of the
    // page Details opens, so the narrower entry cannot sit above the one that contains it.
    // Removing the item from Continue Listening is absent on the player surface: being on this
    // screen signals an active listening context, even while playback is paused.
    let progress = MediaProgressActionPolicy.actions(
      for: playbackStatus, isCurrentlyPlaying: true
    ).compactMap { action in
      switch action {
      case .markAsFinished: Action.markAsFinished
      case .resetProgress: Action.resetProgress
      case .removeFromContinueListening: nil
      }
    }
    return (includesAddBookmark ? [.addBookmark] : []) + [.viewDetails]
      + (includesTranscript ? [.transcript] : []) + (includesLookBack ? [.lookBack] : [])
      + (includesHistory ? [.history] : [])
      + (supplementCount > 0 ? [.viewSupplement] : []) + download + progress + removal
  }

  static func group(_ action: Action) -> Group {
    switch action {
    case .addBookmark: return .bookmark
    case .viewDetails, .transcript, .lookBack, .history, .viewSupplement: return .surface
    case .download: return .storage
    case .markAsFinished, .resetProgress: return .progress
    case .deleteDownload, .deletingDownload: return .destructive
    }
  }

  /// The menu as drawn: one array per group, with the progress pair folded into the shared
  /// submenu by the same rule every item menu follows.
  static func sections(_ actions: [Action]) -> [[Entry]] {
    var groups: [[Action]] = []
    for action in actions {
      if let previous = groups.last?.last, group(previous) == group(action) {
        groups[groups.count - 1].append(action)
      } else {
        groups.append([action])
      }
    }
    return groups.map { members in
      MediaItemMenuLayout.fold(
        members.map(Entry.action),
        key: { entry -> MediaItemMenuLayout.Submenu? in
          guard case .action(let action) = entry, group(action) == .progress else { return nil }
          return .progress
        },
        make: { submenu, entries in
          .submenu(
            submenu,
            entries.compactMap { entry in
              guard case .action(let action) = entry else { return nil }
              return action
            })
        })
    }
  }

  /// Whether a separator belongs above `action`. Derived from the group change rather than named
  /// per action, so adding an entry cannot silently land it inside the wrong group.
  static func dividerPrecedes(_ action: Action, in actions: [Action]) -> Bool {
    guard let index = actions.firstIndex(of: action), index > 0 else { return false }
    return group(actions[index - 1]) != group(action)
  }
}

nonisolated enum PlaybackRateMenuPresentation {
  struct Option: Sendable, Equatable, Identifiable {
    let rate: Double
    let isSelected: Bool

    var id: Double { rate }
  }

  static func options(encodedPresets: String, currentRate: Double) -> [Option] {
    var rates = PlaybackRatePresetConfiguration.decode(encodedPresets).rates
    if rates.contains(where: { abs($0 - currentRate) < 0.001 }) == false {
      rates.append(currentRate)
    }
    return rates.map { rate in
      Option(rate: rate, isSelected: abs(rate - currentRate) < 0.001)
    }
  }

  /// The speed a speed control shows. The live player's rate for the item it is playing; for any
  /// other title, that title's resolved speed, since PlayerCore resets to 1× when it goes idle.
  static func displayedRate(isLiveItem: Bool, liveRate: Double, titleRate: Double) -> Double {
    isLiveItem ? liveRate : titleRate
  }

  static let maximumGridColumns = 4
  static let maximumAccessibilityGridColumns = 2

  /// How many equal-width columns the speed card's grid uses. Four buttons fit across a phone at
  /// standard text sizes, two at accessibility sizes. Past that the grid gains rows, balanced so
  /// none is left nearly empty: six presets are 3 + 3, never 4 + 2.
  static func gridColumnCount(optionCount: Int, isAccessibilitySize: Bool) -> Int {
    guard optionCount > 0 else { return 0 }
    let maximum = isAccessibilitySize ? maximumAccessibilityGridColumns : maximumGridColumns
    let rowCount = (optionCount + maximum - 1) / maximum
    return (optionCount + rowCount - 1) / rowCount
  }
}

nonisolated enum SleepTimerMenuPresentation {
  enum Completion: Sendable, Equatable {
    case chapter
    case episode

    var title: String {
      switch self {
      case .chapter: "End of Chapter"
      case .episode: "End of Episode"
      }
    }
  }

  enum Option: Sendable, Equatable, Identifiable {
    case minutes(Int)
    case endOf(Completion)

    var id: String {
      switch self {
      case .minutes(let minutes): return "minutes-\(minutes)"
      case .endOf(let completion): return "end-of-\(completion)"
      }
    }
  }

  /// The item-boundary option a sleep-timer menu may offer: the episode boundary for a podcast,
  /// the chapter boundary for a book with a chapter map, and nothing unless the item on screen is
  /// the one actually loaded (a boundary timer on a retained item would end someone else's audio).
  static func completion(
    isLiveItem: Bool, episodeID: String?, liveItemHasChapters: Bool
  ) -> Completion? {
    guard isLiveItem else { return nil }
    if episodeID != nil { return .episode }
    return liveItemHasChapters ? .chapter : nil
  }

  static func options(encodedPresets: String, completion: Completion?) -> [Option] {
    var options = SleepTimerPresetConfiguration.decode(encodedPresets).minutes.map(Option.minutes)
    if let completion {
      options.append(.endOf(completion))
    }
    return options
  }

  static func activeLabel(
    for state: SleepTimerState, completion: Completion
  ) -> (compact: String?, accessible: String?) {
    guard case .endOfChapter = state.mode, completion == .episode else {
      return (state.compactRemainingText, state.accessibleRemainingText)
    }
    return ("Episode", "Until end of episode")
  }

  static func showsTurnOff(for state: SleepTimerState) -> Bool {
    state.mode != .off
  }

  /// The intent a menu row stands for. Kept here rather than in the view so the row and the
  /// selection below can never disagree about what a given option means.
  static func duration(for option: Option) -> SleepTimerDuration {
    switch option {
    case .minutes(let minutes): .custom(seconds: Double(minutes * 60))
    case .endOf(let completion): completion == .episode ? .endOfItem : .endOfChapter
    }
  }

  /// The `Option.id` the running timer corresponds to, or nil when no row describes it (none
  /// running, a typed custom timer, or a countdown extended past its setting); the nearest preset
  /// would misstate what tapping it does. Only `configuredSeconds` is consulted, or the checkmark
  /// would move down the menu as the timer ran.
  static func selectionID(
    mode: PlayerQuickActionsSleepTimerMode, completion: Completion?
  ) -> String? {
    switch mode {
    case .off:
      return nil
    case .endOfChapter:
      // The end-of-boundary row is only in the menu when a completion is offered; without one
      // there is no row to mark even though a boundary timer is running.
      return completion.map { Option.endOf($0).id }
    case .countdown(let configuredSeconds):
      guard let configuredSeconds, configuredSeconds.isFinite, configuredSeconds > 0 else {
        return nil
      }
      let minutes = configuredSeconds / 60
      let rounded = minutes.rounded()
      guard abs(minutes - rounded) < 0.001, rounded > 0 else { return nil }
      return Option.minutes(Int(rounded)).id
    }
  }
}
