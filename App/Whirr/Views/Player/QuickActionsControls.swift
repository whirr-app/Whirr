import AVFoundation
import AppModel
import Combine
import DesignSystem
import Persistence
import PlayerCore
import SwiftUI

/// Equatable on the visible menu presentation only, so playback position ticks do not rebuild
/// this subtree. The live sleep-timer text is isolated in `SleepTimerQuickActionLabel`.
struct QuickActionsControls: View, Equatable {
  let player: any PlaybackControlling
  let itemID: String
  let episodeID: String?
  /// The timer mode controls whether the native menu has a Turn Off action. Countdown seconds are
  /// read by the label leaf so they cannot invalidate this menu source.
  let sleepTimerMode: PlayerQuickActionsSleepTimerMode
  let rate: Double
  /// Whether this title has a saved speed. Keep this in `==` so the menu's Use Default Speed
  /// action updates even when saving or clearing an override leaves the effective rate unchanged.
  let hasRateOverride: Bool
  /// The rate a Focus is playing this title at, or nil. In `==` so the card's header follows a
  /// Focus turning on or off even when the rate it plays is unchanged.
  var focusRate: Double? = nil
  /// The item-boundary option offered for the matching live item: chapters for books with a
  /// chapter map, and the episode boundary for podcasts.
  let sleepTimerCompletion: SleepTimerMenuPresentation.Completion?
  let encodedRatePresets: String
  let encodedTimerPresets: String
  @Binding var isShowingSleepTimer: Bool
  @Binding var isShowingUpNext: Bool
  /// Pins a preset to this title through the rate coordinator. Never `player.send` directly: a raw
  /// `.setRate` changes the audio without durably recording anything, so the pin would not survive
  /// the session and the lock screen would disagree with the menu.
  let onSelectRate: (Double) -> Void
  let onClearRateOverride: () -> Void

  /// View-local presentation state. Not part of `identity`: `@State` survives the equatable gate,
  /// and opening the card must not depend on the parent rebuilding this row.
  @State private var isShowingSpeedCard = false
  @State private var opensCustomSpeedAfterCard = false
  @State private var customSpeed = CustomSpeedPrompt()

  /// Everything the visible menus are built from, and nothing else. A separate value so the gate
  /// can be tested without constructing the view (which needs the whole shell's models). It
  /// decides what invalidates this subtree. The playhead is absent so position ticks do not
  /// rebuild native menu sources.
  struct Identity: Equatable {
    let itemID: String
    let episodeID: String?
    let sleepTimerMode: PlayerQuickActionsSleepTimerMode
    let rate: Double
    let hasRateOverride: Bool
    var focusRate: Double? = nil
    let sleepTimerCompletion: SleepTimerMenuPresentation.Completion?
    let encodedRatePresets: String
    let encodedTimerPresets: String
    /// Drives the Up Next action's selected state and spoken name while the queue is inline.
    var isUpNextShown = false
  }

  var identity: Identity {
    Identity(
      itemID: itemID, episodeID: episodeID,
      sleepTimerMode: sleepTimerMode, rate: rate, hasRateOverride: hasRateOverride,
      focusRate: focusRate, sleepTimerCompletion: sleepTimerCompletion,
      encodedRatePresets: encodedRatePresets, encodedTimerPresets: encodedTimerPresets,
      isUpNextShown: isShowingUpNext)
  }

