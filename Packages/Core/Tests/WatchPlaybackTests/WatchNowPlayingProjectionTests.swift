import Foundation
import Testing
import WatchProtocol

@testable import WatchPlayback

/// Now Playing under the peer model: focus follows what is playing, then what was listened to last, remote transport follows
/// reachability rather than snapshot age, and the phone's published owner decides nothing.
@Suite struct WatchNowPlayingProjectionTests {
  private let stamp = try! WatchAccountStamp(accountIdentityHash: "account", serverIdentityHash: "server")
  private let book = WatchSelection.audiobookshelf(itemID: "book", episodeID: nil)
  private let watchBook = WatchSelection.audiobookshelf(itemID: "watch-book", episodeID: nil)

  private let earlier = Date(timeIntervalSince1970: 1_790_000_000)
  private let later = Date(timeIntervalSince1970: 1_790_000_120)

  private func item(current: Bool = true, phonePlayable: Bool = true, listened: Date? = nil) -> WatchCatalogueItem {
    try! WatchCatalogueItem(
      id: "book", selection: book, title: "Phone book", progressSeconds: 60, durationSeconds: 600,
      isCurrentPlayback: current, capabilities: .init(phonePlayable: phonePlayable, watchPlayable: true),
      lastListenedAt: listened)
  }

  private func snapshot(
    state: WatchPlaybackState = .playing, items: [WatchCatalogueItem]? = nil, rate: Double? = nil
  ) -> WatchCatalogueSnapshot {
    try! WatchCatalogueSnapshot(
      accountStamp: stamp, items: items ?? [item()], playbackState: state, playbackRate: rate)
  }

  private func local(
    playing: Bool = true, wantsPlayback: Bool = true, failure: String? = nil, listened: Date? = nil
  ) -> WatchNowPlayingProjection.LocalPlayback {
    .init(
      selection: watchBook, title: "Watch book", playing: playing, wantsPlayback: wantsPlayback, failure: failure,
      lastListenedAt: listened)
  }

  private func project(
    local: WatchNowPlayingProjection.LocalPlayback? = nil, snapshot: WatchCatalogueSnapshot?,
    stale: Bool = false, pending: Bool = false, busy: WatchBusyHolder? = nil, moving: Bool = false,
    accountsMatch: Bool = true,
    reachable: Bool = true, localNativeCopies: Set<WatchSelection> = []
  ) -> WatchNowPlayingProjection {
    WatchNowPlayingProjection(
      .init(
        local: local, snapshot: snapshot, snapshotIsStale: stale, commandPending: pending, busyHolder: busy,
        moving: moving, accountsMatch: accountsMatch, phoneReachable: reachable,
        localNativeCopies: localNativeCopies))
  }

  // MARK: Remote control with the Watch idle

  @Test func phonePlayingIsShownAndControllable() {
    let view = project(snapshot: snapshot())
    #expect(view.subject == .phone(item()))
    #expect(view.title == "Phone book")
    #expect(view.playing)
    #expect(!view.loading)
    #expect(view.playbackStatus == "Playing on iPhone")
    #expect(!view.controlsDisabled)
    #expect(!view.startingActionsDisabled)
    #expect(!view.canStartPhonePlayback)
    #expect(view.playButtonLabel == "Pause")
    #expect(view.playIntent == .phone(.pause))
    #expect(!view.audioOptionsDisabled)
    #expect(view.offersPhoneOptions)
  }

  @Test func phonePausedResumesThere() {
    let view = project(snapshot: snapshot(state: .paused))
    #expect(!view.playing)
    #expect(view.playbackStatus == "Paused on iPhone")
    #expect(view.playButtonLabel == "Resume")
    #expect(view.playIntent == .phone(.resume))
    #expect(!view.controlsDisabled)
  }

