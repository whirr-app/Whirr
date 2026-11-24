import Persistence
import PlayerCore
import SyncEngine

/// Payload-free reasons a car command was not performed. None carries a title, an account or a
/// server identity, so a template can map each to short fixed feedback.
public enum CarPlayPlaybackRejection: Sendable, Equatable {
  /// The row or this facade belongs to a graph that has since been replaced.
  case staleGeneration
  case accountUnavailable
  case invalidSelection
  case preparationFailed
  case cancelled
  case nothingToResume
  case noActivePlayback
  case invalidChapter
  case invalidRate
}

/// `.accepted` means the exact selection was prepared and handed to the player, as it does for
/// `CompanionPlaybackActionResult`; it does not claim that audio started.
public enum CarPlayPlaybackResult: Sendable, Equatable {
  case accepted
  case rejected(CarPlayPlaybackRejection)
}

/// The car's command boundary over the account-scoped playback graph.
///
/// A car scene outlives account graphs, and its rows are built ahead of the tap. So the facade
/// holds a lease on the runtime generation it was composed in, every command names its row's
/// generation, and both are checked against the current one before and after each suspension. A
/// generation is replaced at every account boundary, so the lease needs no account key.
///
/// Starting, resuming and rate changes use the facades the Watch and Siri already use, adding no
/// second path into `PlaybackModel`.
@MainActor
public final class CarPlayPlaybackActions {
  public let generation: Int
  private let currentGeneration: @MainActor () -> Int
  private let playback: PlaybackModel
  private let player: any PlaybackControlling
  private let account: any AccountLifecycle
  private let selections: CompanionPlaybackActions
  private let voice: VoicePlaybackActions

  public init(
    generation: Int,
    currentGeneration: @escaping @MainActor () -> Int,
    playback: PlaybackModel,
    player: any PlaybackControlling,
    account: any AccountLifecycle,
    bookmarkStore: any PlaybackBookmarkStoring
  ) {
    self.generation = generation
    self.currentGeneration = currentGeneration
    self.playback = playback
    self.player = player
    self.account = account
    selections = CompanionPlaybackActions(playback: playback, player: player, account: account)
    voice = VoicePlaybackActions(
      playback: playback, player: player, account: account, bookmarkStore: bookmarkStore)
  }

  /// Starts exactly the row's identity: an audiobook with no episode, a podcast with its episode,
  /// in whichever source namespace the identity names. Nothing else is ever substituted.
  public func play(
    identity: ListeningIdentity, chapter: ListeningQueueRowChapter? = nil, generation row: Int
  ) async -> CarPlayPlaybackResult {
    if let rejection = admission(row: row) { return .rejected(rejection) }
    guard let source = PodcastSourceIdentity(itemId: identity.itemID) else {
      return .rejected(.invalidSelection)
    }
    let result = await selections.start(source: source, episodeID: identity.episodeID, chapter: chapter)
    guard leaseHolds else { return .rejected(.staleGeneration) }
    switch result {
    case .accepted: return .accepted
    case .rejected(.accountUnavailable): return .rejected(.accountUnavailable)
    case .rejected(.invalidSelection): return .rejected(.invalidSelection)
    case .rejected(.cancelled): return .rejected(.cancelled)
    case .rejected(.preparationFailed), .rejected(.staleRequest), .rejected(.noActivePlayback),
      .rejected(.invalidPosition), .rejected(.invalidRate):
      // Only the first two can come from a start; neither means the row is wrong.
      return .rejected(.preparationFailed)
    }
  }

  /// The bookmark-aware resume Siri uses, which reads the bookmark itself on a cold start.
  public func resumeLastPlayed() async -> CarPlayPlaybackResult {
    if let rejection = admission(row: generation) { return .rejected(rejection) }
    let result = await voice.resumeLastPlayed()
    guard leaseHolds else { return .rejected(.staleGeneration) }
    switch result {
    case .performed: return .accepted
    case .unavailable(.accountUnavailable): return .rejected(.accountUnavailable)
    case .unavailable(.noBookmark): return .rejected(.nothingToResume)
    case .unavailable(.noActivePlayback): return .rejected(.noActivePlayback)
    case .unavailable(.startFailed), .unavailable(.itemUnavailable), .unavailable(.noChapters),
      .unavailable(.noSleepTimer):
      return .rejected(.preparationFailed)
    }
  }

  /// Seeks to a chapter of the loaded item, as the phone's chapter sheet does. The row names the
  /// item it was listed under, so a row left over from the previous title is refused.
  public func selectChapter(
    _ chapter: PlaybackChapter, itemID: String, episodeID: String?, generation row: Int
  ) -> CarPlayPlaybackResult {
    if let rejection = admission(row: row) { return .rejected(rejection) }
    guard let item = player.state.item, item.id == itemID, item.episodeID == episodeID,
      playback.isLoaded(itemID: itemID, episodeID: episodeID)
    else { return .rejected(.noActivePlayback) }
    guard item.chapters.chapters.contains(chapter) else { return .rejected(.invalidChapter) }
    player.send(.selectChapter(chapter))
    return .accepted
  }

  public func setRate(_ rate: Double, generation row: Int) -> CarPlayPlaybackResult {
    if let rejection = admission(row: row) { return .rejected(rejection) }
    switch selections.setRate(rate) {
    case .accepted: return .accepted
    case .rejected(.accountUnavailable): return .rejected(.accountUnavailable)
    case .rejected(.invalidRate): return .rejected(.invalidRate)
    default: return .rejected(.noActivePlayback)
    }
  }

  private var leaseHolds: Bool { generation == currentGeneration() }

  private func admission(row: Int) -> CarPlayPlaybackRejection? {
    guard row == generation, leaseHolds else { return .staleGeneration }
    guard account.isAuthenticated, playback.isQuiescedForLogout == false else {
      return .accountUnavailable
    }
    return nil
  }
}
