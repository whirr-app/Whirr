import AppModel
import DesignSystem
import Persistence
import SwiftUI
import SyncEngine
import UIKit

/// One show's Show Settings destination: tri-state auto-download/keep-latest/delete-after-played
/// overrides, plus the read-only server section built verbatim from
/// `PodcastServerSettingsPresentation.section`. Every string comes from `PodcastDownloadCopy`,
/// `PodcastShowSettingsViewPresentation` or that section.
///
/// The server section is plain `LabeledContent` in a headed, footed `Section`, the grouped-`Form`
/// idiom of `DownloadSettingsView`, with no DesignSystem component, material, blur or tint.
/// For an account that may save to the server (ADR 0017) it holds standard `Toggle`/`Picker`
/// controls instead, keeping no state and showing the stored value until observed values change.
struct PodcastShowSettingsView: View {
  private let itemID: String
  private let titleSeed: String?
  private let reading: any PodcastSettingsReading
  private let writing: any PodcastSettingsWriting
  private let podcastReading: any PodcastReading
  private let podcastRefreshing: any PodcastRefreshing
  /// The shell's one speed owner. Not the `ItemPlaybackSettingsWriting` boundary directly: a
  /// screen writing to the store itself would leave the coordinator's view of the governing scope
  /// stale while this show is playing.
  private let playbackRate: PlaybackRateCoordinator
  private let nativeFeedManaging: any NativeFeedManaging
  private let nativeShowsReading: any NativePodcastShowsReading
  private let notificationModel: PodcastNotificationSettingsModel?
  private let serverMutationCapability: any ServerPodcastMutationCapabilityReading
  private let automationSettingsWriting: any ServerPodcastAutomationSettingsWriting

  @AppStorage("player.playbackRate.presets") private var encodedRatePresets = ""
  @Environment(\.showPlaybackEffects) private var showPlaybackEffects

  // `PodcastShowSettingsModel.init` opens two GRDB observations synchronously, so building it in
  // `View.init` would reopen them on every re-evaluation. See `DeferredModel`. The model's
  // once-per-instance server-fetch guard rides on the same identity.
  @State private var deferred = DeferredModel<PodcastShowSettingsModel>()

  private var model: PodcastShowSettingsModel {
    deferred.resolve {
      PodcastShowSettingsModel(
        itemID: itemID, reading: reading, writing: writing, podcastReading: podcastReading,
        refreshing: podcastRefreshing, nativeFeedManaging: nativeFeedManaging,
        nativeShowsReading: nativeShowsReading, notificationSettings: notificationModel,
        serverMutationCapability: serverMutationCapability,
        automationSettingsWriting: automationSettingsWriting, titleSeed: titleSeed)
    }
  }

  init(
    itemID: String, titleSeed: String? = nil, reading: any PodcastSettingsReading,
    writing: any PodcastSettingsWriting,
    podcastReading: any PodcastReading, podcastRefreshing: any PodcastRefreshing,
    playbackRate: PlaybackRateCoordinator,
    nativeFeedManaging: any NativeFeedManaging = NoOpNativeFeedManaging(),
    nativeShowsReading: any NativePodcastShowsReading = NoOpNativePodcastShowsReading(),
    notificationModel: PodcastNotificationSettingsModel? = nil,
    serverMutationCapability: any ServerPodcastMutationCapabilityReading =
      NoOpServerPodcastMutationCapabilityReading(),
    automationSettingsWriting: any ServerPodcastAutomationSettingsWriting =
      NoOpServerPodcastAutomationSettingsWriting()
  ) {
    self.itemID = itemID
    self.titleSeed = titleSeed
    self.reading = reading
    self.writing = writing
    self.podcastReading = podcastReading
    self.podcastRefreshing = podcastRefreshing
    self.playbackRate = playbackRate
    self.nativeFeedManaging = nativeFeedManaging
    self.nativeShowsReading = nativeShowsReading
    self.notificationModel = notificationModel
    self.serverMutationCapability = serverMutationCapability
    self.automationSettingsWriting = automationSettingsWriting
  }

