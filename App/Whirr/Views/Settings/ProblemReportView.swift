import AppModel
import DesignSystem
import SwiftUI

/// Settings › About › Report a Problem. Two actions: the public repository's bug form, prefilled
/// with version strings, and the diagnostics bundle for the system share sheet. The bundle is
/// built on arrival so sharing is one tap, and its text is one push away because the footer's
/// promise is only worth what the person can check.
struct ProblemReportView: View {
  let sources: ProblemReportSources
  let exportDirectory: URL

  // Built lazily: this view is reconstructed on every parent evaluation, and the model owns a
  // file on disk.
  @State private var deferred = DeferredModel<ProblemReportModel>()

  private var model: ProblemReportModel {
    deferred.resolve { ProblemReportModel(sources: sources, exportDirectory: exportDirectory) }
  }

  var body: some View {
    let model = model
    List {
      Section {
        if let issueURL = model.issueURL {
          Link(destination: issueURL) {
            actionRow(
              title: ProblemReportCopy.issueTitle, detail: ProblemReportCopy.issueDetail,
              systemImage: "ladybug", trailingSystemImage: "arrow.up.right")
          }
          .accessibilityHint("Opens in Safari")
        } else {
          actionRow(
            title: ProblemReportCopy.issueTitle, detail: ProblemReportCopy.issueDetail,
            systemImage: "ladybug", trailingSystemImage: "arrow.up.right"
          )
          .foregroundStyle(.secondary)
        }
      }

      Section {
        if let exportURL = model.exportURL {
          ShareLink(item: exportURL, subject: Text("Whirr diagnostics")) {
            actionRow(
              title: ProblemReportCopy.shareTitle, detail: ProblemReportCopy.shareDetail,
              systemImage: "square.and.arrow.up", trailingSystemImage: nil)
          }
        } else if model.exportError {
          Button {
            Task { await model.prepareExport() }
          } label: {
            actionRow(
              title: ProblemReportCopy.shareTitle, detail: ProblemReportCopy.shareFailed,
              systemImage: "square.and.arrow.up", trailingSystemImage: "arrow.clockwise")
          }
          .accessibilityLabel(ProblemReportCopy.shareFailed)
        } else {
          HStack(spacing: WhirrSpacing.small) {
            ProgressView()
            Text(ProblemReportCopy.preparingShare)
              .foregroundStyle(WhirrColorToken.textSecondary.color)
          }
          .frame(minHeight: 44)
        }

        NavigationLink {
          ProblemReportPreviewView(text: model.preview ?? "")
        } label: {
          SettingsNavigationRow(
            title: ProblemReportCopy.previewTitle, detail: ProblemReportCopy.previewDetail,
            systemImage: "doc.text.magnifyingglass")
        }
        .disabled(model.preview == nil)
      } footer: {
        Text(ProblemReportCopy.footer)
      }
    }
    .navigationTitle(ProblemReportCopy.rowTitle)
    .navigationBarTitleDisplayMode(.inline)
    .task {
      await model.loadEnvironment()
      await model.prepareExport()
    }
  }

  private func actionRow(
    title: String, detail: String, systemImage: String, trailingSystemImage: String?
  ) -> some View {
    HStack(spacing: WhirrSpacing.small) {
      Image(systemName: systemImage)
        .font(.body.weight(.medium))
        .foregroundStyle(.secondary)
        .frame(width: 24, height: 24)
      VStack(alignment: .leading, spacing: 2) {
        Text(title)
          .font(.body)
          .foregroundStyle(.primary)
        Text(detail)
          .font(.caption)
          .foregroundStyle(WhirrColorToken.textSecondary.color)
      }
      Spacer()
      if let trailingSystemImage {
        Image(systemName: trailingSystemImage)
          .font(.footnote.weight(.semibold))
          .foregroundStyle(.secondary)
      }
    }
    .frame(minHeight: 56)
    .contentShape(Rectangle())
    .accessibilityElement(children: .combine)
  }
}

/// The bundle verbatim, selectable so a line can be copied out, and never truncated: the person
/// is deciding whether to share it.
struct ProblemReportPreviewView: View {
  let text: String

  var body: some View {
    ScrollView([.vertical, .horizontal]) {
      Text(text)
        .font(.caption.monospaced())
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
    }
    .navigationTitle(ProblemReportCopy.previewTitle)
    .navigationBarTitleDisplayMode(.inline)
  }
}
