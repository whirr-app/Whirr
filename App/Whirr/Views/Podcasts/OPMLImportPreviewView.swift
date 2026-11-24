import AppModel
import DesignSystem
import SwiftUI

struct OPMLImportPreviewView: View {
  @Bindable var model: PodcastSubscriptionOPMLModel
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      Form {
        if let failure = model.importFailure {
          Section {
            Text(message(for: failure)).foregroundStyle(.red)
          }
        } else {
          Section {
            ForEach(model.rows) { row in
              importRow(row)
            }
          }
        }
      }
      .formStyle(.grouped)
      // The commit lives outside the scroll. Inside it, each committed row added a status line
      // and pushed the button off the bottom of the sheet mid-import.
      .safeAreaInset(edge: .bottom, spacing: 0) { commitBar }
      .navigationTitle(PodcastSubscriptionOPMLPresentation.previewTitle)
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button(role: .close) { dismiss() }
        }
      }
    }
  }

  /// A pending row is a full-width `Toggle` so the whole row selects it. Once it commits, the
  /// switch is replaced by a fixed-size accessory: a disabled switch reads as "you may not",
  /// not as "this one is done", and the swap holds the row at one height.
  @ViewBuilder
  private func importRow(_ row: OPMLImportRow) -> some View {
    VStack(alignment: .leading, spacing: WhirrSpacing.xxSmall) {
      if row.status == .pending {
        Toggle(
          isOn: Binding(
            get: { row.isSelected },
            set: { model.setSelected($0, rowID: row.id) })
        ) {
          rowLabel(row)
        }
        .disabled(model.isFollowing)
      } else {
        HStack(spacing: WhirrSpacing.small) {
          rowLabel(row)
          Spacer(minLength: 0)
          statusAccessory(row.status)
        }
      }
      if let failure = PodcastSubscriptionOPMLPresentation.failureText(row.status) {
        Text(failure)
          .font(.caption)
          .foregroundStyle(.red)
      }
    }
  }

  private func rowLabel(_ row: OPMLImportRow) -> some View {
    VStack(alignment: .leading, spacing: WhirrSpacing.xxSmall) {
      Text(row.title)
      Text(row.feedURL.absoluteString)
        .font(.caption)
        .foregroundStyle(WhirrColorToken.textSecondary.color)
        .lineLimit(1)
    }
  }

  @ViewBuilder
  private func statusAccessory(_ status: OPMLImportRow.Status) -> some View {
    switch status {
    case .pending:
      EmptyView()
    case .following:
      ProgressView()
        .accessibilityLabel(PodcastSubscriptionOPMLPresentation.followingLabel)
    case .followed:
      Image(systemName: "checkmark.circle.fill")
        .foregroundStyle(.green)
        .accessibilityLabel(PodcastSubscriptionOPMLPresentation.followedLabel)
    case .failed:
      // The caption below already states the failure; a second reading of it here would be a
      // duplicate stop for VoiceOver.
      Image(systemName: "exclamationmark.triangle.fill")
        .foregroundStyle(.red)
        .accessibilityHidden(true)
    }
  }

  @ViewBuilder
  private var commitBar: some View {
    if model.importFailure == nil, model.rows.isEmpty == false {
      let state = model.commitState
      Button {
        switch state {
        case .done: dismiss()
        case .follow, .following: Task { await model.followSelected() }
        }
      } label: {
        HStack(spacing: WhirrSpacing.small) {
          if case .following = state { ProgressView() }
          Text(PodcastSubscriptionOPMLPresentation.commitLabel(state))
        }
        .frame(maxWidth: .infinity, minHeight: WhirrMetric.minimumTouchTarget)
      }
      .buttonStyle(.glassProminent)
      .buttonBorderShape(.capsule)
      // Not disabled while following: `.glassProminent` drops its fill when disabled, which
      // would empty the capsule the running batch reports into. The model already refuses a
      // second concurrent commit.
      .disabled(state == .follow(count: 0))
      .padding(.horizontal, WhirrSpacing.medium)
      .padding(.vertical, WhirrSpacing.small)
      .background(.bar)
    }
  }

  private func message(for failure: OPMLImportFailure) -> String {
    switch failure {
    case .invalidDocument: PodcastSubscriptionOPMLPresentation.invalidDocumentMessage
    case .noFeeds: PodcastSubscriptionOPMLPresentation.noFeedsMessage
    }
  }
}
