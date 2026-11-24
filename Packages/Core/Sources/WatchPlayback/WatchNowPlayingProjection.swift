import Foundation
import WatchProtocol

/// What the Watch's Now Playing screen shows and which of its controls are live. The Watch has two
/// roles in one screen: the player for a title loaded on the Watch, and a remote control for the
/// phone's player. The devices are peers, so the phone's published owner decides nothing here:
/// focus follows what is playing, then what was listened to last, and remote transport
/// follows reachability.
public struct WatchNowPlayingProjection: Sendable, Equatable {
  /// The title loaded on the Watch, as the engine reports it.
  public struct LocalPlayback: Sendable, Equatable {
    public var selection: WatchSelection
    public var title: String
    public var playing: Bool
    /// Asked to play; a stream that is still buffering is wanted but not audible.
    public var wantsPlayback: Bool
    public var failure: String?
    /// When the Watch last listened to or moved this title, if this process saw it.
    public var lastListenedAt: Date?

    public init(
      selection: WatchSelection, title: String, playing: Bool, wantsPlayback: Bool, failure: String? = nil,
      lastListenedAt: Date? = nil
    ) {
      self.selection = selection
      self.title = title
      self.playing = playing
      self.wantsPlayback = wantsPlayback
      self.failure = failure
      self.lastListenedAt = lastListenedAt
    }
  }

  public struct Input: Sendable, Equatable {
    public var local: LocalPlayback?
    public var snapshot: WatchCatalogueSnapshot?
    public var snapshotIsStale: Bool
    /// A remote command is waiting for the phone's reply.
    public var commandPending: Bool
    /// What holds the library: a restore, install or logout, or a download starting.
    public var busyHolder: WatchBusyHolder?
    /// A move between devices started from this screen is in flight.
    public var moving: Bool
    /// The Watch's account is the account the phone is signed in to.
    public var accountsMatch: Bool
    /// The phone can be reached: tracked reachability holds and the last command reached it. Snapshot
    /// age is not reachability, because the phone publishes only on change.
    public var phoneReachable: Bool
    /// Native-feed titles the Watch holds a complete copy of. The wire never claims Watch
    /// playability for one, so only this says it can play here (ADR 0019).
    public var localNativeCopies: Set<WatchSelection>

    public init(
      local: LocalPlayback?, snapshot: WatchCatalogueSnapshot?, snapshotIsStale: Bool = false,
      commandPending: Bool = false, busyHolder: WatchBusyHolder? = nil, moving: Bool = false,
      accountsMatch: Bool = false,
      phoneReachable: Bool = true,
      localNativeCopies: Set<WatchSelection> = []
    ) {
      self.local = local
      self.snapshot = snapshot
      self.snapshotIsStale = snapshotIsStale
      self.commandPending = commandPending
      self.busyHolder = busyHolder
      self.moving = moving
      self.accountsMatch = accountsMatch
      self.phoneReachable = phoneReachable
      self.localNativeCopies = localNativeCopies
    }
  }

  public enum Subject: Sendable, Equatable {
    case watch(WatchSelection)
    case phone(WatchCatalogueItem)
    case none
  }

  /// What the play button does.
  public enum PlayIntent: Sendable, Equatable {
    case pauseWatch
    case resumeWatch
    case phone(WatchCommandAction)
    case none
  }

  public let subject: Subject
  public let title: String
  public let playing: Bool
  /// Asked to play on the Watch but not yet audible.
  public let loading: Bool
  public let busy: Bool
  /// The phone's retained title can be started there although its player is dormant.
  public let canStartPhonePlayback: Bool
  /// Skips, speed and the move to iPhone.
  public let controlsDisabled: Bool
  /// The play button and the move to Watch, which outlive a dormant phone player's transport.
  public let startingActionsDisabled: Bool
  public let playbackStatus: String?
  public let playButtonLabel: String
  public let audioOptionsDisabled: Bool
  /// The audio sheet offers the phone's destination section.
  public let offersPhoneOptions: Bool
  /// The phone's playback rate, when it is fresh and in range.
  public let phoneRate: Double?
  public let moveToPhoneDisabled: Bool
  /// Starting the phone's title on the Watch; it needs no phone, so only a busy library stops it.
  public let moveToWatchDisabled: Bool
  /// The phone is shown but cannot be reached: transport is off and "Play on Watch" is offered.
  public let phoneUnreachable: Bool
  /// The phone's title can be played on the Watch instead.
  public let offersPlayOnWatch: Bool
  public let playIntent: PlayIntent

