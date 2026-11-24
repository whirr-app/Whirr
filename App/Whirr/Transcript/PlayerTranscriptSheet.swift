import AppModel
import DesignSystem
import Persistence
import PlayerCore
import SwiftUI
import TipKit

/// A page's transcript state: which downloaded episode the page is showing, if it has a transcript
/// to offer, and the sheet's model for it. One object so the page holds one property for all of
/// it, as `PlayerBookmarkController` does for bookmarks. The expanded player and the episode card
/// each hold one.
@MainActor
@Observable
final class PlayerTranscriptController {
  /// What choosing Transcript in the menu does.
  enum ShowAction: Equatable {
    case present
    case transcribeAndPresent
    /// Ask before starting, because the iPhone is on battery.
    case confirm
  }

  /// The eligible downloaded episode behind the page; nil hides the overflow entry.
  private(set) var identity: AdSkipEpisodeIdentity?
  private(set) var model: EpisodeTranscriptModel?
  var isPresented = false
  var isConfirmingOnBattery = false
  /// A list menu chose an episode this app cannot transcribe.
  var isUnavailablePresented = false

  /// The episode a list menu chose, until its tracking says what it is.
  private var pending: (itemID: String, episodeID: String)?
  private var pendingShow: Task<Void, Never>?

  private let defaults: UserDefaults
  private let isOnExternalPower: @MainActor () -> Bool

  init(
    defaults: UserDefaults = .standard,
    isOnExternalPower: @escaping @MainActor () -> Bool = TranscriptBatteryConfirmation.isOnExternalPower
  ) {
    self.defaults = defaults
    self.isOnExternalPower = isOnExternalPower
  }

  /// Raises the sheet, starting a transcript first when there is none; nil while there is no
  /// transcript to offer.
  var onShow: (() -> Void)? {
    identity == nil ? nil : { [weak self] in self?.show() }
  }

  /// A transcript that exists or is under way opens as it is. With none, choosing Transcript is the
  /// request to make one, so the sheet opens already working; on battery it asks first.
  static func showAction(
    for state: EpisodeTranscriptModel.State, skipsConfirmation: Bool, isOnExternalPower: Bool
  ) -> ShowAction {
    switch state {
    case .offer, .failed:
      skipsConfirmation || isOnExternalPower ? .transcribeAndPresent : .confirm
    case .loading, .unavailable, .needsAsset, .held, .generating, .ready:
      .present
    }
  }

  func show() {
    guard let model else { return }
    TranscriptTip().invalidate(reason: .actionPerformed)
    let skips = defaults.bool(forKey: TranscriptBatteryConfirmation.skipKey)
    switch Self.showAction(
      for: model.state, skipsConfirmation: skips, isOnExternalPower: skips ? false : isOnExternalPower())
    {
    case .present: isPresented = true
    case .transcribeAndPresent: startTranscription(stopAsking: false)
    case .confirm: isConfirmingOnBattery = true
    }
  }

  /// Choosing Transcript from a list, where nothing tracked the episode beforehand: decides as
  /// `show()` does once tracking has the episode and its status, or says it cannot be transcribed.
  func open(itemID: String, episodeID: String) {
    if let identity, identity.itemID == itemID, identity.episodeID == episodeID {
      show()
      return
    }
    pendingShow?.cancel()
    pending = (itemID, episodeID)
  }

  private func resolvePending(_ identity: AdSkipEpisodeIdentity?) {
    guard let pending else { return }
    guard let identity else {
      self.pending = nil
      isUnavailablePresented = true
      return
    }
    guard identity.itemID == pending.itemID, identity.episodeID == pending.episodeID,
      let model
    else { return }
    self.pending = nil
    // A new model starts `.loading`, which would open the sheet without starting a transcript.
    pendingShow = Task { [weak self] in
      for await state in Observations({ model.state }) where state != .loading {
        guard let self, self.model === model else { return }
        self.show()
        return
      }
    }
  }

  func startTranscription(stopAsking: Bool) {
    if stopAsking { defaults.set(true, forKey: TranscriptBatteryConfirmation.skipKey) }
    model?.transcribe()
    isPresented = true
  }

  /// Follows the page's episode until cancelled, keeping its model current so the menu knows
  /// whether a transcript exists. A book, or no coordinator, offers nothing.
  func track(
    itemID: String, episodeID: String?, coordinator: EpisodeTranscriptCoordinator?,
    adSkip: AdSkipCoordinator?, playback: PlaybackModel
  ) async {
    guard let episodeID, let coordinator else {
      clear()
      return
    }
    await track(
      identities: await coordinator.identityChanges(itemID: itemID, episodeID: episodeID),
      makeModel: { identity in
        EpisodeTranscriptModel(
          source: .coordinator(coordinator, identity: identity, adSkip: adSkip, playback: playback),
          seek: { [weak playback] time in
            // Starts the episode first if the page is showing it before it has loaded.
            Task {
              await playback?.startOrSeek(itemID: itemID, toGlobalOffset: time, episodeID: episodeID)
            }
          })
      })
  }

