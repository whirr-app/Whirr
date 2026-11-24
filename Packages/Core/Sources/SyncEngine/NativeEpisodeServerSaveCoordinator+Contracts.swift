import ABSApi
import Foundation
import Persistence

/// A destination selected by the user. Only server-owned identifiers cross the public command
/// boundary; URLs, filesystem paths, and credentials cannot be supplied by a caller.
public enum ServerPodcastSaveChoice: Sendable, Equatable, Hashable, CustomStringConvertible,
  CustomDebugStringConvertible, CustomReflectable
{
  case existing(serverItemID: String)
  case libraryAndFolder(libraryID: String, folderID: String)

  public static func libraryFolder(libraryID: String, folderID: String) -> Self {
    .libraryAndFolder(libraryID: libraryID, folderID: folderID)
  }

  public var description: String {
    switch self {
    case .existing: return "ServerPodcastSaveChoice(existing)"
    case .libraryAndFolder: return "ServerPodcastSaveChoice(libraryAndFolder)"
    }
  }

  public var debugDescription: String { description }
  public var customMirror: Mirror { Mirror(self, unlabeledChildren: []) }
}

public struct NativeEpisodeServerSaveLibraryChoice: Sendable, Equatable, Hashable,
  CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable
{
  public let libraryID: String
  public let displayName: String
  public let folders: [NativeEpisodeServerSaveFolderChoice]

  public init(
    libraryID: String,
    displayName: String,
    folders: [NativeEpisodeServerSaveFolderChoice]
  ) {
    self.libraryID = libraryID
    self.displayName = displayName
    self.folders = folders
  }

  public var description: String {
    "NativeEpisodeServerSaveLibraryChoice(folderCount: \(folders.count))"
  }

  public var debugDescription: String { description }
  public var customMirror: Mirror { Mirror(self, unlabeledChildren: []) }
}

public struct NativeEpisodeServerSaveExistingChoice: Sendable, Equatable, Hashable,
  CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable
{
  public let serverItemID: String
  public let displayName: String

  public init(serverItemID: String, displayName: String) {
    self.serverItemID = serverItemID
    self.displayName = displayName
  }

  public var description: String {
    "NativeEpisodeServerSaveExistingChoice(serverItemID: <redacted>, "
      + "displayName: <redacted>)"
  }

  public var debugDescription: String { description }
  public var customMirror: Mirror { Mirror(self, unlabeledChildren: []) }
}

public struct NativeEpisodeServerSaveFolderChoice: Sendable, Equatable, Hashable,
  CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable
{
  public let folderID: String
  public let displayName: String

  public init(folderID: String, displayName: String) {
    self.folderID = folderID
    self.displayName = displayName
  }

  public var description: String {
    "NativeEpisodeServerSaveFolderChoice(folderID: <redacted>, "
      + "displayName: <redacted>)"
  }

  public var debugDescription: String { description }
  public var customMirror: Mirror { Mirror(self, unlabeledChildren: []) }
}

public enum NativeEpisodeServerSaveChoicePrompt: Sendable, Equatable, CustomStringConvertible,
  CustomDebugStringConvertible, CustomReflectable
{
  case existing(candidates: [NativeEpisodeServerSaveExistingChoice])
  case libraryAndFolder(libraries: [NativeEpisodeServerSaveLibraryChoice])

  public var description: String {
    switch self {
    case .existing(let candidates):
      return "NativeEpisodeServerSaveChoicePrompt(existing, candidateCount: \(candidates.count))"
    case .libraryAndFolder(let libraries):
      return "NativeEpisodeServerSaveChoicePrompt(libraryAndFolder, libraryCount: \(libraries.count))"
    }
  }

  public var debugDescription: String { description }
  public var customMirror: Mirror { Mirror(self, unlabeledChildren: []) }
}