  public var isWatch: Bool {
    if case .watch = subject { return true }
    return false
  }

  public var phoneItem: WatchCatalogueItem? {
    if case .phone(let item) = subject { return item }
    return nil
  }

  /// The title on screen, which is what its artwork must show: a title paused on the Watch sits
  /// behind the phone's player and is not the one shown.
  public var selection: WatchSelection? {
    switch subject {
    case .watch(let selection): selection
    case .phone(let item): item.selection
    case .none: nil
    }
  }

  public var hasSelection: Bool { subject != .none }

  public init(_ input: Input) {
    let snapshot = input.snapshot
    let currentPhoneItem = Self.phonePlayerItem(snapshot: snapshot)
    let phoneState = Self.phoneState(snapshot, isStale: input.snapshotIsStale)
    let phoneReports = currentPhoneItem != nil && (phoneState == .playing || phoneState == .paused)
    let local = input.local
    // Starting, seeking and handing off all want playback or move it; a paused title does not.
    let watchActive =
      local.map { ($0.wantsPlayback && $0.failure == nil) || $0.playing || input.moving } ?? false
    subject = Self.focus(
      local: local, watchActive: watchActive, phoneItem: currentPhoneItem, phoneState: phoneState,
      phoneReports: phoneReports)
    let showsWatch = Self.showsWatch(subject)
    let phoneItem = showsWatch ? nil : currentPhoneItem
    let shownLocal = showsWatch ? local : nil
    title = shownLocal?.title ?? phoneItem?.title ?? "Nothing playing"
    playing = shownLocal.map(\.playing) ?? (phoneItem != nil && phoneState == .playing)
    loading = shownLocal.map { !$0.playing && $0.wantsPlayback && $0.failure == nil } ?? false
    let availability = Self.availability(
      input: input, snapshot: snapshot, showsWatch: showsWatch, phoneItem: phoneItem,
      phoneState: phoneState, phoneReports: phoneReports, shownLocal: shownLocal, playing: playing,
      loading: loading)
    busy = availability.busy
    phoneUnreachable = availability.phoneUnreachable
    canStartPhonePlayback = availability.canStartPhonePlayback
    controlsDisabled = availability.controlsDisabled
    startingActionsDisabled = availability.startingActionsDisabled
    playbackStatus = Self.playbackStatus(
      shownLocal: shownLocal, playing: playing, loading: loading,
      phoneUnreachable: availability.phoneUnreachable, phoneItem: phoneItem, phoneState: phoneState)
    playButtonLabel = availability.playButtonLabel
    audioOptionsDisabled = availability.audioOptionsDisabled
    offersPhoneOptions = availability.offersPhoneOptions
    phoneRate = Self.selectedPlaybackRate(snapshot?.playbackRate, isStale: input.snapshotIsStale)
    moveToPhoneDisabled = availability.moveToPhoneDisabled
    moveToWatchDisabled = availability.moveToWatchDisabled
    offersPlayOnWatch = availability.offersPlayOnWatch
    playIntent = availability.playIntent
  }

  /// The screen focuses on what is playing, then on what was listened to last.
  private static func focus(
    local: LocalPlayback?, watchActive: Bool, phoneItem: WatchCatalogueItem?,
    phoneState: WatchPlaybackState?, phoneReports: Bool
  ) -> Subject {
    if let local,
      watchActive || !phoneReports
        || (phoneState != .playing && watchListenedLast(local, phone: phoneItem))
    {
      return .watch(local.selection)
    }
    if let phoneItem { return .phone(phoneItem) }
    return .none
  }

  private static func showsWatch(_ subject: Subject) -> Bool {
    if case .watch = subject { return true }
    return false
  }

