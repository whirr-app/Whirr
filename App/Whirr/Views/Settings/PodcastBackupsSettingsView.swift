import AppModel
import DesignSystem
import Foundation
import Persistence
import SwiftUI
import SyncEngine
import UniformTypeIdentifiers

/// Settings > Podcasts > Backups: a manual backup file through the share sheet and a fill-in
/// restore from the system file picker. Neither needs iCloud consent; with sync on, restore
/// syncs first so it writes against everything the other devices have sent.
struct PodcastBackupsSettingsView: View {
  let syncOn: Bool
  @State private var backup: PodcastBackupModel
  @State private var restore: PodcastBackupRestoreModel
  @State private var isImporterPresented = false
  /// One importer serves both pickers; SwiftUI presents only one `.fileImporter` per view.
  @State private var importerKind = ImporterKind.backupFile
  private let automatic = PodcastBackupComposition.autoBackupModel

  private enum ImporterKind {
    case backupFile, folder
  }

  init(syncOn: Bool, podcastRefreshing: any PodcastRefreshing) {
    self.syncOn = syncOn
    _backup = State(initialValue: PodcastBackupComposition.makeBackupModel())
    _restore = State(initialValue: PodcastBackupComposition.makeRestoreModel(podcastRefreshing: podcastRefreshing))
  }

  var body: some View {
    Form {
      Section {
        createRow
        Button {
          restore.reset()
          present(.backupFile)
        } label: {
          HStack {
            Text(restoreLabel)
            if isRestoreBusy {
              Spacer()
              ProgressView()
            }
          }
        }
        .disabled(isRestoreBusy)
        .accessibilityIdentifier(PodcastBackupsAccessibilityID.restore)
      } footer: {
        VStack(alignment: .leading, spacing: WhirrSpacing.xSmall) {
          if let export = backup.lastExport {
            Text(PodcastBackupPresentation.exportSummary(export))
          }
          Text(PodcastBackupPresentation.footer)
        }
      }
      if PodcastDataSettingsReadiness.automaticBackups {
        automaticSection
      }
    }
    .formStyle(.grouped)
    .navigationTitle(PodcastDataSettingsCopy.backupsRowTitle)
    .navigationBarTitleDisplayMode(.inline)
    .task { await backup.prepareExport() }
    .fileImporter(
      isPresented: $isImporterPresented,
      allowedContentTypes: importerKind == .folder ? [.folder] : [.json]
    ) { result in
      guard case .success(let url) = result else { return }
      switch importerKind {
      case .backupFile:
        Task {
          // An unreadable or oversized file reads as empty, which the service reports as damaged.
          let data = (try? PodcastBackupFileSupport.read(url)) ?? Data()
          await restore.read(data)
        }
      case .folder:
        Task { await automatic.choose(folder: url) }
      }
    }
    .alert(
      alertTitle,
      isPresented: Binding(
        get: { alertTitle.isEmpty == false },
        set: { presented in if presented == false { dismissAlert() } })
    ) {
      alertActions
    } message: {
      Text(alertMessage)
    }
  }

  @ViewBuilder private var createRow: some View {
    if let exportURL = backup.exportURL {
      ShareLink(item: exportURL) {
        Text(PodcastBackupPresentation.createBackup)
      }
      .accessibilityIdentifier(PodcastBackupsAccessibilityID.create)
    } else if backup.exportError {
      Button(PodcastBackupPresentation.createBackup) {
        Task { await backup.prepareExport() }
      }
      .accessibilityIdentifier(PodcastBackupsAccessibilityID.create)
      Text(PodcastBackupPresentation.createFailed)
        .foregroundStyle(WhirrColorToken.textSecondary.color)
    } else {
      HStack {
        Text(PodcastBackupPresentation.preparingBackup)
          .foregroundStyle(WhirrColorToken.textSecondary.color)
        Spacer()
        ProgressView()
      }
    }
  }

  private func present(_ kind: ImporterKind) {
    importerKind = kind
    isImporterPresented = true
  }

  // MARK: - Automatic backups

