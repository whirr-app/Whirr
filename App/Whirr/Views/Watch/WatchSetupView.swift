import ABSApi
import AuthenticationServices
import DesignSystem
import Persistence
import SwiftUI

/// The phone's Apple Watch status screen. It says whether listening on the Watch works and, if not,
/// why; the setup form appears only when the Watch holds no account or the person chooses to
/// reconnect. The Watch receives its own login after the password is confirmed here, or after a
/// second single sign-on for an OpenID account; it never presents a credential field of its own.
struct WatchSetupView: View {
  @Bindable var model: WatchPhoneSetupModel
  /// The shell's shared artwork pipeline, passed to On Apple Watch. Optional so a preview or
  /// harness without an artwork composition still builds the screen.
  var coverClient: (any ArtworkServing)? = nil
  @Environment(\.watchCopies) private var watchCopies
  /// Default on, so an install that never opens this screen keeps the documented behaviour.
  @AppStorage(WatchEpisodeSendPreferences.removesPlayedEpisodesKey)
  private var removesPlayedEpisodes = true
  @State private var password = ""
  @State private var confirmingReconnect = false
  @FocusState private var passwordFocused: Bool
  @Environment(\.webAuthenticationSession) private var webAuthenticationSession

  var body: some View {
    let status = model.linkStatus
    Form {
      if status != .unbound {
        accountSection(status)
      }
      statusSection(status)
      actionSection(status)

      if model.progress > 0, model.progress < 1 {
        Section {
          ProgressView(value: model.progress)
        }
      }

      if let message = model.message, status.showsSetupForm || status == .awaitingReceipt {
        Section {
          Label(message, systemImage: "info.circle")
            .foregroundStyle(.secondary)
        }
      }

      if let error = model.error, !model.isBlockedOnInstall {
        Section {
          Label(error, systemImage: "exclamationmark.triangle")
            .foregroundStyle(.red)
        }
      }

      podcastsSection
      troubleshootingSection(status)
    }
    .scrollDismissesKeyboard(.interactively)
    .confirmationDialog(
      WatchLinkCopy.reconnect, isPresented: $confirmingReconnect, titleVisibility: .visible
    ) {
      Button(WatchLinkCopy.reconnect, role: .destructive) { startReconnect() }
      Button(WatchLinkCopy.cancel, role: .cancel) {}
    } message: {
      Text(WatchLinkCopy.reconnectConfirmation)
    }
    .onDisappear {
      password = ""
      model.cancelReconnect()
    }
    .navigationTitle(model.title)
    .navigationBarTitleDisplayMode(.inline)
    .task {
      await model.loadProfile()
      // Sequential: the probe reads `state`, which `loadProfile` owns for the duration of its
      // fetch. The record only seeds the fallback; the Watch's current health must be asked on
      // every appear.
      await model.refreshConnectionStatus()
    }
    .onChange(of: model.isWatchReachable) { _, reachable in
      // The Watch answers only while it runs Whirr, so ask once as it returns rather than poll.
      guard reachable, !model.isBusy, !model.isCheckingConnection else { return }
      Task { await model.refreshConnectionStatus() }
    }
  }

  @ViewBuilder
  private func accountSection(_ status: WatchLinkStatus) -> some View {
    Section {
      LabeledContent(model.serverLabel, value: model.server)
        .accessibilityIdentifier("watchSetup.server")
      LabeledContent(model.usernameLabel) {
        if model.state == .loadingProfile {
          ProgressView().accessibilityLabel("Loading account")
        } else {
          Text(model.username.isEmpty ? "Unavailable" : model.username)
        }
      }
      .accessibilityIdentifier("watchSetup.username")

      if status.showsSetupForm, !model.usernameIsVerified, model.state != .loadingProfile, !model.server.isEmpty {
        Button("Retry account details") { Task { await model.loadProfile() } }
          .disabled(model.isBusy)
          .accessibilityIdentifier("watchSetup.retryAccount")
      }
    } header: {
      Text(model.accountHeading)
    }
  }

  @ViewBuilder
  private func statusSection(_ status: WatchLinkStatus) -> some View {
    switch status {
    case .notPaired, .appNotInstalled:
      installGuidanceSection
    case .checking:
      checkingSection
    case .settingUp, .notSetUp:
      setupFieldSection
    case .unbound, .awaitingReceipt, .signInRejected, .serverUnreachable, .working, .unconfirmed,
      .otherAccount, .unreachable:
      reportedStatusSection(status)
    }
  }