  @Test func dormantPhonePlayerCanOnlyBeStartedAgain() {
    for state in [WatchPlaybackState.idle, .failed, .unresolved] {
      let view = project(snapshot: snapshot(state: state))
      #expect(view.canStartPhonePlayback, "\(state)")
      #expect(view.controlsDisabled)
      #expect(!view.startingActionsDisabled)
      #expect(view.playButtonLabel == "Play on iPhone")
      #expect(view.playIntent == .phone(.play))
      #expect(!view.audioOptionsDisabled)
      #expect(view.offersPhoneOptions)
      #expect(view.playbackStatus == nil)
    }
  }

  @Test func aTitleThePhoneCannotPlayIsShownButInert() {
    let view = project(snapshot: snapshot(state: .idle, items: [item(phonePlayable: false)]))
    #expect(view.phoneItem != nil)
    #expect(!view.canStartPhonePlayback)
    #expect(view.controlsDisabled)
    #expect(view.startingActionsDisabled)
    #expect(view.audioOptionsDisabled)
    #expect(!view.offersPhoneOptions)
  }

  @Test func phonePreparingShowsLoadingButAcceptsNoTransport() {
    let view = project(snapshot: snapshot(state: .preparing))
    #expect(view.playbackStatus == "Loading on iPhone")
    #expect(view.controlsDisabled)
    #expect(view.startingActionsDisabled)
    #expect(view.playIntent == .phone(.pause))
  }

  /// A stale `playing` report reads as paused; age disables no control.
  @Test func aStalePlayingReportReadsAsPaused() {
    let view = project(snapshot: snapshot(rate: 1.5), stale: true)
    #expect(view.playbackStatus == "Paused on iPhone")
    #expect(!view.playing)
    #expect(view.playIntent == .phone(.resume))
    #expect(view.phoneRate == nil)
    #expect(!view.controlsDisabled)
    #expect(project(snapshot: snapshot(rate: 1.5)).phoneRate == 1.5)
    let paused = project(snapshot: snapshot(state: .paused), stale: true)
    #expect(paused.playbackStatus == "Paused on iPhone")
    #expect(!paused.controlsDisabled)
  }

  // MARK: The phone out of reach

  @Test func anUnreachablePhoneDisablesTransportAndOffersPlayOnWatch() {
    for state in [WatchPlaybackState.playing, .paused, .idle] {
      let view = project(snapshot: snapshot(state: state), reachable: false)
      #expect(view.subject == .phone(item()), "\(state)")
      #expect(view.phoneUnreachable)
      #expect(view.playbackStatus == "iPhone not reachable")
      #expect(view.controlsDisabled)
      #expect(view.startingActionsDisabled)
      #expect(view.offersPlayOnWatch)
      #expect(!view.moveToWatchDisabled)
    }
    let reachable = project(snapshot: snapshot())
    #expect(!reachable.phoneUnreachable)
    #expect(!reachable.offersPlayOnWatch)
  }

  @Test func anUnreachablePhoneOffersPlayOnWatchEvenWithAPausedWatchTitle() {
    let view = project(
      local: local(playing: false, wantsPlayback: false, listened: later),
      snapshot: snapshot(state: .playing, items: [item(listened: later.addingTimeInterval(1))]), reachable: false)
    #expect(view.subject == .phone(item(listened: later.addingTimeInterval(1))))
    #expect(view.offersPlayOnWatch)
    #expect(!view.moveToWatchDisabled)
  }

  @Test func aPhoneTitleTheWatchCannotPlayOffersNoPlayOnWatch() {
    let item = try! WatchCatalogueItem(
      id: "book", selection: book, title: "Phone book", progressSeconds: 60, durationSeconds: 600,
      isCurrentPlayback: true, capabilities: .init(phonePlayable: true, watchPlayable: false))
    let view = project(snapshot: snapshot(items: [item]), reachable: false)
    #expect(view.phoneUnreachable)
    #expect(!view.offersPlayOnWatch)
  }