  static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.identity == rhs.identity
  }

  var body: some View {
    HStack(spacing: WhirrSpacing.small) {
      sleepTimerMenu(completion: sleepTimerCompletion)
        .accessibilityIdentifier(PlayerAccessibilityID.expandedSleepTimer)

      playbackRateMenu(rate: rate)
        .accessibilityLabel("Playback speed")
        .accessibilityValue(ExpandedPlayerView.displayRate(rate))
        .accessibilityIdentifier(PlayerAccessibilityID.expandedRate)

      AudioRouteQuickAction()
        .accessibilityIdentifier(PlayerAccessibilityID.expandedAudioRoute)

      // Shown for both media types. Shows the queue without navigating or collapsing the player:
      // in place on a portrait phone, where this is also its close control, and as a sheet
      // elsewhere (`InlineUpNextPresentation.placement`).
      Button {
        InlineUpNextPresentation.toggle(&isShowingUpNext)
      } label: {
        QuickActionLabel(
          systemImage: ListeningQueueSheetPresentation.upNextSymbol,
          isSelected: isShowingUpNext)
      }
      .accessibilityLabel(
        isShowingUpNext
          ? InlineUpNextPresentation.hideLabel : ListeningQueueSheetPresentation.upNextLabel
      )
      .accessibilityHint(
        isShowingUpNext
          ? InlineUpNextPresentation.hideHint : ListeningQueueSheetPresentation.upNextHint
      )
      .accessibilityAddTraits(isShowingUpNext ? .isSelected : [])
      .accessibilityIdentifier(PlayerAccessibilityID.expandedUpNext)
    }
    .buttonStyle(.plain)
  }

  private func playbackRateMenu(rate: Double) -> some View {
    Button {
      isShowingSpeedCard = true
    } label: {
      QuickActionLabel(
        title: PlaybackRatePresetConfiguration.activeDisplay(rate),
        systemImage: "speedometer")
    }
    .popover(isPresented: $isShowingSpeedCard) {
      PlaybackRateSpeedCard(
        kind: PlaybackRateScopePresentation.Kind.resolve(episodeID: episodeID),
        rate: rate,
        encodedPresets: encodedRatePresets,
        hasRateOverride: hasRateOverride,
        focusRate: focusRate,
        onSelectRate: onSelectRate,
        onClearRateOverride: onClearRateOverride,
        onCustomSpeed: {
          opensCustomSpeedAfterCard = true
          isShowingSpeedCard = false
        },
        showItemID: episodeID == nil ? nil : itemID
      )
      .presentationCompactAdaptation(.popover)
      // The alert waits until the card has gone: presenting it while the popover is still
      // dismissing is dropped by UIKit, so Custom Speed would close the card and open nothing.
      .onDisappear {
        guard opensCustomSpeedAfterCard else { return }
        opensCustomSpeedAfterCard = false
        customSpeed.open(currentRate: rate)
      }
    }
    .customSpeedAlert($customSpeed, onSet: onSelectRate)
  }

  private func sleepTimerMenu(completion: SleepTimerMenuPresentation.Completion?) -> some View {
    let isActive = sleepTimerMode != .off
    let options = SleepTimerMenuPresentation.options(
      encodedPresets: encodedTimerPresets,
      completion: completion)

    let selection = SleepTimerMenuPresentation.selectionID(
      mode: sleepTimerMode, completion: completion)

    return Menu {
      // A `Picker`, not a row of buttons: the options are one exclusive setting, and plain buttons
      // cannot show which is in force. The speed card beside it marks its selection too. Setting
      // is one-way: `selection` is derived from the player and the write side sends an intent
      // rather than assigning, so the checkmark follows the timer that is running, not the tap
      // that asked for it.
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

      if isActive {
        Button("Turn Off") {
          player.send(.setSleepTimer(.off))
        }
      }

      Button("Custom Timer…") {
        isShowingSleepTimer = true
      }
    } label: {
      SleepTimerQuickActionLabel(
        player: player,
        completion: episodeID == nil ? .chapter : .episode)
    }
    .menuStyle(.button)
    .accessibilityLabel("Sleep timer")
  }
}

/// Owns the live audio-route read so changing headphones or an AirPlay destination invalidates
/// only this slot, not the equatable menu row around it. The system route picker remains the full
/// tap target; Whirr supplies the glyph and readout above it, because `AVRoutePickerView`'s own
/// artwork is the same AirPlay mark whatever the route happens to be.
private struct AudioRouteQuickAction: View {
  @State private var display = AudioRoutePresentation.currentDisplay()
  @Environment(\.scenePhase) private var scenePhase

