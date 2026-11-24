import AppModel
import DesignSystem
import Foundation
import Observation
import PlayerCore
import SwiftUI

/// The speed and sleep-timer controls the regular-width mini-player has room for. Speed is always
/// shown; the sleep timer appears only while one runs, as a countdown with a menu to change or
/// cancel it. Starting one stays in the expanded player: an idle control would spend title room.
///
/// Rate changes go through `PlaybackRateCoordinator`, never a raw `.setRate`, as in
/// `QuickActionsRow`: a raw intent changes the audio without recording the title's pin.
struct MiniPlayerRegularWidthControls: View {
  let player: any PlaybackControlling
  let playback: PlaybackModel
  let playbackRate: PlaybackRateCoordinator
  let itemID: String
  let episodeID: String?
  /// Not `@AppStorage`, for the reason `SkipIntervalStore` gives: this is persistent chrome.
  private let presets = MiniPlayerMenuPresetStore.shared
  @State private var isShowingSpeedCard = false
  @State private var opensCustomSpeedAfterCard = false
  @State private var customSpeed = CustomSpeedPrompt()

  var body: some View {
    let quickActions = player.quickActions
    let liveItem = quickActions.item
    let isLiveItem =
      playback.loadedItemID == itemID
      && playback.loadedEpisodeID == episodeID
      && liveItem?.id == itemID
      && liveItem?.episodeID == episodeID
    // PlayerCore resets to 1× when it goes idle, so a retained title's own speed comes from the
    // coordinator's resolution rather than the idle player.
    let rate = PlaybackRateMenuPresentation.displayedRate(
      isLiveItem: isLiveItem, liveRate: quickActions.rate,
      titleRate: playback.effectiveRate(for: itemID))

    HStack(spacing: 0) {
      if isLiveItem, quickActions.isSleepTimerActive {
        sleepTimerMenu(
          mode: quickActions.sleepTimerMode,
          completion: SleepTimerMenuPresentation.completion(
            isLiveItem: isLiveItem, episodeID: episodeID,
            liveItemHasChapters: liveItem?.hasChapters == true))
      }
      // Not gated on transport availability: pinning a retained title's speed before it starts
      // is a setting, not a transport action, and the coordinator applies it on load.
      playbackRateMenu(rate: rate)
    }
  }

  private func playbackRateMenu(rate: Double) -> some View {
    Button {
      isShowingSpeedCard = true
    } label: {
      // Always the number, 1× included: unlike the expanded player's labelled row, a bare
      // speedometer glyph here would not say what it controls.
      MiniPlayerControlLabel(text: PlaybackRatePresetConfiguration.display(rate))
    }
    .buttonStyle(.plain)
    .popover(isPresented: $isShowingSpeedCard) {
      PlaybackRateSpeedCard(
        kind: PlaybackRateScopePresentation.Kind.resolve(episodeID: episodeID),
        rate: rate,
        encodedPresets: presets.encodedRatePresets,
        hasRateOverride: playbackRate.hasOverride(forItemID: itemID),
        focusRate: playbackRate.focusRate(forItemID: itemID),
        onSelectRate: { playbackRate.adjustRate($0, itemID: itemID) },
        onClearRateOverride: { playbackRate.clearOverride(itemID: itemID) },
        onCustomSpeed: {
          opensCustomSpeedAfterCard = true
          isShowingSpeedCard = false
        },
        showItemID: episodeID == nil ? nil : itemID
      )
      .presentationCompactAdaptation(.popover)
      // As in the expanded player: UIKit drops an alert presented while the popover dismisses.
      .onDisappear {
        guard opensCustomSpeedAfterCard else { return }
        opensCustomSpeedAfterCard = false
        customSpeed.open(currentRate: rate)
      }
    }
    .customSpeedAlert($customSpeed) { playbackRate.adjustRate($0, itemID: itemID) }
    .accessibilityLabel("Playback speed")
    .accessibilityValue(PlaybackRatePresetConfiguration.display(rate))
    .accessibilityIdentifier(PlayerAccessibilityID.miniPlayerRate)
  }

