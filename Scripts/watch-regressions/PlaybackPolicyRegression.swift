import ABSApi
import WatchConnectivity

// Same-file extension runs the actual model authorization and controls with hardware stubs.
extension WatchLibraryModel {
  static func runPlaybackPolicyRegression() async throws {
    let model = WatchLibraryModel(companion: WatchCompanionStore(), protectedStore: hostProtectedStore())
    model.account = try WatchAccountRecord(serverURL: URL(string: "https://example.invalid")!, userID: "user")
    let selection = WatchSelection.audiobookshelf(itemID: "book", episodeID: nil)
    let stamp = try model.account!.authenticatedStamp()
    precondition(model.audio.backwardSkipSeconds == 15 && model.audio.forwardSkipSeconds == 30)
    model.companion.snapshot = try WatchCatalogueSnapshot(
      accountStamp: stamp, items: [], skipBackwardSeconds: 10, skipForwardSeconds: 45)
    await hostAwait(
      "the phone's skip intervals",
      observing: { "back \(model.audio.backwardSkipSeconds), forward \(model.audio.forwardSkipSeconds)" },
      until: {
        model.audio.backwardSkipSeconds == 10
      })
    precondition(model.audio.backwardSkipSeconds == 10 && model.audio.forwardSkipSeconds == 45)
    model.companion.snapshot = try WatchCatalogueSnapshot(accountStamp: nil, items: [])
    await hostAwait(
      "the default skip intervals",
      observing: { "back \(model.audio.backwardSkipSeconds), forward \(model.audio.forwardSkipSeconds)" },
      until: {
        model.audio.backwardSkipSeconds == 15
      })
    precondition(model.audio.backwardSkipSeconds == 15 && model.audio.forwardSkipSeconds == 30)
    _ = selection
    try await anUnreadableReceiptAnswersBusyAndIsKept()
    try await signOutClearsProtectedState()
    try await streamedStartPausesResumesAndStops()
    try await startFailingBeforeTheRowLeavesNothingLoaded()
    try await startFailingAfterTheRowRollsItBack()
    try await aStopDuringAStartLeavesNothing()
    try await aPauseDuringASeekLandsPausedAtTheTarget()
    try await quickSkipsAddUp()
    try await anUnauthorizedStreamRenewsOnce()
    try await aLostStreamPausesWithAMessage()
    try await anInterruptionPausesAndResumesWhatItPaused()
    try await refusedStartsSaySoOrNot()
    try await aStartAsksAPlayingPhoneOnlyAboutItsOwnTitle()
    try await aPhoneHandoffPausesAndKeepsTheTitle()
    try await aNativeCopyPlaysWithoutAServerRead()
    try await aNativeCopyMissingSaysToSendIt()
    try await aNativePauseRequestPausesOnlyItsOwnTitle()
    try await aDroppedNativeCopyStopsPlayback()
    try await aFinishedNativeEpisodeLosesItsCopy()
    try await continueOnPhoneUnloadsOnlyOnceThePhoneAccepts()
    try await cancelledOperationsShowNoMessage()
    try await aTitleFinishedElsewhereReplaysFromTheStart()
    try await groupedDownloadsKeepAccountFence()
    await cancellationBelongsToSessionLifecycle()
    await repeatedMessagesStayObservable()
    try await failedAudioIsReported()
    try await aPhoneCatalogueWithNothingWaitingStartsNoUpload()
    print("watch playback policy regressions passed")
  }

  // MARK: The real controller over a host service graph

  /// A streamed start through the real controller: the 3 s shared-progress race, the independent
  /// preparation, the open progress row, the audio and the playing report, in today's order.
  @MainActor
  private static func streamedStartPausesResumesAndStops() async throws {
    let host = try await HostPlayback()
    defer { host.tearDown() }
    let model = host.model
    let started = await model.play(host.selection)
    precondition(started, "a streamable title did not start: \(model.message ?? "no message")")
    precondition(model.currentSelection == host.selection)
    precondition(model.playback.localPlaybackLoaded)
    precondition(model.audio.isPlaying && model.message == nil)
    precondition(host.playingReport()?.playing == true, "a start did not report playing to the phone")
    precondition(model.playback.offlineSessionID != nil, "a started title has no open progress row")
    let opened = await host.rows()
    precondition(opened.count == 1 && opened[0].selection == host.selection)

    await model.pause()
    precondition(!model.audio.isPlaying)
    precondition(model.playback.offlineSessionID == nil, "a paused title kept its row open")
    precondition(model.playback.localPlaybackLoaded && model.currentSelection == host.selection)
    precondition(host.playingReport()?.playing == false, "a pause did not report it to the phone")
    await model.pause()
    precondition(model.playback.localPlaybackLoaded, "a second pause unloaded the local title")

    await model.resume()
    precondition(model.audio.isPlaying, "resume did not play the paused title")
    precondition(model.playback.offlineSessionID != nil, "resume did not reopen a progress row")

    await model.stopPlayback()
    precondition(!model.audio.isPlaying && model.currentSelection == nil)
    precondition(!model.playback.localPlaybackLoaded)
    precondition(model.playback.offlineSessionID == nil)
    precondition(model.playback.retainedSelection == host.selection, "stop did not keep a bookmark")
  }

  @MainActor
  private static func startFailingBeforeTheRowLeavesNothingLoaded() async throws {
    let host = try await HostPlayback(detailAvailable: false)
    defer { host.tearDown() }
    let model = host.model
    let started = await model.play(host.selection)
    precondition(!started)
    precondition(
      model.message == "Couldn’t start on Watch. Check the connection and audio output, then retry.",
      "a failed start did not say so")
    precondition(model.currentSelection == nil && !model.playback.localPlaybackLoaded)
    precondition(model.playback.offlineSessionID == nil && !model.audio.isPlaying)
    let rowsAfterFailure = await host.rows()
    precondition(rowsAfterFailure.isEmpty, "a start that failed before the row wrote one")
    precondition(!model.busy)
  }

