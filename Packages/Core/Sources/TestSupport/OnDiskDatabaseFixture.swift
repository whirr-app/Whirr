import Foundation
import GRDB
import Persistence

/// Admission control for on-disk `AppDatabase` fixtures, shared by every test target.
///
/// A GRDB `DatabasePool` holds a writer queue plus reader queues, and `AppDatabase`'s synchronous
/// entry points bottom out in `dispatch_sync`. With enough live pools the Swift cooperative pool
/// has no runnable thread left to release one, so the run parks instead of failing. `.serialized`
/// does not help: it orders cases within one suite, while the starved resource is process-wide.
///
/// Every on-disk fixture passes through this cap. The gate admits whole scopes, not individual
/// databases: a crash-recovery case holds two pools and a per-database permit would block on
/// itself.
///
/// Permit bookkeeping is lock-based so `release` is synchronous: suites that open their database
/// in `init` have only `deinit` for teardown, which cannot `await`, and a permit returned by a
/// detached task would come back late.
public final class OnDiskDatabaseGate: @unchecked Sendable {

  public static let shared = OnDiskDatabaseGate()

  /// Concurrently admitted scopes. Read from `WHIRR_TEST_ONDISK_SCOPE_LIMIT` when present so the
  /// cap sweep in `docs/TESTING.md` can vary it without a rebuild.
  public static var configuredLimit: Int {
    if let raw = ProcessInfo.processInfo.environment["WHIRR_TEST_ONDISK_SCOPE_LIMIT"],
      let parsed = Int(raw), parsed > 0
    {
      return parsed
    }
    return defaultLimit
  }

  /// Chosen by measurement. See "On-disk database cap" in `docs/TESTING.md`.
  public static let defaultLimit = 4

  private struct State {
    var outstandingPermits = 0
    var waiting: [(ticket: UUID, continuation: CheckedContinuation<Void, Never>)] = []
    /// Tickets that have decided to wait but may not have parked yet.
    var pending: Set<UUID> = []
    /// Tickets cancelled between installing the cancellation handler and registering the
    /// continuation. Without this the cancellation lands on nothing and the waiter parks forever.
    var cancelledBeforeParking: Set<UUID> = []
  }

  public let permitLimit: Int
  private let state = Locked(State())

  public init(limit: Int = OnDiskDatabaseGate.configuredLimit) {
    permitLimit = limit
  }

  /// Scopes currently holding a permit.
  public var liveScopes: Int { state.value.outstandingPermits }

  /// Scopes parked waiting for a permit.
  public var waitingScopes: Int { state.value.waiting.count }

  public func acquire() async {
    let admitted = state.withValue { current -> Bool in
      guard current.outstandingPermits < permitLimit else { return false }
      current.outstandingPermits += 1
      return true
    }
    if admitted { return }

    let ticket = UUID()
    state.withValue { $0.pending.insert(ticket) }

    await withTaskCancellationHandler {
      await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        let resumeImmediately = state.withValue { current -> Bool in
          let wasCancelled = current.cancelledBeforeParking.remove(ticket) != nil
          if wasCancelled || current.outstandingPermits < permitLimit {
            current.pending.remove(ticket)
            current.outstandingPermits += 1
            return true
          }
          current.waiting.append((ticket, continuation))
          return false
        }
        if resumeImmediately { continuation.resume() }
      }
    } onCancel: {
      admitCancelledWaiter(ticket)
    }
  }

  public func release() {
    let next = state.withValue { current -> CheckedContinuation<Void, Never>? in
      guard current.waiting.isEmpty == false else {
        current.outstandingPermits -= 1
        return nil
      }
      // The permit transfers directly, so `outstandingPermits` is unchanged.
      let waiter = current.waiting.removeFirst()
      current.pending.remove(waiter.ticket)
      return waiter.continuation
    }
    next?.resume()
  }

  /// A cancelled waiter is admitted, not left parked: its scope still runs teardown and calls
  /// `release`, so a permit keeps acquire and release symmetric. This can transiently put the
  /// process one scope over the cap, only on a test already being torn down.
  ///
  /// A cancellation arriving before the continuation is registered is recorded and applied at
  /// registration; dropping it would park the waiter forever.
  private func admitCancelledWaiter(_ ticket: UUID) {
    let orphan = state.withValue { current -> CheckedContinuation<Void, Never>? in
      guard current.pending.contains(ticket) else { return nil }
      guard let index = current.waiting.firstIndex(where: { $0.ticket == ticket }) else {
        current.cancelledBeforeParking.insert(ticket)
        return nil
      }
      current.pending.remove(ticket)
      current.outstandingPermits += 1
      return current.waiting.remove(at: index).continuation
    }
    orphan?.resume()
  }
}

