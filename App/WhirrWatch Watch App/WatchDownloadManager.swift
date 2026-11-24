import Foundation
import Observation
import PlayerCore
import WatchPlayback
import WatchProtocol

/// Creates an already-authenticated request for one manifest. The request is held by the
/// in-memory URLSession task only; neither the request nor any URL it contains is persisted.
public typealias WatchDownloadRequestProvider =
  @Sendable (WatchDownloadManifest) async throws -> URLRequest

public enum WatchDownloadManagerError: Error, Sendable, Equatable {
  case store(WatchDownloadStoreError)
  case requestProvider
  case unacceptableHTTPStatus(Int)
  case accountMismatch
  case inactive
}

/// Orchestrates durable downloads. The store is authoritative; the transport preserves temporary
/// files before delivering task- and epoch-fenced events for validation and commit.
@MainActor
@Observable
public final class WatchDownloadManager {
  public private(set) var downloads: [WatchDownloadManifest] = []
  public internal(set) var lastError: WatchDownloadManagerError?

  @ObservationIgnored var onDownloadsChange: (@MainActor ([WatchDownloadManifest]) -> Void)?

  public let accountStamp: WatchAccountStamp
  public let sessionIdentifier: String

  let store: WatchDownloadStore
  private let requestProvider: WatchDownloadRequestProvider
  let renewalProvider: WatchDownloadRequestProvider?
  private var startingIDs: [UUID: UUID] = [:]
  var renewedIDs: Set<UUID> = []
  /// Downloads already continued from resume data since their last fresh start; a second failure
  /// falls back to the normal failed state instead of looping.
  var resumeAttemptedIDs: Set<UUID> = []
  private let isWiFiAvailable: @Sendable () -> Bool
  let transport: WatchDownloadURLSessionAdapter
  var tasksByDownloadID: [UUID: URLSessionDownloadTask] = [:]
  var taskGenerations: [UUID: Int] = [:]
  var generation = 0
  var active = false
  var backgroundCompletionHandlers: [@Sendable () -> Void] = []
  var backgroundEventsFinished = false
  /// Completion callbacks can arrive while `start()` is still rebuilding the surviving task map;
  /// they wait here. The window opens and closes inside `start()` and never spans an unstarted manager.
  var recoveryPending = false
  private var publishedBytes: [UUID: Int64] = [:]
  var recoveryWaiters: [CheckedContinuation<Void, Never>] = []

  public init(
    store: WatchDownloadStore,
    accountStamp: WatchAccountStamp,
    requestProvider: @escaping WatchDownloadRequestProvider,
    renewalProvider: WatchDownloadRequestProvider? = nil,
    rootURL: URL,
    sessionIdentifier: String = "com.remoteconcern.whirr.watch-downloads",
    networkPolicy: WatchDownloadNetworkPolicy = .wifiOnly,
    isWiFiAvailable: @escaping @Sendable () -> Bool = { false }
  ) {
    self.store = store
    self.accountStamp = accountStamp
    self.requestProvider = requestProvider
    self.renewalProvider = renewalProvider
    self.sessionIdentifier = sessionIdentifier
    self.isWiFiAvailable = isWiFiAvailable
    self.transport = WatchDownloadURLSessionAdapter(
      rootURL: rootURL,
      accountIdentity: "\(accountStamp.accountIdentityHash)-\(accountStamp.serverIdentityHash)",
      identifier: sessionIdentifier, networkPolicy: networkPolicy)
    transport.events = self
  }

  isolated deinit {
    transport.invalidateAndCancel()
  }

  nonisolated public static func callbackMatches(
    taskIdentifier: Int,
    generation: Int,
    currentTaskIdentifier: Int?,
    currentGeneration: Int
  ) -> Bool {
    taskIdentifier == currentTaskIdentifier && generation == currentGeneration
  }

  /// Starts the session, reattaches surviving system tasks, fences orphaned tasks, and schedules
  /// queued manifests. A newly created manager is inactive until this method is called.
  public func start() async {
    guard active == false else { return }
    active = true
    backgroundEventsFinished = false
    generation &+= 1
    let currentGeneration = generation
    recoveryPending = true
    transport.sweepUnclaimedIncoming()
    await transport.recoverTasks(generation: currentGeneration)
    finishRecovery()
    guard isCurrent(currentGeneration) else { return }
    await scheduleQueuedDownloads(generation: currentGeneration)
    await refresh()
  }