  /// ADR 0019: a native episode the phone says is not watch-playable is playable here once the
  /// Watch holds the copy the phone sent.
  @Test func aSentNativeEpisodeIsPlayableOnWatchWhenThePhoneIsUnreachable() {
    let native = WatchSelection.nativeFeed(feedID: "feed", episodeID: "episode")
    let item = try! WatchCatalogueItem(
      id: "feed:episode", selection: native, title: "Native episode", progressSeconds: 60,
      durationSeconds: 600, isCurrentPlayback: true,
      capabilities: .init(phonePlayable: true, watchPlayable: false))
    let snapshot = snapshot(items: [item])
    #expect(!project(snapshot: snapshot, reachable: false).offersPlayOnWatch)
    #expect(project(snapshot: snapshot, reachable: false, localNativeCopies: [native]).offersPlayOnWatch)
  }

  /// Reachability is about the phone's player; it never gates the Watch's own title.
  @Test func anUnreachablePhoneDoesNotGateTheWatch() {
    let view = project(local: local(), snapshot: snapshot(), reachable: false)
    #expect(view.isWatch)
    #expect(!view.phoneUnreachable)
    #expect(!view.controlsDisabled)
    #expect(view.moveToPhoneDisabled)
  }

  @Test func aPendingCommandDisablesRemoteControl() {
    let view = project(snapshot: snapshot(), pending: true)
    #expect(view.busy)
    #expect(view.controlsDisabled)
    #expect(view.startingActionsDisabled)
  }

  @Test func accountMismatchDoesNotGateTransport() {
    let view = project(snapshot: snapshot(), accountsMatch: false)
    #expect(!view.controlsDisabled)
    #expect(!view.startingActionsDisabled)
  }

  @Test func nothingCurrentShowsNothingPlaying() {
    for snapshot in [
      snapshot(items: [item(current: false)]), try! WatchCatalogueSnapshot(accountStamp: nil, items: []), nil,
    ] {
      let view = project(snapshot: snapshot)
      #expect(view.subject == .none)
      #expect(!view.hasSelection)
      #expect(view.title == "Nothing playing")
      #expect(view.audioOptionsDisabled)
      #expect(view.playIntent == .none)
    }
  }

  // MARK: A title loaded on the Watch

  // MARK: Focus

  /// A playing, starting or moving Watch title takes the screen even over a playing phone.
  @Test func anActiveWatchTitleTakesFocus() {
    let cases: [(WatchNowPlayingProjection.LocalPlayback, Bool)] = [
      (local(playing: true, wantsPlayback: true), false),
      (local(playing: false, wantsPlayback: true), false),
      (local(playing: false, wantsPlayback: false), true),
    ]
    for (playback, moving) in cases {
      let view = project(local: playback, snapshot: snapshot(), moving: moving)
      #expect(view.subject == .watch(watchBook))
      #expect(view.selection == watchBook)
      #expect(view.phoneItem == nil)
      #expect(view.title == "Watch book")
      #expect(!view.canStartPhonePlayback)
      #expect(!view.offersPhoneOptions)
    }
    let playing = project(local: local(), snapshot: snapshot())
    #expect(playing.playbackStatus == "Playing on Watch")
    #expect(playing.playIntent == .pauseWatch)
    #expect(!playing.controlsDisabled)
  }

  /// A title merely paused on the Watch never hides a playing phone, whenever it was last heard,
  /// nor a paused phone that listened since. The one move back is "Move to Watch", which starts from
  /// the phone's position, the newer of the two.
  @Test func aPausedWatchTitleYieldsToAPlayingPhoneOrOneThatListenedSince() {
    let cases: [(WatchPlaybackState, Date?)] = [(.playing, nil), (.playing, later), (.paused, later)]
    for (state, watchListened) in cases {
      let phoneItem = item(listened: state == .playing ? earlier : later.addingTimeInterval(1))
      let view = project(
        local: local(playing: false, wantsPlayback: false, listened: watchListened),
        snapshot: snapshot(state: state, items: [phoneItem]))
      #expect(view.subject == .phone(phoneItem), "\(state)")
      #expect(view.title == "Phone book")
      #expect(view.selection == item().selection, "the artwork is the shown title's, not the Watch's")
      #expect(view.playing == (state == .playing))
      #expect(view.playIntent == .phone(state == .playing ? .pause : .resume))
      #expect(!view.controlsDisabled)
    }
  }

