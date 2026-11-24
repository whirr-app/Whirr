import ABSApi
import Foundation
import PlayerCore
import WatchProtocol

@MainActor
public protocol WatchSessionAudio: AnyObject, Sendable {
  var position: Double { get }
  var isPlaying: Bool { get }
  func load(_ preparation: WatchAudioPreparation, position: Double) async throws
  func play() async throws
  func pause()
  func seek(to position: Double) async throws
  func setRate(_ rate: Double)
  func stop()
}

public enum WatchPlaybackCoordinatorError: Error, Sendable, Equatable {
  case cancelled
  case invalidSelection
  case mismatchedSession
}

/// Prepares and drives the Watch's local playback: downloaded files, or direct-file streams with
/// no server playback session. Progress is written by `WatchLocalProgressLifecycle` and
/// uploaded as local sessions; the Watch never opens an ABS `/play` session.
public actor WatchPlaybackSessionCoordinator {
  private let account: WatchAccountRecord
  private let service: any WatchCatalogueService & WatchPlaybackService & WatchDownloadService
  private let audio: any WatchSessionAudio
  private var generation = 0

  private var preparationFactory: WatchAudioPreparationFactory {
    WatchAudioPreparationFactory(service: service, serverURL: account.serverURL)
  }

  public init(
    account: WatchAccountRecord,
    service: any WatchCatalogueService & WatchPlaybackService & WatchDownloadService,
    audio: any WatchSessionAudio
  ) {
    self.account = account
    self.service = service
    self.audio = audio
  }

  /// Prepares an Audiobookshelf item for streaming without a server playback session. Every file is
  /// still selected from expanded detail and authorized by the typed download boundary; the
  /// direct-file URLs are capability values for the audio layer, never persisted here.
  public func prepareIndependent(
    selection: WatchSelection, position: Double = 0, rate: Double = 1.0
  ) async throws -> WatchAudioPreparation {
    try await prepareIndependent(selection: selection, position: position, rate: rate, renewAuthorization: false)
  }

  /// Rebuilds a stream preparation with fresh authorization. The caller owns the 401 decision and
  /// how many renewals in a row it allows.
  public func renewIndependent(
    selection: WatchSelection, position: Double = 0, rate: Double = 1.0
  ) async throws -> WatchAudioPreparation {
    try await prepareIndependent(selection: selection, position: position, rate: rate, renewAuthorization: true)
  }

  /// Loads downloaded files.
  public func prepareOffline(_ preparation: WatchAudioPreparation, position: Double = 0, rate: Double = 1.0)
    async throws
  {
    try Task.checkCancellation()
    try validate(rate: rate)
    generation &+= 1
    let token = generation
    try await audio.load(preparation, position: max(0, position))
    try check(token)
    await audio.setRate(rate)
  }

  public func play() async throws {
    try Task.checkCancellation()
    let token = generation
    try await audio.play()
    try check(token)
  }

  public func pause() async throws {
    try Task.checkCancellation()
    await audio.pause()
  }

  public func seek(to position: Double) async throws {
    try Task.checkCancellation()
    guard position.isFinite else { throw WatchPlaybackCoordinatorError.invalidSelection }
    let token = generation
    try await audio.seek(to: max(0, position))
    try check(token)
  }

  public func setRate(_ rate: Double) async throws {
    try Task.checkCancellation()
    try validate(rate: rate)
    await audio.setRate(rate)
  }

  /// Supersedes any preparation in flight and unloads the audio.
  public func cancel() async {
    generation &+= 1
    await audio.stop()
  }

  private func prepareIndependent(
    selection: WatchSelection, position: Double, rate: Double, renewAuthorization: Bool
  ) async throws -> WatchAudioPreparation {
    guard case .audiobookshelf(let itemID, _) = selection else {
      throw WatchLibraryError.nativeSelectionUnavailable
    }
    guard position.isFinite, position >= 0 else { throw WatchLibraryError.invalidPage }
    try validate(rate: rate)
    let tokenAccount = try account.tokenAccount()
    try Task.checkCancellation()
    generation &+= 1
    let token = generation
    let detail = try await service.detail(account: tokenAccount, itemID: itemID)
    try check(token)
    let descriptors = try WatchDownloadPlanner.plan(for: detail)
    guard detail.id == itemID else { throw WatchPlaybackCoordinatorError.mismatchedSession }
    let selected = descriptors.filter { $0.selection == selection }
    guard !selected.isEmpty else { throw WatchLibraryError.libraryUnavailable }
    let preparation = try await preparationFactory.makeIndependentPreparation(
      descriptors: selected, account: tokenAccount, renewAuthorization: renewAuthorization)
    try check(token)
    try await audio.load(preparation, position: position)
    try check(token)
    await audio.setRate(rate)
    return preparation
  }

  private func validate(rate: Double) throws {
    guard rate.isFinite, (0.25...4).contains(rate) else { throw WatchPlaybackCoordinatorError.invalidSelection }
  }

  private func check(_ expected: Int) throws {
    guard expected == generation, !Task.isCancelled else { throw WatchPlaybackCoordinatorError.cancelled }
  }
}
