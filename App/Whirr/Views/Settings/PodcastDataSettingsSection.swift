import AppModel
import DesignSystem
import SwiftUI
import SyncEngine

/// The Podcast Data group of Settings > Podcasts. Rows appear only for destinations whose
/// readiness constant is true; an unfinished destination is omitted rather than shown disabled.
struct PodcastDataSettingsSection: View {
  let consentModel: PodcastCloudSyncConsentModel
  /// Fills in the catalogue of shows a restore follows.
  let podcastRefreshing: any PodcastRefreshing
  private let rows = PodcastDataSettingsPresentation.visibleRows(
    iCloudSyncReady: PodcastCloudSyncComposition.destinationReady)

  var body: some View {
    if rows.isEmpty == false {
      Section {
        ForEach(rows, id: \.self) { row in
          switch row {
          case .iCloudSync:
            NavigationLink {
              ICloudSyncSettingsView(model: consentModel)
            } label: {
              HStack {
                Text(PodcastDataSettingsCopy.iCloudSyncRowTitle)
                Spacer()
                Text(PodcastDataSettingsPresentation.iCloudSyncRowValue(isEnabled: consentModel.isEnabled))
                  .foregroundStyle(WhirrColorToken.textSecondary.color)
              }
              .accessibilityElement(children: .combine)
            }
            .accessibilityIdentifier(PodcastDataSettingsAccessibilityID.iCloudSyncRow)
          case .backups:
            NavigationLink(PodcastDataSettingsCopy.backupsRowTitle) {
              PodcastBackupsSettingsView(syncOn: consentModel.isEnabled, podcastRefreshing: podcastRefreshing)
            }
            .accessibilityIdentifier(PodcastBackupsAccessibilityID.row)
          }
        }
      } header: {
        Text(PodcastDataSettingsCopy.sectionHeader)
      } footer: {
        Text(PodcastDataSettingsCopy.sectionFooter)
      }
    }
  }
}

enum PodcastDataSettingsAccessibilityID {
  static let iCloudSyncRow = "settings.podcasts.data.icloud-sync"
  static let syncToggle = "settings.podcasts.icloud-sync.toggle"
  static let consentEnable = "settings.podcasts.icloud-sync.consent.enable"
  static let consentCancel = "settings.podcasts.icloud-sync.consent.cancel"
  static let status = "settings.podcasts.icloud-sync.status"
  static let statusNote = "settings.podcasts.icloud-sync.status-note"
  static let lastSynced = "settings.podcasts.icloud-sync.last-synced"
  static let retry = "settings.podcasts.icloud-sync.retry"
  static let recover = "settings.podcasts.icloud-sync.recover"
  static let deleteCloudData = "settings.podcasts.icloud-sync.delete"
}

/// Settings > Podcasts > iCloud Sync. Status, Try Again, recovery and deletion appear only when the
/// composition supplies a sync service, and status and Try Again only when sync is not up to date:
/// working sync is silent. Without a service the screen displays local consent state only. Nothing
/// on this screen constructs a CloudKit engine or checks an account; only its explicit actions
/// reach the supplied service.
struct ICloudSyncSettingsView: View {
  @Bindable var model: PodcastCloudSyncConsentModel
  @State private var controls = PodcastCloudSyncControlsModel(
    controller: PodcastCloudSyncComposition.syncController)

