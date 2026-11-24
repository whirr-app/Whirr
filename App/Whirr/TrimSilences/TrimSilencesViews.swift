import AppModel
import DesignSystem
import Persistence
import SwiftUI

/// What the per-show Trim Silences and Voice Boost controls need. Published by `RootView` for the
/// runtime graph; absent elsewhere, which hides the show controls and leaves the speed card's
/// Voice Boost row app-wide.
struct ShowPlaybackEffectsAccess {
  let trimSettings: RoutingTrimSilencesShowSettingsAccess
  let trimDefaults: UserDefaultsTrimSilencesPreferences
  let voiceBoostSettings: RoutingVoiceBoostShowSettingsAccess
  let voiceBoostDefault: UserDefaultsVoiceBoostDefault
  /// The loaded episode's trim status, for the speed card's caption.
  let playback: PlaybackModel

  @MainActor
  func makeTrimModel(itemID: String) -> ShowTrimSilencesModel {
    ShowTrimSilencesModel(itemID: itemID, settings: trimSettings, defaults: trimDefaults)
  }

  @MainActor
  func makeVoiceBoostModel(itemID: String) -> ShowVoiceBoostModel {
    ShowVoiceBoostModel(itemID: itemID, settings: voiceBoostSettings, defaults: voiceBoostDefault)
  }
}

private struct ShowPlaybackEffectsAccessKey: EnvironmentKey {
  static let defaultValue: ShowPlaybackEffectsAccess? = nil
}

extension EnvironmentValues {
  /// A custom value, so sheet and popover content inherits it (see `windowHorizontalSizeClass`).
  var showPlaybackEffects: ShowPlaybackEffectsAccess? {
    get { self[ShowPlaybackEffectsAccessKey.self] }
    set { self[ShowPlaybackEffectsAccessKey.self] = newValue }
  }
}

enum ShowVoiceBoostAccessibilityID {
  static let showPicker = "podcast.showSettings.voiceBoost"
}

enum TrimSilencesAccessibilityID {
  static let settingsToggle = "settings.playback.trimSilences"
  static let settingsStrength = "settings.playback.trimSilences.strength"
  static let showPicker = "podcast.showSettings.trimSilences"
  static let rateCardRow = "player.rateCard.trimSilences"
  static let rateCardCaption = "player.rateCard.trimSilences.caption"
}

/// The show settings page's picker, a row in the speed section: "Default (…)", Off, Moderate,
/// Maximum.
struct ShowTrimSilencesPicker: View {
  let itemID: String
  let access: ShowPlaybackEffectsAccess

  // Built once: the model opens two observations (see `DeferredModel`).
  @State private var deferred = DeferredModel<ShowTrimSilencesModel>()

  private var model: ShowTrimSilencesModel {
    deferred.resolve { access.makeTrimModel(itemID: itemID) }
  }

  var body: some View {
    let model = model
    Picker(
      TrimSilencesCopy.title,
      selection: Binding(
        get: { model.showOverride },
        set: { value in Task { await model.setOverride(value) } })
    ) {
      ForEach(model.choices, id: \.self) { choice in
        Text(model.label(for: choice)).tag(choice)
      }
    }
    .pickerStyle(.menu)
    .accessibilityIdentifier(TrimSilencesAccessibilityID.showPicker)
  }
}

/// The show settings page's Voice Boost picker: "Default (On)" or "Default (Off)", On, Off.
struct ShowVoiceBoostPicker: View {
  let itemID: String
  let access: ShowPlaybackEffectsAccess

  @State private var deferred = DeferredModel<ShowVoiceBoostModel>()

  private var model: ShowVoiceBoostModel {
    deferred.resolve { access.makeVoiceBoostModel(itemID: itemID) }
  }

  var body: some View {
    let model = model
    Picker(
      VoiceBoostCopy.toggleTitle,
      selection: Binding(
        get: { model.showOverride },
        set: { value in Task { await model.setOverride(value) } })
    ) {
      ForEach(model.choices, id: \.self) { choice in
        Text(model.label(for: choice)).tag(choice)
      }
    }
    .pickerStyle(.menu)
    .accessibilityIdentifier(ShowVoiceBoostAccessibilityID.showPicker)
  }
}

/// The speed card's Voice Boost row for the playing show: it writes the show's own setting. An
/// audiobook keeps `PlaybackRateSpeedCard`'s app-wide row.
struct ShowVoiceBoostCardRow: View {
  let itemID: String
  let access: ShowPlaybackEffectsAccess

  @State private var deferred = DeferredModel<ShowVoiceBoostModel>()

  private var model: ShowVoiceBoostModel {
    deferred.resolve { access.makeVoiceBoostModel(itemID: itemID) }
  }

  var body: some View {
    let model = model
    EffectTickRow(
      title: VoiceBoostCopy.toggleTitle, systemImage: VoiceBoostCopy.menuSymbol, isOn: model.isOn
    ) {
      Task { await model.toggle() }
    }
    .accessibilityIdentifier(PlayerAccessibilityID.rateCardVoiceBoost)
  }
}

/// The speed card's tick row, as Apple Podcasts draws it, not a `Toggle`: a switch needs a tinted
/// track, and the only neutral tint (primary ink) is a white track under a white knob in dark mode.
/// Any coloured track clashes with the player's artwork-themed background.
struct EffectTickRow: View {
  let title: String
  let systemImage: String
  let isOn: Bool
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack {
        Label(title, systemImage: systemImage)
        Spacer(minLength: WhirrSpacing.small)
        Image(systemName: "checkmark")
          .font(.body.weight(.semibold))
          .opacity(isOn ? 1 : 0)
          .accessibilityHidden(true)
      }
      .frame(maxWidth: .infinity, minHeight: WhirrMetric.minimumTouchTarget, alignment: .leading)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityAddTraits(isOn ? .isSelected : [])
  }
}

/// The speed card's Trim Silences row for the playing show, and the caption under it. It writes
/// the show's own setting.
struct TrimSilencesCardRow: View {
  let itemID: String
  let access: ShowPlaybackEffectsAccess

  @State private var deferred = DeferredModel<ShowTrimSilencesModel>()

  private var model: ShowTrimSilencesModel {
    deferred.resolve { access.makeTrimModel(itemID: itemID) }
  }

  var body: some View {
    let model = model
    VStack(alignment: .leading, spacing: 0) {
      EffectTickRow(
        title: TrimSilencesCopy.title, systemImage: TrimSilencesCopy.symbol, isOn: model.isOn
      ) {
        Task { await model.toggle() }
      }
      .accessibilityIdentifier(TrimSilencesAccessibilityID.rateCardRow)

      // The status is the loaded episode's; it says nothing while the show plays untrimmed. A
      // Focus that decides the show adds a sentence, since a tap then may not change the tick.
      // The space is always kept: a popover sizes itself once, so a line that appeared
      // later would push the card's ends out of view.
      let caption = TrimSilencesCopy.cardCaption(
        status: access.playback.trimStatus, isOn: model.isOn,
        isGovernedByFocus: model.isGovernedByFocus)
      Text(caption ?? " ")
        .font(.footnote)
        .foregroundStyle(.secondary)
        .lineLimit(2, reservesSpace: true)
        .accessibilityHidden(caption == nil)
        .accessibilityIdentifier(TrimSilencesAccessibilityID.rateCardCaption)
    }
  }
}
