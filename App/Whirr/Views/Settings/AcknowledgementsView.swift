import AppModel
import DesignSystem
import SwiftUI

/// The shipped open-source licences, reachable from Settings ▸ About.
///
/// The list is `ReleaseAcknowledgements.displayOrdered` verbatim. The release audit keeps it in
/// step with both lockfiles, so a dependency added without attribution fails a test.
struct AcknowledgementsView: View {
  var body: some View {
    List {
      Section {
        ForEach(ReleaseAcknowledgements.displayOrdered) { acknowledgement in
          NavigationLink {
            AcknowledgementDetailView(acknowledgement: acknowledgement)
          } label: {
            VStack(alignment: .leading, spacing: 2) {
              Text(acknowledgement.displayName)
                .font(.body)
              Text("\(acknowledgement.version) · \(acknowledgement.licenseIdentifier)")
                .font(.caption)
                .foregroundStyle(WhirrColorToken.textSecondary.color)
            }
            .frame(minHeight: 44, alignment: .leading)
            .accessibilityElement(children: .combine)
          }
        }
      }
    }
    .navigationTitle(SettingsCopy.acknowledgementsRowTitle)
    .navigationBarTitleDisplayMode(.inline)
  }
}

/// One package's verbatim notice. The text is selectable so a licence can be copied out, and is
/// never truncated: reproducing the notice in full is the licence obligation.
struct AcknowledgementDetailView: View {
  let acknowledgement: ReleaseAcknowledgement

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: WhirrSpacing.medium) {
        VStack(alignment: .leading, spacing: WhirrSpacing.xxSmall) {
          Text(acknowledgement.attribution)
            .font(.subheadline)
          Text(acknowledgement.repositoryURL)
            .font(.caption)
            .foregroundStyle(WhirrColorToken.textSecondary.color)
        }

        Divider()

        Text(acknowledgement.licenseText ?? acknowledgement.attribution)
          .font(.footnote)
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      .padding(WhirrSpacing.medium)
    }
    .navigationTitle(acknowledgement.displayName)
    .navigationBarTitleDisplayMode(.inline)
  }
}