  /// A start that fails after its row opened ends fully stopped: nothing selected or loaded,
  /// the row gone, the bookmark untouched, and one message.
  @MainActor
  private static func startFailingAfterTheRowRollsItBack() async throws {
    let host = try await HostPlayback()
    defer { host.tearDown() }
    let model = host.model
    model.audio.playFailure = HostFailure.refused
    let started = await model.play(host.selection)
    precondition(!started && !model.audio.isPlaying)
    precondition(model.message == "Couldn’t start on Watch. Check the connection and audio output, then retry.")
    precondition(model.currentSelection == nil, "a failed start kept the selection")
    precondition(!model.playback.localPlaybackLoaded, "a failed start kept the title loaded")
    precondition(model.playback.offlineSessionID == nil, "a failed start left its row open")
    let rows = await host.rows()
    precondition(rows.isEmpty, "a failed start left a row behind")
    precondition(model.playback.retainedSelection == nil, "a failed start wrote a bookmark")
    model.audio.playFailure = nil
  }

  /// A stop while a start waits for the phone supersedes it. Nothing is loaded after,
  /// and the cancelled start says nothing.
  @MainActor
  private static func aStopDuringAStartLeavesNothing() async throws {
    let host = try await HostPlayback()
    defer {
      host.tearDown()
      WatchPeerMessageSender.handler = nil
      WatchPeerMessageSender.timeouts = []
    }
    let model = host.model
    var held: CheckedContinuation<Void, Never>?
    WatchPeerMessageSender.handler = { _, _ in
      await withCheckedContinuation { held = $0 }
      return nil
    }
    model.companion.phoneReportsPlaying = true
    model.companion.currentItem = try host.item(host.selection)
    let start = Task { await model.play(host.selection) }
    await hostAwait("the start to ask the phone") { held != nil }
    precondition(held != nil && model.currentSelection == host.selection, "a start was not shown at once")
    let stop = Task { await model.stopPlayback() }
    await hostAwait(
      "the stop to reach the machine", observing: { "\(String(describing: model.currentSelection))" },
      until: {
        model.currentSelection == nil
      })
    held?.resume()
    let started = await start.value
    await stop.value
    precondition(!started && model.currentSelection == nil, "a stopped start went on")
    precondition(!model.playback.localPlaybackLoaded && !model.audio.isPlaying, "a stopped start loaded")
    precondition(model.message == nil, "a stopped start said \(model.message ?? "")")
    let rows = await host.rows()
    precondition(rows.isEmpty, "a stopped start wrote a row")
  }

  /// A pause while a seek is in flight lets the seek land, paused at its target, with no
  /// message.
  @MainActor
  private static func aPauseDuringASeekLandsPausedAtTheTarget() async throws {
    let host = try await HostPlayback()
    defer { host.tearDown() }
    let model = host.model
    let started = await model.play(host.selection)
    precondition(started)
    model.audio.holdSeeks = true
    let seek = Task { await model.seek(to: 200) }
    await hostAwait("the seek to reach the engine") { model.audio.heldSeeks.isEmpty == false }
    let pause = Task { await model.pause() }
    await hostAwait(
      "the pause to silence the engine",
      observing: {
        "playing \(model.audio.isPlaying), row \(model.playback.offlineSessionID != nil), message \(model.message ?? "none")"
      },
      until: {
        model.audio.isPlaying == false
      })
    precondition(!model.audio.isPlaying, "a pause during a seek did not silence at once")
    model.audio.releaseSeeks()
    await seek.value
    await pause.value
    precondition(model.audio.position == 200, "a paused seek did not land: \(model.audio.position)")
    precondition(!model.audio.isPlaying && model.message == nil, "a paused seek played or said something")
    precondition(model.currentSelection == host.selection && model.playback.offlineSessionID == nil)
    await model.stopPlayback()
  }

  /// Skips asked for while a seek is in flight add to its target, not to the sampled position.
  @MainActor
  private static func quickSkipsAddUp() async throws {
    let host = try await HostPlayback()
    defer { host.tearDown() }
    let model = host.model
    let started = await model.play(host.selection)
    precondition(started)
    let from = model.audio.position
    model.audio.holdSeeks = true
    for _ in 0..<3 { model.skip(by: 30) }
    await hostAwait("the skips to reach the engine") { model.audio.heldSeeks.isEmpty == false }
    model.audio.releaseSeeks()
    await model.pause()
    precondition(model.audio.position == from + 90, "three skips moved to \(model.audio.position) from \(from)")
    precondition(model.message == nil, "superseded skips said \(model.message ?? "")")
    await model.stopPlayback()
  }

  /// An unauthorized stream renews and plays on; a 401 that arrives before the renewed stream
  /// plays again pauses with a message. A 401 after it plays renews again, which the machine's own
  /// tests pin; here the renewal's play is held so the second 401 lands inside that window.
  @MainActor
  private static func anUnauthorizedStreamRenewsOnce() async throws {
    let host = try await HostPlayback()
    defer { host.tearDown() }
    let model = host.model
    let started = await model.play(host.selection)
    precondition(started)
    let state = {
      "playing \(model.audio.isPlaying), held plays \(model.audio.heldPlays.count), "
        + "message \(model.message ?? "none")"
    }
    // `audioStarted` restarts the ticker, so a new ticker task says the machine heard the renewed
    // stream play; only then does the next 401 count as a fresh one.
    let ticker = model.session.lifecycle.offlineTimer
    model.audio.onFailure?(true)
    model.audio.pause()
    await hostAwait(
      "the machine to hear the renewed stream play", observing: state,
      until: { model.session.lifecycle.offlineTimer != ticker })
    precondition(model.audio.isPlaying && model.message == nil, "a renewed stream did not play on")

    model.audio.holdPlays = true
    model.audio.onFailure?(true)
    model.audio.pause()
    await hostAwait(
      "the second renewal's play to reach the engine", observing: state,
      until: {
        model.audio.heldPlays.isEmpty == false
      })
    // The machine decides on this 401 at once; its pause and message queue behind the held play.
    model.audio.onFailure?(true)
    model.audio.releasePlays()
    await hostAwait("the unhelped renewal's message", observing: state, until: { model.message != nil })
    precondition(model.message == "Reconnect using your iPhone to continue streaming.", "a 401 before playing renewed")
    precondition(!model.audio.isPlaying, "a 401 before playing left the stream playing")
    precondition(model.currentSelection == host.selection, "a 401 before playing unloaded the title")
    await model.stopPlayback()
  }