  /// Which controls are live, given the focus and whether the phone can be reached.
  private struct Availability {
    let busy: Bool
    let phoneUnreachable: Bool
    let canStartPhonePlayback: Bool
    let controlsDisabled: Bool
    let startingActionsDisabled: Bool
    let playButtonLabel: String
    let audioOptionsDisabled: Bool
    let offersPhoneOptions: Bool
    let moveToPhoneDisabled: Bool
    let moveToWatchDisabled: Bool
    let offersPlayOnWatch: Bool
    let playIntent: PlayIntent
  }

  private static func availability(
    input: Input, snapshot: WatchCatalogueSnapshot?, showsWatch: Bool,
    phoneItem: WatchCatalogueItem?, phoneState: WatchPlaybackState?, phoneReports: Bool,
    shownLocal: LocalPlayback?, playing: Bool, loading: Bool
  ) -> Availability {
    // A download starting holds the library against a start, not against transport.
    let transportHeld = input.busyHolder.map { $0 != .downloading } ?? false
    let busy = input.moving || transportHeld || (!showsWatch && input.commandPending)
    let phoneUnreachable = phoneItem != nil && !input.phoneReachable
    let canStartPhonePlayback = phoneItem != nil && canStartPhonePlayer(snapshot: snapshot)
    let controlsDisabled =
      busy || (!showsWatch && (!canControlPhonePlayer(snapshot: snapshot) || phoneUnreachable))
    let startingActionsDisabled = busy || phoneUnreachable || (controlsDisabled && !canStartPhonePlayback)
    let playButtonLabel = playing || loading ? "Pause" : (canStartPhonePlayback ? "Play on iPhone" : "Resume")
    let hasSelection = showsWatch || phoneItem != nil
    let audioOptionsDisabled = !hasSelection || (!showsWatch && !phoneReports && !canStartPhonePlayback)
    let offersPhoneOptions = phoneItem != nil && (phoneReports || canStartPhonePlayback)
    let moveToPhoneDisabled = controlsDisabled || !input.accountsMatch || !input.phoneReachable
    let moveToWatchDisabled = input.moving || input.busyHolder != nil || !input.accountsMatch
    let offersPlayOnWatch =
      phoneUnreachable
      && phoneItem.map {
        WatchDestinationPreference.supports(
          .watch, selection: $0.selection, capabilities: $0.capabilities,
          hasLocalCopy: input.localNativeCopies.contains($0.selection))
      } == true
    let playIntent: PlayIntent
    if let shownLocal {
      playIntent = shownLocal.playing || loading ? .pauseWatch : .resumeWatch
    } else if phoneItem != nil {
      playIntent = canStartPhonePlayback ? .phone(.play) : .phone(phoneState == .paused ? .resume : .pause)
    } else {
      playIntent = .none
    }
    return Availability(
      busy: busy, phoneUnreachable: phoneUnreachable, canStartPhonePlayback: canStartPhonePlayback,
      controlsDisabled: controlsDisabled, startingActionsDisabled: startingActionsDisabled,
      playButtonLabel: playButtonLabel, audioOptionsDisabled: audioOptionsDisabled,
      offersPhoneOptions: offersPhoneOptions, moveToPhoneDisabled: moveToPhoneDisabled,
      moveToWatchDisabled: moveToWatchDisabled, offersPlayOnWatch: offersPlayOnWatch,
      playIntent: playIntent)
  }

  private static func playbackStatus(
    shownLocal: LocalPlayback?, playing: Bool, loading: Bool, phoneUnreachable: Bool,
    phoneItem: WatchCatalogueItem?, phoneState: WatchPlaybackState?
  ) -> String? {
    if let shownLocal {
      if let failure = shownLocal.failure {
        return failure
      } else if loading {
        return "Loading on Watch"
      } else {
        return "\(playing ? "Playing" : "Paused") on Watch"
      }
    } else if phoneUnreachable {
      return "iPhone not reachable"
    } else {
      return phoneItem == nil ? nil : phonePlaybackStatus(phoneState, isStale: false)
    }
  }

