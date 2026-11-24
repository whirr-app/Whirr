import Foundation
import GRDB
import Persistence
import TestSupport
import Testing

@testable import ABSApi
@testable import SyncEngine

/// `PlaybackSessionCoordinator` orchestrates `/play`/`/close` around the durable
/// `PlaybackSessionStore`: stable device id + injected metadata, persist-before-preparation,
/// `ProgressMergePolicy` at session start, malformed-stream compensation close, idempotent repeat
/// start, switch-freezes-former, stop-persists-close-before-I/O, and one explicit order under
/// concurrency.
@Suite struct PlaybackSessionCoordinatorTests {

  @Test func invalidAccountServerURLProducesMissingHostConfigurationError() async throws {
    let harness = try await CoordinatorHarness()
    try await harness.database.writeAsync { db in
      var record = try AccountRecord.fetchOne(db)!
      record.serverBaseURL = "http://[invalid"
      try record.update(db)
    }

    await #expect(throws: APIError.invalidServerConfiguration(.missingHost)) {
      _ = try await harness.coordinator.startSession(
        itemID: CoordinatorHarness.itemID, episodeID: nil)
    }
  }

  // MARK: - Device id + injected metadata

  @Test func startSessionUsesTheAccountsPersistedClientUUIDAsDeviceIdPlusInjectedMetadata() async throws {
    let harness = try await CoordinatorHarness(
      deviceMetadata: PlaybackDeviceMetadata(
        clientVersion: "1.2.3", manufacturer: "Apple", model: "iPhone17,1", clientName: "Whirr",
        deviceName: "Rhys's iPhone"))
    harness.enqueuePlayResponse()

    _ = try await harness.coordinator.startSession(itemID: CoordinatorHarness.itemID, episodeID: nil)

    #expect(harness.http.requests.count == 1)
    #expect(harness.http.requests[0].url.host == "playback.example.test")
    let body = try #require(harness.http.requests[0].body)
    let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
    let deviceInfo = try #require(object["deviceInfo"] as? [String: Any])
    #expect(deviceInfo["deviceId"] as? String == harness.clientUUID)
    #expect(deviceInfo["clientVersion"] as? String == "1.2.3")
    #expect(deviceInfo["manufacturer"] as? String == "Apple")
    #expect(deviceInfo["model"] as? String == "iPhone17,1")
    #expect(deviceInfo["clientName"] as? String == "Whirr")
    #expect(deviceInfo["deviceName"] as? String == "Rhys's iPhone")
  }

  // MARK: - Direct play (API-CONVENTIONS.md rule 6a)

  @Test func startSessionRequestsDirectPlaySoTheServerNeverHandsBackATranscodedHLSStream() async throws {
    let harness = try await CoordinatorHarness()
    harness.enqueuePlayResponse()

    _ = try await harness.coordinator.startSession(itemID: CoordinatorHarness.itemID, episodeID: nil)

    let body = try #require(harness.http.requests[0].body)
    let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
    #expect(object["forceDirectPlay"] as? Bool == true)
    #expect(object["forceTranscode"] == nil)
  }

  @Test func aStreamedPreparationCarriesTheBearerHeaderItsTrackURLsNeed() async throws {
    let harness = try await CoordinatorHarness()
    harness.enqueuePlayResponse()

    let prepared = try await harness.coordinator.startSession(itemID: CoordinatorHarness.itemID, episodeID: nil)

    // Ask against the resolved track URL itself: rule 6a's authorization is a per-resource
    // decision, so this direct-play URL is the one that must get it.
    let trackURL = try #require(prepared.tracks.first?.url)
    let fields = try #require(prepared.streamAuthorization?.httpHeaderFields(for: trackURL))
    #expect(fields["Authorization"] == "Bearer canary-access")
    #expect("\(prepared)".contains("canary-access") == false)
  }

  /// The Bearer stamped at `/play` time is as old as the session, and a listen outlives it.
  /// Renewal is a real refresh, then a re-stamp.
  @Test func renewingStreamAuthorizationRefreshesTheTokenAndReturnsAFreshBearer() async throws {
    let harness = try await CoordinatorHarness()
    harness.enqueuePlayResponse()
    let prepared = try await harness.coordinator.startSession(itemID: CoordinatorHarness.itemID, episodeID: nil)
    let trackURL = try #require(prepared.tracks.first?.url)
    harness.enqueueRefreshResponse(accessToken: "rotated-access", refreshToken: "rotated-refresh")

    let renewed = try #require(await harness.coordinator.renewStreamAuthorization())

    #expect(renewed.httpHeaderFields(for: trackURL)["Authorization"] == "Bearer rotated-access")
    #expect(harness.http.requests.last?.url.path == "/auth/refresh")
  }

  /// Nothing to renew is not a failure: a local (downloaded) session's file URL never carries a
  /// Bearer, and a controller with no live session has none either. Returning `nil` avoids
  /// spending a token rotation on them.
  @Test func renewingStreamAuthorizationWithNoActiveSessionReturnsNil() async throws {
    let harness = try await CoordinatorHarness()

    let renewed = try await harness.coordinator.renewStreamAuthorization()

    #expect(renewed == nil)
    #expect(harness.http.requests.isEmpty)
  }

  // MARK: - Persist before preparation returns

  @Test func startSessionPersistsTheSessionRowBeforeReturning() async throws {
    let harness = try await CoordinatorHarness()
    harness.enqueuePlayResponse(id: "server-session-42")

    _ = try await harness.coordinator.startSession(itemID: CoordinatorHarness.itemID, episodeID: nil)

    let active = try #require(try harness.sessionStore.fetchActiveSession(accountId: harness.accountId))
    #expect(active.serverSessionId == "server-session-42")
    #expect(active.itemId == harness.itemRowId)
    #expect(active.state == .active)
    #expect(active.closePending == false)
  }

  @Test func aFailedPlayCallNeverPersistsASession() async throws {
    let harness = try await CoordinatorHarness()
    harness.http.enqueue(HTTPResponse(statusCode: 500, headers: [:], body: Data()))

    await #expect(throws: (any Error).self) {
      _ = try await harness.coordinator.startSession(itemID: CoordinatorHarness.itemID, episodeID: nil)
    }

    #expect(try harness.sessionStore.fetchActiveSession(accountId: harness.accountId) == nil)
  }

  // MARK: - ProgressMergePolicy at session start

  @Test func localUnacknowledgedProgressWinsOverAnOlderServerStart() async throws {
    let harness = try await CoordinatorHarness()
    try await harness.seedLocalProgress(currentTime: 500, isFinished: false)
    try harness.seedUnacknowledgedProgressWrite()
    harness.enqueuePlayResponse(currentTime: 10)

    let prepared = try await harness.coordinator.startSession(itemID: CoordinatorHarness.itemID, episodeID: nil)

    #expect(prepared.startPosition == 500)
  }

  @Test func aNearZeroServerPositionNeverClobbersSubstantialLocalProgressWithoutAnUnacknowledgedWrite() async throws {
    let harness = try await CoordinatorHarness()
    try await harness.seedLocalProgress(currentTime: 500, isFinished: false)
    harness.enqueuePlayResponse(currentTime: 0)

    let prepared = try await harness.coordinator.startSession(itemID: CoordinatorHarness.itemID, episodeID: nil)

    #expect(prepared.startPosition == 500)
  }

  @Test func theServersPositionIsAppliedWhenNothingProtectsLocalProgress() async throws {
    let harness = try await CoordinatorHarness()
    try await harness.seedLocalProgress(currentTime: 500, isFinished: false)
    harness.enqueuePlayResponse(currentTime: 700)

    let prepared = try await harness.coordinator.startSession(itemID: CoordinatorHarness.itemID, episodeID: nil)

    #expect(prepared.startPosition == 700)
    let progress = try #require(
      try harness.mediaProgressDAO.fetchCurrent(
        accountId: harness.accountId, identity: .item(itemId: harness.itemRowId)))
    #expect(progress.currentTime == 700)
  }

  @Test func startsAtTheServersPositionWhenNoLocalProgressExistsYet() async throws {
    let harness = try await CoordinatorHarness()
    harness.enqueuePlayResponse(currentTime: 42)

    let prepared = try await harness.coordinator.startSession(itemID: CoordinatorHarness.itemID, episodeID: nil)

    #expect(prepared.startPosition == 42)
  }

  // MARK: - Start before a pull: another device's reset (ADR 0011)

  /// When the zero guard would fire over a row this device observed on the server, one `GET`
  /// decides whether the zero is a reset. Without it, this session's sync recreates the server row
  /// at the local position and silently undoes the reset everywhere.
  @Test func aDeletedServerRowIsAResetSoTheStartBeginsAtZero() async throws {
    let harness = try await CoordinatorHarness()
    try await harness.seedObservedServerProgress(
      currentTime: 1200, serverProgressId: "progress_old", serverUpdatedAt: harness.observedAt)
    harness.enqueuePlayResponse(currentTime: 0)
    harness.http.enqueue(HTTPResponse(statusCode: 404, headers: [:], body: Data()))

    let prepared = try await harness.coordinator.startSession(itemID: CoordinatorHarness.itemID, episodeID: nil)

    #expect(prepared.startPosition == 0)
    #expect(harness.http.requests.map(\.url.path).contains("/api/me/progress/\(CoordinatorHarness.itemID)"))
    let progress = try #require(
      try harness.mediaProgressDAO.fetchCurrent(
        accountId: harness.accountId, identity: .item(itemId: harness.itemRowId)))
    #expect(progress.currentTime == 0)
    #expect(progress.isFinished == false)
    #expect(try await harness.mediaProgressDAO.fetchOpenConflictsAsync(accountId: harness.accountId).isEmpty)
  }

  @Test func aRowRecreatedAfterTheObservationIsAResetSoTheStartBeginsAtZero() async throws {
    let harness = try await CoordinatorHarness()
    try await harness.seedObservedServerProgress(
      currentTime: 1200, serverProgressId: "progress_old", serverUpdatedAt: harness.observedAt)
    harness.enqueuePlayResponse(currentTime: 0)
    harness.enqueueProgressRow(
      id: "progress_new", currentTime: 0, startedAt: harness.observedAt.addingTimeInterval(60))

    let prepared = try await harness.coordinator.startSession(itemID: CoordinatorHarness.itemID, episodeID: nil)

    #expect(prepared.startPosition == 0)
    #expect(try await harness.mediaProgressDAO.fetchOpenConflictsAsync(accountId: harness.accountId).isEmpty)
  }

  @Test func aZeroOnTheSameServerRowKeepsLocalAndRecordsTheConflict() async throws {
    let harness = try await CoordinatorHarness()
    try await harness.seedObservedServerProgress(
      currentTime: 1200, serverProgressId: "progress_old", serverUpdatedAt: harness.observedAt)
    harness.enqueuePlayResponse(currentTime: 0)
    harness.enqueueProgressRow(
      id: "progress_old", currentTime: 0, startedAt: harness.observedAt.addingTimeInterval(-3600))

    let prepared = try await harness.coordinator.startSession(itemID: CoordinatorHarness.itemID, episodeID: nil)

    #expect(prepared.startPosition == 1200)
    let conflicts = try await harness.mediaProgressDAO.fetchOpenConflictsAsync(accountId: harness.accountId)
    #expect(conflicts.count == 1)
    #expect(conflicts.first?.serverCurrentTime == 0)
  }

  @Test func anUnansweredCheckIsNoEvidenceSoLocalIsKeptAndTheConflictRecorded() async throws {
    let harness = try await CoordinatorHarness()
    try await harness.seedObservedServerProgress(
      currentTime: 1200, serverProgressId: "progress_old", serverUpdatedAt: harness.observedAt)
    harness.enqueuePlayResponse(currentTime: 0)
    harness.http.enqueue(HTTPResponse(statusCode: 500, headers: [:], body: Data()))

    let prepared = try await harness.coordinator.startSession(itemID: CoordinatorHarness.itemID, episodeID: nil)

    #expect(prepared.startPosition == 1200)
    #expect(try await harness.mediaProgressDAO.fetchOpenConflictsAsync(accountId: harness.accountId).count == 1)
  }

  /// The check is advisory, so a stalled read must not hold playback for the transport timeout.
  @Test func aStalledCheckIsNoEvidenceAndDoesNotHoldTheStart() async throws {
    let harness = try await CoordinatorHarness(resetCheckTimeout: 0.05)
    try await harness.seedObservedServerProgress(
      currentTime: 1200, serverProgressId: "progress_old", serverUpdatedAt: harness.observedAt)
    harness.enqueuePlayResponse(currentTime: 0)
    let readOutlastedHold = Locked(false)
    harness.http.setRequestHook { request in
      guard request.url.path.hasPrefix("/api/me/progress") else { return }
      // Held until the start gives up and cancels the read.
      do { try await Task.sleep(for: .seconds(30)) } catch { return }
      readOutlastedHold.value = true
    }
    harness.http.enqueue(HTTPResponse(statusCode: 404, headers: [:], body: Data()))

    let prepared = try await harness.coordinator.startSession(itemID: CoordinatorHarness.itemID, episodeID: nil)

    // A start that waited for the read would see it finish its hold.
    #expect(readOutlastedHold.value == false)
    #expect(prepared.startPosition == 1200)
    #expect(try await harness.mediaProgressDAO.fetchOpenConflictsAsync(accountId: harness.accountId).count == 1)
  }

  @Test func withoutAnObservedServerRowTheGuardKeepsLocalWithoutAnExtraRequest() async throws {
    let harness = try await CoordinatorHarness()
    try await harness.seedLocalProgress(currentTime: 500, isFinished: false)
    harness.enqueuePlayResponse(currentTime: 0)

    let prepared = try await harness.coordinator.startSession(itemID: CoordinatorHarness.itemID, episodeID: nil)

    #expect(prepared.startPosition == 500)
    #expect(harness.http.requests.contains { $0.url.path.hasPrefix("/api/me/progress") } == false)
    #expect(try await harness.mediaProgressDAO.fetchOpenConflictsAsync(accountId: harness.accountId).count == 1)
  }

  // MARK: - Malformed/unusable streams close the just-opened session as compensation

  @Test func closesTheJustOpenedServerSessionWhenNoTrackSurvivesMapping() async throws {
    let harness = try await CoordinatorHarness()
    harness.enqueuePlayResponse(
      id: "server-session-unusable",
      tracks: [["contentUrl": "/api/items/\(CoordinatorHarness.itemID)/file/101"]]  // no index/startOffset/duration
    )
    harness.http.enqueue(HTTPResponse(statusCode: 200, headers: [:], body: Data()))  // /close

    await #expect(throws: PlaybackCoordinatorError.unusableStream) {
      _ = try await harness.coordinator.startSession(itemID: CoordinatorHarness.itemID, episodeID: nil)
    }

    #expect(harness.http.requests.count == 2)
    #expect(harness.http.requests[1].url.path == "/api/session/server-session-unusable/close")
    // The compensation close was acknowledged locally, so no active session occupies the
    // account's one-active-session slot.
    #expect(try harness.sessionStore.fetchActiveSession(accountId: harness.accountId) == nil)
  }

  /// `forceDirectPlay` is a request the server may ignore. A transcode answer is a valid, fully
  /// indexed session that passes every mapping check, but its single HLS track needs a
  /// `stream_reset` socket lifecycle `AVPlayer` does not speak. It must be refused here rather
  /// than handed to the engine to stall on.
  @Test func closesTheJustOpenedServerSessionWhenTheServerTranscodedAnyway() async throws {
    let harness = try await CoordinatorHarness()
    harness.enqueuePlayResponse(
      id: "server-session-transcoded",
      playMethod: 2,
      tracks: [
        [
          "index": 1, "startOffset": 0, "duration": 100, "title": "Track 1",
          "contentUrl": "/hls/server-session-transcoded/output.m3u8", "mimeType": "application/vnd.apple.mpegurl",
        ]
      ]
    )
    harness.http.enqueue(HTTPResponse(statusCode: 200, headers: [:], body: Data()))  // /close

    await #expect(throws: PlaybackCoordinatorError.unusableStream) {
      _ = try await harness.coordinator.startSession(itemID: CoordinatorHarness.itemID, episodeID: nil)
    }

    #expect(harness.http.requests.count == 2)
    #expect(harness.http.requests[1].url.path == "/api/session/server-session-transcoded/close")
  }

  /// The track shape is refused on its own, so a response whose `playMethod` never decoded cannot
  /// smuggle a playlist past the primary signal.
  @Test func anHLSTrackIsRefusedEvenWhenPlayMethodIsAbsent() async throws {
    let harness = try await CoordinatorHarness()
    harness.enqueuePlayResponse(
      id: "server-session-no-play-method",
      playMethod: nil,
      tracks: [
        [
          "index": 1, "startOffset": 0, "duration": 100, "title": "Track 1",
          "contentUrl": "/hls/server-session-no-play-method/output.m3u8", "mimeType": "application/vnd.apple.mpegurl",
        ]
      ]
    )
    harness.http.enqueue(HTTPResponse(statusCode: 200, headers: [:], body: Data()))  // /close

    await #expect(throws: PlaybackCoordinatorError.unusableStream) {
      _ = try await harness.coordinator.startSession(itemID: CoordinatorHarness.itemID, episodeID: nil)
    }

    #expect(harness.http.requests[1].url.path == "/api/session/server-session-no-play-method/close")
  }

  /// The refusal is narrow: an ordinary direct-play session is untouched.
  @Test func anOrdinaryDirectPlaySessionIsNotRefused() async throws {
    let harness = try await CoordinatorHarness()
    harness.enqueuePlayResponse()

    let prepared = try await harness.coordinator.startSession(itemID: CoordinatorHarness.itemID, episodeID: nil)

    #expect(prepared.tracks.isEmpty == false)
    #expect(harness.http.requests.count == 1, "nothing to compensate - the session stays open")
  }

  @Test func aFailedCompensationCloseStillLeavesTheSessionDurablyClosePending() async throws {
    let harness = try await CoordinatorHarness()
    harness.enqueuePlayResponse(
      id: "server-session-unusable",
      tracks: [["contentUrl": "/api/items/\(CoordinatorHarness.itemID)/file/101"]]
    )
    harness.http.enqueue(HTTPResponse(statusCode: 500, headers: [:], body: Data()))  // /close fails

    await #expect(throws: PlaybackCoordinatorError.unusableStream) {
      _ = try await harness.coordinator.startSession(itemID: CoordinatorHarness.itemID, episodeID: nil)
    }

    // Never acknowledged (the network attempt failed), but durably marked closePending, so the
    // row is left for a later drain rather than lost.
    let stillThere = try #require(
      try harness.sessionStore.fetchSession(clientSessionId: harness.lastGeneratedClientSessionID()))
    #expect(stillThere.closePending == true)
  }

  // MARK: - Repeated start is idempotent

  @Test func repeatedStartForTheSameItemIsIdempotentAndSkipsASecondPlayCall() async throws {
    let harness = try await CoordinatorHarness()
    harness.enqueuePlayResponse()

    let first = try await harness.coordinator.startSession(itemID: CoordinatorHarness.itemID, episodeID: nil)
    let second = try await harness.coordinator.startSession(itemID: CoordinatorHarness.itemID, episodeID: nil)

    #expect(harness.http.requests.count == 1, "no second /play call for a repeated start of the active item")
    #expect(first == second)
  }

  /// The in-place resume hands back the preparation cached when the session opened, positioned
  /// where the listen began, not re-derived from the ticks since. A caller that needs a live
  /// stream again (a stalled one, say) must close the session first; asking for the same item
  /// without closing rewinds it.
  @Test func aRepeatStartResumesInPlaceAtTheOpeningPositionWhileAStopFirstResumesAtTheTickedOne()
    async throws
  {
    let harness = try await CoordinatorHarness()
    harness.enqueuePlayResponse()

    let opened = try await harness.coordinator.startSession(itemID: CoordinatorHarness.itemID, episodeID: nil)
    await harness.coordinator.recordProgressTick(
      itemID: CoordinatorHarness.itemID, episodeID: nil, currentTime: 900, listenedDelta: 900,
      isFinished: false, isSeek: false)

    let resumedInPlace = try await harness.coordinator.startSession(
      itemID: CoordinatorHarness.itemID, episodeID: nil)
    #expect(resumedInPlace.startPosition == opened.startPosition)
    #expect(resumedInPlace.startPosition != 900)

    harness.http.enqueue(HTTPResponse(statusCode: 200, headers: [:], body: Data()))  // /sync
    harness.http.enqueue(HTTPResponse(statusCode: 200, headers: [:], body: Data()))  // /close
    harness.enqueuePlayResponse(id: "session_after_close")
    try await harness.coordinator.stopSession()
    let restarted = try await harness.coordinator.startSession(
      itemID: CoordinatorHarness.itemID, episodeID: nil)

    #expect(restarted.startPosition == 900)
  }

  @Test func repeatedStartForTheSamePodcastEpisodeIsIdempotentAndSkipsASecondPlayCall() async throws {
    let harness = try await CoordinatorHarness()
    harness.enqueuePlayResponse()

    let first = try await harness.coordinator.startSession(
      itemID: CoordinatorHarness.itemID, episodeID: CoordinatorHarness.episodeID)
    let second = try await harness.coordinator.startSession(
      itemID: CoordinatorHarness.itemID, episodeID: CoordinatorHarness.episodeID)

    #expect(harness.http.requests.count == 1)
    #expect(
      harness.http.requests[0].url.path
        == "/api/items/\(CoordinatorHarness.itemID)/play/\(CoordinatorHarness.episodeID)")
    #expect(first == second)
  }

  @Test func aPodcastSessionPersistsItsResolvedEpisodeForeignKey() async throws {
    let harness = try await CoordinatorHarness()
    harness.enqueuePlayResponse()

    _ = try await harness.coordinator.startSession(
      itemID: CoordinatorHarness.itemID, episodeID: CoordinatorHarness.episodeID)

    let active = try #require(try harness.sessionStore.fetchActiveSession(accountId: harness.accountId))
    #expect(active.itemId == harness.itemRowId)
    #expect(active.podcastEpisodeId == harness.episodeRowId)
  }

  @Test func startingASiblingEpisodeClosesTheFormerEpisodeBeforeCallingPlay() async throws {
    let harness = try await CoordinatorHarness()
    harness.enqueuePlayResponse(id: "episode-session-first")
    harness.http.enqueue(HTTPResponse(statusCode: 200, headers: [:], body: Data()))  // /sync
    harness.http.enqueue(HTTPResponse(statusCode: 200, headers: [:], body: Data()))  // /close
    harness.enqueuePlayResponse(id: "episode-session-second")

    _ = try await harness.coordinator.startSession(
      itemID: CoordinatorHarness.itemID, episodeID: CoordinatorHarness.episodeID)
    await harness.coordinator.recordProgressTick(
      itemID: CoordinatorHarness.itemID, episodeID: CoordinatorHarness.episodeID,
      currentTime: 10, listenedDelta: 10, isFinished: false, isSeek: false)
    _ = try await harness.coordinator.startSession(
      itemID: CoordinatorHarness.itemID, episodeID: CoordinatorHarness.siblingEpisodeID)

    #expect(harness.http.requests.count == 4)
    #expect(
      harness.http.requests[0].url.path
        == "/api/items/\(CoordinatorHarness.itemID)/play/\(CoordinatorHarness.episodeID)")
    #expect(harness.http.requests[1].url.path == "/api/session/episode-session-first/sync")
    #expect(harness.http.requests[2].url.path == "/api/session/episode-session-first/close")
    #expect(
      harness.http.requests[3].url.path
        == "/api/items/\(CoordinatorHarness.itemID)/play/\(CoordinatorHarness.siblingEpisodeID)")
    let active = try #require(try harness.sessionStore.fetchActiveSession(accountId: harness.accountId))
    #expect(active.podcastEpisodeId == harness.siblingEpisodeRowId)
  }

  @Test func podcastStartAndTicksUseOnlyEpisodeScopedProgress() async throws {
    let harness = try await CoordinatorHarness()
    try await harness.seedLocalProgress(currentTime: 800, isFinished: false)
    try await harness.seedEpisodeProgress(
      episodeRowId: harness.episodeRowId, currentTime: 120, isFinished: false)
    harness.enqueuePlayResponse(currentTime: 0)

    let prepared = try await harness.coordinator.startSession(
      itemID: CoordinatorHarness.itemID, episodeID: CoordinatorHarness.episodeID)
    #expect(prepared.startPosition == 120)

    await harness.coordinator.recordProgressTick(
      itemID: CoordinatorHarness.itemID, episodeID: CoordinatorHarness.episodeID,
      currentTime: 150, listenedDelta: 30, isFinished: false, isSeek: false)

    let episodeProgress = try #require(
      try harness.mediaProgressDAO.fetchCurrent(
        accountId: harness.accountId,
        identity: .episode(itemId: harness.itemRowId, podcastEpisodeId: harness.episodeRowId)))
    let itemProgress = try #require(
      try harness.mediaProgressDAO.fetchCurrent(
        accountId: harness.accountId, identity: .item(itemId: harness.itemRowId)))
    #expect(episodeProgress.currentTime == 150)
    #expect(itemProgress.currentTime == 800)
  }

  @Test func aSleepTimerMarkerDoesNotCloseAnOnlineSession() async throws {
    let harness = try await CoordinatorHarness()
    harness.enqueuePlayResponse(id: "online-sleep-session")
    _ = try await harness.coordinator.startSession(itemID: CoordinatorHarness.itemID, episodeID: nil)

    await harness.coordinator.recordProgressTick(
      itemID: CoordinatorHarness.itemID, episodeID: nil, currentTime: 42, listenedDelta: 5,
      isFinished: false, isSeek: false, sleepTimerExpired: true)

    let active = try #require(try harness.sessionStore.fetchActiveSession(accountId: harness.accountId))
    #expect(active.serverSessionId == "online-sleep-session")
    #expect(active.closePending == false)
    #expect(
      harness.http.requests.map(\.url.path) == [
        "/api/items/\(CoordinatorHarness.itemID)/play"
      ])
  }

  @Test func staleTickFromSiblingEpisodeCannotWriteIntoTheActiveEpisode() async throws {
    let harness = try await CoordinatorHarness()
    harness.enqueuePlayResponse(id: "episode-session-first")
    harness.http.enqueue(HTTPResponse(statusCode: 200, headers: [:], body: Data()))  // /sync
    harness.http.enqueue(HTTPResponse(statusCode: 200, headers: [:], body: Data()))  // /close
    harness.enqueuePlayResponse(id: "episode-session-second")

    _ = try await harness.coordinator.startSession(
      itemID: CoordinatorHarness.itemID, episodeID: CoordinatorHarness.episodeID)
    await harness.coordinator.recordProgressTick(
      itemID: CoordinatorHarness.itemID, episodeID: CoordinatorHarness.episodeID,
      currentTime: 10, listenedDelta: 10, isFinished: false, isSeek: false)
    _ = try await harness.coordinator.startSession(
      itemID: CoordinatorHarness.itemID, episodeID: CoordinatorHarness.siblingEpisodeID)
    await harness.coordinator.recordProgressTick(
      itemID: CoordinatorHarness.itemID, episodeID: CoordinatorHarness.episodeID,
      currentTime: 999, listenedDelta: 10, isFinished: false, isSeek: false)

    let siblingProgress = try harness.mediaProgressDAO.fetchCurrent(
      accountId: harness.accountId,
      identity: .episode(
        itemId: harness.itemRowId, podcastEpisodeId: harness.siblingEpisodeRowId))
    #expect(siblingProgress == nil)
    let formerProgress = try #require(
      try harness.mediaProgressDAO.fetchCurrent(
        accountId: harness.accountId,
        identity: .episode(
          itemId: harness.itemRowId, podcastEpisodeId: harness.episodeRowId)))
    #expect(
      formerProgress.currentTime == 999,
      "a displaced episode tick may update its own identity, but never the active sibling episode")
  }

  /// Production wraps the coordinator in a decorator (`StreamConfiguringPlaybackSyncing`) behind
  /// `any PlaybackSyncing`. Drives an episode tick through that shape and checks episode identity
  /// reaches durable state: an episode-scoped `mediaProgress` row, and the session's position
  /// advancing off its seed (a stalled `globalPosition` makes `/close` report `currentTime: 0` and
  /// reset the server's progress).
  @Test func anEpisodeTickForwardedThroughAPlaybackSyncingDecoratorStillPersistsEpisodeProgress() async throws {
    let harness = try await CoordinatorHarness()
    harness.enqueuePlayResponse(currentTime: 0)
    let sync: any PlaybackSyncing = PassThroughPlaybackSyncing(underlying: harness.coordinator)

    _ = try await sync.startSession(
      itemID: CoordinatorHarness.itemID, episodeID: CoordinatorHarness.episodeID)
    await sync.recordProgressTick(
      itemID: CoordinatorHarness.itemID, episodeID: CoordinatorHarness.episodeID,
      currentTime: 240, listenedDelta: 30, isFinished: false, isSeek: false)

    let episodeProgress = try #require(
      try harness.mediaProgressDAO.fetchCurrent(
        accountId: harness.accountId,
        identity: .episode(itemId: harness.itemRowId, podcastEpisodeId: harness.episodeRowId)))
    #expect(episodeProgress.currentTime == 240)
    let session = try #require(try harness.sessionStore.fetchActiveSession(accountId: harness.accountId))
    #expect(session.podcastEpisodeId == harness.episodeRowId)
    #expect(session.globalPosition == 240)
    #expect(session.listenedDeltaSeconds == 30)
  }

  // MARK: - Item switch freezes and attempts the former close before /play for the next item

  @Test func startingADifferentItemFreezesAndClosesTheFormerSessionBeforeCallingPlayForTheNewItem() async throws {
    let harness = try await CoordinatorHarness()
    harness.enqueuePlayResponse(id: "server-session-first", itemID: CoordinatorHarness.itemID)
    harness.http.enqueue(HTTPResponse(statusCode: 200, headers: [:], body: Data()))  // /close for the first
    harness.enqueuePlayResponse(id: "server-session-second", itemID: CoordinatorHarness.secondItemID)

    _ = try await harness.coordinator.startSession(itemID: CoordinatorHarness.itemID, episodeID: nil)
    _ = try await harness.coordinator.startSession(itemID: CoordinatorHarness.secondItemID, episodeID: nil)

    #expect(harness.http.requests.count == 3)
    #expect(harness.http.requests[0].url.path == "/api/items/\(CoordinatorHarness.itemID)/play")
    #expect(harness.http.requests[1].url.path == "/api/session/server-session-first/close")
    #expect(harness.http.requests[2].url.path == "/api/items/\(CoordinatorHarness.secondItemID)/play")

    let active = try #require(try harness.sessionStore.fetchActiveSession(accountId: harness.accountId))
    #expect(active.serverSessionId == "server-session-second")
    #expect(active.itemId == harness.secondItemRowId)
  }

  // MARK: - Stop persists close before I/O

  @Test func stopSessionPersistsCloseBeforeAttemptingTheNetworkCall() async throws {
    let harness = try await CoordinatorHarness()
    harness.enqueuePlayResponse(id: "server-session-first")
    // The close fails, so the durable persistence below must not depend on the network attempt.
    harness.http.enqueue(HTTPResponse(statusCode: 500, headers: [:], body: Data()))

    _ = try await harness.coordinator.startSession(itemID: CoordinatorHarness.itemID, episodeID: nil)
    try await harness.coordinator.stopSession()

    #expect(harness.http.requests.count == 2)
    #expect(harness.http.requests[1].url.path == "/api/session/server-session-first/close")
    let stillThere = try #require(
      try harness.sessionStore.fetchSession(clientSessionId: harness.lastGeneratedClientSessionID()))
    #expect(stillThere.closePending == true)
  }

  @Test func stopSessionAcknowledgesTheCloseOnASuccessfulNetworkAttempt() async throws {
    let harness = try await CoordinatorHarness()
    harness.enqueuePlayResponse(id: "server-session-first")
    harness.http.enqueue(HTTPResponse(statusCode: 200, headers: [:], body: Data()))

    _ = try await harness.coordinator.startSession(itemID: CoordinatorHarness.itemID, episodeID: nil)
    try await harness.coordinator.stopSession()

    #expect(try harness.sessionStore.fetchActiveSession(accountId: harness.accountId) == nil)
  }

  @Test func stopSessionDrainsQueuedProgressBeforeClosingWithTheFinalPosition() async throws {
    let harness = try await CoordinatorHarness()
    harness.enqueuePlayResponse(id: "server-session-first")
    harness.http.enqueue(HTTPResponse(statusCode: 200, headers: [:], body: Data()))  // /sync
    harness.http.enqueue(HTTPResponse(statusCode: 200, headers: [:], body: Data()))  // /close

    _ = try await harness.coordinator.startSession(itemID: CoordinatorHarness.itemID, episodeID: nil)
    await harness.coordinator.recordProgressTick(
      itemID: CoordinatorHarness.itemID, episodeID: nil, currentTime: 50, listenedDelta: 46,
      isFinished: false, isSeek: false)
    try await harness.coordinator.stopSession()

    #expect(
      harness.http.requests.map(\.url.path) == [
        "/api/items/\(CoordinatorHarness.itemID)/play",
        "/api/session/server-session-first/sync",
        "/api/session/server-session-first/close",
      ])
    let syncBody = try #require(harness.http.requests[1].body)
    let syncObject = try #require(JSONSerialization.jsonObject(with: syncBody) as? [String: Any])
    #expect(syncObject["currentTime"] as? Double == 50)
    #expect(syncObject["timeListened"] as? Double == 46)
    let closeBody = try #require(harness.http.requests[2].body)
    let closeObject = try #require(JSONSerialization.jsonObject(with: closeBody) as? [String: Any])
    #expect(closeObject["currentTime"] as? Double == 50)
    #expect(closeObject["timeListened"] as? Double == 0)
    #expect(try harness.sessionStore.fetchActiveSession(accountId: harness.accountId) == nil)
  }

  @Test func failedQueuedProgressPreventsCloseAndRemainsDurableForRetry() async throws {
    let harness = try await CoordinatorHarness()
    harness.enqueuePlayResponse(id: "server-session-first")
    harness.http.enqueue(HTTPResponse(statusCode: 500, headers: [:], body: Data()))

    _ = try await harness.coordinator.startSession(itemID: CoordinatorHarness.itemID, episodeID: nil)
    await harness.coordinator.recordProgressTick(
      itemID: CoordinatorHarness.itemID, episodeID: nil, currentTime: 50, listenedDelta: 46,
      isFinished: false, isSeek: false)
    try await harness.coordinator.stopSession()

    #expect(
      harness.http.requests.map(\.url.path) == [
        "/api/items/\(CoordinatorHarness.itemID)/play",
        "/api/session/server-session-first/sync",
      ])
    let session = try #require(
      try harness.sessionStore.fetchSession(clientSessionId: harness.lastGeneratedClientSessionID()))
    #expect(session.closePending == true)
    let queued = try harness.outbox.fetchQueued(
      accountId: harness.accountId,
      entityKey: "session:\(session.clientSessionId)")
    #expect(
      queued.map(\.operationKind) == [
        OutboxOperationKind.sessionSync.rawValue,
        OutboxOperationKind.sessionClose.rawValue,
      ])
  }

  @Test func switchWaitsForAnInFlightDrainToFinishTheFormerSessionBeforePlayingTheReplacement() async throws {
    let harness = try await CoordinatorHarness()
    let gate = OneShotRequestGate()
    harness.http.setRequestHook { request in
      if request.url.path == "/api/session/server-session-first/sync" {
        await gate.suspend()
      }
    }
    harness.enqueuePlayResponse(id: "server-session-first", itemID: CoordinatorHarness.itemID)
    harness.http.enqueue(HTTPResponse(statusCode: 200, headers: [:], body: Data()))  // held /sync
    harness.http.enqueue(HTTPResponse(statusCode: 200, headers: [:], body: Data()))  // /close
    harness.enqueuePlayResponse(id: "server-session-second", itemID: CoordinatorHarness.secondItemID)

    _ = try await harness.coordinator.startSession(itemID: CoordinatorHarness.itemID, episodeID: nil)
    await harness.coordinator.recordProgressTick(
      itemID: CoordinatorHarness.itemID, episodeID: nil, currentTime: 50, listenedDelta: 46,
      isFinished: false, isSeek: false)
    let periodicDrain = Task {
      await harness.coordinator.notifyImmediateSyncTrigger(.backgrounded)
    }
    await harness.http.waitForRequests { requests in
      requests.contains { $0.url.path == "/api/session/server-session-first/sync" }
    }

    let switching = Task {
      try await harness.coordinator.startSession(itemID: CoordinatorHarness.secondItemID, episodeID: nil)
    }
    let closeWasFrozen = await TestSupport.waitUntil {
      (try? harness.sessionStore.fetchActiveSession(accountId: harness.accountId))?.closePending == true
    }
    #expect(closeWasFrozen)
    #expect(
      harness.http.requests.map(\.url.path) == [
        "/api/items/\(CoordinatorHarness.itemID)/play",
        "/api/session/server-session-first/sync",
      ],
      "the replacement /play must wait while the former session still owns the active slot")

    await gate.release()
    await periodicDrain.value
    _ = try await switching.value

    #expect(
      harness.http.requests.map(\.url.path) == [
        "/api/items/\(CoordinatorHarness.itemID)/play",
        "/api/session/server-session-first/sync",
        "/api/session/server-session-first/close",
        "/api/items/\(CoordinatorHarness.secondItemID)/play",
      ])
  }

  @Test func stopSessionIsANoOpWhenNothingIsActive() async throws {
    let harness = try await CoordinatorHarness()

    try await harness.coordinator.stopSession()

    #expect(harness.http.requests.isEmpty)
  }

  // MARK: - Backgrounding and logout lifecycle

  @Test func backgroundedStopRechecksThePhaseWhenPlaybackStartsWhileQueued() async throws {
    let harness = try await CoordinatorHarness()
    let gate = OneShotRequestGate()
    harness.http.setRequestHook { request in
      if request.url.path == "/api/session/server-session-first" {
        await gate.suspend()
      }
    }
    harness.enqueuePlayResponse(id: "server-session-first")

    _ = try await harness.coordinator.startSession(itemID: CoordinatorHarness.itemID, episodeID: nil)
    harness.http.enqueueFailure(FakeHTTPClientError(message: "recovery probe unavailable"))
    harness.http.enqueueFailure(FakeHTTPClientError(message: "open-session probe unavailable"))
    harness.http.enqueue(HTTPResponse(statusCode: 200, headers: [:], body: Data()))  // /close

    let recovery = Task { await harness.coordinator.recoverOpenSessions() }
    await harness.http.waitForRequests { requests in
      requests.contains { $0.url.path == "/api/session/server-session-first" }
    }

    let backgrounded = Task { await harness.coordinator.handleAppBackgrounded() }
    await TestSupport.awaitQuiescence(
      "the recovery request list to remain unchanged while the background transition queues",
      of: { harness.http.requests.map(\.url.path).joined(separator: ",") })
    await harness.coordinator.notifyPlaybackPhase(.buffering)
    await gate.release()
    await recovery.value
    await backgrounded.value

    let active = try #require(
      try harness.sessionStore.fetchActiveSession(accountId: harness.accountId))
    #expect(active.closePending == false)
    #expect(
      harness.http.requests.contains { $0.url.path == "/api/session/server-session-first/close" } == false)
  }

  @Test func backgroundedIdlePhaseClosesTheActiveSession() async throws {
    let harness = try await CoordinatorHarness()
    harness.enqueuePlayResponse(id: "server-session-first")
    harness.http.enqueue(HTTPResponse(statusCode: 200, headers: [:], body: Data()))  // /close

    _ = try await harness.coordinator.startSession(itemID: CoordinatorHarness.itemID, episodeID: nil)
    await harness.coordinator.handleAppBackgrounded()

    #expect(try harness.sessionStore.fetchActiveSession(accountId: harness.accountId) == nil)
    #expect(
      harness.http.requests.contains { $0.url.path == "/api/session/server-session-first/close" })
  }

  @Test func quiesceForLogoutClosesTheSessionEvenWhileBuffering() async throws {
    let harness = try await CoordinatorHarness()
    harness.enqueuePlayResponse(id: "server-session-first")
    harness.http.enqueue(HTTPResponse(statusCode: 200, headers: [:], body: Data()))  // /close

    _ = try await harness.coordinator.startSession(itemID: CoordinatorHarness.itemID, episodeID: nil)
    await harness.coordinator.notifyPlaybackPhase(.buffering)
    await harness.coordinator.quiesceForLogout()

    #expect(try harness.sessionStore.fetchActiveSession(accountId: harness.accountId) == nil)
    #expect(
      harness.http.requests.contains { $0.url.path == "/api/session/server-session-first/close" })
  }

  // MARK: - Concurrent start/stop/switch preserve one explicit order

  @Test func concurrentStartAndStopCallsApplyInOneExplicitOrder() async throws {
    let harness = try await CoordinatorHarness()
    harness.enqueuePlayResponse(id: "server-session-first")
    harness.http.enqueue(HTTPResponse(statusCode: 200, headers: [:], body: Data()))  // close from stop

    async let started: PreparedPlayback = harness.coordinator.startSession(
      itemID: CoordinatorHarness.itemID, episodeID: nil)
    async let stopped: Void = harness.coordinator.stopSession()

    _ = try await started
    try await stopped

    // Whichever order the two `async let`s submit in, the coordinator's chain applies them in
    // submission order: start's single `/play` precedes stop's `/close`, none dropped or doubled.
    #expect(harness.http.requests.count == 2)
    #expect(harness.http.requests[0].url.path == "/api/items/\(CoordinatorHarness.itemID)/play")
    #expect(harness.http.requests[1].url.path == "/api/session/server-session-first/close")
    #expect(try harness.sessionStore.fetchActiveSession(accountId: harness.accountId) == nil)
  }
}

