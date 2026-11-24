import AppModel
import DesignSystem
import Persistence
import SwiftUI
import SyncEngine
import UIKit

/// The two long lists (download defaults and per-show overrides) live in focused destinations,
/// and anything that is one row stays a row on this screen. Each toggle owns its own footer, since
/// a shared footer made episode alerts read as a condition on following feeds directly.
struct PodcastSettingsView: View {
  private let reading: any PodcastSettingsReading
  private let writing: any PodcastSettingsWriting
  private let nativeSettingsAccess: (any (PodcastSettingsReading & PodcastSettingsWriting))?
  private let podcastReading: any PodcastReading
  /// Passed straight down to `PodcastShowSettingsView`; this screen fetches nothing itself.
  private let podcastRefreshing: any PodcastRefreshing
  /// Threaded through to `PodcastShowSettingsView`'s speed row; this screen draws none of its own.
  private let playbackRate: PlaybackRateCoordinator
  private let playback: PlaybackModel?
  private let nativeSubscriptionsReading: any NativePodcastSubscriptionsReading
  private let nativeSubscriptionsWriting: any NativePodcastSubscriptionsWriting
  private let nativeFeedManaging: any NativeFeedManaging
  private let nativeShowsReading: any NativePodcastShowsReading
  /// Passed straight down to `PodcastShowSettingsView` (ADR 0017).
  private let serverMutationCapability: any ServerPodcastMutationCapabilityReading
  private let automationSettingsWriting: any ServerPodcastAutomationSettingsWriting
  @Bindable private var notificationModel: PodcastNotificationSettingsModel
  @Bindable private var subscriptionOPMLModel: PodcastSubscriptionOPMLModel
  private let cloudSyncConsent: PodcastCloudSyncConsentStore
  @State private var nativeSubscriptionsEnabled = true
  @State private var isConfirmingNativeSubscriptionsDisable = false
  @State private var isImporterPresented = false
  @State private var isImportPreviewPresented = false

  // `PodcastSettingsModel.init` opens two GRDB observations synchronously, so building it in
  // `View.init` would reopen them on every re-evaluation of this navigation destination. See
  // `DeferredModel`.
  @State private var deferred = DeferredModel<PodcastSettingsModel>()
  @State private var deferredNative = DeferredModel<PodcastSettingsModel>()
  @State private var deferredCloudSyncConsent = DeferredModel<PodcastCloudSyncConsentModel>()

  private var model: PodcastSettingsModel {
    deferred.resolve { PodcastSettingsModel(reading: reading, writing: writing) }
  }

  init(
    reading: any PodcastSettingsReading, writing: any PodcastSettingsWriting,
    nativeSettingsAccess: (any (PodcastSettingsReading & PodcastSettingsWriting))? = nil,
    podcastReading: any PodcastReading, podcastRefreshing: any PodcastRefreshing,
    playbackRate: PlaybackRateCoordinator, playback: PlaybackModel? = nil,
    nativeSubscriptionsReading: any NativePodcastSubscriptionsReading =
      NoOpNativePodcastSubscriptionsReading(),
    nativeSubscriptionsWriting: any NativePodcastSubscriptionsWriting =
      NoOpNativePodcastSubscriptionsWriting(),
    notificationModel: PodcastNotificationSettingsModel,
    nativeFeedManaging: any NativeFeedManaging = NoOpNativeFeedManaging(),
    nativeShowsReading: any NativePodcastShowsReading = NoOpNativePodcastShowsReading(),
    subscriptionOPMLModel: PodcastSubscriptionOPMLModel,
    serverMutationCapability: any ServerPodcastMutationCapabilityReading =
      NoOpServerPodcastMutationCapabilityReading(),
    automationSettingsWriting: any ServerPodcastAutomationSettingsWriting =
      NoOpServerPodcastAutomationSettingsWriting(),
    cloudSyncConsent: PodcastCloudSyncConsentStore = PodcastCloudSyncComposition.consentStore
  ) {
    self.serverMutationCapability = serverMutationCapability
    self.automationSettingsWriting = automationSettingsWriting
    self.reading = reading
    self.writing = writing
    self.nativeSettingsAccess = nativeSettingsAccess
    self.podcastReading = podcastReading
    self.podcastRefreshing = podcastRefreshing
    self.playbackRate = playbackRate
    self.playback = playback
    self.nativeSubscriptionsReading = nativeSubscriptionsReading
    self.nativeSubscriptionsWriting = nativeSubscriptionsWriting
    self.nativeFeedManaging = nativeFeedManaging
    self.nativeShowsReading = nativeShowsReading
    self.notificationModel = notificationModel
    self.subscriptionOPMLModel = subscriptionOPMLModel
    self.cloudSyncConsent = cloudSyncConsent
  }

