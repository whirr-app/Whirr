import Foundation
import Persistence
import TestSupport
import Testing

@testable import ABSApi
@testable import SyncEngine

/// A `401` mid-transfer pauses and requests one renewed request; a second consecutive failure
/// becomes a durable `pausedAuth`; a successful re-authentication (via `ResolutionCenter`) resumes
/// it through the ordinary scheduler, never an independent refresh loop.
@Suite struct DownloadAuthRecoveryTests {

  @Test func authChallengePausesTheTransferAndRequestsExactlyOneRenewedRequest() async throws {
    let harness = try await DownloadCoordinatorHarness()
    harness.enqueueBookItemDetail(audioFiles: [(index: 0, ino: 100, size: 50, mimeType: "audio/mp4", duration: 5)])
    try await harness.coordinator.requestDownload(itemID: DownloadCoordinatorHarness.itemID)
    let downloadId = try #require(try harness.fetchDownloads(itemId: harness.itemRowId).first?.id)

    harness.enqueueRefreshResponse(accessToken: "renewed-access", refreshToken: "renewed-refresh")
    harness.backgroundTransferring.pushEvent(.authChallenge(identity: .abs(rowID: downloadId)))
    await TestSupport.waitUntil {
      harness.backgroundTransferring.calls.filter {
        if case .enqueue = $0 { return true } else { return false }
      }.count == 2
    }

    #expect(
      try harness.downloadStore.fetch(downloadId: downloadId)?.state == .downloading,
      "one renewal keeps the transfer alive - never a visible pausedAuth for the first challenge")
    #expect(harness.http.requests.contains { $0.url.path == "/auth/refresh" })
    let enqueueCalls = harness.backgroundTransferring.calls.filter {
      if case .enqueue = $0 { return true } else { return false }
    }
    #expect(enqueueCalls.count == 2, "the original start plus exactly one renewed re-enqueue")
  }

  @Test func aSecondConsecutiveAuthFailureTransitionsToDurablePausedAuth() async throws {
    let harness = try await DownloadCoordinatorHarness()
    harness.enqueueBookItemDetail(audioFiles: [(index: 0, ino: 100, size: 50, mimeType: "audio/mp4", duration: 5)])
    try await harness.coordinator.requestDownload(itemID: DownloadCoordinatorHarness.itemID)
    let downloadId = try #require(try harness.fetchDownloads(itemId: harness.itemRowId).first?.id)

    harness.enqueueRefreshResponse(accessToken: "renewed-access", refreshToken: "renewed-refresh")
    harness.backgroundTransferring.pushEvent(.authChallenge(identity: .abs(rowID: downloadId)))
    await TestSupport.waitUntil {
      harness.backgroundTransferring.calls.filter {
        if case .enqueue = $0 { return true } else { return false }
      }.count == 2
    }
    harness.backgroundTransferring.pushEvent(.authChallenge(identity: .abs(rowID: downloadId)))
    await TestSupport.waitUntil {
      (try? harness.downloadStore.fetch(downloadId: downloadId))?.state == .pausedAuth
    }

    #expect(try harness.downloadStore.fetch(downloadId: downloadId)?.state == .pausedAuth)
  }

  @Test func neverAnIndependentRefreshLoopBeyondTheOneRenewedRetry() async throws {
    let harness = try await DownloadCoordinatorHarness()
    harness.enqueueBookItemDetail(audioFiles: [(index: 0, ino: 100, size: 50, mimeType: "audio/mp4", duration: 5)])
    try await harness.coordinator.requestDownload(itemID: DownloadCoordinatorHarness.itemID)
    let downloadId = try #require(try harness.fetchDownloads(itemId: harness.itemRowId).first?.id)

    harness.enqueueRefreshResponse(accessToken: "renewed-access", refreshToken: "renewed-refresh")
    harness.backgroundTransferring.pushEvent(.authChallenge(identity: .abs(rowID: downloadId)))
    await TestSupport.waitUntil {
      harness.backgroundTransferring.calls.filter {
        if case .enqueue = $0 { return true } else { return false }
      }.count == 2
    }
    harness.backgroundTransferring.pushEvent(.authChallenge(identity: .abs(rowID: downloadId)))
    await TestSupport.waitUntil {
      (try? harness.downloadStore.fetch(downloadId: downloadId))?.state == .pausedAuth
    }

    #expect(harness.http.requests.filter { $0.url.path == "/auth/refresh" }.count == 1)
  }

  @Test func rssAuthHoldReleasesGlobalSlotWithoutABSRefresh() async throws {
    let harness = try await DownloadCoordinatorHarness()
    let rss = try await harness.seedRSSDownload(bytes: 50)
    let rssID = try #require(rss.id)
    _ = try harness.rssDownloadStore.transition(downloadId: rssID, to: .downloading)

    let abs = try harness.downloadStore.enqueue(
      accountId: harness.accountId, itemId: harness.itemRowId, serverFileIno: "queued-abs",
      orderIndex: 0, destinationRelativePath: "queued-abs.m4b", expectedBytes: 50,
      expectedMimeType: "audio/mp4", fileDurationSeconds: 1)
    let absID = try #require(abs.id)

    harness.backgroundTransferring.pushEvent(.authChallenge(identity: .rss(rowID: rssID)))
    await TestSupport.waitUntil {
      (try? harness.rssDownloadStore.fetch(downloadId: rssID)?.state) == .pausedAuth
        && (try? harness.downloadStore.fetch(downloadId: absID)?.state) == .downloading
        && harness.backgroundTransferring.calls.contains { call in
          if case .enqueue(let identity, _, _, _) = call { return identity == .abs(rowID: absID) }
          return false
        }
    }

    let held = try #require(try harness.rssDownloadStore.fetch(downloadId: rssID))
    #expect(held.holdReason == .feedCredentials)
    #expect(harness.http.requests.contains { $0.url.path == "/auth/refresh" } == false)
    #expect(
      harness.backgroundTransferring.calls.contains { call in
        if case .enqueue(let identity, _, _, _) = call { return identity == .abs(rowID: absID) }
        return false
      })
  }

  @Test func feedCredentialUpdateReleasesOnlyThatFeedsHoldsWithoutABSRefresh() async throws {
    // This exercises the explicit update path, so omit the unrelated environment subscriptions;
    // otherwise their initial scheduling pass can race this test's deliberate state setup.
    let harness = try await DownloadCoordinatorHarness(startSubscriptions: false)
    let first = try await harness.seedRSSDownload(
      feedID: 41, episodeKey: "first", bytes: 50)
    let second = try await harness.seedRSSDownload(
      feedID: 42, episodeKey: "second", bytes: 50)
    let firstID = try #require(first.id)
    let firstDetails = try #require(
      try harness.rssDownloadStore.transferDetails(downloadId: firstID))
    let firstFeedID = try #require(firstDetails.feed.id)
    let secondID = try #require(second.id)
    for id in [firstID, secondID] {
      _ = try harness.rssDownloadStore.transition(downloadId: id, to: .downloading)
      _ = try harness.rssDownloadStore.transition(
        downloadId: id, to: .pausedAuth, holdReason: .feedCredentials, errorCode: .auth)
    }
    let abs = try harness.downloadStore.enqueue(
      accountId: harness.accountId, itemId: harness.itemRowId, serverFileIno: "abs-held",
      orderIndex: 0, destinationRelativePath: "abs-held.m4b", expectedBytes: 50,
      expectedMimeType: "audio/mp4", fileDurationSeconds: 1)
    let absID = try #require(abs.id)
    _ = try harness.downloadStore.transition(downloadId: absID, to: .downloading)
    _ = try harness.downloadStore.transition(downloadId: absID, to: .pausedAuth)
    try harness.feedCredentialStore.save(
      try FeedCredential.basic(username: "new", password: "credential"),
      forFeedID: firstFeedID)

    await harness.coordinator.handleFeedCredentialUpdate(feedId: firstFeedID)

    #expect(try harness.rssDownloadStore.fetch(downloadId: firstID)?.state == .downloading)
    #expect(try harness.rssDownloadStore.fetch(downloadId: secondID)?.state == .pausedAuth)
    #expect(try harness.downloadStore.fetch(downloadId: absID)?.state == .pausedAuth)
    #expect(harness.http.requests.contains { $0.url.path == "/auth/refresh" } == false)
  }

  @Test func successfulReauthenticationTransitionsToPendingAndResumesThroughTheOrdinaryScheduler() async throws {
    let harness = try await DownloadCoordinatorHarness()
    harness.enqueueBookItemDetail(audioFiles: [(index: 0, ino: 100, size: 50, mimeType: "audio/mp4", duration: 5)])
    try await harness.coordinator.requestDownload(itemID: DownloadCoordinatorHarness.itemID)
    let downloadId = try #require(try harness.fetchDownloads(itemId: harness.itemRowId).first?.id)
    _ = try harness.downloadStore.transition(downloadId: downloadId, to: .pausedAuth)

    await harness.coordinator.handleSuccessfulReauthentication()

    #expect(
      try harness.downloadStore.fetch(downloadId: downloadId)?.state == .downloading,
      "resumes through the ordinary scheduler - pending, then started, since a slot is free")
  }

  @Test(arguments: RenewalFailure.allCases)
  func renewalFailureIsRetryableExceptForUnauthorized(failure: RenewalFailure) async throws {
    let harness = try await DownloadCoordinatorHarness()
    harness.enqueueBookItemDetail(audioFiles: [(index: 0, ino: 100, size: 50, mimeType: "audio/mp4", duration: 5)])
    try await harness.coordinator.requestDownload(itemID: DownloadCoordinatorHarness.itemID)
    let downloadId = try #require(try harness.fetchDownloads(itemId: harness.itemRowId).first?.id)

    failure.enqueue(on: harness)
    harness.backgroundTransferring.pushEvent(.authChallenge(identity: .abs(rowID: downloadId)))
    // Both outcomes are terminal for this attempt. Wait on either so the test checks which one
    // arrived rather than settling for "not downloading".
    await TestSupport.waitUntil {
      let state = (try? harness.downloadStore.fetch(downloadId: downloadId))?.state
      return state == .pausedAuth || state == .failed
    }

    let row = try #require(try harness.downloadStore.fetch(downloadId: downloadId))
    if failure == .unauthorized {
      #expect(row.state == .pausedAuth)
      #expect(row.errorCategory == nil)
    } else {
      #expect(row.state == .failed, "only a rejected credential may reach the durable auth pause")
      #expect(row.errorCategory == .transport)
    }
  }
}

enum RenewalFailure: CaseIterable, Equatable, Sendable {
  case transport
  case rateLimited
  case serverFailure
  case decoding
  case forbidden
  case unauthorized

  func enqueue(on harness: DownloadCoordinatorHarness) {
    switch self {
    case .transport:
      harness.http.enqueueFailure(URLError(.notConnectedToInternet))
    case .rateLimited:
      harness.http.enqueue(HTTPResponse(statusCode: 429, headers: [:], body: Data()))
    case .serverFailure:
      harness.http.enqueue(HTTPResponse(statusCode: 503, headers: [:], body: Data()))
    case .decoding:
      harness.http.enqueue(
        HTTPResponse(statusCode: 200, headers: ["Content-Type": "application/json"], body: Data("malformed".utf8)))
    case .forbidden:
      harness.http.enqueue(HTTPResponse(statusCode: 403, headers: [:], body: Data()))
    case .unauthorized:
      harness.http.enqueue(HTTPResponse(statusCode: 401, headers: [:], body: Data()))
    }
  }
}
