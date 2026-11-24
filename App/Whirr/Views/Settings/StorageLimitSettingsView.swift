import AppModel
import DesignSystem
import SwiftUI
import SyncEngine

/// Settings › Downloads › Storage Limit. The model stays shared with its parent so preference,
/// byte observations, refresh coalescing and staged confirmation have one owner.
///
/// Manage Downloads pushes a view the parent hands down (see `DownloadSettingsView`): this screen
/// is a view-based push, so a route appended from here would land beneath it.
struct StorageLimitSettingsView<ManageDownloadsDestination: View>: View {
  let model: SettingsModel
  @ViewBuilder let manageDownloadsDestination: () -> ManageDownloadsDestination
  @Environment(\.scenePhase) private var scenePhase
  /// The limit under the thumb while it differs from the stored one: during a drag, and from
  /// release until the write lands or the confirmation is cancelled. `nil` shows the stored limit,
  /// so a change made elsewhere is never hidden behind a stale thumb.
  @State private var draft: StorageCeiling?
  @State private var isDragging = false

  var body: some View {
    let pendingConfirmation = model.pendingStorageCeilingConfirmation

    Form {
      summarySection
      limitSection
    }
    .formStyle(.grouped)
    .scrollContentBackground(.hidden)
    .background(WhirrColorToken.groupedSurface.color.ignoresSafeArea())
    .navigationTitle(SettingsCopy.storageCeilingTitle)
    .navigationBarTitleDisplayMode(.inline)
    .accessibilityIdentifier(ScreenAccessibilityID.settingsStorageLimitScreen)
    .onAppear {
      model.startObservingStorage()
      Task { await model.refreshAvailableCapacity() }
    }
    .onDisappear { model.stopObservingStorage() }
    .onChange(of: model.storageCeiling) { _, _ in
      if isDragging == false { draft = nil }
    }
    .onChange(of: scenePhase) { oldPhase, newPhase in
      guard oldPhase != .active, newPhase == .active else { return }
      Task { await model.refreshAvailableCapacity() }
    }
    .alert(
      SettingsCopy.reduceStorageLimitTitle,
      isPresented: Binding(
        get: { pendingConfirmation != nil },
        // The explicit Cancel action owns cancellation. A no-op dismissal setter cannot race the
        // destructive action after `confirmStorageCeiling()` synchronously consumes its target.
        set: { _ in }
      )
    ) {
      Button(SettingsCopy.cancel, role: .cancel) {
        model.cancelStorageCeilingChange()
        draft = nil
      }
      if let pendingConfirmation {
        Button(
          SettingsCopy.useStorageLimitAction(pendingConfirmation),
          role: .destructive
        ) {
          model.confirmStorageCeiling()
        }
      }
    } message: {
      Text(SettingsCopy.reduceStorageLimitMessage)
    }
  }

  private var summarySection: some View {
    Section {
      VStack(alignment: .leading, spacing: WhirrSpacing.small) {
        LabeledContent(SettingsCopy.storageDownloadsTitle) {
          Text(model.downloadedBytesDescription)
            .monospacedDigit()
            .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(
          StorageLimitViewPresentation.dataAccessibilityValue(
            displayedValue: model.downloadedBytesDescription,
            isAvailable: model.hasLoadedDownloadedBytes && model.downloadedBytes != nil))

        Divider()

        LabeledContent(SettingsCopy.storageAvailableOnDeviceTitle) {
          Text(model.availableCapacityDescription)
            .monospacedDigit()
            .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(
          StorageLimitViewPresentation.dataAccessibilityValue(
            displayedValue: model.availableCapacityDescription,
            isAvailable: model.availableCapacityBytes != nil))

        if let bar = model.storageBar {
          Divider()
          StorageBarView(bar: bar, height: WhirrSpacing.small)
          StorageBarLegend(bar: bar)
        }
      }
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier(ScreenAccessibilityID.settingsStorageLimitSummary)

      NavigationLink {
        manageDownloadsDestination()
      } label: {
        Text(SettingsCopy.manageDownloadsRowTitle)
      }
      .accessibilityIdentifier(ScreenAccessibilityID.settingsStorageLimitManageDownloadsLink)
    }
  }

  private var limitSection: some View {
    let stops = model.storageCeilingStops
    let shown = draft ?? model.storageCeiling
    let preview = SettingsCopy.storageCeilingReductionPreview(
      model.storageCeilingReduction(for: shown))

    return Section {
      VStack(alignment: .leading, spacing: WhirrSpacing.xSmall) {
        HStack(alignment: .firstTextBaseline, spacing: WhirrSpacing.small) {
          Text(SettingsCopy.storageLimitSliderTitle)
            .fixedSize(horizontal: false, vertical: true)
          Spacer(minLength: WhirrSpacing.small)
          Text(SettingsCopy.storageCeilingLabel(shown))
            .fontWeight(.semibold)
            .monospacedDigit()
            .fixedSize(horizontal: false, vertical: true)
        }

        Slider(
          value: Binding(
            get: { StorageLimitViewPresentation.sliderValue(for: shown, in: stops) },
            set: { value in
              draft = StorageLimitViewPresentation.ceiling(forSliderValue: value, in: stops)
            }
          ),
          in: StorageLimitViewPresentation.sliderRange(for: stops),
          step: 1
        ) { editing in
          isDragging = editing
          if editing == false { commit(draft) }
        }
        // The bar takes the themed navy rather than the scene tint, which is near-white in dark
        // appearance: the untinted remainder is a light fill, so a near-white bar disappears.
        // The thumb stays system white and reads on the navy in both appearances.
        .tint(AppChrome.brandTint)
        .frame(minHeight: WhirrMetric.minimumTouchTarget)

        // One line either way, so the row does not change height as the thumb crosses the point
        // where a limit starts removing downloads: the standing policy at rest, and what this
        // limit would remove once it would remove something.
        Text(preview ?? SettingsCopy.storageCeilingExplanation)
          .font(.footnote)
          .foregroundStyle(WhirrColorToken.textSecondary.color)
          .fixedSize(horizontal: false, vertical: true)
      }
      // One adjustable element for VoiceOver: a swipe moves one stop and applies it, exactly as
      // releasing the thumb there would, confirmation included.
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(SettingsCopy.storageLimitSliderTitle)
      .accessibilityValue(
        StorageLimitViewPresentation.sliderAccessibilityValue(
          ceiling: shown, reductionPreview: preview)
      )
      .accessibilityHint(SettingsCopy.storageCeilingExplanation)
      .accessibilityAdjustableAction { direction in
        let offset =
          switch direction {
          case .increment: 1
          case .decrement: -1
          @unknown default: 0
          }
        let target = StorageCeilingStops.stop(from: shown, offset: offset, in: stops)
        draft = target
        commit(target)
      }
      .accessibilityIdentifier(ScreenAccessibilityID.settingsStorageLimitSlider)
    } header: {
      Text(SettingsCopy.storageLimitSectionTitle)
    }
  }

  /// Applies the limit the thumb was released on. A limit that needs confirming keeps the thumb
  /// where it was released until the alert is answered; one that changes nothing drops the draft.
  private func commit(_ ceiling: StorageCeiling?) {
    guard let ceiling, ceiling != model.storageCeiling else {
      draft = nil
      return
    }
    model.requestStorageCeiling(ceiling)
  }
}
