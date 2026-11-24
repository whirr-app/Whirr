import ABSApi
import AppModel
import DesignSystem
import Foundation
import Persistence
import SwiftUI
import SyncEngine

/// A compact, self-hoster-focused settings surface; connection tutorials stay in project
/// documentation. Licence acknowledgements are the exception: MIT and BSD-3-Clause require the
/// notice to ship with the binary, so About links to them.
///
/// Logout routes through `SettingsModel.logoutState`; every logout string comes from
/// `AppModel.SettingsCopy`, never hardcoded here.
struct SettingsView<
  ManageDownloadsDestination: View, ResolutionCenterDestination: View
>: View {
  let onLoggedOut: () -> Void
  /// The scheme the presenting shell is showing. See `AppAppearance.colorScheme(ambient:)`:
  /// Settings applies a concrete scheme to its content, so "System" must arrive already resolved.
  let ambientColorScheme: ColorScheme

  /// Not `@AppStorage` (see `AppAppearanceStore`): this view is a tab root rebuilt whenever the
  /// shell's body runs, and `@AppStorage` would make every `UserDefaults` write another trigger.
  private let appearanceStore = AppAppearanceStore.shared
  private let account: any AccountLifecycle
  private let logoutPreflight: (any LogoutPreflighting)?
  private let serverAccountReading: any ServerAccountReading
  private let serverAddressesModel: ServerAddressesModel?
  private let librarySelectionReading: any LibrarySelectionReading
  private let nativePodcastSubscriptionsReading: any NativePodcastSubscriptionsReading
  private let nativePodcastSubscriptionsWriting: any NativePodcastSubscriptionsWriting
  private let podcastNotificationSettingsModel: PodcastNotificationSettingsModel
  private let subscriptionOPMLModel: PodcastSubscriptionOPMLModel
  private let librarySelectionWriting: any LibrarySelectionWriting
  private let sync: any SyncCoordinating
  private let downloadPreferences: any DownloadPreferences
  private let artworkCacheAccess: any ArtworkCacheAccess
  /// The shell's shared artwork pipeline, passed to Settings › Apple Watch › On Apple Watch.
  /// Optional so Settings still builds in tests and harnesses that compose no artwork.
  private let coverClient: (any ArtworkServing)?
  private let storageReading: any StorageReading
  private let deviceStorageCapacityReading: any DeviceStorageCapacityReading
  private let resolutionCenterAccess: any ResolutionCenterAccess
  /// Passed through to `PodcastSettingsView`/`PodcastShowSettingsView`. Defaults to the `NoOp`
  /// boundary so call sites without podcast composition keep compiling.
  private let podcastSettingsReading: any PodcastSettingsReading
  private let nativePodcastSettingsAccess: (any (PodcastSettingsReading & PodcastSettingsWriting))?
  /// Passed through to a show's speed row.
  private let playbackRate: PlaybackRateCoordinator
  private let playback: PlaybackModel?
  private let podcastSettingsWriting: any PodcastSettingsWriting
  private let podcastReading: any PodcastReading
  private let podcastRefreshing: any PodcastRefreshing
  private let nativeFeedManaging: any NativeFeedManaging
  /// Passed straight down to Show Settings' server automation editor (ADR 0017).
  private let serverPodcastMutationCapabilityReading: any ServerPodcastMutationCapabilityReading
  private let serverPodcastAutomationSettingsWriting: any ServerPodcastAutomationSettingsWriting
  /// The two destinations Settings › Downloads pushes. The shell builds them (both need
  /// shell-owned dependencies). Every row here must push a view rather than a route, because the
  /// settings stack's `path` does not describe a view-pushed screen. See `DownloadSettingsView`.
  private let manageDownloadsDestination: () -> ManageDownloadsDestination
  private let resolutionCenterDestination: () -> ResolutionCenterDestination
  /// Settings › About › Report a Problem reads through these. Default to no-op sources and a
  /// scratch directory for the harness; the shell passes the real ones.
  private let problemReportSources: ProblemReportSources
  private let problemReportExportDirectory: URL

  // This view lives inside a `Tab { }` non-escaping `@ViewBuilder`, so it is rebuilt on every
  // `LibraryShellView` body evaluation, whether or not Settings is on screen. Building
  // `SettingsModel` in `init` would open a `DownloadPreferences.changes` subscription each time.
  // See `DeferredModel`.
  @State private var deferredSettings = DeferredModel<SettingsModel>()
  @State private var deferredServerAccount = DeferredModel<ServerAccountSettingsModel>()
  @State private var deferredResolution = DeferredModel<ResolutionCenterModel>()
  @State private var deferredArtworkCache = DeferredModel<ArtworkCacheModel>()
  @State private var deferredLibrarySelection = DeferredModel<LibrarySelectionSettingsModel>()
  @State private var nativeSubscriptionsEnabled = true
  private let adSkip = AdSkipSettingsModel.shared

  private var settingsModel: SettingsModel {
    deferredSettings.resolve {
      SettingsModel(
        downloadPreferences: downloadPreferences,
        account: account,
        storageReading: storageReading,
        deviceStorageCapacityReading: deviceStorageCapacityReading,
        logoutPreflight: logoutPreflight)
    }
  }

  private var serverAccountModel: ServerAccountSettingsModel {
    deferredServerAccount.resolve {
      ServerAccountSettingsModel(reading: serverAccountReading)
    }
  }

  private var resolutionModel: ResolutionCenterModel {
    deferredResolution.resolve { ResolutionCenterModel(access: resolutionCenterAccess) }
  }

  private var artworkCacheModel: ArtworkCacheModel {
    deferredArtworkCache.resolve { ArtworkCacheModel(access: artworkCacheAccess) }
  }

  private var librarySelectionModel: LibrarySelectionSettingsModel {
    deferredLibrarySelection.resolve {
      LibrarySelectionSettingsModel(
        reading: librarySelectionReading, writing: librarySelectionWriting, sync: sync)
    }
  }

  init(
    account: any AccountLifecycle, downloadPreferences: any DownloadPreferences,
    logoutPreflight: (any LogoutPreflighting)? = nil,
    resolutionCenterAccess: any ResolutionCenterAccess,
    serverAccountReading: any ServerAccountReading = NoOpServerAccountReading(),
    serverAddressesModel: ServerAddressesModel? = nil,
    librarySelectionReading: any LibrarySelectionReading = NoOpLibrarySelectionStore(),
    nativePodcastSubscriptionsReading: any NativePodcastSubscriptionsReading =
      NoOpNativePodcastSubscriptionsReading(),
    nativePodcastSubscriptionsWriting: any NativePodcastSubscriptionsWriting =
      NoOpNativePodcastSubscriptionsWriting(),
    podcastNotificationSettingsModel: PodcastNotificationSettingsModel? = nil,
    subscriptionOPMLModel: PodcastSubscriptionOPMLModel,
    librarySelectionWriting: any LibrarySelectionWriting = NoOpLibrarySelectionStore(),
    sync: any SyncCoordinating = SetupSyncCoordinator(),
    artworkCacheAccess: any ArtworkCacheAccess = NoOpArtworkCacheAccess(),
    coverClient: (any ArtworkServing)? = nil,
    storageReading: any StorageReading = NoOpStorageReading(),
    deviceStorageCapacityReading: any DeviceStorageCapacityReading =
      NoOpDeviceStorageCapacityReading(),
    playbackRate: PlaybackRateCoordinator, playback: PlaybackModel? = nil,
    podcastSettingsReading: any PodcastSettingsReading = NoOpPodcastSettingsAccess(),
    nativePodcastSettingsAccess: (any (PodcastSettingsReading & PodcastSettingsWriting))? = nil,
    podcastSettingsWriting: any PodcastSettingsWriting = NoOpPodcastSettingsAccess(),
    podcastReading: any PodcastReading = NoOpPodcastReading(),
    podcastRefreshing: any PodcastRefreshing = NoOpPodcastRefreshing(),
    nativeFeedManaging: any NativeFeedManaging = NoOpNativeFeedManaging(),
    serverPodcastMutationCapabilityReading: any ServerPodcastMutationCapabilityReading =
      NoOpServerPodcastMutationCapabilityReading(),
    serverPodcastAutomationSettingsWriting: any ServerPodcastAutomationSettingsWriting =
      NoOpServerPodcastAutomationSettingsWriting(),
    ambientColorScheme: ColorScheme = .light,
    problemReportSources: ProblemReportSources = .noOp,
    problemReportExportDirectory: URL = FileManager.default.temporaryDirectory
      .appendingPathComponent("Diagnostics", isDirectory: true),
    @ViewBuilder manageDownloadsDestination: @escaping () -> ManageDownloadsDestination,
    @ViewBuilder resolutionCenterDestination: @escaping () -> ResolutionCenterDestination,
    onLoggedOut: @escaping () -> Void
  ) {
    self.onLoggedOut = onLoggedOut
    self.ambientColorScheme = ambientColorScheme
    self.account = account
    self.logoutPreflight = logoutPreflight
    self.serverAccountReading = serverAccountReading
    self.serverAddressesModel = serverAddressesModel
    self.librarySelectionReading = librarySelectionReading
    self.nativePodcastSubscriptionsReading = nativePodcastSubscriptionsReading
    self.nativePodcastSubscriptionsWriting = nativePodcastSubscriptionsWriting
    self.podcastNotificationSettingsModel =
      podcastNotificationSettingsModel
      ?? PodcastNotificationSettingsModel(
        preference: DisabledRSSNotificationIntent(),
        authorizer: NoOpRSSLocalNotificationAuthorizer())
    self.subscriptionOPMLModel = subscriptionOPMLModel
    self.librarySelectionWriting = librarySelectionWriting
    self.sync = sync
    self.downloadPreferences = downloadPreferences
    self.artworkCacheAccess = artworkCacheAccess
    self.coverClient = coverClient
    self.storageReading = storageReading
    self.deviceStorageCapacityReading = deviceStorageCapacityReading
    self.resolutionCenterAccess = resolutionCenterAccess
    self.playbackRate = playbackRate
    self.playback = playback
    self.podcastSettingsReading = podcastSettingsReading
    self.nativePodcastSettingsAccess = nativePodcastSettingsAccess
    self.podcastSettingsWriting = podcastSettingsWriting
    self.podcastReading = podcastReading
    self.podcastRefreshing = podcastRefreshing
    self.nativeFeedManaging = nativeFeedManaging
    self.serverPodcastMutationCapabilityReading = serverPodcastMutationCapabilityReading
    self.serverPodcastAutomationSettingsWriting = serverPodcastAutomationSettingsWriting
    self.manageDownloadsDestination = manageDownloadsDestination
    self.resolutionCenterDestination = resolutionCenterDestination
    self.problemReportSources = problemReportSources
    self.problemReportExportDirectory = problemReportExportDirectory
  }

  var body: some View {
    Form {
      ForEach(SettingsSection.allCases, id: \.self) { section in
        switch section {
        case .appearance:
          appearanceSection
        case .destinations:
          destinationsSection
        case .about:
          aboutSection
        }
      }
    }
    .formStyle(.grouped)
    .scrollContentBackground(.hidden)
    .background(WhirrColorToken.groupedSurface.color.ignoresSafeArea())
    .frame(maxWidth: 620)
    .frame(maxWidth: .infinity)
    // Keep this downstream as an environment value. A `preferredColorScheme` travels upward into
    // the presentation host, and removing it at the commit point of a swipe-down makes the host
    // re-resolve system chrome mid-dismissal. The environment value still repaints this open
    // Settings stack as soon as the picker changes.
    .environment(\.colorScheme, contentColorScheme)
    // The environment never reaches the navigation bar, which is UIKit and keeps the scheme the
    // sheet was presented with: without this the title and close button stayed light after
    // Light then Dark. The bar's own preference stops at the navigation stack, below the host.
    .toolbarColorScheme(contentColorScheme, for: .navigationBar)
    .navigationTitle("Settings")
    .navigationBarTitleDisplayMode(.inline)
    .task {
      await resolutionModel.refresh()
      await librarySelectionModel.load()
    }
    // The setting can change underneath the screen through iCloud; the first value reads the
    // speech model's state. The stream fires for every defaults write, so only a change counts.
    .task {
      var last: Bool?
      for await enabled in AdSkipPreference.changes() where enabled != last {
        last = enabled
        await adSkip.refresh()
      }
    }
    // Keeps the Reduce Ads row's status live while Settings is open, not only on its own page.
    .task { await adSkip.followProgress() }
    .task {
      for await enabled in nativePodcastSubscriptionsReading.observeEnabled() {
        nativeSubscriptionsEnabled = enabled
      }
    }
  }

  // MARK: - Appearance

  private var contentColorScheme: ColorScheme {
    appearanceStore.appearance.colorScheme(ambient: ambientColorScheme)
  }

  private var appearanceSection: some View {
    Section(SettingsSection.appearance.header ?? "") {
      Picker("Theme", selection: appearanceStore.selection) {
        ForEach(AppAppearance.allCases) { appearance in
          Text(appearance.displayName)
            .tag(appearance)
        }
      }
      .pickerStyle(.menu)
    }
  }

  // MARK: - Destinations

  private var destinationsSection: some View {
    Section {
      ForEach(SettingsDestination.allCases, id: \.self) { destination in
        switch destination {
        case .playback:
          NavigationLink {
            PlaybackSettingsView(playbackRate: playbackRate)
          } label: {
            settingsRow(
              title: "Playback",
              detail: SettingsCopy.playbackRowDetail,
              systemImage: "play.circle"
            )
          }
        case .podcasts:
          NavigationLink {
            PodcastSettingsView(
              reading: podcastSettingsReading, writing: podcastSettingsWriting,
              nativeSettingsAccess: nativePodcastSettingsAccess,
              podcastReading: podcastReading, podcastRefreshing: podcastRefreshing,
              playbackRate: playbackRate, playback: playback,
              nativeSubscriptionsReading: nativePodcastSubscriptionsReading,
              nativeSubscriptionsWriting: nativePodcastSubscriptionsWriting,
              notificationModel: podcastNotificationSettingsModel,
              nativeFeedManaging: nativeFeedManaging,
              subscriptionOPMLModel: subscriptionOPMLModel,
              serverMutationCapability: serverPodcastMutationCapabilityReading,
              automationSettingsWriting: serverPodcastAutomationSettingsWriting)
          } label: {
            settingsRow(
              title: "Podcasts", detail: SettingsCopy.podcastsRowDetail,
              systemImage: "antenna.radiowaves.left.and.right")
          }
          // Greys out on the same positive evidence that hides the Podcasts tab: nothing here
          // applies without an included podcast library on this device.
          .disabled(
            SettingsViewPresentation.isPodcastsDestinationEnabled(
              snapshot: librarySelectionModel.snapshot,
              nativeSubscriptionsEnabled: nativeSubscriptionsEnabled) == false
          )
          .accessibilityIdentifier(ScreenAccessibilityID.settingsPodcastsLink)
        case .reduceAds:
          if adSkip.isVisible {
            NavigationLink {
              AdSkipSettingsView(model: adSkip)
            } label: {
              settingsRow(
                title: AdSkipSettingsCopy.title,
                detail: AdSkipSettingsCopy.rowDetail(
                  isEnabled: adSkip.isEnabled, asset: adSkip.asset, progress: adSkip.progress,
                  pauseReason: adSkip.pauseReason),
                systemImage: "forward.end",
                trailingValue: adSkip.isEnabled ? AdSkipSettingsCopy.on : AdSkipSettingsCopy.off)
            }
            .accessibilityIdentifier(ScreenAccessibilityID.settingsReduceAdsLink)
          }
        case .downloads:
          NavigationLink {
            DownloadSettingsView(
              model: settingsModel, resolution: resolutionModel,
              artworkCache: artworkCacheModel,
              manageDownloadsDestination: manageDownloadsDestination,
              resolutionCenterDestination: resolutionCenterDestination)
          } label: {
            // The badge also shows here so an unresolved conflict or paused transfer is visible
            // without opening the screen.
            settingsRow(
              title: SettingsCopy.downloadsRowTitle,
              detail: SettingsCopy.downloadsRowDetail,
              systemImage: "arrow.down.circle",
              badgeCount: resolutionModel.openCount)
          }
          .accessibilityIdentifier(ScreenAccessibilityID.settingsDownloadsLink)
        case .homeScreen:
          NavigationLink {
            HomeSettingsView()
          } label: {
            settingsRow(
              title: SettingsCopy.homeScreenRowTitle, detail: SettingsCopy.homeScreenRowDetail,
              systemImage: "house")
          }
          .accessibilityIdentifier(ScreenAccessibilityID.settingsHomeScreenLink)
        case .libraries:
          NavigationLink {
            LibrarySelectionSettingsView(model: librarySelectionModel)
          } label: {
            settingsRow(
              title: SettingsCopy.librarySelectionTitle,
              detail: SettingsCopy.librarySelectionRowDetail,
              systemImage: "books.vertical",
              trailingValue: librarySelectionModel.selectionRowValue,
              trailingValuePlaceholder: SettingsCopy.librarySelectionCountPlaceholder)
          }
          .accessibilityIdentifier(ScreenAccessibilityID.settingsLibrariesLink)
        case .appleWatch:
          if WatchCompanionRuntime.shared.setupModel.offersSettingsEntry {
            NavigationLink {
              WatchSetupView(model: WatchCompanionRuntime.shared.setupModel, coverClient: coverClient)
            } label: {
              settingsRow(
                title: "Apple Watch", detail: WatchCompanionRuntime.shared.setupModel.linkStatus.rowLabel,
                systemImage: "applewatch")
            }
            .accessibilityIdentifier("settings.appleWatch")
          }
        case .serverAccount:
          NavigationLink {
            ServerAccountSettingsView(
              model: serverAccountModel, serverAddressesModel: serverAddressesModel,
              onLogout: performLogout)
          } label: {
            settingsRow(
              title: ServerAccountSettingsCopy.destinationTitle,
              detail: ServerAccountSettingsCopy.destinationDetail,
              systemImage: "server.rack")
          }
          .accessibilityIdentifier(ScreenAccessibilityID.settingsServerAccountLink)
        }
      }
    }
  }

  // MARK: - Logout

  /// Runs the full removal for whichever screen carries the Log Out button, and reports whether
  /// local removal completed so that screen can raise its own retry alert.
  ///
  /// A retry after failure stages nothing and confirms straight from `.failed` (`requestLogout()`
  /// is a no-op unless `.idle`). Both halves must use one `SettingsModel`: under the iOS 27 SDK a
  /// plain-default `@State` is a `LazyState` that re-runs on every read until SwiftUI attaches a
  /// location, so two reads could stage and confirm on different models.
  @discardableResult
  func performLogout() async -> Bool {
    let model = settingsModel
    model.requestLogout()
    guard await model.confirmLogout() else { return false }
    onLoggedOut()
    return true
  }

  // MARK: - Metadata

  @ViewBuilder
  private var aboutSection: some View {
    Section {
      NavigationLink {
        ProblemReportView(
          sources: problemReportSources, exportDirectory: problemReportExportDirectory)
      } label: {
        settingsRow(
          title: ProblemReportCopy.rowTitle,
          detail: ProblemReportCopy.rowDetail,
          systemImage: "ladybug")
      }
      NavigationLink {
        AcknowledgementsView()
      } label: {
        settingsRow(
          title: SettingsCopy.acknowledgementsRowTitle,
          detail: SettingsCopy.acknowledgementsRowDetail,
          systemImage: "doc.text")
      }
    }

    HStack {
      Text("Whirr")
      Spacer()
      Text(appVersion)
    }
    .font(.footnote)
    .foregroundStyle(WhirrColorToken.textSecondary.color)
    .listRowBackground(Color.clear)
    .listRowSeparator(.hidden)
    .accessibilityElement(children: .combine)
    .accessibilityLabel("Whirr, version \(appVersion)")
  }

  private func settingsRow(
    title: String,
    detail: String,
    systemImage: String,
    badgeCount: Int = 0,
    trailingValue: String? = nil,
    trailingValuePlaceholder: String? = nil
  ) -> some View {
    SettingsNavigationRow(
      title: title, detail: detail, systemImage: systemImage, badgeCount: badgeCount,
      trailingValue: trailingValue, trailingValuePlaceholder: trailingValuePlaceholder)
  }

  private var appVersion: String {
    let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
    switch (version, build) {
    case (.some(let version), .some(let build)): return "\(version) (\(build))"
    case (.some(let version), .none): return version
    default: return "Development"
    }
  }
}