  var body: some View {
    Form {
      Section {
        Toggle(
          PodcastDataSettingsCopy.syncToggleTitle,
          isOn: Binding(get: { model.isEnabled }, set: { model.requestEnabled($0) })
        )
        .tint(AppChrome.brandTint)
        .accessibilityIdentifier(PodcastDataSettingsAccessibilityID.syncToggle)
      } footer: {
        VStack(alignment: .leading, spacing: WhirrSpacing.xSmall) {
          Text(PodcastDataSettingsCopy.syncDescription)
          if model.isEnabled == false {
            Text(PodcastDataSettingsCopy.syncOffNote)
          }
        }
      }
      if model.isEnabled, controls.showsStatus || controls.offersRetry {
        ICloudSyncStatusSection(controls: controls)
      }
      if model.isEnabled, controls.offersRetry {
        ICloudSyncRetrySection(controls: controls)
      }
      if model.isEnabled, let recovery = controls.recoveryAction {
        ICloudSyncRecoverySection(controls: controls, action: recovery)
      }
      Section {
        NavigationLink(PodcastDataSettingsCopy.whatGetsSyncedTitle) {
          WhatGetsSyncedView()
        }
      }
      if controls.isAvailable {
        ICloudPodcastDataDeletionSection(controls: controls)
      }
    }
    .formStyle(.grouped)
    .navigationTitle(PodcastDataSettingsCopy.iCloudSyncRowTitle)
    .navigationBarTitleDisplayMode(.inline)
    .task { await model.observe() }
    // Status changes on the engine's schedule, not the screen's. Polled here rather than in the
    // status section, which is hidden while sync is up to date and could never reveal itself.
    .task(id: model.isEnabled) {
      await controls.refresh()
      guard model.isEnabled else { return }
      while Task.isCancelled == false {
        try? await Task.sleep(for: .seconds(2))
        await controls.refresh()
      }
    }
    // A system alert rather than a sheet: it has the platform's size and button placement on
    // iPhone and iPad, where a fitted sheet around scrolling copy collapsed below tappable size.
    .alert(
      PodcastDataSettingsCopy.consentTitle,
      isPresented: Binding(
        get: { model.isConfirmingEnable },
        // Any dismissal that is not Enable Sync is Cancel: the switch stays off and nothing is
        // written. After Enable Sync this re-reads the consent just granted.
        set: { presented in if presented == false { model.cancelEnable() } })
    ) {
      Button(PodcastDataSettingsCopy.consentCancel, role: .cancel) { model.cancelEnable() }
        .accessibilityIdentifier(PodcastDataSettingsAccessibilityID.consentCancel)
      Button(PodcastDataSettingsCopy.consentEnable) { model.confirmEnable() }
        .keyboardShortcut(.defaultAction)
        .accessibilityIdentifier(PodcastDataSettingsAccessibilityID.consentEnable)
    } message: {
      Text(PodcastDataSettingsCopy.consentMessage)
    }
    .alert(
      PodcastDataSettingsCopy.enableFailedTitle,
      isPresented: Binding(
        get: { model.enableFailed }, set: { if $0 == false { model.dismissEnableFailure() } })
    ) {
      Button("OK", role: .cancel) { model.dismissEnableFailure() }
    } message: {
      Text(PodcastDataSettingsCopy.enableFailedMessage)
    }
  }
}

private struct WhatGetsSyncedView: View {
  var body: some View {
    Form {
      Section("Synced") {
        ForEach(PodcastDataSettingsCopy.syncedItems, id: \.self) { Text($0) }
      }
      Section {
        ForEach(PodcastDataSettingsCopy.notSyncedItems, id: \.self) { Text($0) }
      } header: {
        Text("Not Synced")
      } footer: {
        Text(PodcastDataSettingsCopy.encryptionNote)
      }
    }
    .formStyle(.grouped)
    .navigationTitle(PodcastDataSettingsCopy.whatGetsSyncedTitle)
    .navigationBarTitleDisplayMode(.inline)
  }
}

/// Status, only when there is something to say. Status is text, never colour alone, and refreshing
/// it is not a sync.
private struct ICloudSyncStatusSection: View {
  let controls: PodcastCloudSyncControlsModel

  var body: some View {
    Section {
      LabeledContent(PodcastDataSettingsCopy.statusTitle) {
        Text(controls.statusText ?? "")
      }
      .accessibilityIdentifier(PodcastDataSettingsAccessibilityID.status)
    } footer: {
      VStack(alignment: .leading, spacing: WhirrSpacing.xSmall) {
        if let note = controls.statusNote {
          Text(note)
            .accessibilityIdentifier(PodcastDataSettingsAccessibilityID.statusNote)
        }
        if controls.syncFailed {
          Text(PodcastDataSettingsCopy.syncNowFailed)
        }
        if controls.recovery == .failed {
          Text(PodcastDataSettingsCopy.recoveryFailed)
        }
        if let lastSynced = controls.lastSyncedNote {
          Text(lastSynced)
            .accessibilityIdentifier(PodcastDataSettingsAccessibilityID.lastSynced)
        }
      }
    }
  }
}