  var body: some View {
    Group {
      switch model.state {
      case .loading:
        loadingForm
      case .notFound:
        notFoundView
      case .loaded:
        settingsForm
      }
    }
    .navigationTitle(model.title.isEmpty ? "Show Settings" : model.title)
    .navigationBarTitleDisplayMode(.inline)
    // A typed-but-unsaved feed password must not outlive the screen that collected it. Saving
    // and removing clear it too; this covers leaving without either.
    .onDisappear { model.clearTransientCredentialInput() }
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
    .notificationEnableRefusalAlert(model.notificationRefusal) {
      model.dismissNotificationRefusal()
    }
    .refreshesOnBackgroundRefreshChanges(notificationModel)
  }

  /// Form-shaped so the observation's first value replaces content in place. The disabled menu
  /// pickers use the same row control and grouped sections as `settingsForm`; only their
  /// representative value is redacted.
  private var loadingForm: some View {
    Form {
      loadingSection("Automatic Downloads")
      loadingSection("Keep Latest")
      loadingSection("Delete Played Episodes")
      loadingSection(PlaybackRateScopePresentation.showSpeedRowTitle)
    }
    .formStyle(.grouped)
    .allowsHitTesting(false)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Loading show settings")
    .accessibilityAddTraits(.updatesFrequently)
  }

  private func loadingSection(_ title: String) -> some View {
    Section {
      Picker(selection: .constant(0)) {
        Text("Placeholder value").tag(0)
      } label: {
        Text(title)
      }
      .pickerStyle(.menu)
      .disabled(true)
      .redacted(reason: .placeholder)
    }
  }

  private var notFoundView: some View {
    ContentUnavailableView(
      PodcastShowSettingsViewPresentation.notFoundTitle,
      systemImage: "questionmark.circle",
      description: Text(PodcastDownloadCopy.showSettingsNotFound))
  }

