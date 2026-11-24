/// The sleep-timer shape that changes the native menu's structure. Remaining seconds are omitted:
/// they belong to `PlayerController.quickActionsSleepTimer`, which only the timer label should
/// read. The countdown's `configuredSeconds` is carried because it is the user's choice and
/// changes only when a timer is set, extended, or cleared, so the menu can mark it without a
/// per-second invalidation.
public enum PlayerQuickActionsSleepTimerMode: Sendable, Equatable {
  case off
  case countdown(configuredSeconds: Double?)
  case endOfChapter

  public var isOff: Bool { self == .off }

  init(_ state: SleepTimerState) {
    switch state.mode {
    case .off: self = .off
    case .countdown: self = .countdown(configuredSeconds: state.configuredSeconds)
    case .endOfChapter: self = .endOfChapter
    }
  }
}

/// Stable details about the loaded item needed by the quick-action row. Not a `PlayerItem`: the
/// row only needs identity, duration, and whether End of Chapter is available, none of which
/// changes with the playback position.
public struct PlayerQuickActionsItem: Sendable, Equatable {
  public let id: String
  public let episodeID: String?
  public let totalDuration: Double
  public let hasChapters: Bool

  public init(id: String, episodeID: String?, totalDuration: Double, hasChapters: Bool) {
    self.id = id
    self.episodeID = episodeID
    self.totalDuration = totalDuration
    self.hasChapters = hasChapters
  }
}

/// The quiet, menu-structure projection of `PlayerState`. It excludes the playhead and the live
/// countdown value so a steady playback tick cannot invalidate native `Menu` sources.
public struct PlayerQuickActionsState: Sendable, Equatable {
  public let rate: Double
  public let sleepTimerMode: PlayerQuickActionsSleepTimerMode
  public let item: PlayerQuickActionsItem?

  public var isSleepTimerActive: Bool { sleepTimerMode.isOff == false }

  public init(rate: Double, sleepTimerMode: PlayerQuickActionsSleepTimerMode, item: PlayerQuickActionsItem?) {
    self.rate = rate
    self.sleepTimerMode = sleepTimerMode
    self.item = item
  }

  init(state: PlayerState) {
    rate = state.rate
    sleepTimerMode = PlayerQuickActionsSleepTimerMode(state.sleepTimer)
    item = state.item.map { item in
      PlayerQuickActionsItem(
        id: item.id,
        episodeID: item.episodeID,
        totalDuration: item.timeline.totalDuration,
        hasChapters: item.chapters.chapters.isEmpty == false)
    }
  }
}