/// The screen's sync actions as the app's capsule action button: the brand tint is near-black, so
/// a tinted text row reads as a label rather than an action.
private struct ICloudSyncActionButton: View {
  let title: String
  let isWorking: Bool
  let isEnabled: Bool
  let accessibilityID: String
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: WhirrSpacing.small) {
        if isWorking { ProgressView().tint(.white) }
        Text(isWorking ? PodcastDataSettingsCopy.syncingNow : title)
      }
      .font(.headline)
      .frame(maxWidth: .infinity, minHeight: WhirrMetric.minimumTouchTarget)
    }
    .buttonStyle(.borderedProminent)
    .buttonBorderShape(.capsule)
    .tint(AppChrome.brandTint)
    .foregroundStyle(.white)
    .disabled(isEnabled == false)
    .listRowInsets(EdgeInsets())
    .listRowBackground(Color.clear)
    .accessibilityIdentifier(accessibilityID)
  }
}

private struct ICloudSyncRetrySection: View {
  let controls: PodcastCloudSyncControlsModel

  var body: some View {
    Section {
      ICloudSyncActionButton(
        title: PodcastDataSettingsCopy.tryAgain, isWorking: controls.isSyncing,
        isEnabled: controls.canSyncNow, accessibilityID: PodcastDataSettingsAccessibilityID.retry
      ) {
        Task { await controls.syncNow() }
      }
    }
  }
}

/// The explicit recovery a lost zone or a quarantined clock waits on. Recreating the zone resumes
/// uploads, so it asks first; Cancel leaves sync suspended and the action on offer.
private struct ICloudSyncRecoverySection: View {
  let controls: PodcastCloudSyncControlsModel
  let action: PodcastCloudSyncStatusPresentation.Recovery

  var body: some View {
    Section {
      ICloudSyncActionButton(
        title: PodcastDataSettingsCopy.recoveryTitle(for: action),
        isWorking: controls.recovery == .recovering, isEnabled: controls.canRecover,
        accessibilityID: PodcastDataSettingsAccessibilityID.recover
      ) {
        controls.requestRecovery()
      }
    }
    .alert(
      PodcastDataSettingsCopy.recreateZoneConfirmTitle,
      isPresented: Binding(
        get: { controls.recovery == .confirming },
        set: { presented in if presented == false { controls.cancelRecovery() } })
    ) {
      Button(PodcastDataSettingsCopy.consentCancel, role: .cancel) { controls.cancelRecovery() }
      Button(PodcastDataSettingsCopy.recreateZoneConfirmAction) { controls.confirmRecovery() }
        .keyboardShortcut(.defaultAction)
    } message: {
      Text(PodcastDataSettingsCopy.recreateZoneConfirmMessage)
    }
  }
}

/// Deletes Whirr's iCloud copy. Showing it makes no request; the action asks for a separate
/// confirmation and reports success only once the service has confirmed it.
private struct ICloudPodcastDataDeletionSection: View {
  let controls: PodcastCloudSyncControlsModel

  var body: some View {
    Section {
      Button(role: .destructive) {
        controls.requestDeletion()
      } label: {
        HStack {
          Text(
            controls.deletion == .deleting
              ? PodcastDataSettingsCopy.deleting : PodcastDataSettingsCopy.deleteCloudData)
          if controls.deletion == .deleting {
            Spacer()
            ProgressView()
          }
        }
      }
      .disabled(controls.deletion == .deleting)
      .accessibilityIdentifier(PodcastDataSettingsAccessibilityID.deleteCloudData)
    } footer: {
      VStack(alignment: .leading, spacing: WhirrSpacing.xSmall) {
        Text(PodcastDataSettingsCopy.deleteCloudDataExplanation)
        switch controls.deletion {
        case .deleted: Text(PodcastDataSettingsCopy.deleteSucceeded)
        case .failed: Text(PodcastDataSettingsCopy.deleteFailed)
        case .idle, .confirming, .deleting: EmptyView()
        }
      }
    }
    .alert(
      PodcastDataSettingsCopy.deleteConfirmTitle,
      isPresented: Binding(
        get: { controls.deletion == .confirming },
        set: { presented in if presented == false { controls.cancelDeletion() } })
    ) {
      Button(PodcastDataSettingsCopy.consentCancel, role: .cancel) { controls.cancelDeletion() }
      Button(PodcastDataSettingsCopy.deleteConfirmAction, role: .destructive) {
        controls.confirmDeletion()
      }
    } message: {
      Text(PodcastDataSettingsCopy.deleteConfirmMessage)
    }
  }
}