  /// Cancels all live tasks and fences every callback from this account generation. The durable
  /// manifest remains on disk for explicit recovery by a new manager, but no old task can relabel
  /// or republish data after sign-out.
  public func stop() async {
    generation &+= 1
    active = false
    for task in tasksByDownloadID.values { task.cancel() }
    tasksByDownloadID.removeAll()
    taskGenerations.removeAll()
    transport.invalidateAndCancel()
    downloads = []
    onDownloadsChange?(downloads)
    startingIDs.removeAll()
    renewedIDs.removeAll()
    resumeAttemptedIDs.removeAll()
    publishedBytes.removeAll()
    backgroundEventsFinished = true
    finishRecovery()
    completeBackgroundEventsIfReady()
  }

  public func refresh() async {
    guard active else { return }
    let token = generation
    let manifests = await store.allManifests()
    guard isCurrent(token) else { return }
    downloads = manifests
    onDownloadsChange?(downloads)
  }

  @discardableResult
  public func enqueue(
    selection: WatchSelection,
    downloadGroupID: String = "",
    expectedTrackCount: Int = 1,
    fileID: String,
    fileIndex: Int = 0,
    startOffset: Double = 0,
    duration: Double? = nil,
    expectedBytes: Int64? = nil,
    expectedMIMEType: String,
    id: UUID = UUID(),
    chapters: [PlayerCore.PlaybackChapter] = [],
    origin: WatchABSOrigin = .watch,
    phoneRevision: UInt64? = nil
  ) async -> UUID? {
    guard active else {
      lastError = .inactive
      return nil
    }
    do {
      _ = try await store.enqueue(
        selection: selection, downloadGroupID: downloadGroupID,
        expectedTrackCount: expectedTrackCount, fileID: fileID, fileIndex: fileIndex,
        startOffset: startOffset, duration: duration, expectedBytes: expectedBytes,
        expectedMIMEType: expectedMIMEType, id: id, chapters: chapters, origin: origin,
        phoneRevision: phoneRevision)
      await refresh()
      await startDownload(id: id)
      return id
    } catch {
      lastError = .store(Self.storeError(from: error))
      await refresh()
      return nil
    }
  }

  /// `userInitiated` marks a start the person asked for by tapping, which bypasses the Wi-Fi
  /// admission signal. That signal is a guess about a path watchOS does not describe honestly, and
  /// a retry gated on the guess that produced the hold can only reproduce it.
  public func startDownload(id: UUID, userInitiated: Bool = false) async {
    await startDownload(id: id, renewAuthorization: false, userInitiated: userInitiated)
  }

  func startDownload(id: UUID, renewAuthorization: Bool, userInitiated: Bool = false) async {
    guard active else {
      lastError = .inactive
      return
    }
    let currentGeneration = generation
    guard tasksByDownloadID[id] == nil, startingIDs[id] == nil else { return }
    resumeAttemptedIDs.remove(id)
    let operation = UUID()
    startingIDs[id] = operation
    defer { if startingIDs[id] == operation { startingIDs.removeValue(forKey: id) } }
    do {
      guard let initial = await store.manifest(id: id), initial.accountStamp == accountStamp else {
        throw WatchDownloadManagerError.accountMismatch
      }
      let manifest: WatchDownloadManifest
      if initial.state == .queued {
        manifest = try await store.beginTransfer(
          id: id, isWiFiAvailable: userInitiated || isWiFiAvailable())
        if manifest.state == .queued {
          await refresh()
          return
        }
      } else if initial.state == .downloading {
        manifest = initial
      } else {
        return
      }

      let provider = renewAuthorization ? (renewalProvider ?? requestProvider) : requestProvider
      var request = try await provider(manifest)
      request.allowsCellularAccess = await store.networkPolicy == .anyNetwork
      guard isCurrent(currentGeneration), startingIDs[id] == operation,
        (await store.manifest(id: id))?.state == .downloading
      else { return }
      let task = transport.downloadTask(with: request)
      task.taskDescription = WatchDownloadURLSessionAdapter.taskDescription(for: id, generation: currentGeneration)
      if let expectedBytes = manifest.expectedBytes, expectedBytes > 0 {
        task.countOfBytesClientExpectsToReceive = expectedBytes
      }
      do {
        _ = try await store.attachTransfer(taskIdentifier: String(task.taskIdentifier), to: id)
      } catch {
        task.cancel()
        throw error
      }
      guard isCurrent(currentGeneration), startingIDs[id] == operation else {
        task.cancel()
        return
      }
      tasksByDownloadID[id] = task
      taskGenerations[id] = currentGeneration
      task.resume()
      WatchDiagnostics.record(.downloadTransferStarted)
      await refresh()
    } catch let error as WatchDownloadManagerError {
      lastError = error
      await refresh()
    } catch let error as WatchDownloadStoreError {
      lastError = .store(error)
      await refresh()
    } catch {
      if isCurrent(currentGeneration) {
        if (await store.manifest(id: id))?.state == .downloading {
          await fail(id, .transport)
        }
        lastError = .requestProvider
        await refresh()
      }
    }
  }