  /// A stream that fails to play to the end pauses at once, closes its row and says so; the
  /// item's `.failed` status for the same failure does not say it twice.
  @MainActor
  private static func aLostStreamPausesWithAMessage() async throws {
    let host = try await HostPlayback()
    defer { host.tearDown() }
    let model = host.model
    let started = await model.play(host.selection)
    precondition(started && model.audio.wantsPlayback)
    model.audio.onObservation?(.failedToPlayToEnd)
    await hostAwait(
      "the lost stream to close its row",
      observing: {
        "playing \(model.audio.isPlaying), row \(model.playback.offlineSessionID != nil), message \(model.message ?? "none")"
      },
      until: {
        model.playback.offlineSessionID == nil
      })
    precondition(!model.audio.isPlaying && !model.audio.wantsPlayback, "a lost stream kept playing")
    precondition(
      model.message == "Lost the stream. Tap play to try again.", "a lost stream said \(model.message ?? "nothing")")
    precondition(model.playback.offlineSessionID == nil && model.currentSelection == host.selection)
    await model.resume()
    precondition(model.audio.isPlaying && model.message == nil, "tap play did not try again")
    await model.stopPlayback()
  }

  /// An interruption pauses what plays and its end resumes it plainly; one that began while
  /// paused leaves it paused.
  @MainActor
  private static func anInterruptionPausesAndResumesWhatItPaused() async throws {
    let host = try await HostPlayback()
    defer { host.tearDown() }
    let model = host.model
    let started = await model.play(host.selection)
    precondition(started)
    model.audio.onInterruption?(.interruptionBegan)
    await hostAwait(
      "the interruption to close the row",
      observing: {
        "playing \(model.audio.isPlaying), row \(model.playback.offlineSessionID != nil), message \(model.message ?? "none")"
      },
      until: {
        model.playback.offlineSessionID == nil
      })
    precondition(!model.audio.isPlaying && model.playback.offlineSessionID == nil, "an interruption kept playing")
    model.audio.onInterruption?(.interruptionEnded(shouldResume: true))
    await hostAwait(
      "the interruption's end to resume",
      observing: {
        "playing \(model.audio.isPlaying), row \(model.playback.offlineSessionID != nil), message \(model.message ?? "none")"
      }, until: { model.audio.isPlaying })
    precondition(
      model.audio.isPlaying && model.playback.offlineSessionID != nil, "the interruption's end did not resume")
    precondition(model.message == nil)

    await model.pause()
    model.audio.onInterruption?(.interruptionBegan)
    model.audio.onInterruption?(.interruptionEnded(shouldResume: true))
    await hostAwaitQuiescence("a paused title through an interruption") {
      "playing \(model.audio.isPlaying), row \(model.playback.offlineSessionID != nil)"
    }
    precondition(!model.audio.isPlaying, "an interruption resumed a title the listener paused")
    await model.stopPlayback()
  }

  /// Every refusal says why. A native feed episode is refused with a reason too.
  @MainActor
  private static func refusedStartsSaySoOrNot() async throws {
    let unconfigured = WatchLibraryModel(companion: WatchCompanionStore(), protectedStore: hostProtectedStore())
    let book = WatchSelection.audiobookshelf(itemID: "book", episodeID: nil)
    let unconfiguredStarted = await unconfigured.play(book)
    precondition(!unconfiguredStarted)
    precondition(unconfigured.message == "Whirr is still starting. Try again in a moment.")

    let host = try await HostPlayback()
    defer { host.tearDown() }
    let model = host.model
    model.setBusy(.downloading)
    let busyStarted = await model.play(host.selection)
    precondition(!busyStarted && model.message == "Whirr is starting a download. Try again in a moment.")
    model.setBusy(nil)
    await model.resume()
    precondition(model.message == "Choose something to play.", "a resume with nothing said nothing")
    let feedStarted = await model.play(.nativeFeed(feedID: "feed", episodeID: "episode"))
    precondition(!feedStarted)
    precondition(model.message == "Send this episode to your Watch from iPhone.")
    precondition(model.currentSelection == nil)
  }

  /// An operation a pause, stop, newer start, handoff or logout superseded shows no message.
  /// Only a failure does.
  @MainActor
  private static func cancelledOperationsShowNoMessage() async throws {
    let host = try await HostPlayback()
    defer { host.tearDown() }
    let model = host.model
    model.audio.playFailure = CancellationError()
    let cancelledStart = await model.play(host.selection)
    precondition(!cancelledStart)
    precondition(model.message == nil, "a cancelled start said \(model.message ?? "")")
    model.audio.playFailure = nil
    await model.stopPlayback()

    let started = await model.play(host.selection)
    precondition(started)
    model.audio.seekFailure = CancellationError()
    await model.seek(to: 30)
    precondition(model.message == nil, "a superseded seek said \(model.message ?? "")")
    model.audio.seekFailure = WatchAudioEngineError.seekUnfinished
    await model.seek(to: 30)
    precondition(model.message == "Couldn’t seek. Try again.", "an unfinished seek did not say so")
    model.audio.seekFailure = nil

    await model.pause()
    model.setMessage(nil)
    model.audio.playFailure = CancellationError()
    await model.resume()
    precondition(model.message == nil, "a cancelled resume said \(model.message ?? "")")
    model.audio.playFailure = WatchAudioEngineError.noOutput
    await model.resume()
    precondition(model.message == "Choose an available audio output and try again.")
    model.audio.playFailure = nil
    await model.stopPlayback()
  }

  /// The shared candidate comes from the full server snapshot. A title finished on another
  /// device is not in Continue Listening, and a stale bookmark must not win over it.
  @MainActor
  private static func aTitleFinishedElsewhereReplaysFromTheStart() async throws {
    let finished = MediaProgress(
      libraryItemID: "book", episodeID: nil, mediaItemID: nil, mediaItemType: nil, duration: 600, progress: 1,
      currentTime: 600, isFinished: true, hideFromContinueListening: false, ebookLocation: nil, ebookProgress: nil,
      lastUpdate: Date().addingTimeInterval(-60), startedAt: nil, finishedAt: nil)
    let host = try await HostPlayback(progress: UserProgressSnapshot(progress: [finished], hiddenSeriesIDs: []))
    defer { host.tearDown() }
    let model = host.model
    model.playback.retainedSelection = host.selection
    model.playback.retainedPosition = 120
    let started = await model.play(host.selection)
    precondition(started, "a finished title did not start: \(model.message ?? "no message")")
    precondition(model.audio.position == 0, "a title finished elsewhere resumed at \(model.audio.position)")
    await model.stopPlayback()
  }

