/// The car's four destinations, in tab order.
public enum CarPlayTab: Sendable, Hashable, CaseIterable {
  case continueListening
  case books
  case podcasts
  case downloads

  public var title: String {
    switch self {
    case .continueListening: "Continue"
    case .books: "Books"
    case .podcasts: "Podcasts"
    case .downloads: "Downloads"
    }
  }
}

/// How the root is built. A car that permits fewer tabs than there are destinations gets one
/// list linking to them, never an oversized tab array.
public enum CarPlayRootLayout: Sendable, Equatable {
  case tabs([CarPlayTab])
  case list([CarPlayTab])

  public init(maximumTabCount: Int) {
    let tabs = CarPlayTab.allCases
    self = maximumTabCount >= tabs.count ? .tabs(tabs) : .list(tabs)
  }
}

/// One level of the car's navigation stack.
public enum CarPlayScreen: Sendable, Hashable {
  case root
  /// A destination opened from the root list, when the car does not permit tabs.
  case tab(CarPlayTab)
  case list(CarPlayBrowseRoute)
  case nowPlaying
  case upNext
  case chapters
}

/// The navigation budget. Audio apps get five levels; Now Playing sits at level four at most, so
/// Chapters or Up Next always has the fifth. The stack is tracked here because the system can
/// open Now Playing itself and the listener can go back without the app being asked.
public struct CarPlayNavigation: Sendable, Equatable {
  public static let maximumDepth = 5
  public static let nowPlayingMaximumDepth = 4

  public enum Step: Sendable, Equatable {
    case push(CarPlayScreen)
    case pop(to: CarPlayScreen)
  }

  public private(set) var stack: [CarPlayScreen] = [.root]

  public init() {}

  public var depth: Int { stack.count }
  public var top: CarPlayScreen { stack.last ?? .root }

  /// The template operations that bring `screen` to the top, applied to the stack as they are
  /// returned. Empty when it is already there; nil when showing it would break the budget or
  /// the screen has nothing to stand on.
  public mutating func show(_ screen: CarPlayScreen) -> [Step]? {
    if top == screen { return [] }
    if let index = stack.firstIndex(of: screen) {
      stack.removeSubrange((index + 1)...)
      return [.pop(to: screen)]
    }
    switch screen {
    case .root:
      return nil
    case .tab, .list:
      // A browse list must leave Now Playing a place at level four.
      guard stack.contains(.nowPlaying) == false, depth < Self.nowPlayingMaximumDepth - 1 else { return nil }
      stack.append(screen)
      return [.push(screen)]
    case .nowPlaying:
      guard depth < Self.nowPlayingMaximumDepth else { return nil }
      stack.append(screen)
      return [.push(screen)]
    case .upNext, .chapters:
      guard let index = stack.firstIndex(of: .nowPlaying) else { return nil }
      var steps: [Step] = []
      if index + 1 < stack.count {
        stack.removeSubrange((index + 1)...)
        steps.append(.pop(to: .nowPlaying))
      }
      stack.append(screen)
      return steps + [.push(screen)]
    }
  }

  /// Records a screen the car put on top without being asked: the system opening Now Playing,
  /// or the listener going back to a screen already beneath.
  public mutating func appeared(_ screen: CarPlayScreen) {
    if let index = stack.firstIndex(of: screen) {
      stack.removeSubrange((index + 1)...)
    } else if screen == .nowPlaying {
      stack.append(screen)
    }
  }

  public mutating func reset() { stack = [.root] }
}

/// What one list shows within the car's item limit. Page controls are rows too, so they are
/// counted here rather than left for the template to drop.
public struct CarPlayListLayout: Sendable, Equatable {
  /// Below this many content rows a paged list is not worth its two control rows.
  static let minimumPageSize = 4

  public let rows: [CarPlayBrowseRow]
  public let showsPrevious: Bool
  public let showsNext: Bool
  /// Rows exist that this list cannot reach; the list says so instead of implying it is whole.
  public let isTruncated: Bool

  public var itemCount: Int { rows.count + (showsPrevious ? 1 : 0) + (showsNext ? 1 : 0) }

  /// The page size to read so that a full page and both controls fit, or nil when the car
  /// allows too few items to page at all.
  public static func pageSize(maximumItemCount: Int, productLimit: Int) -> Int? {
    let size = min(productLimit, maximumItemCount - 2)
    return size >= minimumPageSize ? size : nil
  }