  private var settingsForm: some View {
    Form {
      // Read-only, and first: the kind of show decides what every section below means (an RSS
      // show's downloads are the device's alone; an ABS show's also answer to the server).
      if let sourceSection = model.sourceSection {
        Section {
          ForEach(sourceSection.rows) { row in
            sourceRow(row)
          }
        } header: {
          Text(PodcastShowSourcePresentation.sectionHeader)
        } footer: {
          Text(sourceSection.footer)
        }
      }

      Section {
        Picker("Automatic Downloads", selection: autoDownloadOverrideBinding) {
          ForEach(PodcastShowSettingsViewPresentation.autoDownloadOverrideChoices, id: \.self) {
            choice in
            Text(
              PodcastDownloadCopy.autoDownloadOverrideLabel(
                choice, effectiveIsEnabled: model.effective.isEnabled)
            )
            .tag(choice)
          }
        }
        .pickerStyle(.menu)
      } footer: {
        Text(
          "Default uses the download settings for this show’s source. Choose On or Off to override them for this show.")
      }

      Section {
        Picker("Keep Latest", selection: keepLatestOverrideBinding) {
          ForEach(PodcastShowSettingsViewPresentation.keepLatestOverrideChoices, id: \.self) {
            choice in
            Text(
              PodcastDownloadCopy.keepLatestOverrideLabel(
                choice, effectiveCount: model.effective.keepLatestCount)
            )
            .tag(choice)
          }
        }
        .pickerStyle(.menu)
      }

      Section {
        Picker("Delete Played Episodes", selection: deleteAfterPlayedOverrideBinding) {
          ForEach(PodcastShowSettingsViewPresentation.deleteAfterPlayedOverrideChoices, id: \.self) { choice in
            Text(
              PodcastDownloadCopy.deleteAfterPlayedOverrideLabel(
                choice, effectiveValue: model.effective.deleteAfterPlayed)
            )
            .tag(choice)
          }
        }
        .pickerStyle(.menu)
      }

      if let includeInLatest = model.includeInLatest {
        Section {
          Toggle(
            PodcastShowSettingsViewPresentation.includeInLatestTitle,
            isOn: Binding(
              get: { includeInLatest },
              set: { enabled in Task { await model.setIncludeInLatest(enabled) } })
          )
          .tint(AppChrome.brandTint)
        } footer: {
          Text(PodcastShowSettingsViewPresentation.includeInLatestFooter)
        }
      }

      if model.notificationOverride != nil {
        Section {
          Picker("New Episode Notifications", selection: notificationOverrideBinding) {
            Text("Default").tag(RSSNotificationOverride.inherit)
            Text("On").tag(RSSNotificationOverride.enabled)
            Text("Off").tag(RSSNotificationOverride.disabled)
          }
          .pickerStyle(.menu)
          if model.notificationOverride == .enabled,
            let notificationModel,
            notificationModel.requiresSystemSettingsRecovery
          {
            Button("Open System Settings") { SystemSettingsLink.open() }
          }
        } footer: {
          Text("Controls alerts for this show independently of Latest Episodes.")
        }
      }

      if model.supportsFeedCredentials {
        Section {
          TextField(
            PodcastShowSettingsViewPresentation.privateFeedUsernameLabel,
            text: Binding(
              get: { model.feedCredentialUsername },
              set: { model.feedCredentialUsername = $0 })
          )
          .textContentType(.username)
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled()
          SecureField(
            PodcastShowSettingsViewPresentation.privateFeedPasswordLabel,
            text: Binding(
              get: { model.feedCredentialPassword },
              set: { model.feedCredentialPassword = $0 })
          )
          .textContentType(.password)
          Button(PodcastShowSettingsViewPresentation.privateFeedSaveLabel) {
            model.requestSaveFeedCredential()
          }
          .disabled(model.feedCredentialPassword.isEmpty)
          if model.hasFeedCredential {
            Button(
              PodcastShowSettingsViewPresentation.privateFeedRemoveLabel, role: .destructive
            ) {
              model.requestRemoveFeedCredential()
            }
          }
        } header: {
          Text(PodcastShowSettingsViewPresentation.privateFeedSectionHeader)
        } footer: {
          Text(PodcastShowSettingsViewPresentation.privateFeedFooter)
        }
      }

      // The show's playback speed, in the same inherit-first shape as the three device overrides
      // above. One speed for the whole feed, inherited by every episode.
      Section {
        Picker(PlaybackRateScopePresentation.showSpeedRowTitle, selection: speedOverrideBinding) {
          ForEach(
            PlaybackRateScopePresentation.showSpeedChoices(
              encodedPresets: encodedRatePresets,
              currentRate: currentSpeedOverride),
            id: \.self
          ) { choice in
            Text(
              PlaybackRateScopePresentation.showSpeedLabel(
                choice, defaultRate: playbackRate.globalDefaultRate)
            )
            .tag(choice)
          }
        }
        .pickerStyle(.menu)
        // Beside the speed, in the same inherit-first shape and the speed card's order.
        if let showPlaybackEffects {
          ShowVoiceBoostPicker(itemID: itemID, access: showPlaybackEffects)
          ShowTrimSilencesPicker(itemID: itemID, access: showPlaybackEffects)
        }
      }

      if let editor = model.serverSettingsEditor {
        serverEditorSection(editor)
      } else if let serverSettings = model.serverSettings {
        Section {
          ForEach(serverSettings.rows) { row in
            LabeledContent(row.label, value: row.value)
              .accessibilityElement(children: .combine)
          }
        } header: {
          Text(PodcastShowSettingsViewPresentation.serverSectionHeader)
        } footer: {
          Text(serverSettings.footer)
        }
      } else if let notice = model.serverCopiesNotice {
        // A followed feed with several server copies has no editor to offer.
        Section {
          Text(notice)
            .foregroundStyle(.secondary)
        } header: {
          Text(PodcastShowSettingsViewPresentation.serverSectionHeader)
        }
      }
    }
    .formStyle(.grouped)
  }