  /// A Watch start asks the phone to pause only when it reports playing. For the phone's own
  /// title the start waits and begins where the phone was listening; for another title it does
  /// not wait, and a phone that reports nothing is not asked.
  @MainActor
  private static func aStartAsksAPlayingPhoneOnlyAboutItsOwnTitle() async throws {
    let host = try await HostPlayback()
    defer {
      host.tearDown()
      WatchPeerMessageSender.handler = nil
      WatchPeerMessageSender.timeouts = []
    }
    let model = host.model
    var asked: [WatchHandoffRequest] = []
    WatchPeerMessageSender.handler = { data, key in
      guard key == WatchHandoffRequest.transportKey,
        let request = try? WatchWireCodec.decode(WatchHandoffRequest.self, from: data)
      else { return nil }
      asked.append(request)
      // A distinct position per ask, so a later start cannot pass on a position saved earlier.
      let position: Double = asked.count == 1 ? 42 : 77
      return try? WatchWireCodec.encode(
        WatchHandoffReply.paused(request, selection: request.selection, position: position, lastListenedAt: Date()))
    }
    var started = await model.play(host.selection)
    precondition(started && asked.isEmpty, "a start asked a phone that reports nothing")
    await model.stopPlayback()

    model.companion.phoneReportsPlaying = true
    model.companion.currentItem = try host.item(host.selection)
    started = await model.play(host.selection)
    precondition(started && asked.count == 1, "a start did not ask the playing phone")
    precondition(WatchPeerMessageSender.timeouts.last == .seconds(3), "a same-title ask did not wait at most 3 s")
    precondition(model.audio.position == 42, "a same-title start ignored the phone's position")
    await model.stopPlayback()

    let other = WatchSelection.audiobookshelf(itemID: "other", episodeID: nil)
    model.companion.currentItem = try host.item(other)
    started = await model.play(host.selection)
    await hostAwait("the phone to be asked to pause", observing: { "\(asked.count) asks" }, until: { asked.count == 2 })
    precondition(started && asked.count == 2, "another-title start did not ask the phone to pause")
    precondition(WatchPeerMessageSender.timeouts.last == .seconds(8), "another-title ask waited for a reply")
    precondition(model.audio.position != 77, "another-title start took the phone's position")
    await model.stopPlayback()
  }

  /// A phone start pauses the Watch, keeps its title loaded and says where it was. A repeat
  /// only reports; another account is refused; with nothing loaded the Watch says so.
  @MainActor
  private static func aPhoneHandoffPausesAndKeepsTheTitle() async throws {
    let host = try await HostPlayback()
    defer { host.tearDown() }
    let model = host.model
    let stamp = try host.stamp()
    let wire = try WatchABSSelection(selection: host.selection)
    let idleRequest = try WatchHandoffRequest(accountStamp: stamp, selection: wire)
    let idleReply = try await host.answer(idleRequest)
    precondition(idleReply?.status == .idle, "an idle Watch did not say so")

    let started = await model.play(host.selection)
    precondition(started)
    await model.seek(to: 77)
    let request = try WatchHandoffRequest(accountStamp: stamp, selection: wire)
    guard let reply = try await host.answer(request) else { preconditionFailure("no handoff reply") }
    precondition(reply.status == .paused && reply.position(for: wire) == 77, "the reply did not say where")
    precondition(reply.lastListenedAt != nil, "a playing Watch did not date its listen")
    precondition(!model.audio.isPlaying, "a handoff did not pause the Watch")
    precondition(model.currentSelection == host.selection && model.playback.localPlaybackLoaded)
    precondition(model.playback.offlineSessionID == nil, "a handoff left the row open")

    await model.resume()
    let repeated = try await host.answer(request)
    precondition(repeated?.status == .paused && model.audio.isPlaying, "a repeated request paused again")

    let foreign = try WatchHandoffRequest(
      accountStamp: WatchAccountStamp(accountIdentityHash: "other", serverIdentityHash: "server"), selection: wire)
    let refused = try await host.answer(foreign)
    precondition(refused?.status == .rejected && model.audio.isPlaying, "another account paused the Watch")
    await model.stopPlayback()
  }

  // MARK: Received native-RSS copies (ADR 0019)

  /// A received copy plays from its own store and journal: no server read, no ABS row, and the start
  /// is where the phone left it.
  @MainActor
  private static func aNativeCopyPlaysWithoutAServerRead() async throws {
    let host = try await NativeCopyHost()
    defer { host.tearDown() }
    let model = host.model
    await model.episodes.refreshReadyCopies()
    precondition(model.episodes.hasReadyCopy(host.selection), "a committed copy is not ready")
    let started = await model.play(host.selection)
    precondition(started, "a received copy did not play: \(model.message ?? "no message")")
    precondition(model.audio.isPlaying && model.message == nil)
    precondition(model.audio.duration == 600, "the copy's duration was \(model.audio.duration)")
    precondition(model.audio.position == 120, "the copy started at \(model.audio.position)")
    precondition(model.playback.offlineSessionID == nil, "a received copy opened an ABS row")
    let absRows = await host.rows()
    precondition(absRows.isEmpty, "a received copy wrote an ABS row")
    let openedRow = await host.journal.latest(for: host.native)
    precondition(
      openedRow?.position == 120, "the journal row opened at \(String(describing: openedRow?.position))")
    let requests = await host.server.requests
    precondition(requests == 0, "a received copy read the server \(requests) times")
    let report = host.playingReport()
    precondition(report?.nativeSelection == host.native, "a received copy was not reported as playing")
    precondition(report?.selection == nil && report?.playing == true)
    await model.stopPlayback()
  }

  /// A native-feed episode the Watch holds no copy of still says to send it from the iPhone.
  @MainActor
  private static func aNativeCopyMissingSaysToSendIt() async throws {
    let host = try await NativeCopyHost(commit: false)
    defer { host.tearDown() }
    await host.model.episodes.refreshReadyCopies()
    precondition(!host.model.episodes.hasReadyCopy(host.selection))
    let started = await host.model.play(host.selection)
    precondition(!started && !host.model.audio.isPlaying)
    precondition(host.model.message == "Send this episode to your Watch from iPhone.")
    precondition(host.model.currentSelection == nil && !host.model.playback.localPlaybackLoaded)
  }

