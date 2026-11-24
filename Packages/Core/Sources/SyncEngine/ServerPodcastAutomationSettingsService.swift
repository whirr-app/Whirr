import ABSApi
import Foundation

// `ServerPodcastAutomationSettingsWriting` carries these three values across SyncEngine's public
// boundary, and AppModel may not import ABSApi (ARCHITECTURE.md). The owning module stays ABSApi;
// SyncEngine re-exposes the same types so AppModel needs no second import, as with
// `PlaybackStreamAuthorization`.
public typealias PodcastAutomationSchedulePreset = ABSApi.PodcastAutomationSchedulePreset
public typealias PodcastAutomationSettingsRequest = ABSApi.PodcastAutomationSettingsRequest
public typealias PodcastAutomationSettingsResult = ABSApi.PodcastAutomationSettingsResult

/// How a successful write is confirmed.
public enum ServerPodcastAutomationConfirmation: Sendable, Equatable {
  /// The show has a local row: refresh it (never `refreshIfStale`) so the stored columns follow
  /// the write. The caller reads those columns afterwards.
  case refreshLocalRow
  /// The show has no local row: no refresh runs and the write's own response is the evidence.
  case responseOnly
}

/// Whether the post-write refresh of the local row finished.
public enum ServerPodcastAutomationRefreshState: Sendable, Equatable {
  case notAttempted
  case completed
  /// The refresh returned `.partial` or failed, even after the single repeat.
  case incomplete
}

/// The result of one automation-settings write. Descriptions carry no ids, URLs or schedules.
public enum ServerPodcastAutomationSettingsOutcome: Sendable, Equatable {
  /// The server's own response carries every value that was sent.
  case confirmed(PodcastAutomationSettingsResult, refresh: ServerPodcastAutomationRefreshState)
  /// The write was accepted but the response disagrees with it or carries no evidence (for
  /// example an undecodable 200 body). The values are what the server reported, if anything.
  case unconfirmed(PodcastAutomationSettingsResult, refresh: ServerPodcastAutomationRefreshState)
  /// The account cannot save; nothing was sent.
  case notPermitted
  /// The change failed client-side validation or the account could not be read; nothing was sent.
  case invalidRequest
  /// `403`. The capability has been invalidated.
  case forbidden
  /// `404`.
  case notFound
  /// `400`.
  case rejected
  /// The request may or may not have reached the server. No retry was made.
  case uncertain
  /// The account changed between the send and the refresh. No refresh ran and no value is
  /// reported.
  case accountChanged
  case cancelled
  /// Any other status (`401` after the transport's one resend, `429`, `5xx`).
  case failed
}

public protocol ServerPodcastAutomationSettingsWriting: Sendable {
  func update(
    itemID: String,
    change: PodcastAutomationSettingsRequest,
    confirmation: ServerPodcastAutomationConfirmation
  ) async -> ServerPodcastAutomationSettingsOutcome
}

/// Composition default for callers without a live server account.
public struct NoOpServerPodcastAutomationSettingsWriting:
  ServerPodcastAutomationSettingsWriting, Sendable
{
  public init() {}

  public func update(
    itemID: String,
    change: PodcastAutomationSettingsRequest,
    confirmation: ServerPodcastAutomationConfirmation
  ) async -> ServerPodcastAutomationSettingsOutcome { .notPermitted }
}

/// SyncEngine's narrow write seam, so the service is testable without a live `ABSClient`.
public protocol ServerPodcastAutomationSettingsClient: Sendable {
  func updatePodcastAutomationSettings(
    account: TokenAccount,
    itemID: String,
    request: PodcastAutomationSettingsRequest
  ) async throws -> PodcastAutomationSettingsResult
}

extension ABSClient: ServerPodcastAutomationSettingsClient {}