  /// Pausing on the Watch keeps the Watch on screen while the phone sits paused on what it
  /// heard before, including a stale "playing" and a phone that sends no listen time. A tie goes
  /// to the Watch.
  @Test func aPausedWatchTitleKeepsFocusOverAPhoneThatListenedBefore() {
    let cases: [(state: WatchPlaybackState, stale: Bool, phone: Date?, watch: Date?)] = [
      (.paused, false, earlier, later),
      (.paused, false, later, later),
      (.paused, false, nil, later),
      (.paused, false, nil, nil),
      (.playing, true, earlier, later),
    ]
    for c in cases {
      let view = project(
        local: local(playing: false, wantsPlayback: false, listened: c.watch),
        snapshot: snapshot(state: c.state, items: [item(listened: c.phone)]), stale: c.stale)
      #expect(view.subject == .watch(watchBook), "\(c)")
      #expect(view.playbackStatus == "Paused on Watch")
      #expect(view.playIntent == .resumeWatch)
    }
  }

  /// With the phone dormant or absent, the paused Watch title keeps the screen.
  @Test func aPausedWatchTitleKeepsFocusOverADormantPhone() {
    for snapshot in [snapshot(state: .idle), snapshot(state: .preparing), snapshot(items: [item(current: false)]), nil]
    {
      let view = project(local: local(playing: false, wantsPlayback: false), snapshot: snapshot)
      #expect(view.subject == .watch(watchBook))
      #expect(view.playbackStatus == "Paused on Watch")
      #expect(view.playIntent == .resumeWatch)
    }
  }

  @Test func aBufferingWatchStreamShowsLoadingAndPauses() {
    let view = project(local: local(playing: false, wantsPlayback: true), snapshot: nil)
    #expect(view.loading)
    #expect(view.playbackStatus == "Loading on Watch")
    #expect(view.playButtonLabel == "Pause")
    #expect(view.playIntent == .pauseWatch)
  }

  @Test func aWatchFailureReplacesTheStatus() {
    let view = project(local: local(playing: false, wantsPlayback: true, failure: "Lost it"), snapshot: nil)
    #expect(!view.loading)
    #expect(view.playbackStatus == "Lost it")
    #expect(view.playIntent == .resumeWatch)
  }

  @Test func aPendingPhoneCommandDoesNotBlockTheWatch() {
    let view = project(local: local(), snapshot: snapshot(), pending: true)
    #expect(!view.busy)
    #expect(!view.controlsDisabled)
  }

  @Test func aBusyLibraryOrMoveDisablesEverything() {
    let held: [(WatchBusyHolder?, Bool)] = [
      (.restoring, false), (.installing, false), (.signingOut, false), (nil, true),
    ]
    for (busy, moving) in held {
      let view = project(local: local(), snapshot: nil, busy: busy, moving: moving)
      #expect(view.busy)
      #expect(view.controlsDisabled)
      #expect(view.startingActionsDisabled)
    }
  }

  /// A download starting does not take transport away from a title already playing here, but a
  /// move to the Watch waits for it, since a start would be refused while it holds the library.
  @Test func aStartingDownloadLeavesTheWatchTransportAlone() {
    let view = project(local: local(), snapshot: snapshot(), busy: .downloading)
    #expect(!view.busy)
    #expect(!view.controlsDisabled)
    #expect(view.moveToWatchDisabled)
  }

  @Test func movingToThePhoneNeedsMatchingAccountsAndReach() {
    #expect(!project(local: local(), snapshot: snapshot()).moveToPhoneDisabled)
    #expect(project(local: local(), snapshot: snapshot(), accountsMatch: false).moveToPhoneDisabled)
    #expect(project(local: local(), snapshot: snapshot(), reachable: false).moveToPhoneDisabled)
  }