  /// The phone's pause request pauses only the episode it names, and the reply says where the Watch
  /// was; another title is answered without touching playback.
  @MainActor
  private static func aNativePauseRequestPausesOnlyItsOwnTitle() async throws {
    let host = try await NativeCopyHost()
    defer { host.tearDown() }
    let model = host.model
    await model.episodes.refreshReadyCopies()
    let started = await model.play(host.selection)
    precondition(started)
    await model.seek(to: 77)

    let other = try WatchNativeSelection(feedID: "feed", episodeID: "other")
    let otherReply = await host.answerNativePause(other)
    precondition(otherReply?.paused == false, "another title's request paused the Watch")
    precondition(otherReply?.position == nil)
    precondition(model.audio.isPlaying, "another title's request stopped playback")

    guard let reply = await host.answerNativePause(host.native) else {
      preconditionFailure("a native pause request got no reply")
    }
    precondition(reply.paused, "the playing episode was not paused")
    precondition(reply.position == 77, "the reply said \(String(describing: reply.position))")
    precondition(reply.lastListenedAt != nil, "a playing Watch did not date its listen")
    precondition(!model.audio.isPlaying, "a native pause request did not pause the Watch")
    precondition(model.currentSelection == host.selection && model.playback.localPlaybackLoaded)
    precondition(model.playback.offlineSessionID == nil, "a native pause left the ABS row set")
    let closedRow = await host.journal.latest(for: host.native)
    precondition(
      closedRow?.position == 77, "the closed row said \(String(describing: closedRow?.position))")
    await hostAwait(
      "the pause's native report",
      observing: { "reports \(host.sentNativeReports())" },
      until: {
        host.reportedEntries().contains { $0.selection == host.native && $0.position == 77 }
      })
    await model.stopPlayback()
  }

  /// A copy the phone's next offer drops stops playback and forgets its bookmark, because the next
  /// resume would point at a file that is gone.
  @MainActor
  private static func aDroppedNativeCopyStopsPlayback() async throws {
    let host = try await NativeCopyHost()
    defer { host.tearDown() }
    let model = host.model
    await model.episodes.refreshReadyCopies()
    let started = await model.play(host.selection)
    precondition(started && model.audio.isPlaying)
    let empty = try WatchEpisodeSendOffer(generation: 2, watchInstallID: nil, entries: [], sentAt: Date())
    model.episodes.receiveOffer(try WatchWireCodec.encode(empty))
    await hostAwait(
      "the dropped copy to stop playback",
      observing: { "playing \(model.audio.isPlaying), selection \(String(describing: model.currentSelection))" },
      until: { !model.audio.isPlaying })
    precondition(model.currentSelection == nil, "a dropped copy kept playing")
    // The stop saves a bookmark at the position before it unloads, so the unload is the point from
    // which only the dropped copy's own cleanup is left.
    await hostAwait(
      "the dropped copy to unload", until: { !model.playback.localPlaybackLoaded })
    await hostAwait(
      "the dropped copy to forget its bookmark",
      until: { model.playback.retainedSelection == nil })
    precondition(model.playback.savedBookmark() == nil, "a dropped copy left its saved bookmark")
    await hostAwait(
      "the copy to leave the ready set", until: { !model.episodes.hasReadyCopy(host.selection) })
  }

  /// A finished native episode reports the finish and then loses its copy, so the Watch does not
  /// keep an episode the phone records as played.
  @MainActor
  private static func aFinishedNativeEpisodeLosesItsCopy() async throws {
    let host = try await NativeCopyHost()
    defer { host.tearDown() }
    let model = host.model
    await model.episodes.refreshReadyCopies()
    let started = await model.play(host.selection)
    precondition(started)
    // A listen dates the row; a finish with no listen has nothing to report.
    await model.seek(to: 200)
    model.audio.onEnded?()
    await hostAwait(
      "the finished copy to be removed",
      observing: { "selection \(String(describing: model.currentSelection))" },
      until: { !model.audio.isPlaying && !model.episodes.hasReadyCopy(host.selection) })
    guard let entry = await host.store.entry(for: host.native) else {
      preconditionFailure("a finished episode lost its entry, not just its copy")
    }
    precondition(entry.state == .removed, "a finished episode kept its copy as \(entry.state)")
    await hostAwait(
      "the finished copy to forget its bookmark",
      until: { model.playback.retainedSelection == nil })
    await hostAwait(
      "the finish's native report",
      observing: { "reports \(host.sentNativeReports())" },
      until: {
        host.reportedEntries().contains { $0.selection == host.native && $0.isFinished }
      })
  }

  /// Continue on iPhone pauses, hands the position over with the start, and unloads only
  /// when the phone accepts.
  @MainActor
  private static func continueOnPhoneUnloadsOnlyOnceThePhoneAccepts() async throws {
    let host = try await HostPlayback()
    defer { host.tearDown() }
    let model = host.model
    var started = await model.play(host.selection)
    precondition(started)
    await model.seek(to: 55)
    model.companion.outcome = .phoneUnavailable
    await model.continueOnPhone()
    precondition(!model.audio.isPlaying && model.currentSelection == host.selection, "a refused move unloaded")
    precondition(model.message == "Open Whirr on your nearby iPhone, then try again.")
    let sent = model.companion.sent.last
    precondition(sent?.action == .play && sent?.value == 55, "the start did not hand the position over")

    await model.resume()
    model.companion.outcome = .sent
    await model.continueOnPhone()
    precondition(
      model.currentSelection == nil && !model.playback.localPlaybackLoaded, "an accepted move kept the title")
    precondition(model.message == nil && model.playback.retainedSelection == host.selection)
    started = await model.play(host.selection)
    precondition(started)
    await model.stopPlayback()
  }

  @MainActor
  private static func repeatedMessagesStayObservable() async {
    let model = WatchLibraryModel(companion: WatchCompanionStore(), protectedStore: hostProtectedStore())
    model.setMessage("Choose headphones and try again.")
    let first = model.messageID
    model.setMessage("Choose headphones and try again.")
    precondition(model.messageID != first, "a repeated action failure must still be observable")
  }

  /// A stream the Watch cannot play stops the audio; the listener must be told, or every retry
  /// looks like a tap that did nothing.
  @MainActor
  private static func failedAudioIsReported() async throws {
    let host = try await HostPlayback()
    defer { host.tearDown() }
    let model = host.model
    let started = await model.play(host.selection)
    precondition(started)
    // The engine has already paused itself when it reports a failed item.
    model.audio.pause()
    model.audio.onFailure?(false)
    await hostAwait(
      "the failed audio's message",
      observing: {
        "playing \(model.audio.isPlaying), row \(model.playback.offlineSessionID != nil), message \(model.message ?? "none")"
      }, until: { model.message != nil })
    precondition(
      model.message == "Couldn’t stream this on Watch. Check the connection, or download it first.",
      "failed Watch audio stopped without telling the listener")
    precondition(model.currentSelection == host.selection && model.playback.offlineSessionID == nil)
    await model.stopPlayback()
  }

