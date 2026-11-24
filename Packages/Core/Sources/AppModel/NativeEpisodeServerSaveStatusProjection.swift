import Persistence
import SyncEngine

/// The smallest account read needed by the presentation projection. An absent account and a
/// failed read are indistinguishable to callers: both mean no status is shown.
public protocol NativeEpisodeServerSaveAccountIDReading: Sendable {
  func currentAccountID() async throws -> Int64
}

public struct PersistenceNativeEpisodeServerSaveAccountIDReader:
  NativeEpisodeServerSaveAccountIDReading, Sendable
{
  private let accountDAO: AccountDAO

  public init(database: AppDatabase) {
    accountDAO = AccountDAO(database: database)
  }

  public func currentAccountID() async throws -> Int64 {
    guard let id = try await accountDAO.fetchAsync()?.id else {
      throw NativeEpisodeServerSaveAccountIDReadingError.noAccount
    }
    return id
  }
}

public enum NativeEpisodeServerSaveAccountIDReadingError: Error, Sendable, Equatable {
  case noAccount
}

public struct NativeEpisodeServerSaveStatusSnapshot: Sendable, Equatable {
  public let status: NativeEpisodeServerSaveStatus
  public let attemptID: Int64?
  public let preflightPresence: NativeEpisodeServerSavePreflightPresence?

  public init(
    status: NativeEpisodeServerSaveStatus,
    attemptID: Int64? = nil,
    preflightPresence: NativeEpisodeServerSavePreflightPresence? = nil
  ) {
    self.status = status
    self.attemptID = attemptID
    self.preflightPresence = preflightPresence
  }
}

public protocol NativeEpisodeServerSaveStatusReading: Sendable {
  func status(feedId: Int64, episodeId: Int64) async -> NativeEpisodeServerSaveStatusSnapshot
  /// The list form: one snapshot per resolved episode, keyed by row id. Episodes with no attempt
  /// may be absent; the caller treats absence as `.none`. Readers that cannot batch inherit the
  /// per-episode loop below; the durable projection overrides it with one read.
  func statuses(
    feedId: Int64, episodeIds: [Int64]
  ) async -> [Int64: NativeEpisodeServerSaveStatusSnapshot]

  /// A bounded, account-scoped stream for the visible native episode rows. The default keeps
  /// older readers source-compatible by yielding one current aggregate snapshot and finishing;
  /// the durable projection overrides this with its persistence observation boundary. Models must
  /// subscribe once for the visible row set rather than opening one observation per episode.
  func observeStatuses(
    feedId: Int64, episodeIds: [Int64]
  ) -> AsyncStream<[Int64: NativeEpisodeServerSaveStatusSnapshot]>

  /// The server show's view of the same attempts: one snapshot per server episode id that a
  /// Whirr save confirmed into `serverItemId`. This is what lets the server-owned show screen
  /// and card offer Remove for an episode Whirr put there. Readers with no server-side index
  /// inherit the default, which reports nothing and finishes.
  func observeServerItemStatuses(
    serverItemId: String
  ) -> AsyncStream<[String: NativeEpisodeServerSaveStatusSnapshot]>
}

extension NativeEpisodeServerSaveStatusReading {
  public func statuses(
    feedId: Int64, episodeIds: [Int64]
  ) async -> [Int64: NativeEpisodeServerSaveStatusSnapshot] {
    var snapshots: [Int64: NativeEpisodeServerSaveStatusSnapshot] = [:]
    for episodeId in episodeIds {
      snapshots[episodeId] = await status(feedId: feedId, episodeId: episodeId)
    }
    return snapshots
  }