/// Live and peak on-disk pool counts. Synchronous, because fixtures open and close databases from
/// non-async code. Suites use `shared`; the fixture's own tests need a private census.
public final class OnDiskDatabaseCensus: @unchecked Sendable {

  public static let shared = OnDiskDatabaseCensus()

  public init() {}

  public struct Snapshot: Sendable, Equatable {
    public var liveDatabases: Int
    public var peakLiveDatabases: Int
    public var liveScopes: Int
    public var peakLiveScopes: Int
    public var openedDatabases: Int
  }

  private let state = Locked(
    Snapshot(
      liveDatabases: 0, peakLiveDatabases: 0, liveScopes: 0, peakLiveScopes: 0, openedDatabases: 0))

  public var snapshot: Snapshot { state.value }

  /// Clears the peaks (not the live counts) so one suite can measure its own high-water mark.
  public func resetPeaks() {
    state.withValue { current in
      current.peakLiveDatabases = current.liveDatabases
      current.peakLiveScopes = current.liveScopes
      current.openedDatabases = 0
    }
  }

  func noteDatabaseOpened() {
    state.withValue { current in
      current.liveDatabases += 1
      current.openedDatabases += 1
      current.peakLiveDatabases = max(current.peakLiveDatabases, current.liveDatabases)
    }
  }

  func noteDatabaseClosed() {
    state.withValue { $0.liveDatabases -= 1 }
  }

  func noteScopeEntered() {
    state.withValue { current in
      current.liveScopes += 1
      current.peakLiveScopes = max(current.peakLiveScopes, current.liveScopes)
    }
  }

  func noteScopeExited() {
    state.withValue { $0.liveScopes -= 1 }
  }
}

/// File attributes that do nothing, for fixtures whose scratch directory has no protection class to
/// apply.
public struct InertFileAttributes: FileAttributeApplying {
  public init() {}
  public func protectDirectory(at directoryURL: URL) throws {}
  public func protectDatabaseArtifacts(at databaseURL: URL) throws {}
  public func protectDownloadsRoot(at directoryURL: URL) throws {}
  public func protectDownloadedFile(at fileURL: URL) throws {}
}

/// Owns one test case's scratch directory and every on-disk database opened inside it.
///
/// Not `Sendable`: it lives for one `withOnDiskDatabases` body on that body's isolation; handing
/// it to another task would defeat the accounting.
public final class OnDiskDatabaseScope {

  /// The scratch directory. Removed, with everything in it, when the scope ends.
  public let directoryURL: URL

  private var liveDatabases: [ObjectIdentifier: AppDatabase] = [:]
  private let census: OnDiskDatabaseCensus

  /// Databases this scope has opened and not yet closed. Scope-local, so a test can assert on it
  /// without reading a counter every other suite in the process is also writing to.
  public var openDatabaseCount: Int { liveDatabases.count }

