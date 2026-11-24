import AppModel
import SwiftUI

struct PlaybackSettingsView: View {
  private enum InputField: Hashable {
    case rate
    case minutes
  }

  private enum ResetTarget: Identifiable {
    case rates
    case timers

    var id: Self { self }
  }

  /// The app-wide default's only home. The player's speed controls pin one title each and never
  /// write the default, so this row is the one place the number every unpinned title inherits is set.
  let playbackRate: PlaybackRateCoordinator

  @AppStorage("player.playbackRate.presets") private var encodedRatePresets = ""
  @AppStorage("player.sleepTimer.presets") private var encodedTimerPresets = ""
  @AppStorage(UserDefaultsPlaybackPreferences.smartRewindKey)
  private var smartRewindEnabled = true
  @AppStorage(UserDefaultsPlaybackPreferences.voiceBoostKey)
  private var voiceBoostEnabled = false
  @AppStorage(UserDefaultsTrimSilencesPreferences.enabledKey)
  private var trimSilencesEnabled = false
  @AppStorage(UserDefaultsTrimSilencesPreferences.strengthKey)
  private var trimSilencesStrength = TrimStrength.moderate
  @AppStorage(UserDefaultsPlaybackPreferences.sleepTimerResumeGraceKey)
  private var sleepTimerResumeGraceSeconds = 0
  @AppStorage(SkipIntervalConfiguration.forwardStorageKey)
  private var storedForwardSkipSeconds = SkipIntervalConfiguration.defaultForwardSeconds
  @AppStorage(SkipIntervalConfiguration.backwardStorageKey)
  private var storedBackwardSkipSeconds = SkipIntervalConfiguration.defaultBackwardSeconds
  @State private var draftRate = ""
  @State private var draftMinutes = ""
  @State private var pendingReset: ResetTarget?
  @FocusState private var focusedField: InputField?

  private var rateConfiguration: PlaybackRatePresetConfiguration {
    PlaybackRatePresetConfiguration.decode(encodedRatePresets)
  }

  private var timerConfiguration: SleepTimerPresetConfiguration {
    SleepTimerPresetConfiguration.decode(encodedTimerPresets)
  }

  var body: some View {
    Form {
      defaultRateSection
      rateSection
      timerSection
      sleepTimerRestartSection
      smartRewindSection
      voiceBoostSection
      trimSilencesSection
      skipSection
    }
    .formStyle(.grouped)
    .scrollDismissesKeyboard(.interactively)
    .navigationTitle("Playback")
    .toolbar {
      ToolbarItem { EditButton() }
      // The number pads have no Return key, so this bar is the way out of a field.
      ToolbarItemGroup(placement: .keyboard) {
        Button("Cancel") { focusedField = nil }
        Spacer()
        Button("Add") { addFocusedDraft() }
          .fontWeight(.semibold)
          .disabled(focusedDraftIsAddable == false)
      }
    }
    // Leaving a field without adding discards what was typed in it.
    .onChange(of: focusedField) { previous, _ in
      switch previous {
      case .rate: draftRate = ""
      case .minutes: draftMinutes = ""
      case nil: break
      }
    }
    // An alert, not a dialog: a dialog anchors to the Reset row as a popover with no Cancel.
    .alert(resetTitle, isPresented: resetDialogBinding, presenting: pendingReset) { target in
      Button("Cancel", role: .cancel) {}
      Button("Reset", role: .destructive) { reset(target) }
    } message: { target in
      Text(
        target == .rates
          ? PlaybackRatePresetConfiguration.resetMessage : SleepTimerPresetConfiguration.resetMessage)
    }
  }

  private var defaultRateSection: some View {
    Section {
      Picker(
        PlaybackRateScopePresentation.defaultSpeedRowTitle, selection: defaultRateBinding
      ) {
        ForEach(
          PlaybackRateScopePresentation.defaultSpeedChoices(
            encodedPresets: encodedRatePresets, currentRate: playbackRate.globalDefaultRate),
          id: \.self
        ) { rate in
          Text(PlaybackRatePresetConfiguration.display(rate)).tag(rate)
        }
      }
    } footer: {
      Text(PlaybackRateScopePresentation.defaultSpeedFooter)
    }
  }