// MARK: - CoordinatorHarness

private final class CoordinatorHarness: @unchecked Sendable {
  static let itemID = "item_book_fixture"
  static let secondItemID = "item_book_second_fixture"
  static let episodeID = "episode_fixture"
  static let siblingEpisodeID = "episode_sibling_fixture"

  let http: FakeHTTPClient
  let database: AppDatabase
  let outbox: OutboxStore
  let sessionStore: PlaybackSessionStore
  let mediaProgressDAO: MediaProgressDAO
  let coordinator: PlaybackSessionCoordinator
  let accountId: Int64
  let clientUUID: String
  let itemRowId: Int64
  let secondItemRowId: Int64
  let episodeRowId: Int64
  let siblingEpisodeRowId: Int64

  private let generatedClientSessionIDs = Locked<[String]>([])

  init(
    deviceMetadata: PlaybackDeviceMetadata = PlaybackDeviceMetadata(),
    resetCheckTimeout: TimeInterval = PlaybackSessionCoordinator.resetCheckTimeout
  ) async throws {
    let server = try ABSServerConfig(url: try #require(URL(string: "https://playback.example.test")))
    let localClientUUID = UUID().uuidString
    let account = try TokenAccount(
      credentialNamespace: AccountRecord.credentialNamespace(forClientUUID: localClientUUID), userID: "user_fixture")
    let tokenStore = InMemoryTokenStore()
    try tokenStore.save(TokenPair(accessToken: "canary-access", refreshToken: "canary-refresh"), for: account)

    http = FakeHTTPClient()
    let client = ABSClient(server: server, httpClient: http, tokenStore: tokenStore)

    let localDatabase = try AppDatabase.inMemory()
    let savedAccount = try await localDatabase.writeAsync { db in
      var record = AccountRecord(
        clientUUID: localClientUUID, serverBaseURL: server.baseURL.absoluteString, serverUserId: "user_fixture",
        serverVersion: "2.35.1")
      try record.save(db)
      return record
    }
    let localAccountId = try #require(savedAccount.id)

    let libraryId = try await localDatabase.writeAsync { db -> Int64 in
      var library = LibraryRecord(
        accountId: localAccountId, serverLibraryId: "lib-1", mediaType: "book", name: "Library")
      try library.insert(db)
      return library.id!
    }
    let itemDAO = ItemDAO(database: localDatabase)
    let localItemRowId = try #require(
      try await itemDAO.upsertAsync(
        ItemRecord(
          accountId: localAccountId, libraryId: libraryId, serverItemId: Self.itemID, mediaKind: "book",
          title: "Title", sortTitle: "title")
      ).id)
    let localSecondItemRowId = try #require(
      try await itemDAO.upsertAsync(
        ItemRecord(
          accountId: localAccountId, libraryId: libraryId, serverItemId: Self.secondItemID, mediaKind: "book",
          title: "Second Title", sortTitle: "second title")
      ).id)
    let episodeDAO = PodcastEpisodeDAO(database: localDatabase)
    let localEpisodeRowId = try #require(
      try await episodeDAO.upsertAsync(
        PodcastEpisodeRecord(
          accountId: localAccountId, itemId: localItemRowId, serverEpisodeId: Self.episodeID,
          title: "Episode", lastSeenGeneration: 1)
      ).id)
    let localSiblingEpisodeRowId = try #require(
      try await episodeDAO.upsertAsync(
        PodcastEpisodeRecord(
          accountId: localAccountId, itemId: localItemRowId, serverEpisodeId: Self.siblingEpisodeID,
          title: "Sibling Episode", lastSeenGeneration: 1)
      ).id)

    database = localDatabase
    accountId = localAccountId
    clientUUID = localClientUUID
    itemRowId = localItemRowId
    secondItemRowId = localSecondItemRowId
    episodeRowId = localEpisodeRowId
    siblingEpisodeRowId = localSiblingEpisodeRowId

    outbox = try OutboxStore(database: database)
    sessionStore = PlaybackSessionStore(database: database, outbox: outbox)
    mediaProgressDAO = MediaProgressDAO(database: database)

    let ids = generatedClientSessionIDs
    let drainer = OutboxDrainer(
      outboxStore: outbox, database: database, absClient: client, account: account,
      accountId: accountId)
    coordinator = PlaybackSessionCoordinator(
      client: client, database: database, outbox: outbox, deviceMetadata: deviceMetadata,
      clock: FakeSyncClock(now: Date(timeIntervalSince1970: 1_700_000_000)),
      clientSessionIDGenerator: {
        let id = UUID().uuidString
        ids.withValue { $0.append(id) }
        return id
      },
      requestDrain: { await drainer.drainOutbox(now: Date(timeIntervalSince1970: 1_700_000_000)) },
      resetCheckTimeout: resetCheckTimeout)
  }

  func lastGeneratedClientSessionID() -> String {
    generatedClientSessionIDs.value.last ?? ""
  }

  // MARK: - Fixtures

  func enqueuePlayResponse(
    id: String = "session_fixture",
    itemID: String = CoordinatorHarness.itemID,
    currentTime: Double = 0,
    duration: Double? = 3600,
    playMethod: Int? = 0,
    tracks: [[String: Any]]? = nil
  ) {
    var object: [String: Any] = [
      "id": id,
      "libraryItemId": itemID,
      "mediaType": "book",
      "displayTitle": "Fixture Book",
      "duration": duration as Any,
      "currentTime": currentTime,
      "deviceInfo": ["deviceId": "server-echoed-id"],
      "audioTracks": tracks ?? Self.defaultTracks(itemID: itemID),
      "chapters": [] as [Any],
    ]
    // Omitted rather than sent as null when nil, so the decoder sees a truly absent field.
    if let playMethod { object["playMethod"] = playMethod }
    http.enqueue(
      HTTPResponse(
        statusCode: 200, headers: ["Content-Type": "application/json"],
        body: try! JSONSerialization.data(withJSONObject: object)))
  }

  /// The `/auth/refresh` body the account's single-flight refresh consumes.
  func enqueueRefreshResponse(accessToken: String, refreshToken: String) {
    http.enqueue(
      HTTPResponse(
        statusCode: 200, headers: ["Content-Type": "application/json"],
        body: try! JSONSerialization.data(
          withJSONObject: ["user": ["accessToken": accessToken, "refreshToken": refreshToken]])))
  }

  static func defaultTracks(itemID: String) -> [[String: Any]] {
    [
      [
        "index": 1, "startOffset": 0, "duration": 100, "title": "Track 1",
        "contentUrl": "/api/items/\(itemID)/file/101", "mimeType": "audio/mpeg",
      ]
    ]
  }

  func seedLocalProgress(currentTime: Double, isFinished: Bool) async throws {
    try await database.writeAsync { db in
      var record = MediaProgressRecord(
        accountId: self.accountId, itemId: self.itemRowId, currentTime: currentTime, isFinished: isFinished,
        serverUpdatedAt: nil, localSequence: 1, origin: .local, originKey: self.clientUUID)
      try record.insert(db)
    }
  }

  /// A pulled row: the state this device last saw on the server, with that row's id.
  let observedAt = Date(timeIntervalSince1970: 1_699_990_000)

  func seedObservedServerProgress(
    currentTime: Double, serverProgressId: String, serverUpdatedAt: Date
  ) async throws {
    try await database.writeAsync { db in
      var record = MediaProgressRecord(
        accountId: self.accountId, itemId: self.itemRowId, currentTime: currentTime, isFinished: false,
        serverUpdatedAt: serverUpdatedAt, localSequence: 0, origin: .server,
        originKey: ProgressOrigin.serverOriginKey)
      record.serverProgressId = serverProgressId
      record.serverProgressUpdatedAt = serverUpdatedAt
      try record.insert(db)
    }
  }

  func enqueueProgressRow(id: String, currentTime: Double, startedAt: Date) {
    let millis = Int(startedAt.timeIntervalSince1970 * 1000)
    let object: [String: Any] = [
      "id": id, "libraryItemId": Self.itemID, "currentTime": currentTime, "isFinished": false,
      "startedAt": millis, "lastUpdate": millis,
    ]
    http.enqueue(
      HTTPResponse(
        statusCode: 200, headers: ["Content-Type": "application/json"],
        body: try! JSONSerialization.data(withJSONObject: object)))
  }

  func seedEpisodeProgress(
    episodeRowId: Int64, currentTime: Double, isFinished: Bool
  ) async throws {
    try await database.writeAsync { db in
      var record = MediaProgressRecord(
        accountId: self.accountId, itemId: self.itemRowId, podcastEpisodeId: episodeRowId,
        currentTime: currentTime, isFinished: isFinished, serverUpdatedAt: nil, localSequence: 1,
        origin: .local, originKey: self.clientUUID)
      try record.insert(db)
    }
  }

  /// Matches the `entityKey` production writes for a `progress`-kind row: the server item id, as
  /// `PlaybackSessionStore.markSessionGone` and `OutboxDrainer.sendProgress`'s wire
  /// `libraryItemID` use. A local-row-id string would silently fail to match in
  /// `MediaProgressDAO.hasUnacknowledgedLocalOperation`.
  func seedUnacknowledgedProgressWrite() throws {
    try outbox.enqueueProgress(
      accountId: accountId, entityKey: Self.itemID, podcastEpisodeId: nil, coalescingKey: Self.itemID, localSequence: 1,
      payload: OutboxProgressPayload(currentTime: 500, isFinished: false, accumulatedDeltaSeconds: 0))
  }
}

