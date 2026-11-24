import AppModel
import DesignSystem
import Persistence
import SwiftUI

/// Settings › Libraries. This is described as a Whirr device choice: accessibility
/// comes from the reconciled server list, while inclusion controls what this installation shows
/// and syncs rather than attempting to describe or modify server permissions.
struct LibrarySelectionSettingsView: View {
  let model: LibrarySelectionSettingsModel

  var body: some View {
    let toggleError = model.toggleError

    Form {
      if let refreshMessage = model.refreshMessage {
        Section {
          Label(refreshMessage, systemImage: "exclamationmark.triangle")
            .foregroundStyle(.secondary)
        }
      }

      selectionSection
    }
    .formStyle(.grouped)
    .scrollContentBackground(.hidden)
    .background(WhirrColorToken.groupedSurface.color.ignoresSafeArea())
    .navigationTitle(SettingsCopy.librarySelectionTitle)
    .navigationBarTitleDisplayMode(.inline)
    .task { await model.load() }
    .alert(
      SettingsCopy.librarySelectionTitle,
      isPresented: Binding(
        get: { toggleError != nil },
        set: { if $0 == false { model.dismissToggleError() } }
      )
    ) {
      Button(SettingsCopy.cancel, role: .cancel) { model.dismissToggleError() }
    } message: {
      Text(toggleError ?? "")
    }
    .accessibilityIdentifier(ScreenAccessibilityID.settingsLibrariesScreen)
  }

  @ViewBuilder
  private var selectionSection: some View {
    Section {
      selectionRows
    } footer: {
      Text(SettingsCopy.librarySelectionFooter)
    }
  }

  @ViewBuilder
  private var selectionRows: some View {
    if model.libraries.isEmpty {
      switch model.loadState {
      case .loading:
        HStack(spacing: WhirrSpacing.small) {
          ProgressView()
          Text(SettingsCopy.librarySelectionLoading)
        }
      case .loaded, .failed:
        Text(SettingsCopy.librarySelectionEmpty)
          .foregroundStyle(WhirrColorToken.textSecondary.color)
      }
    } else {
      ForEach(model.libraries, id: \.serverLibraryID) { library in
        Toggle(isOn: inclusionBinding(for: library)) {
          VStack(alignment: .leading, spacing: WhirrSpacing.xxSmall) {
            Text(library.name)
            Text(library.mediaType.capitalized)
              .font(.caption)
              .foregroundStyle(WhirrColorToken.textSecondary.color)
          }
        }
        .tint(AppChrome.brandTint)
        .accessibilityLabel("\(library.name), \(library.mediaType)")
        .accessibilityHint("Controls whether Whirr shows and syncs this library on this device.")
        .accessibilityIdentifier(
          ScreenAccessibilityID.settingsLibraryTogglePrefix + library.serverLibraryID)
      }
    }
  }

  private func inclusionBinding(for library: SelectableLibrary) -> Binding<Bool> {
    Binding(
      get: { library.isIncluded },
      set: { included in
        Task { await model.setIncluded(included, libraryID: library.serverLibraryID) }
      }
    )
  }
}