  @MainActor
  private static func groupedDownloadsKeepAccountFence() async throws {
    let model = WatchLibraryModel(companion: WatchCompanionStore(), protectedStore: hostProtectedStore())
    let account = try WatchAccountRecord(serverURL: URL(string: "https://example.invalid")!, userID: "downloads")
    let stamp = try account.authenticatedStamp()
    let selection = WatchSelection.audiobookshelf(itemID: "saved-book", episodeID: nil)
    let manifest = WatchDownloadManifest(
      id: UUID(), accountStamp: stamp, selection: selection, downloadGroupID: "saved-book", expectedTrackCount: 1,
      fileID: "track", fileIndex: 0, startOffset: 0, duration: 60, expectedBytes: 100,
      expectedMIMEType: "audio/mpeg", destinationRelativePath: "track.mp3", state: .paused,
      receivedBytes: 0, createdAt: .distantPast, updatedAt: .distantPast)
    model.downloadsController.downloads = [manifest]
    model.downloadsController.downloadLabels = [manifest.id.uuidString: "Saved book"]
    let group = model.downloadGroups[0]
    for currentAccount in [nil, try WatchAccountRecord(serverURL: account.serverURL, userID: "replacement")] {
      model.publishAccount(currentAccount)
      await model.retry(group: group)
      precondition(model.downloads == [manifest], "stale group retried another account's manifests")
      await model.delete(group: group)
      precondition(model.downloads == [manifest], "stale group deleted another account's manifests")
      precondition(model.downloadLabels[manifest.id.uuidString] == "Saved book")
    }
  }

  /// Before first unlock the receipt file exists but cannot be read. Setup answers busy rather
  /// than treating it as absent, and keeps the file; once it reads, setup proceeds.
  @MainActor
  private static func anUnreadableReceiptAnswersBusyAndIsKept() async throws {
    let store = hostProtectedStore()
    let stamp = try WatchAccountRecord(serverURL: URL(string: "https://example.invalid")!, userID: "user")
      .authenticatedStamp()
    let receipt = try WatchSetupReceipt(id: UUID(), accountStamp: stamp, nonce: UUID(), status: .installed)
    try store.save(WatchWireCodec.encode(receipt), key: "watch.setup.receipt.v1")
    let file = store.rootURL.appendingPathComponent("watch.setup.receipt.v1")
    try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path) }

    let receiver = WatchSetupReceiver(
      store: store, currentAccount: { nil }, install: { _ in }, isInstalled: { _ in false })
    let hello = try WatchWireCodec.encode(WatchSetupHello(id: UUID(), accountStamp: stamp, issuedAt: Date()))
    func status() async throws -> WatchSetupStatus {
      guard let reply = await receiver.receive(hello, key: WatchTransportKey.setupHello) else {
        preconditionFailure("setup hello got no reply")
      }
      return try WatchWireCodec.decode(WatchSetupChallenge.self, from: reply).status
    }
    let locked = try await status()
    precondition(locked == .busy, "an unreadable receipt did not answer busy")
    precondition(FileManager.default.fileExists(atPath: file.path), "an unreadable receipt was deleted")

    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    let unlocked = try await status()
    precondition(unlocked != .busy, "a readable receipt still answered busy")
  }

  /// Sign-out leaves no account-linked file in the protected store, whether or not a session was
  /// configured, and drops the saved phone catalogue.
  @MainActor
  private static func signOutClearsProtectedState() async throws {
    let store = hostProtectedStore()
    let model = WatchLibraryModel(companion: WatchCompanionStore(), protectedStore: store)
    for key in [
      "watch.resume.bookmark", "watch.download.labels.aaaa", "watch.download.labels.bbbb",
      "watch.setup.receipt.v1",
    ] {
      try store.save(Data("x".utf8), key: key)
    }
    await model.logout()
    let left = (try? FileManager.default.contentsOfDirectory(atPath: store.rootURL.path)) ?? []
    precondition(left.isEmpty, "sign-out left protected state: \(left)")
    precondition(model.companion.cacheClears == 1, "sign-out kept the saved phone catalogue")
  }

  @MainActor
  private static func cancellationBelongsToSessionLifecycle() async {
    let model = WatchLibraryModel(companion: WatchCompanionStore(), protectedStore: hostProtectedStore())
    let lifecycle = model.session.lifecycle
    func pending() -> Task<Void, Never> {
      Task {
        do { try await Task.sleep(for: .seconds(60)) } catch {}
      }
    }
    let initialization = pending()
    let restore = pending()
    let install = pending()
    let timer = pending()
    let reconciliation = pending()
    lifecycle.initialization = initialization
    lifecycle.restore = restore
    lifecycle.install = install
    lifecycle.offlineTimer = timer
    lifecycle.reconciliation = reconciliation
    let epoch = model.session.epoch
    await model.logout()
    precondition(model.session.epoch != epoch, "logout did not invalidate session replies")
    for task in [initialization, restore, install, timer, reconciliation] {
      precondition(task.isCancelled, "logout left session work running")
      await task.value
    }
    precondition(lifecycle.initialization == nil && lifecycle.restore == nil && lifecycle.install == nil)
    precondition(lifecycle.offlineTimer == nil && lifecycle.reconciliation == nil)
  }

  /// A phone catalogue is not a reconnect: the phone republishes on every change and on its
  /// playhead while it plays. With no closed row waiting, one starts no upload run, so it neither
  /// reads the server nor sends the phone a pending-progress report.
  @MainActor
  private static func aPhoneCatalogueWithNothingWaitingStartsNoUpload() async throws {
    let host = try await HostPlayback()
    defer { host.tearDown() }
    let rows = await host.rows()
    precondition(rows.isEmpty)
    WCSession.default.outstandingUserInfoTransfers = []
    for _ in 0..<3 { await host.model.peerDidSendContext() }
    precondition(
      WCSession.default.outstandingUserInfoTransfers.isEmpty,
      "a catalogue with nothing waiting sent \(WCSession.default.outstandingUserInfoTransfers.count) reports")
  }

}
private enum HostFailure: Error { case refused, unavailable }