  var body: some View {
    Form {
      nativeSubscriptionsSection
      if nativeSubscriptionsEnabled { notificationSection }
      Section {
        NavigationLink("Downloads") { downloadSettings }
        NavigationLink("Show Settings") { showSettings }
        NavigationLink(PodcastsViewPresentation.sectionsEntryTitle) { PodcastsSettingsView() }
          .accessibilityIdentifier(PodcastsViewPresentation.sectionsEntryAccessibilityID)
      }
      // Retained data can still be managed with direct subscriptions disabled.
      PodcastDataSettingsSection(
        consentModel: deferredCloudSyncConsent.resolve {
          PodcastCloudSyncConsentModel(store: cloudSyncConsent)
        }, podcastRefreshing: podcastRefreshing)
      // Two buttons: a row's worth of content, so it stays on this screen rather
      // than behind a disclosure leading to a form holding only itself.
      if nativeSubscriptionsEnabled { subscriptionTransferSection }
    }
    .formStyle(.grouped)
    .navigationTitle("Podcasts")
    .navigationBarTitleDisplayMode(.inline)
    .task {
      for await enabled in nativeSubscriptionsReading.observeEnabled() {
        nativeSubscriptionsEnabled = enabled
      }
    }
    .alert(
      "Podcasts",
      isPresented: Binding(
        get: { model.actionErrorMessage != nil },
        set: { isPresented in if isPresented == false { model.dismissActionError() } }
      )
    ) {
      Button("OK", role: .cancel) { model.dismissActionError() }
    } message: {
      Text(model.actionErrorMessage ?? "")
    }
    .alert(
      SettingsCopy.nativePodcastSubscriptionsDisableTitle,
      isPresented: $isConfirmingNativeSubscriptionsDisable
    ) {
      Button("Cancel", role: .cancel) {}
      Button("Stop and Disable", role: .destructive) {
        Task {
          await playback?.stopForNativeSubscriptionsDisable()
          await nativeSubscriptionsWriting.setEnabled(false)
        }
      }
    } message: {
      Text(SettingsCopy.nativePodcastSubscriptionsDisableMessage)
    }
    .fileImporter(
      isPresented: $isImporterPresented,
      allowedContentTypes: OPMLFileSupport.allowedContentTypes
    ) { result in
      guard case .success(let url) = result else { return }
      Task {
        let data = (try? OPMLFileSupport.read(url)) ?? Data()
        await subscriptionOPMLModel.loadImport(data: data)
        isImportPreviewPresented = true
      }
    }
    .sheet(isPresented: $isImportPreviewPresented) {
      OPMLImportPreviewView(model: subscriptionOPMLModel)
        .adaptiveSheetPresentation(role: .large)
    }
    .task { await subscriptionOPMLModel.prepareExport() }
    .task { await notificationModel.load() }
    .notificationEnableRefusalAlert(notificationModel.enableRefusal) {
      notificationModel.dismissEnableRefusal()
    }
    .refreshesOnBackgroundRefreshChanges(notificationModel)
  }

  /// Both stores' defaults are shown together rather than switched between, so nothing hides
  /// behind a control's other half. `downloadDefaultsScopes` decides when an account needs only
  /// one of them.
  private var downloadSettings: some View {
    let scopes = PodcastSettingsViewPresentation.downloadDefaultsScopes(
      showRows: model.showRows, nativeSubscriptionsEnabled: nativeSubscriptionsEnabled,
      hasDirectFeedDefaults: nativeSettingsAccess != nil)
    return Form {
      if scopes.contains(.direct), let nativeSettingsAccess {
        defaultsSection(
          model: deferredNative.resolve {
            PodcastSettingsModel(reading: nativeSettingsAccess, writing: nativeSettingsAccess)
          },
          header: PodcastSettingsViewPresentation.followedSectionTitle,
          footer: PodcastDownloadCopy.directDefaultsFooter)
      }
      if scopes.contains(.server) {
        defaultsSection(
          model: model,
          header: PodcastSettingsViewPresentation.serverSectionTitle,
          footer: PodcastDownloadCopy.serverDefaultsFooter)
      }
    }
    .formStyle(.grouped)
    .navigationTitle("Downloads")
    .navigationBarTitleDisplayMode(.inline)
  }

  private var showSettings: some View {
    Form { showSettingsSection }
      .formStyle(.grouped)
      .navigationTitle("Show Settings")
      .navigationBarTitleDisplayMode(.inline)
  }

  private var notificationSection: some View {
    Section {
      Toggle(
        SettingsCopy.podcastEpisodeNotificationsToggleTitle,
        isOn: Binding(
          get: { notificationModel.isEnabled },
          set: { enabled in notificationModel.requestEnabled(enabled) })
      )
      .tint(AppChrome.brandTint)
      if notificationModel.showsSystemSettingsRecovery {
        Button("Open System Settings") { SystemSettingsLink.open() }
      }
    } footer: {
      if let warning = notificationModel.backgroundRefreshWarning {
        Label(warning, systemImage: "exclamationmark.triangle")
      } else {
        Text(SettingsCopy.podcastEpisodeNotificationsFooter)
      }
    }
    .tint(AppChrome.brandTint)
  }