  @ViewBuilder
  private var installGuidanceSection: some View {
    if let guidance = model.installGuidance {
      Section {
        Label(guidance, systemImage: "applewatch.slash")
          .accessibilityIdentifier("watchSetup.installGuidance")
      }
    }
  }

  private var checkingSection: some View {
    Section {
      LabeledContent(model.watchLabel) {
        ProgressView().accessibilityLabel(model.checkingConnectionLabel)
      }
      .accessibilityIdentifier("watchSetup.checkingConnection")
    }
  }

  @ViewBuilder
  private var setupFieldSection: some View {
    Section {
      if model.state == .waitingForReceipt {
        EmptyView()
      } else if model.usesSingleSignOn {
        Text(model.singleSignOnExplanation)
          .font(.footnote)
          .foregroundStyle(.secondary)
          .accessibilityIdentifier("watchSetup.singleSignOn")
      } else {
        SecureField(model.passwordLabel, text: $password)
          .textContentType(.password)
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled()
          .focused($passwordFocused)
          .submitLabel(.go)
          .onSubmit { if canSubmit { submit() } }
          .disabled(model.isBusy || !model.usernameIsVerified || model.state == .loadingProfile)
          .accessibilityIdentifier("watchSetup.password")
      }
    } header: {
      Text(model.watchLabel)
    }
  }

  /// The headed status, its confirmation time, and Check Now. The explanation is the section
  /// footer, not a second row: a row would draw a separator between the status and its reason.
  private func reportedStatusSection(_ status: WatchLinkStatus) -> some View {
    Section {
      if let headline = status.headline {
        statusRow(status, headline: headline)
      }
      if status.primaryAction == .checkAgain {
        checkNowRow
      }
    } footer: {
      if let explanation = status.explanation {
        Text(explanation)
          .accessibilityIdentifier("watchSetup.statusExplanation")
      }
    }
  }

  private func statusRow(_ status: WatchLinkStatus, headline: String) -> some View {
    VStack(alignment: .leading, spacing: WhirrSpacing.xxSmall) {
      HStack(spacing: WhirrSpacing.small) {
        Text(model.watchLabel)
        Spacer(minLength: WhirrSpacing.small)
        Image(systemName: symbol(for: status))
          .foregroundStyle(tint(for: status))
          .accessibilityHidden(true)
        Text(headline)
          .foregroundStyle(tint(for: status))
      }
      if let confirmedAt = model.confirmedAt {
        confirmationLine(confirmedAt)
      }
    }
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("watchSetup.status")
  }

  private func confirmationLine(_ confirmedAt: Date) -> some View {
    TimelineView(.periodic(from: .now, by: 30)) { context in
      Text(WatchLinkConfirmationCopy.line(confirmedAt: confirmedAt, now: context.date))
        .font(.footnote)
        .foregroundStyle(.secondary)
    }
  }

  private var checkNowRow: some View {
    Button {
      Task { await model.refreshConnectionStatus() }
    } label: {
      HStack(spacing: WhirrSpacing.small) {
        Text(WatchLinkCopy.checkAgain)
        Spacer(minLength: WhirrSpacing.small)
        if model.isCheckingConnection {
          ProgressView()
            .controlSize(.small)
            .accessibilityHidden(true)
        }
      }
    }
    .tint(AppChrome.brandTint)
    .disabled(model.isBusy || model.isCheckingConnection)
    .accessibilityIdentifier("watchSetup.checkAgain")
  }

  @ViewBuilder
  private func actionSection(_ status: WatchLinkStatus) -> some View {
    if status.showsSetupForm {
      setupActionSection
    } else if status.primaryAction == .retrySetup {
      Section {
        connectButton(reconnecting: false)
      }
    }
    if status.primaryAction == .reconnect {
      Section {
        reconnectButton
          .tint(AppChrome.brandTint)
      }
    }
  }

  /// A healthy Watch keeps Reconnect as a last resort: at the foot of the screen, in the primary
  /// text colour, with a footer saying when it is worth using.
  @ViewBuilder
  private func troubleshootingSection(_ status: WatchLinkStatus) -> some View {
    if status.primaryAction != .reconnect, status.offersReconnect {
      Section {
        reconnectButton
          .foregroundStyle(.primary)
      } footer: {
        Text(WatchLinkCopy.reconnectFooter)
      }
    }
  }