/// A signed-in Watch session graph with a host service: one streamable book, no network, and
/// stores in a temporary folder.
@MainActor
private final class HostPlayback {
  let model = WatchLibraryModel(companion: WatchCompanionStore(), protectedStore: hostProtectedStore())
  let selection = WatchSelection.audiobookshelf(itemID: "book", episodeID: nil)
  let root = FileManager.default.temporaryDirectory.appendingPathComponent("watch-host-\(UUID().uuidString)")
  /// What the session's service was asked, so a native start can prove it read no server.
  let service: HostLibraryService
  private var progressStore: WatchOfflineProgressStore!

  init(
    detailAvailable: Bool = true, progress: UserProgressSnapshot? = nil,
    receivedEpisodes: WatchReceivedEpisodeStore? = nil,
    nativeJournal: WatchNativeProgressJournal? = nil
  ) async throws {
    let record = try WatchAccountRecord(serverURL: URL(string: "https://example.invalid/abs")!, userID: "user")
    let stamp = try record.authenticatedStamp()
    let tokenAccount = try record.tokenAccount()
    let tokens = InMemoryTokenStore()
    try tokens.save(TokenPair(accessToken: "access", refreshToken: "refresh"), for: tokenAccount)
    let server = try ABSServerConfig(url: record.serverURL)
    let request = try await ABSClient.production(server: server, tokenStore: tokens).makeAuthorizedDownloadRequest(
      FileDownloadRequest(itemID: "book", fileID: "one", expectedMIMEType: "audio/mpeg", expectedSize: 10),
      account: tokenAccount)
    WCSession.default.activationState = .activated
    let service = HostLibraryService(
      detail: detailAvailable ? Self.detail : nil, request: request, progress: progress)
    self.service = service
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let accountStore = WatchAccountStore(
      tokenStore: tokens,
      settings: try WatchProtectedFileStore(rootURL: root.appendingPathComponent("Protected"))
        .settings(forKey: WatchAccountStore.recordKey))
    let downloadStore = try WatchDownloadStore(rootURL: root.appendingPathComponent("Downloads"), accountStamp: stamp)
    progressStore = try WatchOfflineProgressStore(rootURL: root.appendingPathComponent("Progress"), accountStamp: stamp)
    let coordinator = WatchPlaybackSessionCoordinator(
      account: record, service: service, audio: model.audio)
    let manager = WatchDownloadManager(
      store: downloadStore, accountStamp: stamp, requestProvider: { _ in throw HostFailure.unavailable },
      rootURL: root.appendingPathComponent("Transfers"), sessionIdentifier: "watch-host-\(UUID().uuidString)")
    // A restore whose server call fails still signs the client in from the stored record.
    try await accountStore.install(record, tokens: TokenPair(accessToken: "access", refreshToken: "refresh"))
    let libraryClient = WatchLibraryClient(accountStore: accountStore, service: service)
    _ = try await libraryClient.restore()
    model.session.adopt(
      WatchSessionContext(
        account: record, authenticatedStamp: stamp, epoch: model.session.epoch,
        libraryClient: libraryClient,
        service: ABSWatchLibraryService(server: server, tokenStore: tokens), coordinator: coordinator,
        downloadStore: downloadStore, progressStore: progressStore, downloadManager: manager,
        receivedEpisodes: receivedEpisodes, nativeJournal: nativeJournal))
  }

  func rows() async -> [WatchOfflineProgressSession] { await progressStore.allSessions() }

  func stamp() throws -> WatchAccountStamp { try model.account!.authenticatedStamp() }

  /// The phone's catalogue row for `selection`, as the phone reports its current title.
  func item(_ selection: WatchSelection) throws -> WatchCatalogueItem {
    try WatchCatalogueItem(
      id: "current", selection: selection, title: "Book", isCurrentPlayback: true,
      capabilities: .init(phonePlayable: true, watchPlayable: true))
  }

  func answer(_ request: WatchHandoffRequest) async throws -> WatchHandoffReply? {
    guard let data = await model.playback.answerHandoff(try WatchWireCodec.encode(request)) else { return nil }
    return try WatchWireCodec.decode(WatchHandoffReply.self, from: data)
  }

  /// The Watch's last playing report, as the phone would read it from the application context.
  func playingReport() -> WatchPlayingReport? {
    guard let data = WCSession.default.applicationContext[WatchPlayingReport.transportKey] as? Data else { return nil }
    return try? WatchWireCodec.decode(WatchPlayingReport.self, from: data)
  }

  func tearDown() {
    model.session.lifecycle.offlineTimer?.cancel()
    try? FileManager.default.removeItem(at: root)
  }

  static let detail = ItemDetail(
    id: "book", libraryID: "library", mediaType: "book",
    media: .book(
      BookMedia(
        title: "Book", subtitle: nil, authorName: nil, narratorName: nil, seriesName: nil, description: nil,
        duration: 600,
        audioFiles: AudioFileCatalog(
          files: [AudioFileInfo(index: 0, ino: "one", expectedSize: 10, mimeType: "audio/mpeg", duration: 600)],
          invalidEntryCount: 0),
        tracks: [
          AudioTrack(index: 0, startOffset: 0, duration: 600, title: nil, contentUrl: nil, mimeType: "audio/mpeg")
        ],
        chapters: [], ebookFile: nil)))
}

/// A HostPlayback whose session also holds one received RSS copy and its journal, so the native path
/// runs against the real stores, the real controller and the hardware stubs.
@MainActor
private final class NativeCopyHost {
  let host: HostPlayback
  let native: WatchNativeSelection
  let selection: WatchSelection
  let store: WatchReceivedEpisodeStore
  let journal: WatchNativeProgressJournal
  private let directory: URL

  var model: WatchLibraryModel { host.model }
  var server: HostLibraryService { host.service }