  @Test func phoneStateReadsOnlyAStalePlayingAsPaused() {
    #expect(WatchNowPlayingProjection.phoneState(snapshot(), isStale: true) == .paused)
    #expect(WatchNowPlayingProjection.phoneState(snapshot(), isStale: false) == .playing)
    #expect(WatchNowPlayingProjection.phoneState(snapshot(state: .preparing), isStale: true) == .preparing)
    #expect(WatchNowPlayingProjection.phoneState(nil, isStale: true) == nil)
  }

  // MARK: Helpers kept for the navigation policy

  @Test func phonePlaybackStatusCopy() {
    #expect(WatchNowPlayingProjection.phonePlaybackStatus(.playing, isStale: false) == "Playing on iPhone")
    #expect(WatchNowPlayingProjection.phonePlaybackStatus(.paused, isStale: false) == "Paused on iPhone")
    #expect(WatchNowPlayingProjection.phonePlaybackStatus(.preparing, isStale: false) == "Loading on iPhone")
    for state in [WatchPlaybackState.idle, .failed, .unresolved] {
      #expect(WatchNowPlayingProjection.phonePlaybackStatus(state, isStale: false) == nil)
    }
    for state in [WatchPlaybackState.playing, .paused, .preparing, .idle, .failed, .unresolved] {
      #expect(WatchNowPlayingProjection.phonePlaybackStatus(state, isStale: true) == nil, "\(state)")
    }
    #expect(WatchNowPlayingProjection.phonePlaybackStatus(nil, isStale: false) == nil)
  }

  /// Moved from the `NavigationRegression` host program: the published state alone
  /// decides control and restart.
  @Test func phonePlayerRulesFollowThePublishedStateAlone() {
    for state in [WatchPlaybackState.idle, .unresolved, .preparing, .failed, .paused, .playing] {
      let published = snapshot(state: state)
      let canControl = WatchNowPlayingProjection.canControlPhonePlayer(snapshot: published)
      let canStart = WatchNowPlayingProjection.canStartPhonePlayer(snapshot: published)
      #expect(WatchNowPlayingProjection.phonePlayerItem(snapshot: published) == item(), "\(state)")
      #expect(canControl == [.playing, .paused].contains(state), "\(state)")
      #expect(canStart == [.idle, .failed, .unresolved].contains(state), "\(state)")
      #expect(!(canStart && canControl), "\(state)")
    }
  }

  @Test func noCurrentTitleMeansNoPhonePlayer() {
    let library = try! WatchCatalogueItem(
      id: "library", selection: .audiobookshelf(itemID: "library", episodeID: nil), title: "Library book",
      capabilities: .init(phonePlayable: true, watchPlayable: false))
    let withoutCurrent = snapshot(state: .playing, items: [library])
    let signedOut = try! WatchCatalogueSnapshot(accountStamp: nil, items: [])
    for published in [withoutCurrent, signedOut, nil] as [WatchCatalogueSnapshot?] {
      #expect(WatchNowPlayingProjection.phonePlayerItem(snapshot: published) == nil)
      #expect(!WatchNowPlayingProjection.canControlPhonePlayer(snapshot: published))
      #expect(!WatchNowPlayingProjection.canStartPhonePlayer(snapshot: published))
    }
  }

  @Test func aTitleThePhoneCannotPlayCannotBeStartedThere() {
    let published = snapshot(state: .idle, items: [item(phonePlayable: false)])
    #expect(!WatchNowPlayingProjection.canStartPhonePlayer(snapshot: published))
  }

  @Test func selectedPlaybackRateBounds() {
    #expect(WatchNowPlayingProjection.selectedPlaybackRate(1.25, isStale: false) == 1.25)
    #expect(WatchNowPlayingProjection.selectedPlaybackRate(0.2, isStale: false) == nil)
    #expect(WatchNowPlayingProjection.selectedPlaybackRate(4.5, isStale: false) == nil)
    for invalid in [Double.nan, .infinity, 0, 0.24, 4.01] {
      #expect(WatchNowPlayingProjection.selectedPlaybackRate(invalid, isStale: false) == nil, "\(invalid)")
    }
    #expect(WatchNowPlayingProjection.selectedPlaybackRate(1.35, isStale: true) == nil)
    #expect(WatchNowPlayingProjection.selectedPlaybackRate(nil, isStale: false) == nil)
  }