  private var nativeSubscriptionsSection: some View {
    Section {
      Toggle(
        SettingsCopy.nativePodcastSubscriptionsToggleTitle,
        isOn: Binding(
          get: { nativeSubscriptionsEnabled },
          set: { enabled in
            if enabled == false, playback?.isActiveNativePodcastPlayback == true {
              isConfirmingNativeSubscriptionsDisable = true
            } else {
              Task { await nativeSubscriptionsWriting.setEnabled(enabled) }
            }
          })
      )
      .tint(AppChrome.brandTint)
    } footer: {
      Text(SettingsCopy.nativePodcastSubscriptionsFooter)
    }
    .tint(AppChrome.brandTint)
  }

  private var subscriptionTransferSection: some View {
    Section {
      Button {
        subscriptionOPMLModel.resetImport()
        isImporterPresented = true
      } label: {
        Label(PodcastSubscriptionOPMLPresentation.importLabel, systemImage: "square.and.arrow.down")
      }
      if let exportURL = subscriptionOPMLModel.exportURL {
        ShareLink(item: exportURL) {
          Label(PodcastSubscriptionOPMLPresentation.exportLabel, systemImage: "square.and.arrow.up")
        }
      } else if subscriptionOPMLModel.exportError {
        Text(PodcastSubscriptionOPMLPresentation.exportFailureMessage)
          .foregroundStyle(.red)
      } else {
        HStack {
          ProgressView()
          Text(PodcastSubscriptionOPMLPresentation.exportLabel)
        }
      }
    } header: {
      Text(PodcastSettingsViewPresentation.followedSectionTitle)
    }
  }

  private func defaultsSection(
    model: PodcastSettingsModel, header: String, footer: String
  ) -> some View {
    Section {
      Toggle(
        PodcastDownloadCopy.autoDownloadToggleTitle,
        isOn: Binding(
          get: { model.global.autoDownloadEnabled },
          set: { value in Task { await model.setAutoDownloadEnabled(value) } })
      )
      .tint(AppChrome.brandTint)
      if model.global.autoDownloadEnabled {
        Picker(
          "Keep Latest",
          selection: Binding(
            get: { model.global.keepLatestCount },
            set: { value in Task { await model.setKeepLatestCount(value) } })
        ) {
          ForEach(PodcastSettingsViewPresentation.keepLatestChoices, id: \.self) { count in
            Text(PodcastDownloadCopy.keepLatestValueLabel(count)).tag(count)
          }
        }
        .pickerStyle(.menu)
      }
      Toggle(
        "Delete Played Episodes",
        isOn: Binding(
          get: { model.global.deleteAfterPlayed },
          set: { value in Task { await model.setDeleteAfterPlayed(value) } })
      )
      .tint(AppChrome.brandTint)
      if model.global.autoDownloadEnabled {
        Toggle(
          PodcastDownloadCopy.allowCellularToggleTitle,
          isOn: Binding(
            get: { model.global.allowCellularAutoDownload },
            set: { value in Task { await model.setAllowCellularAutoDownload(value) } })
        )
        .tint(AppChrome.brandTint)
      }
      if let message = model.actionErrorMessage {
        Text(message).foregroundStyle(.red)
      }
    } header: {
      Text(header)
    } footer: {
      Text(footer)
    }
    .tint(AppChrome.brandTint)
  }

  @ViewBuilder
  private var showSettingsSection: some View {
    let rows = PodcastSettingsViewPresentation.partitionedShowRows(
      model.showRows, nativeSubscriptionsEnabled: nativeSubscriptionsEnabled)
    if rows.native.isEmpty && rows.server.isEmpty {
      Section {
        Text("No podcasts yet.")
          .foregroundStyle(WhirrColorToken.textSecondary.color)
      }
    }
    if rows.native.isEmpty == false {
      Section(PodcastSettingsViewPresentation.followedSectionTitle) { showRows(rows.native) }
    }
    if rows.server.isEmpty == false {
      Section(PodcastSettingsViewPresentation.serverSectionTitle) { showRows(rows.server) }
    }
  }

  @ViewBuilder
  private func showRows(_ rows: [PodcastShowSettingsSummary]) -> some View {
    ForEach(rows, id: \.itemID) { row in
      NavigationLink {
        PodcastShowSettingsView(
          itemID: row.itemID, titleSeed: row.title, reading: reading, writing: writing,
          podcastReading: podcastReading, podcastRefreshing: podcastRefreshing,
          playbackRate: playbackRate, nativeFeedManaging: nativeFeedManaging,
          nativeShowsReading: nativeShowsReading, notificationModel: notificationModel,
          serverMutationCapability: serverMutationCapability,
          automationSettingsWriting: automationSettingsWriting)
      } label: {
        HStack {
          Text(row.title)
          Spacer()
          // Only a show that overrides the default carries a value; an inheriting row would
          // otherwise restate the one global setting once per show.
          if let label = PodcastDownloadCopy.showRowLabel(row) {
            Text(label)
              .foregroundStyle(WhirrColorToken.textSecondary.color)
          }
        }
      }
      .accessibilityElement(children: .combine)
      .accessibilityLabel(
        PodcastDownloadCopy.showRowLabel(row).map { "\(row.title). \($0)" } ?? row.title)
    }
  }
}