  public init(rows: [CarPlayBrowseRow], hasPrevious: Bool, hasNext: Bool, maximumItemCount: Int) {
    let capacity = max(0, maximumItemCount)
    let controls = (hasPrevious ? 1 : 0) + (hasNext ? 1 : 0)
    if rows.count + controls <= capacity {
      self.rows = rows
      showsPrevious = hasPrevious
      showsNext = hasNext
      isTruncated = false
    } else {
      // A control that led past rows this list had to drop would skip them for good.
      self.rows = Array(rows.prefix(capacity))
      showsPrevious = false
      showsNext = false
      isTruncated = true
    }
  }
}

/// A short alert. Titles run longest first; the car shows the first that fits.
public struct CarPlayAlert: Sendable, Equatable {
  public let titleVariants: [String]
  public let canRetry: Bool
}

/// What the car shows for the end of a selection. No case carries a title, an account or an
/// error's text.
public enum CarPlayFeedback: Sendable, Equatable {
  case none
  case showNowPlaying
  /// The row came from a replaced graph: rebuild the list rather than explain.
  case reload
  case alert(CarPlayAlert)

  public var alert: CarPlayAlert? {
    if case .alert(let alert) = self { alert } else { nil }
  }

  public init(_ outcome: CarPlaySelectionOutcome) {
    switch outcome {
    case .started: self = .showNowPlaying
    case .superseded, .cancelled: self = .none
    case .failed(let rejection): self.init(rejection)
    }
  }

  public init(_ rejection: CarPlayPlaybackRejection) {
    switch rejection {
    case .staleGeneration:
      self = .reload
    case .cancelled, .noActivePlayback, .invalidChapter, .invalidRate:
      // The control that sent it is already gone or about to be redrawn.
      self = .none
    case .preparationFailed:
      self = .alert(.init(titleVariants: ["Whirr couldn't start playback", "Couldn't play"], canRetry: true))
    case .accountUnavailable:
      self = .alert(
        .init(titleVariants: ["Open Whirr on your iPhone to sign in", "Sign in on iPhone"], canRetry: false))
    case .invalidSelection:
      self = .alert(.init(titleVariants: ["This is no longer available", "Not available"], canRetry: false))
    case .nothingToResume:
      self = .alert(.init(titleVariants: ["There is nothing to resume yet", "Nothing to resume"], canRetry: false))
    }
  }

  public init(_ failure: CarPlayLateFailure) {
    switch failure {
    case .failed(let isRecoverable):
      self = .alert(
        .init(titleVariants: ["Whirr couldn't start playback", "Couldn't play"], canRetry: isRecoverable))
    case .stalled:
      self = .alert(
        .init(titleVariants: ["Playback is waiting for a connection", "No connection"], canRetry: true))
    }
  }
}

/// A full-screen status in place of the browser.
public struct CarPlayStatusMessage: Sendable, Equatable {
  public let title: String
  public let detail: String
}

/// Why the car has no browser to show. Account setup and recovery stay on the phone, so each
/// message says where to go and offers no action.
public enum CarPlayRootState: Sendable, Equatable {
  case starting
  /// Before the first unlock since the phone restarted.
  case unlockPhone
  /// No account, or one that is being removed.
  case signedOut
  /// The library could not be opened.
  case unavailable
  case ready

  public var message: CarPlayStatusMessage? {
    switch self {
    case .ready:
      nil
    case .starting:
      .init(title: "Loading", detail: "Opening your library.")
    case .unlockPhone:
      .init(title: "Unlock iPhone", detail: "When safely parked, unlock your iPhone to open your library.")
    case .signedOut:
      .init(title: "Not Signed In", detail: "Open Whirr on your iPhone to sign in.")
    case .unavailable:
      .init(title: "Library Unavailable", detail: "Open Whirr on your iPhone for details.")
    }
  }
}

extension CarPlayBrowseRoute {
  /// What a list that is known to be empty says, as distinct from one still loading.
  public var emptyMessage: String {
    switch self {
    case .continueListening: "Nothing in progress"
    case .upNext: "Nothing is queued"
    case .recentBooks: "No recently added books"
    case .latestEpisodes: "No new episodes"
    case .audiobooks, .authorBooks, .seriesBooks: "No books"
    case .authors: "No authors"
    case .series: "No series"
    case .podcastShows: "No shows"
    case .showEpisodes: "No episodes"
    case .downloads: "No downloads"
    }
  }
}