  /// Compatibility observation for readers that only provide pull reads. Production persistence
  /// readers override this method with a live aggregate stream; this fallback emits once so tests
  /// and lightweight compositions do not create a polling loop.
  public func observeStatuses(
    feedId: Int64, episodeIds: [Int64]
  ) -> AsyncStream<[Int64: NativeEpisodeServerSaveStatusSnapshot]> {
    let reader = self
    return AsyncStream { continuation in
      let task = Task {
        guard episodeIds.isEmpty == false else {
          continuation.yield([:])
          continuation.finish()
          return
        }
        continuation.yield(await reader.statuses(feedId: feedId, episodeIds: episodeIds))
        continuation.finish()
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }

  public func observeServerItemStatuses(
    serverItemId: String
  ) -> AsyncStream<[String: NativeEpisodeServerSaveStatusSnapshot]> {
    AsyncStream { continuation in
      continuation.yield([:])
      continuation.finish()
    }
  }
}

/// Reads only durable state; it never cancels, deletes, transitions or reconciles an attempt. If
/// native subscriptions are disabled, the account is absent, or the current account does not fence
/// the row, even a requested or saved row becomes none for the presentation. That means "nothing to
/// show for this account", not that Whirr withdrew an operation already sent to the server.
///
/// On teardown, preparing and creatingShow are unsent and may have their local prompt/status
/// discarded. requestingDownload and every later state may already have been sent: the
/// presentation still disappears with its account context, but this reader leaves the row
/// untouched and claims no cancellation, revocation or undo.
public struct NativeEpisodeServerSaveStatusProjection: NativeEpisodeServerSaveStatusReading, Sendable {
  private let attemptStore: NativeEpisodeServerSaveAttemptStore
  private let accountIDReading: any NativeEpisodeServerSaveAccountIDReading
  private let nativeSubscriptionsReading: any NativePodcastSubscriptionsReading

  /// `nativeSubscriptionsReading` has no default. The only available no-op conformance answers
  /// `isEnabled() == true`, so defaulting to it would compose a projection that reports a
  /// server-save status while native subscriptions are switched off.
  public init(
    attemptStore: NativeEpisodeServerSaveAttemptStore,
    accountIDReading: any NativeEpisodeServerSaveAccountIDReading,
    nativeSubscriptionsReading: any NativePodcastSubscriptionsReading
  ) {
    self.attemptStore = attemptStore
    self.accountIDReading = accountIDReading
    self.nativeSubscriptionsReading = nativeSubscriptionsReading
  }

  public init(
    database: AppDatabase,
    nativeSubscriptionsReading: any NativePodcastSubscriptionsReading
  ) {
    self.init(
      attemptStore: NativeEpisodeServerSaveAttemptStore(database: database),
      accountIDReading: PersistenceNativeEpisodeServerSaveAccountIDReader(database: database),
      nativeSubscriptionsReading: nativeSubscriptionsReading)
  }

  public func status(feedId: Int64, episodeId: Int64) async -> NativeEpisodeServerSaveStatusSnapshot {
    guard await nativeSubscriptionsReading.isEnabled() else { return Self.none }

    let accountID: Int64
    do {
      accountID = try await accountIDReading.currentAccountID()
    } catch {
      return Self.none
    }

    let attempts: [NativeEpisodeServerSaveAttemptRecord]
    do {
      attempts = try await attemptStore.fetchAttemptsAsync(
        accountId: accountID, feedId: feedId, episodeId: episodeId)
    } catch {
      return Self.none
    }
    guard let attempt = attempts.max(by: { $0.isOlder(than: $1) }) else { return Self.none }
    return Self.snapshot(for: attempt)
  }

  /// One feature-flag read, one account read, one attempt query for the whole list. Every
  /// gate that silences `status(feedId:episodeId:)` silences this the same way: an empty answer.
  public func statuses(
    feedId: Int64, episodeIds: [Int64]
  ) async -> [Int64: NativeEpisodeServerSaveStatusSnapshot] {
    guard episodeIds.isEmpty == false else { return [:] }
    guard await nativeSubscriptionsReading.isEnabled() else { return [:] }

    let accountID: Int64
    do {
      accountID = try await accountIDReading.currentAccountID()
    } catch {
      return [:]
    }

    let attempts: [NativeEpisodeServerSaveAttemptRecord]
    do {
      attempts = try await attemptStore.fetchAttemptsAsync(
        accountId: accountID, feedId: feedId, episodeIds: episodeIds)
    } catch {
      return [:]
    }

    var latest: [Int64: NativeEpisodeServerSaveAttemptRecord] = [:]
    for attempt in attempts {
      if let current = latest[attempt.episodeId], attempt.isOlder(than: current) { continue }
      latest[attempt.episodeId] = attempt
    }
    return latest.mapValues(Self.snapshot(for:))
  }

  /// Both gates are resolved once at subscribe time, not per emission.
  /// `observeServerSaveProjection` in `PodcastShowServerSaveModel.swift` cancels and replaces the
  /// subscription's task on account replacement or the native-subscriptions-disabled trigger, so a
  /// stale gate value cannot outlive the condition that produced it.
  public func observeStatuses(
    feedId: Int64, episodeIds: [Int64]
  ) -> AsyncStream<[Int64: NativeEpisodeServerSaveStatusSnapshot]> {
    guard episodeIds.isEmpty == false else {
      return AsyncStream { continuation in
        continuation.yield([:])
        continuation.finish()
      }
    }
    let attemptStore = attemptStore
    let accountIDReading = accountIDReading
    let nativeSubscriptionsReading = nativeSubscriptionsReading
    return AsyncStream { continuation in
      let task = Task {
        guard await nativeSubscriptionsReading.isEnabled() else {
          continuation.yield([:])
          continuation.finish()
          return
        }
        let accountID: Int64
        do {
          accountID = try await accountIDReading.currentAccountID()
        } catch {
          continuation.yield([:])
          continuation.finish()
          return
        }
        for await attempts in attemptStore.observeLatestAttempts(
          accountId: accountID, feedId: feedId, episodeIds: episodeIds)
        {
          guard Task.isCancelled == false else { break }
          continuation.yield(attempts.mapValues(Self.snapshot(for:)))
        }
        continuation.finish()
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }

  /// Same gates as `observeStatuses`, resolved once at subscribe time for the same reason.
  public func observeServerItemStatuses(
    serverItemId: String
  ) -> AsyncStream<[String: NativeEpisodeServerSaveStatusSnapshot]> {
    let attemptStore = attemptStore
    let accountIDReading = accountIDReading
    let nativeSubscriptionsReading = nativeSubscriptionsReading
    return AsyncStream { continuation in
      let task = Task {
        guard await nativeSubscriptionsReading.isEnabled() else {
          continuation.yield([:])
          continuation.finish()
          return
        }
        let accountID: Int64
        do {
          accountID = try await accountIDReading.currentAccountID()
        } catch {
          continuation.yield([:])
          continuation.finish()
          return
        }
        for await attempts in attemptStore.observeLatestAttempts(
          accountId: accountID, serverItemId: serverItemId)
        {
          guard Task.isCancelled == false else { break }
          continuation.yield(attempts.mapValues(Self.snapshot(for:)))
        }
        continuation.finish()
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }

  private static let none = NativeEpisodeServerSaveStatusSnapshot(status: .none)

  private static func snapshot(
    for attempt: NativeEpisodeServerSaveAttemptRecord
  ) -> NativeEpisodeServerSaveStatusSnapshot {
    NativeEpisodeServerSaveStatusSnapshot(
      status: NativeEpisodeServerSaveStatus.status(
        for: attempt.state, category: attempt.errorCategory ?? .unknown),
      attemptID: attempt.id,
      preflightPresence: attempt.preflightPresence)
  }
}

public struct NoOpNativeEpisodeServerSaveStatusReading:
  NativeEpisodeServerSaveStatusReading, Sendable
{
  public init() {}

  public func status(feedId: Int64, episodeId: Int64) async -> NativeEpisodeServerSaveStatusSnapshot {
    NativeEpisodeServerSaveStatusSnapshot(status: .none)
  }

  public func statuses(
    feedId: Int64, episodeIds: [Int64]
  ) async -> [Int64: NativeEpisodeServerSaveStatusSnapshot] {
    [:]
  }
}