  /// ADR 0017. Every control reads the model's value and writes through its async intent. The
  /// model shows the choice while it is being written and restores the stored value if the write
  /// fails. Controls are disabled while a write is in flight, and the message is an inline
  /// secondary row rather than the alert `actionErrorMessage` raises.
  @ViewBuilder
  private func serverEditorSection(_ editor: PodcastServerSettingsEditor) -> some View {
    Section {
      if let downloadsNewEpisodes = editor.downloadsNewEpisodes {
        Toggle(
          PodcastServerSettingsEditor.downloadsNewEpisodesLabel,
          isOn: Binding(
            get: { downloadsNewEpisodes },
            set: { enabled in Task { await model.setServerDownloadsNewEpisodes(enabled) } })
        )
        .tint(AppChrome.brandTint)
      }
      if let schedule = editor.schedule {
        Picker(
          schedule.label,
          selection: Binding<PodcastServerScheduleChoice?>(
            get: { schedule.selection },
            set: { choice in
              // A stored custom schedule is display-only; only a preset is sent.
              guard case .preset(let preset)? = choice else { return }
              Task { await model.setServerSchedule(preset) }
            })
        ) {
          ForEach(schedule.choices) { choice in
            Text(choice.label).tag(Optional(choice.value))
          }
        }
        .pickerStyle(.menu)
      }
      if let limit = editor.newEpisodeLimit {
        countPicker(limit) { count in await model.setServerNewEpisodeLimit(count) }
      }
      if let retention = editor.retention {
        countPicker(retention) { count in await model.setServerKeepLimit(count) }
      }
      if model.isSavingServerSettings {
        HStack(spacing: 8) {
          ProgressView()
          Text("Saving on the server")
            .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
      }
      if let message = model.serverSettingsMessage {
        Text(message)
          .font(.footnote)
          .foregroundStyle(.secondary)
      }
    } header: {
      Text(PodcastShowSettingsViewPresentation.serverSectionHeader)
    } footer: {
      Text(editor.footer)
    }
    .disabled(model.isSavingServerSettings)
  }

  private func countPicker(
    _ picker: PodcastServerSettingsPicker<Int>,
    send: @escaping @MainActor (Int) async -> Void
  ) -> some View {
    Picker(
      picker.label,
      selection: Binding<Int>(
        get: { picker.selection ?? 0 },
        set: { count in Task { await send(count) } })
    ) {
      ForEach(picker.choices) { choice in
        Text(choice.label).tag(choice.value)
      }
    }
    .pickerStyle(.menu)
  }

  /// A feed URL is too long for a trailing value column, so it stacks under its label; the source
  /// row is a short word and reads as a plain labeled value like the server rows below.
  @ViewBuilder
  private func sourceRow(_ row: PodcastShowSourceRow) -> some View {
    switch row.field {
    case .source:
      LabeledContent(row.label, value: row.value)
        .accessibilityElement(children: .combine)
    case .feedURL:
      VStack(alignment: .leading, spacing: 4) {
        Text(row.label)
        Text(row.value)
          .font(.footnote)
          .foregroundStyle(.secondary)
          .textSelection(.enabled)
      }
      .accessibilityElement(children: .combine)
    }
  }

  private var currentSpeedOverride: Double? {
    // The stored speed, not the effective one: under a Focus the effective rate is the Focus's,
    // and this picker edits what is stored.
    playbackRate.overrideRate(forItemID: itemID)
  }

  /// `nil` means inherit, as the absence of a row does in the store.
  private var speedOverrideBinding: Binding<Double?> {
    Binding(
      get: { currentSpeedOverride },
      set: { newValue in
        if let newValue {
          playbackRate.setOverride(newValue, itemID: itemID)
        } else {
          playbackRate.clearOverride(itemID: itemID)
        }
      }
    )
  }

  private var autoDownloadOverrideBinding: Binding<PodcastShowAutoDownloadOverride> {
    Binding(
      get: { model.autoDownloadOverride },
      set: { newValue in Task { await model.setAutoDownloadOverride(newValue) } }
    )
  }

  private var keepLatestOverrideBinding: Binding<Int?> {
    Binding(
      get: { model.keepLatestOverride },
      set: { newValue in Task { await model.setKeepLatestOverride(newValue) } }
    )
  }

  private var deleteAfterPlayedOverrideBinding: Binding<Bool?> {
    Binding(
      get: { model.deleteAfterPlayedOverride },
      set: { newValue in Task { await model.setDeleteAfterPlayedOverride(newValue) } }
    )
  }

  private var notificationOverrideBinding: Binding<RSSNotificationOverride> {
    Binding(
      get: { model.notificationOverride ?? .inherit },
      set: { newValue in model.requestNotificationOverride(newValue) }
    )
  }
}