  func track(
    identities: AsyncStream<AdSkipEpisodeIdentity?>,
    makeModel: (AdSkipEpisodeIdentity) -> EpisodeTranscriptModel
  ) async {
    // Every call runs a model of its own: a restarted `.task` finds the previous call's model
    // still held, but that call's run ended with it, so comparing against `self.identity` alone
    // would keep a model that no longer hears status changes.
    await withTaskGroup(of: Void.self) { group in
      var tracked: AdSkipEpisodeIdentity??
      for await identity in identities {
        guard identity != tracked else { continue }
        tracked = identity
        group.cancelAll()
        guard let identity else {
          clear()
          resolvePending(nil)
          continue
        }
        let model = (identity == self.identity ? self.model : nil) ?? makeModel(identity)
        self.identity = identity
        self.model = model
        group.addTask { await model.run() }
        resolvePending(identity)
      }
      group.cancelAll()
    }
  }

  private func clear() {
    pendingShow?.cancel()
    identity = nil
    model = nil
    isPresented = false
    isConfirmingOnBattery = false
  }
}

extension View {
  /// The transcript sheet over the expanded player or the episode card, and the tracking that
  /// decides whether its menu offers it. `accent` is the page's play-button pair, so the sheet's actions wear
  /// the show's colour with ink that stays legible on it. `chapters` is read inside the sheet, so
  /// the page does not observe the player for it. Kept out of `ExpandedPlayerView`, which is at the size where the
  /// working agreement asks for a split rather than more code.
  func playerTranscriptSheet(
    _ controller: PlayerTranscriptController, coordinator: EpisodeTranscriptCoordinator?,
    playback: PlaybackModel,
    itemID: String, episodeID: String?, accent: TranscriptAccent,
    chapters: @escaping () -> [PlaybackChapter]
  ) -> some View {
    modifier(
      PlayerTranscriptSheetModifier(
        controller: controller, coordinator: coordinator, adSkip: AdSkipComposition.coordinator,
        playback: playback,
        itemID: itemID, episodeID: episodeID, accent: accent, chapters: chapters))
  }
}

private struct PlayerTranscriptSheetModifier: ViewModifier {
  @Bindable var controller: PlayerTranscriptController
  let coordinator: EpisodeTranscriptCoordinator?
  let adSkip: AdSkipCoordinator?
  let playback: PlaybackModel
  let itemID: String
  let episodeID: String?
  let accent: TranscriptAccent
  let chapters: () -> [PlaybackChapter]

  private struct TrackingID: Hashable {
    let itemID: String
    let episodeID: String?
  }

  func body(content: Content) -> some View {
    content
      .task(id: TrackingID(itemID: itemID, episodeID: episodeID)) {
        await controller.track(
          itemID: itemID, episodeID: episodeID, coordinator: coordinator, adSkip: adSkip,
          playback: playback)
      }
      // Raised over the page like Chapters and History, so audio keeps playing beneath it.
      .sheet(isPresented: $controller.isPresented) {
        if let model = controller.model {
          EpisodeTranscriptSheet(
            model: model, playback: playback, itemID: itemID, episodeID: episodeID, accent: accent,
            chapters: chapters
          )
          // Scroll-first: read by scrolling for minutes, and under `.automatic` a downward scroll
          // kept collapsing it to `.medium`. Resizing is left to the grabber and the bar.
          .themedSheet(
            accent: accent.fill, role: .form, detents: [.medium, .large],
            contentInteraction: .scrolls)
        }
      }
      .alert(TranscriptBatteryConfirmation.title, isPresented: $controller.isConfirmingOnBattery) {
        Button(TranscriptBatteryConfirmation.transcribe) {
          controller.startTranscription(stopAsking: false)
        }
        Button(TranscriptBatteryConfirmation.transcribeAndStopAsking) {
          controller.startTranscription(stopAsking: true)
        }
        Button("Cancel", role: .cancel) {}
      } message: {
        Text(TranscriptBatteryConfirmation.message)
      }
      .alert(TranscriptUnavailableCopy.title, isPresented: $controller.isUnavailablePresented) {
        Button("OK", role: .cancel) {}
      } message: {
        Text(TranscriptUnavailableCopy.message)
      }
  }
}

/// Said when a list menu's Transcript reaches an episode that cannot be transcribed after all: a
/// show in another language, or a download in more than one file.
enum TranscriptUnavailableCopy {
  static let title = "No Transcript"
  static let message = "Whirr can transcribe downloaded episodes of English-language shows."
}