  // MARK: The phone's clock between publications

  private let published = Date(timeIntervalSinceReferenceDate: 800_000_000)

  private func clockItem(
    progress: Double = 60, duration: Double? = 600, chapter: (start: Double, end: Double)? = nil
  ) -> WatchCatalogueItem {
    try! WatchCatalogueItem(
      id: "book", selection: book, title: "Phone book", progressSeconds: progress, durationSeconds: duration,
      isCurrentPlayback: true, chapterTitle: chapter == nil ? nil : "Chapter 2",
      chapterStartSeconds: chapter?.start, chapterEndSeconds: chapter?.end,
      capabilities: .init(phonePlayable: true, watchPlayable: true))
  }

  private func clockSnapshot(
    _ item: WatchCatalogueItem, state: WatchPlaybackState = .playing, rate: Double? = 1
  ) -> WatchCatalogueSnapshot {
    try! WatchCatalogueSnapshot(
      accountStamp: stamp, generatedAt: published, items: [item], playbackState: state, playbackRate: rate)
  }

  private func estimate(
    _ item: WatchCatalogueItem, _ snapshot: WatchCatalogueSnapshot, after seconds: TimeInterval, stale: Bool = false
  ) -> Double {
    WatchNowPlayingProjection.estimatedPhonePosition(
      of: item, snapshot: snapshot, isStale: stale, at: published.addingTimeInterval(seconds))
  }

  @Test func aPlayingPhoneAdvancesFromItsPublishedPositionAtItsRate() {
    let item = clockItem()
    #expect(estimate(item, clockSnapshot(item), after: 0) == 60)
    #expect(estimate(item, clockSnapshot(item), after: 7) == 67)
    #expect(estimate(item, clockSnapshot(item, rate: 1.5), after: 10) == 75)
  }

  @Test func onlyAPlayingPhoneAdvances() {
    let item = clockItem()
    for state in [WatchPlaybackState.paused, .preparing, .idle, .failed, .unresolved] {
      #expect(estimate(item, clockSnapshot(item, state: state), after: 10) == 60, "\(state)")
    }
    #expect(estimate(item, clockSnapshot(item), after: 10, stale: true) == 60)
    #expect(estimate(item, clockSnapshot(item, rate: nil), after: 10) == 60)
  }

  /// The phone republishes a playing position at least every 15 s, so a longer silence means the
  /// link or the phone has stopped and the clock must not run on regardless.
  @Test func theEstimateStopsWhenPublicationsStop() {
    let item = clockItem()
    let window = WatchNowPlayingProjection.phonePositionEstimateWindow
    #expect(estimate(item, clockSnapshot(item), after: window) == 60 + window)
    #expect(estimate(item, clockSnapshot(item), after: window + 60) == 60 + window)
  }

  /// A Watch clock a little behind the phone's must not run the position backwards.
  @Test func aPublicationFromTheWatchsFutureHoldsThePublishedPosition() {
    let item = clockItem()
    #expect(estimate(item, clockSnapshot(item), after: -2) == 60)
  }

  @Test func theEstimateStopsAtTheEndOfTheTitle() {
    let item = clockItem(progress: 595, duration: 600)
    #expect(estimate(item, clockSnapshot(item), after: 10) == 600)
    let unknownLength = clockItem(progress: 595, duration: nil)
    #expect(estimate(unknownLength, clockSnapshot(unknownLength), after: 10) == 605)
  }

  /// Crossing into the next chapter is a change the phone publishes at once; until it lands the
  /// published chapter's clock holds at its end rather than overrunning it.
  @Test func theEstimateStopsAtTheEndOfThePublishedChapter() {
    let item = clockItem(progress: 295, chapter: (start: 200, end: 300))
    #expect(estimate(item, clockSnapshot(item), after: 3) == 298)
    #expect(estimate(item, clockSnapshot(item), after: 10) == 300)
  }
}