  private func sleepTimerMenu(
    mode: PlayerQuickActionsSleepTimerMode, completion: SleepTimerMenuPresentation.Completion?
  ) -> some View {
    let options = SleepTimerMenuPresentation.options(
      encodedPresets: presets.encodedTimerPresets, completion: completion)
    let selection = SleepTimerMenuPresentation.selectionID(mode: mode, completion: completion)

    return Menu {
      // Same one-way picker as the expanded player's menu: the checkmark follows the running
      // timer, and a pick sends an intent rather than assigning.
      Picker(
        "Sleep Timer",
        selection: Binding(
          get: { selection },
          set: { id in
            guard let option = options.first(where: { $0.id == id }) else { return }
            player.send(.setSleepTimer(SleepTimerMenuPresentation.duration(for: option)))
          }
        )
      ) {
        ForEach(options) { option in
          switch option {
          case .minutes(let minutes):
            Text("\(minutes) minutes").tag(Optional(option.id))
          case .endOf(let completion):
            Text(completion.title).tag(Optional(option.id))
          }
        }
      }
      .pickerStyle(.inline)

      Divider()

      Button("Turn Off") {
        player.send(.setSleepTimer(.off))
      }
    } label: {
      MiniPlayerSleepTimerLabel(
        player: player, completion: episodeID == nil ? .chapter : .episode)
    }
    .menuStyle(.button)
    .buttonStyle(.plain)
    .accessibilityLabel("Sleep timer")
    .accessibilityIdentifier(PlayerAccessibilityID.miniPlayerSleepTimer)
  }
}

/// The only part of the regular-width controls that reads the live countdown, so each tick
/// redraws this label and not the menus around it.
private struct MiniPlayerSleepTimerLabel: View {
  let player: any PlaybackControlling
  let completion: SleepTimerMenuPresentation.Completion

  var body: some View {
    let label = SleepTimerMenuPresentation.activeLabel(
      for: player.quickActionsSleepTimer, completion: completion)
    MiniPlayerControlLabel(systemImage: "moon.zzz", text: label.compact ?? "")
      .accessibilityValue(label.accessible ?? "Off")
  }
}

/// Caption-sized so the controls read as secondary to the transport beside them, with the same
/// 44pt minimum target the transport uses.
private struct MiniPlayerControlLabel: View {
  var systemImage: String? = nil
  let text: String

  var body: some View {
    HStack(spacing: WhirrSpacing.xxSmall) {
      if let systemImage {
        Image(systemName: systemImage)
          .accessibilityHidden(true)
      }
      Text(text)
        .lineLimit(1)
        .monospacedDigit()
    }
    .font(WhirrTypeToken.caption.font.weight(.semibold))
    .padding(.horizontal, WhirrSpacing.xSmall)
    .frame(minWidth: PlayerMetric.miniPlayerPlayPauseSize, minHeight: PlayerMetric.miniPlayerPlayPauseSize)
    .contentShape(Rectangle())
  }
}

/// Reports the live chapter's title to the mini-player without making the whole bar depend on the
/// playhead. This leaf reads `player.state` (republished every engine tick) and writes upward
/// only when the chapter actually changes, so the container rebuilds once per chapter rather than
/// twice a second. Only a matching live item answers: a retained item has no playhead to place.
struct MiniPlayerChapterTitleReader: View {
  let player: any PlaybackControlling
  let playback: PlaybackModel
  let itemID: String
  @Binding var chapterTitle: String?

  var body: some View {
    let state = player.state
    let liveItem = ExpandedPlayerPresentation.livePlayerItem(
      itemID: itemID, loadedItemID: playback.loadedItemID,
      loadedEpisodeID: playback.loadedEpisodeID, playerItem: state.item)
    let title = liveItem?.chapters.currentChapterTitle(at: state.globalPosition)
    Color.clear
      .accessibilityHidden(true)
      .onChange(of: title, initial: true) { _, newTitle in
        if chapterTitle != newTitle { chapterTitle = newTitle }
      }
      .onDisappear { chapterTitle = nil }
  }
}

/// The speed and sleep-timer preset lists, republished once per change. See `SkipIntervalStore`
/// for why the persistent mini-player cannot use `@AppStorage` for these.
@MainActor
@Observable
final class MiniPlayerMenuPresetStore {
  static let shared = MiniPlayerMenuPresetStore()

  static let ratePresetsKey = "player.playbackRate.presets"
  static let timerPresetsKey = "player.sleepTimer.presets"

  @ObservationIgnored private let defaults: UserDefaults
  @ObservationIgnored private var observer: NSObjectProtocol?

  private(set) var encodedRatePresets: String
  private(set) var encodedTimerPresets: String

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    self.encodedRatePresets = defaults.string(forKey: Self.ratePresetsKey) ?? ""
    self.encodedTimerPresets = defaults.string(forKey: Self.timerPresetsKey) ?? ""
    observer = NotificationCenter.default.addObserver(
      forName: UserDefaults.didChangeNotification, object: defaults, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.reread() }
    }
  }

  deinit {
    if let observer { NotificationCenter.default.removeObserver(observer) }
  }

  private func reread() {
    let rates = defaults.string(forKey: Self.ratePresetsKey) ?? ""
    if rates != encodedRatePresets { encodedRatePresets = rates }
    let timers = defaults.string(forKey: Self.timerPresetsKey) ?? ""
    if timers != encodedTimerPresets { encodedTimerPresets = timers }
  }
}