/// The public operation result contains only opaque ids and sanitized lifecycle state. The custom
/// mirror is needed because Swift's synthesized reflection would otherwise expose ids supplied
/// by a malicious or malformed server response.
public enum NativeEpisodeServerSaveOutcome: Sendable, Equatable, CustomStringConvertible,
  CustomDebugStringConvertible, CustomReflectable
{
  case needsChoice(attemptID: Int64, prompt: NativeEpisodeServerSaveChoicePrompt)
  case alreadyPresent(attemptID: Int64, serverItemID: String)
  case accepted(attemptID: Int64, serverItemID: String)
  case uncertain(
    attemptID: Int64,
    state: NativeEpisodeServerSaveAttemptState,
    category: NativeEpisodeServerSaveErrorCategory)
  case failed(
    attemptID: Int64?,
    state: NativeEpisodeServerSaveAttemptState,
    category: NativeEpisodeServerSaveErrorCategory)
  case inProgress(
    attemptID: Int64,
    state: NativeEpisodeServerSaveAttemptState,
    serverItemID: String?)

  public var attemptID: Int64? {
    switch self {
    case .needsChoice(let id, _), .alreadyPresent(let id, _), .accepted(let id, _),
      .uncertain(let id, _, _), .inProgress(let id, _, _):
      return id
    case .failed(let id, _, _): return id
    }
  }

  public var state: NativeEpisodeServerSaveAttemptState {
    switch self {
    case .needsChoice, .alreadyPresent: return .preparing
    case .accepted: return .accepted
    case .uncertain(_, let state, _), .failed(_, let state, _), .inProgress(_, let state, _):
      return state
    }
  }

  public var errorCategory: NativeEpisodeServerSaveErrorCategory? {
    switch self {
    case .uncertain(_, _, let category), .failed(_, _, let category): return category
    case .needsChoice, .alreadyPresent, .accepted, .inProgress: return nil
    }
  }

  public var serverItemID: String? {
    switch self {
    case .alreadyPresent(_, let id), .accepted(_, let id): return id
    case .inProgress(_, _, let id): return id
    case .needsChoice, .uncertain, .failed: return nil
    }
  }

  public var description: String {
    switch self {
    case .needsChoice(_, let prompt):
      return "NativeEpisodeServerSaveOutcome(needsChoice: \(prompt.description))"
    case .alreadyPresent: return "NativeEpisodeServerSaveOutcome(alreadyPresent)"
    case .accepted: return "NativeEpisodeServerSaveOutcome(accepted)"
    case .uncertain(_, let state, let category):
      return "NativeEpisodeServerSaveOutcome(uncertain, state: \(state.rawValue), category: \(category.rawValue))"
    case .failed(_, let state, let category):
      return "NativeEpisodeServerSaveOutcome(failed, state: \(state.rawValue), category: \(category.rawValue))"
    case .inProgress(_, let state, _):
      if state == .removed {
        return "NativeEpisodeServerSaveOutcome(removedFromAudiobookshelf)"
      }
      return "NativeEpisodeServerSaveOutcome(inProgress, state: \(state.rawValue))"
    }
  }

  public var debugDescription: String { description }
  public var customMirror: Mirror { Mirror(self, unlabeledChildren: []) }
}

/// The relaunch entry point for attempts whose last network result is not known locally. A pass
/// observes and checkpoints; the only request it can send is the enqueue that resumes a
/// `createUncertain` attempt whose show has been re-resolved.
public protocol NativeEpisodeServerSaveRecovering: Sendable {
  /// Recovers the current account's unsettled attempts, optionally only one feed's, and returns
  /// the attempt ids it visited.
  @discardableResult
  func recoverPendingAttempts(feedId: Int64?) async -> [Int64]
}

public struct NoOpNativeEpisodeServerSaveRecovering: NativeEpisodeServerSaveRecovering {
  public init() {}
  public func recoverPendingAttempts(feedId: Int64?) async -> [Int64] { [] }
}

public protocol NativeEpisodeServerSaving: Sendable {
  func save(
    feedId: Int64,
    episodeId: Int64,
    choice: ServerPodcastSaveChoice?
  ) async -> NativeEpisodeServerSaveOutcome

  func remove(attemptID: Int64) async -> NativeEpisodeServerSaveOutcome
}

/// A transient account context. `tokenAccount` is internal and this type redacts itself so the
/// server URL/user id cannot escape through diagnostics.
public struct NativeEpisodeServerSaveAccount: Sendable, Equatable, CustomStringConvertible,
  CustomDebugStringConvertible, CustomReflectable
{
  public let accountID: Int64
  public let clientUUID: String
  public let serverIdentityFingerprint: String
  let tokenAccount: TokenAccount

  public init(
    accountID: Int64,
    clientUUID: String,
    serverIdentityFingerprint: String,
    tokenAccount: TokenAccount
  ) {
    self.accountID = accountID
    self.clientUUID = clientUUID
    self.serverIdentityFingerprint = serverIdentityFingerprint
    self.tokenAccount = tokenAccount
  }

  public var description: String {
    "NativeEpisodeServerSaveAccount(accountID: \(accountID), fence: <redacted>)"
  }

  public var debugDescription: String { description }
  public var customMirror: Mirror { Mirror(self, unlabeledChildren: []) }
}

/// The coordinator's retained account identity. It contains no `TokenAccount`; the
/// raw server URL and user id are acquired only as a transient value immediately before a read or
/// write endpoint call.
struct NativeEpisodeServerSaveAccountFence: Sendable, Equatable {
  let accountID: Int64
  let clientUUID: String
  let serverIdentityFingerprint: String

  init(account: NativeEpisodeServerSaveAccount) {
    accountID = account.accountID
    clientUUID = account.clientUUID
    serverIdentityFingerprint = account.serverIdentityFingerprint
  }
}

public enum NativeEpisodeServerSaveAccountReadingError: Error, Sendable, Equatable,
  CustomStringConvertible
{
  case notAuthenticated
  case unavailable
  case malformedAccount

  public var description: String {
    switch self {
    case .notAuthenticated: return "No Audiobookshelf account is available."
    case .unavailable: return "The Audiobookshelf account could not be read."
    case .malformedAccount: return "The Audiobookshelf account is malformed."
    }
  }
}