  init(commit: Bool = true, position: Double = 120, duration: Double? = 600) async throws {
    let native = try WatchNativeSelection(feedID: "feed", episodeID: "episode")
    let record = try WatchAccountRecord(serverURL: URL(string: "https://example.invalid/abs")!, userID: "user")
    let stamp = try record.authenticatedStamp()
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("watch-native-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let store = try WatchReceivedEpisodeStore(
      rootURL: directory.appendingPathComponent("Received"), accountStamp: stamp,
      installID: UUID().uuidString.lowercased(), budget: WatchStorageBudget())
    let journal = try WatchNativeProgressJournal(
      fileURL: directory.appendingPathComponent("native-progress.json"), accountStamp: stamp)
    let host = try await HostPlayback(receivedEpisodes: store, nativeJournal: journal)
    // Each native case reads only the transfers it caused.
    WCSession.default.outstandingUserInfoTransfers = []
    let entry = try WatchEpisodeOfferEntry(
      selection: native, revision: 1, title: "Episode", showTitle: "Show", duration: duration,
      declaredBytes: 16, enclosureURL: URL(string: "https://example.invalid/episode.mp3")!,
      mimeType: "audio/mpeg", chapters: [try WatchEpisodeChapter(title: "One", start: 0, end: 300)],
      position: position, lastListenedAt: Date().addingTimeInterval(-3600))
    let offer = try WatchEpisodeSendOffer(
      generation: 1, watchInstallID: nil, entries: [entry], sentAt: Date())
    _ = try await store.apply(offer)
    if commit {
      let incoming = directory.appendingPathComponent("incoming.mp3")
      try Data(repeating: 0, count: 16).write(to: incoming)
      _ = try await store.commitDownloadedFile(
        selection: native, revision: 1, temporaryFileURL: incoming, acceptedBytes: 16)
    }
    self.native = native
    self.selection = native.selection
    self.store = store
    self.journal = journal
    self.host = host
    self.directory = directory
  }

  func rows() async -> [WatchOfflineProgressSession] { await host.rows() }

  func playingReport() -> WatchPlayingReport? { host.playingReport() }

  func answerNativePause(_ selection: WatchNativeSelection) async -> WatchNativePauseReply? {
    guard let data = try? WatchWireCodec.encode(WatchNativePauseRequest(selection: selection)),
      let reply = await model.playback.answerNativePause(data)
    else { return nil }
    return try? WatchWireCodec.decode(WatchNativePauseReply.self, from: reply)
  }

  /// Native progress reports the Watch handed to `transferUserInfo`, in send order.
  func reportedEntries() -> [WatchNativeProgressEntry] {
    WCSession.default.outstandingUserInfoTransfers.flatMap { transfer -> [WatchNativeProgressEntry] in
      guard let data = transfer.userInfo[WatchTransportKey.nativeProgressReport] as? Data,
        let report = try? WatchWireCodec.decode(WatchNativeProgressReport.self, from: data)
      else { return [] }
      return report.entries
    }
  }

  func sentNativeReports() -> Int {
    WCSession.default.outstandingUserInfoTransfers.filter {
      $0.userInfo[WatchTransportKey.nativeProgressReport] != nil
    }.count
  }

  func tearDown() {
    host.tearDown()
    try? FileManager.default.removeItem(at: directory)
  }
}

/// Serves one book's detail and its file authorization; every other call fails as an offline
/// server would.
private actor HostLibraryService: WatchLibraryService {
  let detailValue: ItemDetail?
  let request: AuthorizedDownloadRequest
  let progressValue: UserProgressSnapshot?
  private var countedRequests = 0

  /// Every call that would have reached the server. A native start must leave it at zero.
  var requests: Int { countedRequests }

  init(detail: ItemDetail?, request: AuthorizedDownloadRequest, progress: UserProgressSnapshot?) {
    detailValue = detail
    self.request = request
    progressValue = progress
  }

  func detail(account: TokenAccount, itemID: String) async throws -> ItemDetail {
    countedRequests += 1
    guard let detailValue, detailValue.id == itemID else { throw HostFailure.unavailable }
    return detailValue
  }
  func audioDownload(account: TokenAccount, itemID: String, fileID: String, mimeType: String, expectedSize: Int)
    async throws -> AuthorizedDownloadRequest
  {
    countedRequests += 1
    guard fileID == request.fileID else { throw HostFailure.unavailable }
    return request
  }
  func renewAudioDownload(account: TokenAccount, itemID: String, fileID: String, mimeType: String, expectedSize: Int)
    async throws -> AuthorizedDownloadRequest
  {
    countedRequests += 1
    return request
  }
  func login(username: String, password: String) async throws -> WatchLoginResult { throw HostFailure.unavailable }
  func login(apiToken: String) async throws -> WatchLoginResult { throw HostFailure.unavailable }
  func restore(account: TokenAccount) async throws -> WatchLoginResult { throw HostFailure.unavailable }
  func logout(account: TokenAccount) async throws {}
  func libraries(account: TokenAccount) async throws -> [Library] { throw HostFailure.unavailable }
  func page(
    account: TokenAccount, libraryID: String, page: Int, limit: Int, sort: String?, filter: LibraryItemFilter?
  ) async throws -> LibraryItemsPage { throw HostFailure.unavailable }
  func filterData(account: TokenAccount, libraryID: String) async throws -> LibraryFilterData {
    throw HostFailure.unavailable
  }
  func recentEpisodes(account: TokenAccount, libraryID: String, page: Int, limit: Int) async throws -> [RecentEpisode] {
    throw HostFailure.unavailable
  }
  func progress(account: TokenAccount) async throws -> UserProgressSnapshot {
    countedRequests += 1
    guard let progressValue else { throw HostFailure.unavailable }
    return progressValue
  }
  func startSession(account: TokenAccount, itemID: String, episodeID: String?) async throws -> PlaybackSession {
    throw HostFailure.unavailable
  }
  func fetchSession(account: TokenAccount, sessionID: String) async throws -> PlaybackSession? {
    throw HostFailure.unavailable
  }
  func syncSession(account: TokenAccount, sessionID: String, update: SessionSyncUpdate) async throws {
    throw HostFailure.unavailable
  }
  func closeSession(account: TokenAccount, sessionID: String, finalPosition: SessionSyncUpdate?) async throws {
    throw HostFailure.unavailable
  }
  func streamAuthorization(account: TokenAccount) async throws -> PlaybackStreamAuthorization {
    throw HostFailure.unavailable
  }
  func renewStreamAuthorization(account: TokenAccount) async throws -> PlaybackStreamAuthorization {
    throw HostFailure.unavailable
  }
  func syncLocalSessions(account: TokenAccount, sessions: [LocalPlaybackSession]) async throws
    -> LocalSessionSyncOutcome
  { throw HostFailure.unavailable }
}

@main struct PlaybackPolicyRegression {
  static func main() async throws { try await WatchLibraryModel.runPlaybackPolicyRegression() }
}