  private var reconnectButton: some View {
    Button(WatchLinkCopy.reconnect) { confirmingReconnect = true }
      .disabled(model.isBusy || model.isCheckingConnection)
      .accessibilityIdentifier("watchSetup.reconnect")
  }

  @ViewBuilder
  private var setupActionSection: some View {
    Section {
      connectButton(reconnecting: model.wantsReconnect)
      if model.wantsReconnect {
        Button(WatchLinkCopy.cancel) {
          password = ""
          passwordFocused = false
          model.cancelReconnect()
        }
        .disabled(model.isBusy)
        .frame(maxWidth: .infinity)
        .listRowBackground(Color.clear)
        .accessibilityIdentifier("watchSetup.cancelReconnect")
      }
    }
  }

  private func connectButton(reconnecting: Bool) -> some View {
    prominentButton(model.buttonTitle(reconnecting: reconnecting), busy: model.isBusy) { submit() }
      .disabled(!canSubmit)
      .accessibilityIdentifier("watchSetup.connect")
  }

  @ViewBuilder
  private var podcastsSection: some View {
    if let watchCopies {
      Section {
        NavigationLink {
          OnAppleWatchView(coverClient: coverClient)
        } label: {
          Label(OnAppleWatchPresentation.title, systemImage: "applewatch")
        }
        .accessibilityIdentifier("watchSetup.onAppleWatch")

        Toggle(OnAppleWatchPresentation.removePlayedTitle, isOn: $removesPlayedEpisodes)
          // The app tint is near-white in dark appearance, so an untinted switch draws white on
          // white here. Every other Settings toggle names the brand navy.
          .tint(AppChrome.brandTint)
          .onChange(of: removesPlayedEpisodes) { _, _ in
            // Plans both desired sets: followed-show episodes and Audiobookshelf titles.
            WatchCompanionRuntime.shared.refreshEpisodeSend()
          }
          .accessibilityIdentifier("watchSetup.removePlayed")
      } header: {
        Text(OnAppleWatchPresentation.title)
      } footer: {
        Text(OnAppleWatchPresentation.removePlayedFooter)
      }
      .task {
        watchCopies.start()
        watchCopies.refreshWatchAvailability()
      }
    }
  }

  private func prominentButton(_ title: String, busy: Bool, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      HStack(spacing: WhirrSpacing.small) {
        if busy { ProgressView().tint(.white) }
        Text(title)
      }
      .font(.headline)
      .frame(maxWidth: .infinity, minHeight: WhirrMetric.minimumTouchTarget)
    }
    .buttonStyle(.borderedProminent)
    .buttonBorderShape(.capsule)
    .tint(AppChrome.brandTint)
    .foregroundStyle(.white)
    .listRowInsets(EdgeInsets())
    .listRowBackground(Color.clear)
  }

  private func symbol(for status: WatchLinkStatus) -> String {
    switch status {
    case .working: return "checkmark.circle.fill"
    case .serverUnreachable: return "wifi.exclamationmark"
    case .otherAccount: return "person.crop.circle.badge.exclamationmark"
    case .unconfirmed, .unreachable: return "applewatch.radiowaves.left.and.right"
    default: return "exclamationmark.triangle.fill"
    }
  }

  private func tint(for status: WatchLinkStatus) -> Color {
    switch status {
    case .working: return .green
    case .unconfirmed, .unreachable: return .secondary
    default: return .orange
    }
  }

  private func startReconnect() {
    model.beginReconnect()
    passwordFocused = !model.usesSingleSignOn
  }

  private var canSubmit: Bool {
    !model.isBusy && !model.isCheckingConnection && model.state != .connecting && model.state != .loadingProfile
      && (model.state == .waitingForReceipt
        || (model.usernameIsVerified && (model.usesSingleSignOn || !password.isEmpty)))
  }

  private func submit() {
    guard canSubmit else { return }
    let captured = password
    password = ""
    passwordFocused = false
    if model.usesSingleSignOn {
      model.submitSingleSignOn(using: SingleSignOnBrowser(session: webAuthenticationSession))
    } else {
      model.submit(password: captured)
    }
  }
}
