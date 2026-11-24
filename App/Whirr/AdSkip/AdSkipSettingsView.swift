import DesignSystem
import SwiftUI

/// The Reduce Ads page: the toggle, the speech model, how far analysis has got, and what the
/// feature does and does not do.
struct AdSkipSettingsView: View {
  @Bindable var model: AdSkipSettingsModel
  @State private var isHowItWorksExpanded = false

  var body: some View {
    Form {
      settingSection
      explanationSection(AdSkipSettingsCopy.goodToKnow, rows: AdSkipSettingsCopy.goodToKnowRows)
      explanationSection(
        AdSkipSettingsCopy.whenItGetsItWrong, rows: AdSkipSettingsCopy.whenItGetsItWrongRows)
      howItWorksSection
      // Offered with the setting off too: turning it off keeps what was learned.
      Section {
        Button(AdSkipSettingsCopy.forget, role: .destructive) { model.isConfirmingForget = true }
      }
    }
    .formStyle(.grouped)
    .navigationTitle(AdSkipSettingsCopy.title)
    .navigationBarTitleDisplayMode(.inline)
    .task { await model.followProgress() }
    .adSkipDownloadConfirmation(
      isPresented: $model.isConfirmingDownload,
      onConfirm: { model.confirmDownload(allowingCellular: $0) },
      onCancel: { model.cancelDownloadConfirmation() }
    )
    .alert(AdSkipSettingsCopy.forgetTitle, isPresented: $model.isConfirmingForget) {
      Button(AdSkipSettingsCopy.cancel, role: .cancel) {}
      Button(AdSkipSettingsCopy.forget, role: .destructive) { model.confirmForget() }
    } message: {
      Text(AdSkipSettingsCopy.forgetMessage)
    }
  }

  private var settingSection: some View {
    Section {
      Toggle(
        AdSkipSettingsCopy.title,
        isOn: Binding(get: { model.isToggleOn }, set: { model.setToggle($0) })
      )
      .tint(AppChrome.brandTint)
      assetRow
      if model.isEnabled {
        Toggle(
          AdSkipSettingsCopy.onlyWhileCharging,
          isOn: Binding(
            get: { model.isOnlyWhileCharging }, set: { model.setOnlyWhileCharging($0) })
        )
        .tint(AppChrome.brandTint)
      }
      if model.isEnabled, model.asset == .installed, let progress = model.progress {
        progressRow(AdSkipProgressCopy.status(for: progress, pauseReason: model.pauseReason))
      }
    }
  }

  private func progressRow(_ status: AdSkipProgressCopy.Status) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(status.title)
        .monospacedDigit()
      if let detail = status.detail {
        Text(detail)
          .font(.footnote)
          .foregroundStyle(.secondary)
      }
    }
    .accessibilityElement(children: .combine)
  }

  private func explanationSection(
    _ title: String, rows: [(title: String, detail: String?, systemImage: String)]
  ) -> some View {
    Section {
      explanationRows(rows)
    } header: {
      Text(title)
    }
  }

  /// Collapsed by default: the mechanism is the least-needed content, and a remembered-open
  /// disclosure would quietly grow the page again.
  private var howItWorksSection: some View {
    Section {
      DisclosureGroup(isExpanded: $isHowItWorksExpanded) {
        explanationRows(AdSkipSettingsCopy.howItWorksRows)
      } label: {
        Text(AdSkipSettingsCopy.howItWorks)
      }
    }
  }

  @ViewBuilder
  private func explanationRows(_ rows: [(title: String, detail: String?, systemImage: String)])
    -> some View
  {
    ForEach(rows, id: \.title) { row in
      Label {
        VStack(alignment: .leading, spacing: 2) {
          Text(row.title)
          if let detail = row.detail {
            Text(detail)
              .font(.footnote)
              .foregroundStyle(.secondary)
          }
        }
      } icon: {
        Image(systemName: row.systemImage)
          .foregroundStyle(AppChrome.brandTint)
      }
      .accessibilityElement(children: .combine)
    }
  }

  @ViewBuilder
  private var assetRow: some View {
    switch model.asset {
    case .waitingForWiFi:
      Label(AdSkipSettingsCopy.waitingForWiFi, systemImage: "wifi")
        .foregroundStyle(.secondary)
    case .downloading(let fraction) where model.isEnabled:
      VStack(alignment: .leading, spacing: WhirrSpacing.xSmall) {
        Text(AdSkipSettingsCopy.downloading)
          .foregroundStyle(.secondary)
        if let fraction {
          ProgressView(value: fraction)
        } else {
          ProgressView()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
      }
      .accessibilityElement(children: .combine)
    case .failed where model.isEnabled:
      VStack(alignment: .leading, spacing: WhirrSpacing.xSmall) {
        Label(AdSkipSettingsCopy.failed, systemImage: "exclamationmark.triangle")
          .foregroundStyle(.secondary)
        Button(AdSkipSettingsCopy.retry) { model.retry() }
      }
    case .notInstalled where model.isEnabled:
      Button(AdSkipSettingsCopy.download) { model.isConfirmingDownload = true }
    default:
      EmptyView()
    }
  }
}
