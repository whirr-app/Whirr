import ABSApi
import Foundation
import Persistence

/// The two action-specific permissions needed by the native-podcast server-save surface.
/// Derivation is fail-closed: a stale or incomplete profile must not make a
/// destructive action appear available.
public struct ServerPodcastMutationCapability: Sendable, Equatable {
  public let canSave: Bool
  public let canRemove: Bool

  public static let none = ServerPodcastMutationCapability(canSave: false, canRemove: false)

  /// Remove is stored as an intersection rather than as the caller's literal argument: removal
  /// requires everything save requires plus the delete permission, so a value can never claim a
  /// removal capability it has no save capability to justify.
  public init(canSave: Bool, canRemove: Bool) {
    self.canSave = canSave
    self.canRemove = canSave && canRemove
  }

  public static func derive(from profile: UserProfile) -> ServerPodcastMutationCapability {
    let normalizedType = profile.type?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard normalizedType == "admin" || normalizedType == "root", profile.isActive == true else {
      return .none
    }

    let canSave = profile.permissionsUpdate == true
    return ServerPodcastMutationCapability(
      canSave: canSave,
      canRemove: canSave && profile.permissionsDelete == true)
  }
}

public protocol ServerPodcastMutationCapabilityReading: Sendable {
  func capability() async -> ServerPodcastMutationCapability
  func invalidate() async
}

/// Default composition for callers that do not have a live server account. Unknown capability is
/// represented by the same empty value as a failed profile read.
public struct NoOpServerPodcastMutationCapabilityReading:
  ServerPodcastMutationCapabilityReading, Sendable
{
  public init() {}

  public func capability() async -> ServerPodcastMutationCapability { .none }

  public func invalidate() async {}
}

/// SyncEngine's narrow read seam keeps the capability service testable without constructing a live
/// ABSClient. The concrete ABSClient conformance below is the only production implementation.
public protocol ServerPodcastMutationCapabilityProfileReading: Sendable {
  func fetchUserProfile(account: TokenAccount) async throws -> UserProfile
}

extension ABSClient: ServerPodcastMutationCapabilityProfileReading {}

/// Reads the single persisted account's live profile once, coalesces concurrent reads, and caches
/// only a successfully fetched profile. A failed account lookup, malformed account, or failed
/// profile request returns `.none` but remains retryable rather than being cached as authority.
public actor ServerPodcastMutationCapabilityService: ServerPodcastMutationCapabilityReading {
  private struct CapabilityLoad: Sendable {
    let capability: ServerPodcastMutationCapability
    let cacheable: Bool
  }

  private struct InFlight {
    let id: UInt64
    let invalidationEpoch: UInt64
    let task: Task<CapabilityLoad, Never>
  }

  private let client: any ServerPodcastMutationCapabilityProfileReading
  private let accountDAO: AccountDAO
  private var cachedCapability: ServerPodcastMutationCapability?
  private var inFlight: InFlight?
  private var nextRequestID: UInt64 = 0
  private var invalidationEpoch: UInt64 = 0

  public init(
    client: any ServerPodcastMutationCapabilityProfileReading,
    database: AppDatabase
  ) {
    self.client = client
    accountDAO = AccountDAO(database: database)
  }

  public func capability() async -> ServerPodcastMutationCapability {
    if let cachedCapability {
      return cachedCapability
    }

    if let inFlight {
      let result = await inFlight.task.value
      finish(inFlight, result: result)
      return result.capability
    }

    nextRequestID &+= 1
    let requestID = nextRequestID
    let requestEpoch = invalidationEpoch
    let client = self.client
    let accountDAO = self.accountDAO
    let task = Task<CapabilityLoad, Never> {
      await Self.loadCapability(accountDAO: accountDAO, client: client)
    }
    let request = InFlight(id: requestID, invalidationEpoch: requestEpoch, task: task)
    inFlight = request

    let result = await task.value
    finish(request, result: result)
    return result.capability
  }

  public func invalidate() async {
    invalidationEpoch &+= 1
    cachedCapability = nil
    // Detaching the old flight prevents its result from repopulating a cache after logout or
    // account replacement. A new caller may start a fresh read immediately after invalidation.
    inFlight?.task.cancel()
    inFlight = nil
  }

  private func finish(_ request: InFlight, result: CapabilityLoad) {
    guard inFlight?.id == request.id else { return }
    inFlight = nil
    guard request.invalidationEpoch == invalidationEpoch, result.cacheable else { return }
    cachedCapability = result.capability
  }

  private nonisolated static func loadCapability(
    accountDAO: AccountDAO,
    client: any ServerPodcastMutationCapabilityProfileReading
  ) async -> CapabilityLoad {
    do {
      try Task.checkCancellation()
      guard let record = try await accountDAO.fetchAsync(), record.id != nil else {
        return CapabilityLoad(capability: .none, cacheable: false)
      }

      let account: TokenAccount
      do {
        account = try tokenAccount(for: record)
      } catch {
        return CapabilityLoad(capability: .none, cacheable: false)
      }

      try Task.checkCancellation()
      let profile = try await client.fetchUserProfile(account: account)
      return CapabilityLoad(
        capability: .derive(from: profile),
        cacheable: true)
    } catch {
      return CapabilityLoad(capability: .none, cacheable: false)
    }
  }
}
