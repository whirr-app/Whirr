import AppModel
import DesignSystem
import SwiftUI
import SyncEngine

/// Settings › Downloads, a pushed destination as in `PodcastShowSettingsView`. Footers are
/// reserved for consequences the control label cannot convey.
///
/// Picker and Storage Limit rows state no tint and inherit the neutral chrome (`AppChrome.tint`,
/// scene root); a system green would paint a picker's label, chevron and checkmark green. Safe in
/// both appearances: the neutral tint is a foreground pair. The white-on-white trap
/// `AppChrome.onTint` documents is for `.borderedProminent`, which fills with the tint.
///
/// The management rows push views, not `NavigationModel.Route` values, built by shell-supplied
/// builders (both destinations need shell-owned dependencies). This is a view-based push, so the
/// settings stack's `path` doesn't describe it: a route appended here would be installed beneath
/// it, invisible until the user swiped back, one copy per tap.
/// The `settings-stack-pushes-views-not-routes` source rule gates it.
///
/// The artwork row is a destructive action, not a push: it has no chevron and clears in place
/// behind the same confirmation. A chevron would promise a detail screen the tap never shows.
struct DownloadSettingsView<
  ManageDownloadsDestination: View, ResolutionCenterDestination: View
>: View {
  let model: SettingsModel
  let resolution: ResolutionCenterModel
  let artworkCache: ArtworkCacheModel
  @ViewBuilder let manageDownloadsDestination: () -> ManageDownloadsDestination
  @ViewBuilder let resolutionCenterDestination: () -> ResolutionCenterDestination
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @Environment(\.scenePhase) private var scenePhase

  var body: some View {
    // Read the flag outside a `Binding` getter so a button-triggered transition invalidates this
    // body and hands the alert its new presentation value.
    let isConfirmingClear = artworkCache.isConfirmingClearArtwork

    Form {
      networkSection
      automaticDownloadSection
      storageSection
      resolutionSection
    }
    .formStyle(.grouped)
    .scrollContentBackground(.hidden)
    .background(WhirrColorToken.groupedSurface.color.ignoresSafeArea())
    .navigationTitle(SettingsCopy.downloadsRowTitle)
    .navigationBarTitleDisplayMode(.inline)
    .task { await resolution.refresh() }
    // The row's trailing slot quotes the size, and the walk runs off this actor. Measured only on
    // this screen, not on every Settings appearance.
    .task { await artworkCache.refreshArtworkCacheSize() }
    .onAppear {
      model.startObservingStorage()
      Task { await model.refreshAvailableCapacity() }
    }
    .onDisappear { model.stopObservingStorage() }
    .onChange(of: scenePhase) { oldPhase, newPhase in
      guard oldPhase != .active, newPhase == .active else { return }
      Task { await model.refreshAvailableCapacity() }
    }
    .alert(
      SettingsCopy.artworkCacheClearArtworkTitle,
      isPresented: Binding(
        get: { isConfirmingClear },
        set: { presented in
          if presented == false { artworkCache.cancelClearArtwork() }
        })
    ) {
      Button(SettingsCopy.cancel, role: .cancel) { artworkCache.cancelClearArtwork() }
      Button(SettingsCopy.artworkCacheConfirmClearArtwork) {
        artworkCache.confirmClearArtwork()
      }
    } message: {
      Text(SettingsCopy.artworkCacheClearArtworkMessage(bytes: artworkCache.artworkCacheBytes ?? 0))
    }
  }

  // MARK: - Network

  private var networkSection: some View {
    Section {
      Toggle(
        SettingsCopy.cellularDownloadsToggleTitle,
        isOn: Binding(
          get: { model.allowCellularDownloads },
          set: { newValue in Task { await model.setAllowCellularDownloads(newValue) } }
        )
      )
      .tint(AppChrome.brandTint)
      .accessibilityIdentifier(ScreenAccessibilityID.settingsCellularToggle)
    }
  }

  // MARK: - Automatic downloads

  private var automaticDownloadSection: some View {
    Section {
      Picker(
        SettingsCopy.queueAutoDownloadTitle,
        selection: Binding(
          get: { model.queueAutoDownloadPolicy },
          set: { policy in Task { await model.setQueueAutoDownloadPolicy(policy) } }
        )
      ) {
        ForEach(QueueAutoDownloadPolicy.allCases, id: \.rawValue) { policy in
          Text(SettingsCopy.queueAutoDownloadLabel(policy))
            .tag(policy)
        }
      }
      .pickerStyle(.menu)
      .accessibilityIdentifier(ScreenAccessibilityID.settingsQueueAutoDownloadPicker)

      Picker(
        SettingsCopy.savedShelfAutoDownloadTitle,
        selection: Binding(
          get: { model.savedShelfAutoDownloadPolicy },
          set: { policy in Task { await model.setSavedShelfAutoDownloadPolicy(policy) } }
        )
      ) {
        ForEach(SavedShelfAutoDownloadPolicy.allCases, id: \.rawValue) { policy in
          Text(SettingsCopy.savedShelfAutoDownloadLabel(policy))
            .tag(policy)
        }
      }
      .pickerStyle(.menu)
      .accessibilityIdentifier(ScreenAccessibilityID.settingsSavedShelfAutoDownloadPicker)

      Toggle(
        SettingsCopy.deleteWhenFinishedToggleTitle,
        isOn: Binding(
          get: { model.deleteDownloadsWhenFinished },
          set: { newValue in Task { await model.setDeleteDownloadsWhenFinished(newValue) } }
        )
      )
      .tint(AppChrome.brandTint)
      .accessibilityIdentifier(ScreenAccessibilityID.settingsDeleteWhenFinishedToggle)
    } header: {
      Text(SettingsCopy.automaticDownloadsSectionTitle)
    }
  }

  // MARK: - Storage

  /// How much is downloaded sits directly above the row that frees it.
  private var storageSection: some View {
    Section {
      NavigationLink {
        StorageLimitSettingsView(
          model: model, manageDownloadsDestination: manageDownloadsDestination)
      } label: {
        VStack(alignment: .leading, spacing: WhirrSpacing.xSmall) {
          HStack(alignment: .firstTextBaseline, spacing: WhirrSpacing.small) {
            Text(SettingsCopy.storageCeilingTitle)
            Spacer(minLength: WhirrSpacing.small)
            Text(SettingsCopy.storageCeilingLabel(model.storageCeiling))
              .fixedSize(horizontal: false, vertical: true)
          }

          if let bar = model.storageSummaryBar {
            StorageBarView(bar: bar, height: WhirrSpacing.xxSmall)
          }

          compactStatus
        }
        .padding(.vertical, WhirrSpacing.xxSmall)
      }
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(SettingsCopy.storageCeilingTitle)
      .accessibilityValue(
        StorageLimitViewPresentation.compactAccessibilityValue(
          ceiling: model.storageCeiling,
          usage: model.storageUsageDescription,
          availableCapacity: model.compactAvailableCapacityDescription)
      )
      .accessibilityIdentifier(ScreenAccessibilityID.settingsStorageLimitLink)

      NavigationLink {
        manageDownloadsDestination()
      } label: {
        SettingsNavigationRow(
          title: SettingsCopy.manageDownloadsRowTitle,
          detail: SettingsCopy.manageDownloadsRowDetail,
          systemImage: "arrow.down.circle")
      }
      .accessibilityIdentifier(ScreenAccessibilityID.settingsStorageLink)

      // Not destructive: covers download again as they are drawn, and the alert confirms first.
      Button {
        artworkCache.requestClearArtwork()
      } label: {
        SettingsNavigationRow(
          title: artworkCache.isClearingArtwork
            ? SettingsCopy.artworkCacheClearingArtwork : SettingsCopy.artworkCacheClearArtwork,
          detail: SettingsCopy.artworkCacheRowDetail,
          systemImage: "photo.stack",
          trailingValue: artworkCache.artworkCacheBytes.map {
            SettingsCopy.artworkCacheSizeDetail(bytes: $0)
          },
          trailingValuePlaceholder: SettingsCopy.artworkCacheRowSizePlaceholder
        )
      }
      .buttonStyle(.plain)
      .disabled(isArtworkClearUnavailable)
      .accessibilityIdentifier(ScreenAccessibilityID.settingsClearArtworkButton)
    }
  }

  /// Nothing to clear while the size is still being measured, and nothing to clear at zero: a live
  /// red row there would confirm an action that frees nothing.
  private var isArtworkClearUnavailable: Bool {
    if artworkCache.isClearingArtwork { return true }
    guard let bytes = artworkCache.artworkCacheBytes else { return true }
    return bytes == 0
  }

  @ViewBuilder
  private var compactStatus: some View {
    if StorageLimitViewPresentation.stacksCompactStatus(
      isAccessibilitySize: dynamicTypeSize.isAccessibilitySize)
    {
      VStack(alignment: .leading, spacing: WhirrSpacing.xxSmall) {
        compactUsage
        compactCapacity
      }
    } else {
      HStack(alignment: .firstTextBaseline, spacing: WhirrSpacing.small) {
        compactUsage
        Spacer(minLength: WhirrSpacing.small)
        compactCapacity
      }
    }
  }

  private var compactUsage: some View {
    Text(model.storageUsageDescription)
      .font(.footnote)
      .foregroundStyle(WhirrColorToken.textSecondary.color)
      .monospacedDigit()
      .fixedSize(horizontal: false, vertical: true)
  }

  @ViewBuilder
  private var compactCapacity: some View {
    if let capacity = model.compactAvailableCapacityDescription {
      Text(capacity)
        .font(.footnote)
        .foregroundStyle(WhirrColorToken.textSecondary.color)
        .monospacedDigit()
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  // MARK: - Resolution Center

  /// On its own: it is about sync conflicts and paused transfers, not about storage.
  private var resolutionSection: some View {
    Section {
      NavigationLink {
        resolutionCenterDestination()
      } label: {
        SettingsNavigationRow(
          title: SettingsCopy.resolutionCenterRowTitle,
          detail: SettingsCopy.resolutionCenterRowDetail,
          systemImage: "arrow.triangle.2.circlepath",
          badgeCount: resolution.openCount)
      }
      .accessibilityIdentifier(ScreenAccessibilityID.settingsResolutionCenterLink)
    }
  }
}