public protocol NativeEpisodeServerSaveAccountReading: Sendable {
  func currentAccount() async throws -> NativeEpisodeServerSaveAccount
}

public enum NativeEpisodeServerSaveDestinationResolution: Sendable, Equatable,
  CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable
{
  case reuse(serverItemID: String)
  case create(ServerPodcastDestination)
  case needsChoice(NativeEpisodeServerSaveChoicePrompt)
  case noAccessiblePodcastLibraries

  public var description: String {
    switch self {
    case .reuse: return "NativeEpisodeServerSaveDestinationResolution(reuse)"
    case .create: return "NativeEpisodeServerSaveDestinationResolution(create)"
    case .needsChoice(let prompt):
      return "NativeEpisodeServerSaveDestinationResolution(\(prompt.description))"
    case .noAccessiblePodcastLibraries:
      return "NativeEpisodeServerSaveDestinationResolution(noAccessiblePodcastLibraries)"
    }
  }

  public var debugDescription: String { description }
  public var customMirror: Mirror { Mirror(self, unlabeledChildren: []) }
}

public protocol NativeEpisodeServerSaveDestinationResolving: Sendable {
  func resolveNativeEpisodeServerSaveDestination(
    feedURL: URL,
    nativeFeedTitle: String,
    account: TokenAccount,
    choice: ServerPodcastSaveChoice?
  ) async throws -> NativeEpisodeServerSaveDestinationResolution
}

public protocol NativeEpisodeServerSavePodcastWriting: Sendable {
  func createPodcast(
    account: TokenAccount,
    request: PodcastCreateRequest,
    diagnostics: DecodeDiagnostics?
  ) async throws -> String

  func enqueuePodcastEpisode(
    account: TokenAccount,
    itemID: String,
    episode: PodcastEpisodeDownloadRequest
  ) async throws

  func removePodcastEpisode(
    account: TokenAccount,
    itemID: String,
    episodeID: String
  ) async throws
}

public protocol NativeEpisodeServerSaveItemDetailReading: Sendable {
  func fetchItemDetail(
    account: TokenAccount,
    itemID: String,
    diagnostics: DecodeDiagnostics?
  ) async throws -> ItemDetail
}

public protocol NativeEpisodeServerSaveAttemptStoring: Sendable {
  func beginAttemptAsync(
    accountId: Int64,
    feedId: Int64,
    episodeId: Int64,
    episodeIdentityKey: String
  ) async throws -> NativeEpisodeServerSaveAttemptRecord

  func fetchAttemptAsync(id: Int64) async throws -> NativeEpisodeServerSaveAttemptRecord?

  func fetchAttemptsAsync(
    accountId: Int64,
    states: Set<NativeEpisodeServerSaveAttemptState>
  ) async throws -> [NativeEpisodeServerSaveAttemptRecord]

  func confirmPreExistingAsync(
    attemptId: Int64,
    serverItemId: String,
    serverEpisodeId: String
  ) async throws -> NativeEpisodeServerSaveAttemptRecord

  func transitionAsync(
    attemptId: Int64,
    to newState: NativeEpisodeServerSaveAttemptState,
    serverItemId: String?,
    errorCategory: NativeEpisodeServerSaveErrorCategory?
  ) async throws -> NativeEpisodeServerSaveAttemptRecord

  /// Records a known server absence whose local catalogue reconciliation is still pending. The
  /// concrete GRDB store also updates an existing `.deleteUncertain` row in place so a retry never
  /// needs to send DELETE again.
  func markRemovalConvergencePendingAsync(
    attemptId: Int64,
    serverItemId: String,
    accountId: Int64,
    errorCategory: NativeEpisodeServerSaveErrorCategory
  ) async throws -> NativeEpisodeServerSaveAttemptRecord

  /// The `.removed` transition with its post-delete episode/count reconciliation committed
  /// atomically. See `NativeEpisodeServerSaveAttemptStore
  /// .transitionToRemovedApplyingReconciliation` for the committed transaction shape. `episodes`
  /// is `nil` when the server no longer has the item, so there is no list to reconcile.
  func transitionToRemovedApplyingReconciliation(
    attemptId: Int64,
    serverItemId: String,
    accountId: Int64,
    episodes: [PodcastEpisodeRecord]?,
    refreshedAt: Date
  ) async throws -> NativeEpisodeServerSaveAttemptRecord

  func recordServerItemIDAsync(
    _ serverItemId: String,
    attemptId: Int64
  ) async throws -> NativeEpisodeServerSaveAttemptRecord

  func recordServerEpisodeIDAsync(
    _ serverEpisodeId: String,
    attemptId: Int64
  ) async throws -> NativeEpisodeServerSaveAttemptRecord

  func recordPreflightPresenceAsync(
    _ presence: NativeEpisodeServerSavePreflightPresence,
    attemptId: Int64
  ) async throws -> NativeEpisodeServerSaveAttemptRecord
}