  var body: some View {
    // An overlay, not a `ZStack` layer: `AVRoutePickerView` reports no intrinsic size, so as an
    // independent layer it is height-flexible and swallows the proposal's height, growing this
    // slot and the player chrome (instead of measuring 54pt like its siblings) and pinning the
    // artwork to `minimumCoverSize`. An overlay is sized by the label beneath, so the picker keeps
    // the row's height and stays the full tap target at every Dynamic Type size.
    QuickActionLabel(title: display.label, systemImage: display.symbol)
      .allowsHitTesting(false)
      .accessibilityHidden(true)
      .overlay { AudioRoutePicker(spokenRoute: display.spokenRoute) }
      .frame(maxWidth: .infinity, minHeight: PlayerMetric.quickActionMinHeight)
      .onReceive(
        NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification)
      ) { _ in
        display = AudioRoutePresentation.currentDisplay()
      }
      // Headphones can be swapped from Control Center while Whirr is suspended, and the route
      // change notification is missed, so refresh when the player appears.
      .onAppear { display = AudioRoutePresentation.currentDisplay() }
      .onChange(of: scenePhase) { _, phase in
        guard phase == .active else { return }
        display = AudioRoutePresentation.currentDisplay()
      }
  }
}

/// The only quick-action leaf that reads the live timer value. Its parent menu reads only the
/// stable timer mode, so countdown ticks update this label without rebuilding native menu sources.
private struct SleepTimerQuickActionLabel: View {
  let player: any PlaybackControlling
  let completion: SleepTimerMenuPresentation.Completion

  var body: some View {
    let timer = player.quickActionsSleepTimer
    let label = SleepTimerMenuPresentation.activeLabel(for: timer, completion: completion)
    QuickActionLabel(title: label.compact, systemImage: "moon.zzz")
      // The spoken form, not the drawn one: without it "13:59" is a number with no unit and no
      // subject.
      .accessibilityValue(label.accessible ?? "Off")
  }
}

/// Sized from `PlayerMetric.quickAction*` rather than the bare touch-target floor: at footnote size
/// on a 44pt row they read as a caption strip under the transport, not as quick actions.
private struct QuickActionLabel: View {
  let title: String?
  let systemImage: String
  /// A filled plate behind the glyph, for an action that is showing what it toggles.
  let isSelected: Bool
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize

  init(title: String? = nil, systemImage: String, isSelected: Bool = false) {
    self.title = title
    self.systemImage = systemImage
    self.isSelected = isSelected
  }

  var body: some View {
    let layoutValues = PlayerQuickActionLayoutValues.resolve(
      isAccessibilitySize: dynamicTypeSize.isAccessibilitySize)

    return VStack(spacing: PlayerMetric.quickActionLabelSpacing) {
      Image(systemName: systemImage)
        .font(
          .system(
            size: PlayerMetric.quickActionSymbolSize,
            weight: PlayerMetric.quickActionSymbolWeight)
        )
        .background {
          // Square on the glyph's longer side, so a wide symbol still sits inside a true circle.
          Circle()
            .fill(.primary.opacity(isSelected ? 0.16 : 0))
            .aspectRatio(1, contentMode: .fill)
            .padding(-8)
        }
        .accessibilityHidden(true)
      quickActionText(
        title: PlayerQuickActionLayoutValues.labelLine(for: title), layoutValues: layoutValues)
    }
    .frame(maxWidth: .infinity, minHeight: layoutValues.minimumHeight)
    .padding(.horizontal, WhirrSpacing.xSmall)
  }

  @ViewBuilder
  private func quickActionText(
    title: String, layoutValues: PlayerQuickActionLayoutValues
  ) -> some View {
    if let minimumScaleFactor = layoutValues.minimumScaleFactor {
      quickActionTextBase(title: title, layoutValues: layoutValues)
        .minimumScaleFactor(minimumScaleFactor)
    } else {
      quickActionTextBase(title: title, layoutValues: layoutValues)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  private func quickActionTextBase(
    title: String, layoutValues: PlayerQuickActionLayoutValues
  ) -> some View {
    // Full-strength primary ink keeps the canvas's 4.5:1 contrast on these small readouts in
    // light and dark. Monospaced digits stop the ticking timer reflowing the row.
    Text(title)
      .font(PlayerMetric.quickActionLabelType.font)
      .foregroundStyle(.primary)
      .lineLimit(layoutValues.labelLineLimit)
      .monospacedDigit()
  }
}