  init(name: String, census: OnDiskDatabaseCensus) throws {
    self.census = census
    let sanitized = name.replacingOccurrences(of: "/", with: "-")
      .replacingOccurrences(of: " ", with: "-")
      .prefix(60)
    directoryURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("whirr-ondisk-\(sanitized)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
  }

  /// A path inside the scope's directory. The file need not exist yet.
  public func url(_ filename: String = "app.sqlite") -> URL {
    directoryURL.appendingPathComponent(filename)
  }

  /// Opens an on-disk database inside the scope's directory and registers it for close.
  @discardableResult
  public func open(
    _ filename: String = "app.sqlite",
    fileAttributes: any FileAttributeApplying = InertFileAttributes(),
    seeding: OnDiskDatabaseSeeding = .fromTemplate
  ) throws -> AppDatabase {
    try open(at: url(filename), fileAttributes: fileAttributes, seeding: seeding)
  }

  /// Opens an on-disk database at an explicit URL (a crash-recovery case reopens the same file
  /// after the simulated relaunch) and registers it for close. A path with no file yet is seeded
  /// per `seeding`; an existing file is reopened as it is.
  @discardableResult
  public func open(
    at url: URL,
    fileAttributes: any FileAttributeApplying = InertFileAttributes(),
    seeding: OnDiskDatabaseSeeding = .fromTemplate
  ) throws -> AppDatabase {
    if seeding == .fromTemplate {
      try OnDiskDatabaseTemplate.seedIfAbsent(at: url)
    }
    let database = try AppDatabase.onDisk(at: url, fileAttributes: fileAttributes)
    liveDatabases[ObjectIdentifier(database)] = database
    census.noteDatabaseOpened()
    return database
  }

  /// Closes one database early. A crash-recovery case uses this as the moment the process dies:
  /// the writer must be gone before the same file is reopened, and leaving it to ARC keeps pools
  /// alive far longer.
  public func close(_ database: AppDatabase) {
    guard liveDatabases.removeValue(forKey: ObjectIdentifier(database)) != nil else { return }
    try? database.dbWriter.close()
    census.noteDatabaseClosed()
  }

  func closeAll() {
    for database in liveDatabases.values {
      try? database.dbWriter.close()
      census.noteDatabaseClosed()
    }
    liveDatabases.removeAll()
  }

  func removeDirectory() {
    try? FileManager.default.removeItem(at: directoryURL)
  }
}

/// Runs `body` holding one slot in the process-wide on-disk database gate, with a scratch directory
/// and automatic close of every database the body opened.
///
/// Callers get the cap for free, which is why every on-disk fixture goes through this one entry.
public func withOnDiskDatabases<T>(
  named name: String = #function,
  gate: OnDiskDatabaseGate = .shared,
  census: OnDiskDatabaseCensus = .shared,
  isolation: isolated (any Actor)? = #isolation,
  _ body: (OnDiskDatabaseScope) async throws -> T
) async throws -> T {
  await gate.acquire()
  census.noteScopeEntered()
  let scope: OnDiskDatabaseScope
  do {
    scope = try OnDiskDatabaseScope(name: name, census: census)
  } catch {
    census.noteScopeExited()
    gate.release()
    throw error
  }
  do {
    let value = try await body(scope)
    scope.closeAll()
    scope.removeDirectory()
    census.noteScopeExited()
    gate.release()
    return value
  } catch {
    scope.closeAll()
    scope.removeDirectory()
    census.noteScopeExited()
    gate.release()
    throw error
  }
}

/// The non-scoped form of `withOnDiskDatabases`, for suites that open their database in `init`.
/// Swift Testing gives them only `deinit` for teardown, which cannot `await`, so the gate's
/// `release` is synchronous.
///
/// Prefer `withOnDiskDatabases` where the lifetime fits in one function. This form needs the suite
/// instance released promptly: anything capturing `self` past the test delays the permit and the
/// writer close.
public final class SuiteOnDiskDatabases {

  public let scope: OnDiskDatabaseScope
  private let gate: OnDiskDatabaseGate
  private let census: OnDiskDatabaseCensus

  public static func acquire(
    named name: String = #function,
    gate: OnDiskDatabaseGate = .shared,
    census: OnDiskDatabaseCensus = .shared
  ) async throws -> SuiteOnDiskDatabases {
    await gate.acquire()
    census.noteScopeEntered()
    do {
      let scope = try OnDiskDatabaseScope(name: name, census: census)
      return SuiteOnDiskDatabases(scope: scope, gate: gate, census: census)
    } catch {
      census.noteScopeExited()
      gate.release()
      throw error
    }
  }

  private init(scope: OnDiskDatabaseScope, gate: OnDiskDatabaseGate, census: OnDiskDatabaseCensus) {
    self.scope = scope
    self.gate = gate
    self.census = census
  }

  deinit {
    scope.closeAll()
    scope.removeDirectory()
    census.noteScopeExited()
    gate.release()
  }
}