  private var automaticSection: some View {
    Section {
      Toggle(
        PodcastBackupPresentation.automaticToggle,
        isOn: Binding(
          get: { automatic.isOn },
          set: { on in
            // Turning on only asks for a folder; it switches on once a backup there succeeds.
            if on { present(.folder) } else { automatic.turnOff() }
          })
      )
      .tint(AppChrome.brandTint)
      .disabled(automatic.isRunning)
      .accessibilityIdentifier(PodcastBackupsAccessibilityID.automaticToggle)
      if automatic.isRunning {
        HStack {
          Text(PodcastBackupPresentation.automaticRunning)
            .foregroundStyle(WhirrColorToken.textSecondary.color)
          Spacer()
          ProgressView()
        }
      }
      if automatic.isOn {
        Button {
          present(.folder)
        } label: {
          LabeledContent(PodcastBackupPresentation.automaticFolder, value: automatic.state.folderName ?? "")
        }
        .foregroundStyle(WhirrColorToken.textPrimary.color)
        .disabled(automatic.isRunning)
        .accessibilityIdentifier(PodcastBackupsAccessibilityID.automaticFolder)
        LabeledContent(
          PodcastBackupPresentation.automaticLastBackup,
          value: automatic.state.lastSuccess.map { $0.formatted(date: .abbreviated, time: .shortened) }
            ?? PodcastBackupPresentation.automaticNever)
      }
    } header: {
      Text(PodcastBackupPresentation.automaticHeader)
    } footer: {
      VStack(alignment: .leading, spacing: WhirrSpacing.xSmall) {
        if automatic.choiceKeptExistingBackups {
          Text(PodcastBackupPresentation.automaticChoiceKeptExistingBackups)
        } else if automatic.choiceFailed {
          Text(PodcastBackupPresentation.automaticChoiceFailed)
        } else if automatic.isOn, let failure = automatic.state.failure {
          Text(PodcastBackupPresentation.automaticFailureMessage(failure))
        }
        Text(PodcastBackupPresentation.automaticFooter)
      }
    }
  }

  private var isRestoreBusy: Bool {
    switch restore.phase {
    case .reading, .restoring: true
    case .idle, .preview, .finished, .failed: false
    }
  }

  private var restoreLabel: String {
    switch restore.phase {
    case .reading: PodcastBackupPresentation.readingBackup
    case .restoring: PodcastBackupPresentation.restoring
    case .idle, .preview, .finished, .failed: PodcastBackupPresentation.restoreBackup
    }
  }

  // MARK: - Alert

  private var alertTitle: String {
    switch restore.phase {
    case .preview(_, let outcome):
      (PodcastBackupPresentation.hasChanges(outcome) || restore.smartListsPending > 0)
        ? PodcastBackupPresentation.previewTitle : PodcastBackupPresentation.nothingToRestoreTitle
    case .finished: PodcastBackupPresentation.finishedTitle
    case .failed: PodcastBackupPresentation.failedTitle
    case .idle, .reading, .restoring: ""
    }
  }

  private var alertMessage: String {
    switch restore.phase {
    case .preview(let document, let outcome):
      (PodcastBackupPresentation.hasChanges(outcome) || restore.smartListsPending > 0)
        ? "\(Self.backupDate(document.exportedAt)) "
          + PodcastBackupPresentation.previewMessage(
            outcome, syncOn: syncOn, smartLists: restore.smartListsPending)
        : PodcastBackupPresentation.nothingToRestoreMessage
    case .finished(let outcome):
      PodcastBackupPresentation.finishedMessage(
        outcome, smartLists: restore.smartListOutcome, smartListsFailed: restore.smartListsFailed)
    case .failed(let failure): PodcastBackupPresentation.failureMessage(failure)
    case .idle, .reading, .restoring: ""
    }
  }

  @ViewBuilder private var alertActions: some View {
    if case .preview(_, let outcome) = restore.phase,
      PodcastBackupPresentation.hasChanges(outcome) || restore.smartListsPending > 0
    {
      Button(PodcastDataSettingsCopy.consentCancel, role: .cancel) { restore.reset() }
      Button(PodcastBackupPresentation.previewConfirm) {
        // Immediate, so the phase has left the preview before the alert re-reads its binding.
        // The export is prepared again so its counts and the shared file include what came back.
        Task.immediate {
          await restore.confirm()
          await backup.prepareExport()
        }
      }
      .keyboardShortcut(.defaultAction)
    } else {
      Button("OK", role: .cancel) { restore.reset() }
    }
  }

  /// The preview's own buttons decide it; resetting a preview here could race Merge Backup.
  private func dismissAlert() {
    switch restore.phase {
    case .finished, .failed: restore.reset()
    case .idle, .reading, .preview, .restoring: break
    }
  }

  private static func backupDate(_ date: Date) -> String {
    "Backup from \(date.formatted(date: .abbreviated, time: .shortened))."
  }
}

enum PodcastBackupsAccessibilityID {
  static let row = "settings.podcasts.data.backups"
  static let create = "settings.podcasts.backups.create"
  static let restore = "settings.podcasts.backups.restore"
  static let automaticToggle = "settings.podcasts.backups.automatic"
  static let automaticFolder = "settings.podcasts.backups.automatic.folder"
}

nonisolated enum PodcastBackupFileSupport {
  static func read(_ url: URL) throws -> Data {
    let accessed = url.startAccessingSecurityScopedResource()
    defer { if accessed { url.stopAccessingSecurityScopedResource() } }
    let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
    guard values.isRegularFile != false, (values.fileSize ?? 0) <= PodcastStateSnapshotCodec.maxBytes else {
      throw CocoaError(.fileReadTooLarge)
    }
    return try Data(contentsOf: url, options: .mappedIfSafe)
  }
}
