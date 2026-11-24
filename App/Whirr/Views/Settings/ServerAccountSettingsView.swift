import AppModel
import DesignSystem
import Persistence
import SwiftUI
import SyncEngine

/// Settings › Server & Account. Durable rows remain visible when the live profile cannot be read;
/// the model, rather than this view, owns the loading and failure decisions.
struct ServerAccountSettingsView: View {
  let model: ServerAccountSettingsModel
  var serverAddressesModel: ServerAddressesModel? = nil
  /// Performs the confirmed removal, reporting whether local removal completed. The Settings root
  /// owns the post-logout handoff, but the alerts live on this screen: UIKit drops an alert
  /// attached to the covered root of a `NavigationStack`.
  var onLogout: (() async -> Bool)? = nil

  @State private var isConfirmingLogout = false
  @State private var isShowingLogoutFailure = false
  @State private var isLoggingOut = false

  var body: some View {
    Form {
      content
    }
    .alert(SettingsCopy.logoutTitle, isPresented: $isConfirmingLogout) {
      Button(SettingsCopy.cancel, role: .cancel) {}
      Button(SettingsCopy.confirmLogout, role: .destructive) {
        Task { await attemptLogout() }
      }
    } message: {
      Text(SettingsCopy.logoutMessage)
    }
    .alert(SettingsCopy.logoutFailedTitle, isPresented: $isShowingLogoutFailure) {
      Button(SettingsCopy.cancel, role: .cancel) {}
      Button(SettingsCopy.retryLogout) {
        Task { await attemptLogout() }
      }
    } message: {
      Text(SettingsCopy.logoutFailedMessage)
    }
    .formStyle(.grouped)
    .scrollContentBackground(.hidden)
    .background(WhirrColorToken.groupedSurface.color.ignoresSafeArea())
    .navigationTitle(ServerAccountSettingsCopy.destinationTitle)
    .navigationBarTitleDisplayMode(.inline)
    .task {
      await model.load()
    }
  }

  @ViewBuilder
  private var content: some View {
    switch model.loadState {
    case .loading:
      loadingSection
    case .failed:
      failedSection
    case .loaded:
      if let durableSettings = model.durableSettings {
        serverSection(durableSettings)
        if let serverAddressesModel {
          Section {
            NavigationLink {
              ServerAddressesView(model: serverAddressesModel)
            } label: {
              Label(ServerAddressesCopy.listTitle, systemImage: "server.rack")
            }
            .accessibilityIdentifier(ScreenAccessibilityID.serverAddressesLink)
          }
        }
        connectionSection(durableSettings)
        accountSection(durableSettings)
        headersSection(durableSettings)
      } else {
        failedSection
      }
    }
    logoutSection
  }

  /// Shown in every load state: logging out must stay reachable when the profile cannot be read.
  ///
  /// No glyph. The rows above pair an icon with a destination; this one is an action.
  @ViewBuilder
  private var logoutSection: some View {
    if onLogout != nil {
      Section {
        Button(SettingsCopy.confirmLogout, role: .destructive) { isConfirmingLogout = true }
          .disabled(isLoggingOut)
          .accessibilityIdentifier(ScreenAccessibilityID.settingsLogoutButton)
          .accessibilityHint("Removes this account and its library data from this device.")
      }
    }
  }

  /// Serialised behind `isLoggingOut` so a second attempt cannot race the first and raise the
  /// failure alert. A failure here is the only thing that opens the retry alert.
  private func attemptLogout() async {
    guard let onLogout, isLoggingOut == false else { return }
    isLoggingOut = true
    let removed = await onLogout()
    isLoggingOut = false
    if removed == false {
      isShowingLogoutFailure = true
    }
  }

  private var loadingSection: some View {
    Section {
      HStack(spacing: WhirrSpacing.small) {
        ProgressView()
        Text(ServerAccountSettingsCopy.loading)
      }
    }
  }

  private var failedSection: some View {
    Section {
      Label {
        Text(ServerAccountSettingsCopy.failedMessage)
      } icon: {
        Image(systemName: "exclamationmark.triangle")
      }

      Button(ServerAccountSettingsCopy.tryAgain) {
        Task { await model.load() }
      }
    } header: {
      Text(ServerAccountSettingsCopy.failedTitle)
    }
  }

  private func serverSection(_ durableSettings: ServerAccountDurableSettings) -> some View {
    Section(ServerAccountSettingsCopy.serverHeader) {
      valueRow(
        title: ServerAccountSettingsCopy.serverVersion,
        value: durableSettings.serverVersion)
    }
  }

  private func connectionSection(_ durableSettings: ServerAccountDurableSettings) -> some View {
    Section {
      valueRow(
        title: ServerAccountSettingsCopy.liveProfile,
        value: ServerAccountSettingsCopy.profileStatus(for: model.profileState))

      valueRow(
        title: ServerAccountSettingsCopy.librarySync,
        value: ServerAccountSettingsCopy.syncStatus(for: durableSettings.syncStatus))

      valueRow(
        title: ServerAccountSettingsCopy.oldestLibraryCompletion,
        value: durableSettings.syncStatus.lastCompletedAt?.formatted(
          date: .abbreviated, time: .shortened) ?? ServerAccountSettingsCopy.noCompletedLibrary)
    } header: {
      Text(ServerAccountSettingsCopy.connectionHeader)
    } footer: {
      VStack(alignment: .leading, spacing: WhirrSpacing.xSmall) {
        if model.profileState == .unavailable {
          Text(ServerAccountSettingsCopy.profileUnavailableMessage)
        }
        Text(ServerAccountSettingsCopy.syncFooter)
      }
    }
  }

  @ViewBuilder
  private func accountSection(_ durableSettings: ServerAccountDurableSettings) -> some View {
    Section(ServerAccountSettingsCopy.accountHeader) {
      switch model.profileState {
      case .loading:
        HStack {
          Text(ServerAccountSettingsCopy.liveProfile)
          Spacer()
          ProgressView()
        }
      case .available:
        if let profile = model.profile {
          if let username = profile.username {
            valueRow(title: ServerAccountSettingsCopy.username, value: username)
          }
          if let type = profile.type {
            valueRow(title: ServerAccountSettingsCopy.accountType, value: type)
          }
        }
      case .unavailable:
        Text(ServerAccountSettingsCopy.profileUnavailableMessage)
          .foregroundStyle(WhirrColorToken.textSecondary.color)
      }
    }
  }

  private func headersSection(_ durableSettings: ServerAccountDurableSettings) -> some View {
    Section {
      valueRow(
        title: ServerAccountSettingsCopy.headersInPlay,
        value: durableSettings.customHeaders.count == 0
          ? ServerAccountSettingsCopy.noHeaders
          : "\(durableSettings.customHeaders.count)")

      // Field names only. The values are proxy credentials and never reach a rendered surface
      // (SECURITY.md), so the boundary exposes names and a count rather than pairs.
      ForEach(durableSettings.customHeaders.names, id: \.self) { name in
        Text(name)
          .font(.caption)
          .foregroundStyle(WhirrColorToken.textSecondary.color)
      }
    } header: {
      Text(ServerAccountSettingsCopy.headersHeader)
    } footer: {
      Text(ServerAccountSettingsCopy.headersFooter)
    }
  }

  private func valueRow(title: String, value: String) -> some View {
    HStack {
      Text(title)
      Spacer()
      Text(value)
        .foregroundStyle(WhirrColorToken.textSecondary.color)
        .multilineTextAlignment(.trailing)
    }
    .accessibilityElement(children: .combine)
  }
}