// Kept: a forwarding decorator over the real coordinator, which is the subject under test;
// FakePlaybackSyncing would replace the coordinator it is meant to exercise.
/// Core-side stand-in for the App's `StreamConfiguringPlaybackSyncing`: forwards every
/// `PlaybackSyncing` call unchanged, so the coordinator's episode contract runs through the same
/// indirection production uses.
private struct PassThroughPlaybackSyncing: PlaybackSyncing {
  let underlying: any PlaybackSyncing

  func startSession(itemID: String, episodeID: String?) async throws -> PreparedPlayback {
    try await underlying.startSession(itemID: itemID, episodeID: episodeID)
  }
  func promoteStreamingSessionToLocalDownload(
    itemID: String, episodeID: String?, currentPosition: Double, streamedDuration: Double?
  ) async -> PreparedPlayback? {
    await underlying.promoteStreamingSessionToLocalDownload(
      itemID: itemID, episodeID: episodeID, currentPosition: currentPosition,
      streamedDuration: streamedDuration)
  }
  func stopSession() async throws { try await underlying.stopSession() }
  func renewStreamAuthorization() async throws -> PlaybackStreamAuthorization? {
    try await underlying.renewStreamAuthorization()
  }
  func notifyPlaybackPhase(_ phase: PlaybackCadencePhase) async {
    await underlying.notifyPlaybackPhase(phase)
  }
  func willStartPlayback(itemID: String) {
    underlying.willStartPlayback(itemID: itemID)
  }
  func notifyImmediateSyncTrigger(_ trigger: PlaybackImmediateSyncTrigger) async {
    await underlying.notifyImmediateSyncTrigger(trigger)
  }
  func handleAppBackgrounded() async { await underlying.handleAppBackgrounded() }
  func recoverOpenSessions() async { await underlying.recoverOpenSessions() }
  func quiesceForLogout() async { await underlying.quiesceForLogout() }
  func recordProgressTick(
    itemID: String, episodeID: String?, currentTime: Double, listenedDelta: Double,
    isFinished: Bool, isSeek: Bool, sleepTimerExpired: Bool = false
  ) async {
    await underlying.recordProgressTick(
      itemID: itemID, episodeID: episodeID, currentTime: currentTime, listenedDelta: listenedDelta,
      isFinished: isFinished, isSeek: isSeek, sleepTimerExpired: sleepTimerExpired)
  }
}

private actor OneShotRequestGate {
  // The request runs to completion regardless of cancellation, so a cancelled one stays parked.
  private nonisolated let gate = TestGate<Void>(
    label: "OneShotRequestGate suspend", ignoresCancellation: true)

  init() {
    gate.hold()
  }

  func suspend() async {
    await gate.pass()
  }

  func release() {
    gate.release()
  }
}