/// Writes a show's automatic-download settings. Independent of the native-episode save
/// coordinator: it shares no state with it and only reuses its account-reading seam.
public struct ServerPodcastAutomationSettingsService: ServerPodcastAutomationSettingsWriting,
  Sendable
{
  private let client: any ServerPodcastAutomationSettingsClient
  private let capabilityReader: any ServerPodcastMutationCapabilityReading
  private let accountReader: any NativeEpisodeServerSaveAccountReading
  private let refreshing: any PodcastRefreshing

  public init(
    client: any ServerPodcastAutomationSettingsClient,
    capabilityReader: any ServerPodcastMutationCapabilityReading,
    accountReader: any NativeEpisodeServerSaveAccountReading,
    refreshing: any PodcastRefreshing
  ) {
    self.client = client
    self.capabilityReader = capabilityReader
    self.accountReader = accountReader
    self.refreshing = refreshing
  }

  public func update(
    itemID: String,
    change: PodcastAutomationSettingsRequest,
    confirmation: ServerPodcastAutomationConfirmation
  ) async -> ServerPodcastAutomationSettingsOutcome {
    guard await capabilityReader.capability().canSave else { return .notPermitted }

    let sentAccount: NativeEpisodeServerSaveAccount
    do {
      sentAccount = try await accountReader.currentAccount()
    } catch {
      return .invalidRequest
    }

    let result: PodcastAutomationSettingsResult
    do {
      result = try await client.updatePodcastAutomationSettings(
        account: sentAccount.tokenAccount, itemID: itemID, request: change)
    } catch let error as APIError {
      switch error {
      case .forbidden:
        await capabilityReader.invalidate()
        return .forbidden
      case .notFound: return .notFound
      case .badRequest: return .rejected
      case .transport: return .uncertain
      case .cancelled: return .cancelled
      default: return .failed
      }
    } catch is PodcastWriteError {
      return .invalidRequest
    } catch is CancellationError {
      return .cancelled
    } catch {
      return .uncertain
    }

    // The write has landed. From here no outcome may be reported for a different account.
    guard await accountMatches(sentAccount) else { return .accountChanged }

    var refreshState = ServerPodcastAutomationRefreshState.notAttempted
    if confirmation == .refreshLocalRow {
      refreshState = await refreshLocalRow(itemID: itemID)
      if refreshState == .incomplete, await accountMatches(sentAccount) == false {
        return .accountChanged
      }
    }

    return Self.response(result, carries: change)
      ? .confirmed(result, refresh: refreshState)
      : .unconfirmed(result, refresh: refreshState)
  }

  /// One refresh, repeated exactly once when the first was partial or failed: it can join a
  /// refresh that began before the write, and a partial response keeps the old columns.
  private func refreshLocalRow(itemID: String) async -> ServerPodcastAutomationRefreshState {
    for _ in 0..<2 {
      if let outcome = try? await refreshing.refresh(itemID: itemID), outcome == .complete {
        return .completed
      }
    }
    return .incomplete
  }

  private func accountMatches(_ expected: NativeEpisodeServerSaveAccount) async -> Bool {
    guard let current = try? await accountReader.currentAccount() else { return false }
    return current.accountID == expected.accountID
      && current.clientUUID == expected.clientUUID
      && current.serverIdentityFingerprint == expected.serverIdentityFingerprint
      && current.tokenAccount == expected.tokenAccount
  }

  /// Every field that was sent must come back equal. An absent value is not evidence.
  private static func response(
    _ result: PodcastAutomationSettingsResult, carries change: PodcastAutomationSettingsRequest
  ) -> Bool {
    if let sent = change.autoDownloadEpisodes, result.autoDownloadEpisodes != sent { return false }
    if let sent = change.autoDownloadSchedule, result.autoDownloadSchedule != sent.cronExpression {
      return false
    }
    if let sent = change.maxNewEpisodesToDownload, result.maxNewEpisodesToDownload != sent {
      return false
    }
    if let sent = change.maxEpisodesToKeep, result.maxEpisodesToKeep != sent { return false }
    return true
  }
}