  /// Writes straight through the coordinator, which is the only thing allowed to touch a stored
  /// speed. Titles already carrying their own speed are untouched, so this is heard immediately
  /// only when what is playing inherits.
  private var defaultRateBinding: Binding<Double> {
    Binding(
      get: { playbackRate.globalDefaultRate },
      set: { playbackRate.setGlobalDefault($0) }
    )
  }

  private var rateSection: some View {
    Section {
      ForEach(rateConfiguration.rates, id: \.self) { rate in
        Text(PlaybackRatePresetConfiguration.display(rate))
          .deleteDisabled(rateConfiguration.rates.count <= 1)
      }
      .onDelete(perform: deleteRates)

      HStack {
        TextField("Add speed", text: $draftRate)
          .keyboardType(.decimalPad)
          .focused($focusedField, equals: .rate)
        Button("Add", systemImage: "plus.circle.fill") { addRate() }
          .labelStyle(.iconOnly)
          .disabled(normalizedDraftRate == nil)
      }

      // Destructive, confirmed, and absent when there is nothing to reset: it sits under the
      // field a person has just been typing in.
      if rateConfiguration.isDefault == false {
        Button("Reset Speed Shortcuts", role: .destructive) { pendingReset = .rates }
      }
    } header: {
      Text("Playback Speed Shortcuts")
    }
  }

  private var timerSection: some View {
    Section {
      ForEach(timerConfiguration.minutes, id: \.self) { minutes in
        Text("\(minutes) minutes")
          .deleteDisabled(timerConfiguration.minutes.count <= 1)
      }
      .onDelete(perform: deleteTimerPresets)

      HStack {
        TextField("Add minutes", text: $draftMinutes)
          .keyboardType(.numberPad)
          .focused($focusedField, equals: .minutes)
        Button("Add", systemImage: "plus.circle.fill") { addTimerPreset() }
          .labelStyle(.iconOnly)
          .disabled(normalizedDraftMinutes == nil)
      }

      if timerConfiguration.isDefault == false {
        Button("Reset Timer Shortcuts", role: .destructive) { pendingReset = .timers }
      }
    } header: {
      Text("Sleep Timer")
    }
  }

  /// Its own section so the timer's reset row is not wedged between two controls.
  private var sleepTimerRestartSection: some View {
    Section {
      Picker("Restart If Resumed Within", selection: $sleepTimerResumeGraceSeconds) {
        ForEach(UserDefaultsPlaybackPreferences.sleepTimerResumeGraceOptions, id: \.self) { seconds in
          Text(seconds == 0 ? "Off" : "\(seconds / 60) min")
            .tag(seconds)
        }
      }
      .pickerStyle(.menu)
    } footer: {
      Text("If you press play soon after the sleep timer stops playback, the timer starts again.")
    }
  }

  private var skipSection: some View {
    Section("Skip Buttons") {
      Picker("Seek Forwards By", selection: forwardSkipBinding) {
        ForEach(SkipIntervalConfiguration.presets, id: \.self) { seconds in
          Text(SkipIntervalConfiguration.displayName(seconds: seconds))
            .tag(seconds)
        }
      }
      .pickerStyle(.menu)

      Picker("Seek Backwards By", selection: backwardSkipBinding) {
        ForEach(SkipIntervalConfiguration.presets, id: \.self) { seconds in
          Text(SkipIntervalConfiguration.displayName(seconds: seconds))
            .tag(seconds)
        }
      }
      .pickerStyle(.menu)
    }
  }

  private var smartRewindSection: some View {
    Section {
      Toggle("Rewind on Resume", isOn: $smartRewindEnabled)
        .tint(AppChrome.brandTint)
    } header: {
      Text("Smart Rewind")
    } footer: {
      Text("Rewinds up to 10 seconds after a break.")
    }
  }

  private var voiceBoostSection: some View {
    Section {
      Toggle(VoiceBoostCopy.toggleTitle, isOn: $voiceBoostEnabled)
        .tint(AppChrome.brandTint)
    } header: {
      Text(VoiceBoostCopy.settingsHeader)
    } footer: {
      Text(VoiceBoostCopy.settingsFooter)
    }
  }