  /// The phone's current title. Whether it takes the screen is the focus rule's decision.
  /// of two paused players, the one listened to last is the one the listener left. A phone
  /// that sends no listen time (an older phone, or one relaunched since it played) counts as the
  /// older; a Watch with none yields to a phone that has one; a tie goes to the Watch.
  static func watchListenedLast(_ local: LocalPlayback, phone: WatchCatalogueItem?) -> Bool {
    guard let phoneListened = phone?.lastListenedAt else { return true }
    guard let watchListened = local.lastListenedAt else { return false }
    return watchListened >= phoneListened
  }

  public static func phonePlayerItem(snapshot: WatchCatalogueSnapshot?) -> WatchCatalogueItem? {
    snapshot?.items.first(where: \.isCurrentPlayback)
  }

  /// The phone's reported state, with a stale `playing` read as paused: a persisted
  /// snapshot survives relaunch, and a phone that stopped long ago must not hide the Watch.
  public static func phoneState(_ snapshot: WatchCatalogueSnapshot?, isStale: Bool) -> WatchPlaybackState? {
    guard let state = snapshot?.playbackState else { return nil }
    return isStale && state == .playing ? .paused : state
  }

  /// Transport reaches a phone player that is playing or paused on a current title.
  public static func canControlPhonePlayer(snapshot: WatchCatalogueSnapshot?) -> Bool {
    guard let snapshot, snapshot.accountStamp != nil, snapshot.items.contains(where: \.isCurrentPlayback)
    else { return false }
    return [.playing, .paused].contains(snapshot.playbackState)
  }

  /// The phone keeps publishing its retained current title after the player goes idle, fails, or
  /// has its audio session refused. Transport against a dormant player is meaningless, but starting
  /// that title again is exactly what the Now Playing card is for, so the play and move actions
  /// stay live where the controls beside them do not. A refused activation is worth retrying: the
  /// user may have freed the phone's audio session since the snapshot was published.
  public static func canStartPhonePlayer(snapshot: WatchCatalogueSnapshot?) -> Bool {
    guard let snapshot, snapshot.accountStamp != nil, !canControlPhonePlayer(snapshot: snapshot),
      let item = snapshot.items.first(where: \.isCurrentPlayback),
      WatchDestinationPreference.supports(.phone, selection: item.selection, capabilities: item.capabilities)
    else { return false }
    return [.idle, .failed, .unresolved].contains(snapshot.playbackState)
  }

  public static func phonePlaybackStatus(_ state: WatchPlaybackState?, isStale: Bool) -> String? {
    guard !isStale else { return nil }
    switch state {
    case .playing: return "Playing on iPhone"
    case .paused: return "Paused on iPhone"
    case .preparing: return "Loading on iPhone"
    case .idle, .failed, .unresolved, nil: return nil
    }
  }

  /// How long after a publication the phone's clock keeps running on the Watch. The phone
  /// republishes a playing position at least every 15 s, so twice that without one means the link
  /// or the phone has stopped, and the clock holds rather than inventing progress.
  public static let phonePositionEstimateWindow: TimeInterval = 30

  /// The phone's playhead at `now`, estimated as the system's Now Playing does: the published
  /// position plus the time since publication at the published rate, while the phone is playing.
  /// The phone republishes when its playhead leaves this line (a seek, a skip, trimmed silence), so
  /// the estimate only has to bridge its 15 s position cadence. It holds at the published chapter's
  /// end, whose crossing the phone publishes at once, and at the title's end.
  public static func estimatedPhonePosition(
    of item: WatchCatalogueItem, snapshot: WatchCatalogueSnapshot?, isStale: Bool, at now: Date
  ) -> Double {
    let published = item.progressSeconds
    guard let snapshot, phoneState(snapshot, isStale: isStale) == .playing,
      let rate = selectedPlaybackRate(snapshot.playbackRate, isStale: isStale)
    else { return published }
    let elapsed = min(max(0, now.timeIntervalSince(snapshot.generatedAt)), phonePositionEstimateWindow)
    var limit = item.durationSeconds ?? .infinity
    if let chapterEnd = item.chapterEndSeconds, chapterEnd > published { limit = min(limit, chapterEnd) }
    return max(published, min(published + elapsed * rate, limit))
  }

  public static func selectedPlaybackRate(_ rate: Double?, isStale: Bool) -> Double? {
    guard !isStale, let rate, rate.isFinite, (0.25...4).contains(rate) else { return nil }
    return rate
  }
}