  public func pause(id: UUID) async {
    startingIDs.removeValue(forKey: id)
    tasksByDownloadID[id]?.suspend()
    do {
      _ = try await store.pause(id: id)
      await refresh()
    } catch { lastError = .store(Self.storeError(from: error)) }
  }

  public func resume(id: UUID) async {
    renewedIDs.remove(id)
    startingIDs.removeValue(forKey: id)
    do {
      tasksByDownloadID[id]?.cancel()
      tasksByDownloadID.removeValue(forKey: id)
      taskGenerations.removeValue(forKey: id)
      _ = try await store.resume(id: id)
      await refresh()
      await startDownload(id: id, userInitiated: true)
    } catch { lastError = .store(Self.storeError(from: error)) }
  }

  public func retry(id: UUID) async {
    renewedIDs.remove(id)
    do {
      _ = try await store.retry(id: id)
      await refresh()
      await startDownload(id: id, userInitiated: true)
    } catch { lastError = .store(Self.storeError(from: error)) }
  }

  public func delete(id: UUID) async {
    tearDown(id: id)
    do {
      try await store.delete(id: id)
      await refresh()
    } catch { lastError = .store(Self.storeError(from: error)) }
  }

  /// Cancels an active transfer while retaining its durable row for an explicit retry or delete.
  public func cancel(id: UUID) async {
    tearDown(id: id)
    do {
      if let manifest = await store.manifest(id: id), manifest.state != .completed {
        _ = try await store.fail(id: id, reason: .cancelled)
      }
      await refresh()
    } catch { lastError = .store(Self.storeError(from: error)) }
  }

  /// Drops every in-memory trace of `id`'s transfer before the store settles its durable row.
  private func tearDown(id: UUID) {
    renewedIDs.remove(id)
    startingIDs.removeValue(forKey: id)
    tasksByDownloadID[id]?.cancel()
    tasksByDownloadID.removeValue(forKey: id)
    taskGenerations.removeValue(forKey: id)
  }

  public func redownload(id: UUID) async {
    renewedIDs.remove(id)
    startingIDs.removeValue(forKey: id)
    do {
      if let manifest = await store.manifest(id: id), manifest.state == .completed {
        try await store.delete(id: id)
        _ = try await store.enqueue(
          selection: manifest.selection, downloadGroupID: manifest.downloadGroupID,
          expectedTrackCount: manifest.expectedTrackCount, fileID: manifest.fileID,
          fileIndex: manifest.fileIndex,
          startOffset: manifest.startOffset, duration: manifest.duration,
          expectedBytes: manifest.expectedBytes, expectedMIMEType: manifest.expectedMIMEType, id: id,
          chapters: manifest.chapters)
      } else {
        _ = try await store.retry(id: id)
      }
      tasksByDownloadID.removeValue(forKey: id)
      taskGenerations.removeValue(forKey: id)
      await refresh()
      await startDownload(id: id, userInitiated: true)
    } catch { lastError = .store(Self.storeError(from: error)) }
  }

  /// Called by WatchBackgroundDelegate when the system wakes the app for this session.
  public func handleBackgroundEvents(completionHandler: @escaping @Sendable () -> Void) {
    backgroundCompletionHandlers.append(completionHandler)
    completeBackgroundEventsIfReady()
  }

  private func scheduleQueuedDownloads(generation: Int) async {
    guard isCurrent(generation) else { return }
    let manifests = await store.allManifests()
    for manifest in manifests where manifest.state == .queued {
      guard isCurrent(generation) else { return }
      await startDownload(id: manifest.id)
    }
  }

  func isCurrent(_ generation: Int) -> Bool {
    active && generation == self.generation
  }

  func callbackMatches(_ token: WatchDownloadCallbackToken) -> Bool {
    guard active, token.generation == generation,
      let task = tasksByDownloadID[token.id],
      let taskGeneration = taskGenerations[token.id]
    else { return false }
    return Self.callbackMatches(
      taskIdentifier: token.taskIdentifier, generation: token.generation,
      currentTaskIdentifier: task.taskIdentifier, currentGeneration: taskGeneration)
  }

  /// Progress arrives many times a second; the list is republished only after a coarse step.
  /// State changes go through `refresh()`.
  func publishProgress(_ manifest: WatchDownloadManifest) {
    guard active, let index = downloads.firstIndex(where: { $0.id == manifest.id }) else { return }
    let published = publishedBytes[manifest.id] ?? downloads[index].receivedBytes
    let step = manifest.progressStep
    guard manifest.receivedBytes < published || manifest.receivedBytes - published >= step else { return }
    publishedBytes[manifest.id] = manifest.receivedBytes
    downloads[index] = manifest
    onDownloadsChange?(downloads)
  }

}