  /// The default for every show without its own setting.
  private var trimSilencesSection: some View {
    Section {
      Toggle(TrimSilencesCopy.title, isOn: $trimSilencesEnabled)
        .tint(AppChrome.brandTint)
        .accessibilityIdentifier(TrimSilencesAccessibilityID.settingsToggle)
      // Kept enabled while off: it is also the strength a show's own setting is ticked to.
      Picker(TrimSilencesCopy.strengthTitle, selection: $trimSilencesStrength) {
        ForEach(TrimStrength.allCases, id: \.self) { strength in
          Text(TrimSilencesCopy.strengthLabel(strength)).tag(strength)
        }
      }
      .pickerStyle(.menu)
      .accessibilityIdentifier(TrimSilencesAccessibilityID.settingsStrength)
    } footer: {
      Text(TrimSilencesCopy.settingsFooter)
    }
  }

  private var forwardSkipBinding: Binding<Int> {
    Binding(
      get: {
        SkipIntervalConfiguration.resolvedSeconds(storedForwardSkipSeconds, forward: true)
      },
      set: { storedForwardSkipSeconds = $0 }
    )
  }

  private var backwardSkipBinding: Binding<Int> {
    Binding(
      get: {
        SkipIntervalConfiguration.resolvedSeconds(storedBackwardSkipSeconds, forward: false)
      },
      set: { storedBackwardSkipSeconds = $0 }
    )
  }

  private var normalizedDraftRate: Double? {
    guard let value = PlaybackRatePresetConfiguration.parsedRate(draftRate),
      let normalized = PlaybackRatePresetConfiguration.normalizedRate(value),
      rateConfiguration.rates.contains(normalized) == false,
      rateConfiguration.rates.count < PlaybackRatePresetConfiguration.maximumCount
    else { return nil }
    return normalized
  }

  private var normalizedDraftMinutes: Int? {
    guard let value = Int(draftMinutes),
      SleepTimerPresetConfiguration.allowedRange.contains(value),
      timerConfiguration.minutes.contains(value) == false,
      timerConfiguration.minutes.count < SleepTimerPresetConfiguration.maximumCount
    else { return nil }
    return value
  }

  private var focusedDraftIsAddable: Bool {
    switch focusedField {
    case .rate: normalizedDraftRate != nil
    case .minutes: normalizedDraftMinutes != nil
    case nil: false
    }
  }

  private func addFocusedDraft() {
    switch focusedField {
    case .rate: addRate()
    case .minutes: addTimerPreset()
    case nil: break
    }
  }

  private var resetTitle: String {
    pendingReset == .timers ? "Reset Timer Shortcuts?" : "Reset Speed Shortcuts?"
  }

  private var resetDialogBinding: Binding<Bool> {
    Binding(
      get: { pendingReset != nil },
      set: { if $0 == false { pendingReset = nil } }
    )
  }

  private func reset(_ target: ResetTarget) {
    switch target {
    case .rates:
      setRates(PlaybackRatePresetConfiguration.defaults)
    case .timers:
      setTimerPresets(SleepTimerPresetConfiguration.defaults)
    }
  }

  private func addRate() {
    guard let rate = normalizedDraftRate else { return }
    setRates(rateConfiguration.rates + [rate])
    draftRate = ""
    focusedField = nil
  }

  private func deleteRates(at offsets: IndexSet) {
    var rates = rateConfiguration.rates
    rates.remove(atOffsets: offsets)
    setRates(rates)
  }

  private func setRates(_ rates: [Double]) {
    encodedRatePresets = PlaybackRatePresetConfiguration(rates: rates).encoded
  }

  private func addTimerPreset() {
    guard let minutes = normalizedDraftMinutes else { return }
    setTimerPresets(timerConfiguration.minutes + [minutes])
    draftMinutes = ""
    focusedField = nil
  }

  private func deleteTimerPresets(at offsets: IndexSet) {
    var minutes = timerConfiguration.minutes
    minutes.remove(atOffsets: offsets)
    setTimerPresets(minutes)
  }

  private func setTimerPresets(_ minutes: [Int]) {
    encodedTimerPresets = SleepTimerPresetConfiguration(minutes: minutes).encoded
  }
}
