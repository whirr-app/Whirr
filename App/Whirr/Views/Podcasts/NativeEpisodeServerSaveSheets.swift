import AppModel
import DesignSystem
import SwiftUI
import SyncEngine

/// The staged removal shared by the show row and the episode card. Only removal is confirmed (Save
/// runs on the menu tap), via an `alert`: a screen-level `confirmationDialog` anchors its popover
/// to an arbitrary row and can't anchor to a context-menu action.
struct NativeEpisodeServerSaveRemovalConfirmation: Equatable, Identifiable {
  let episodeID: String

  var id: String { episodeID }
}

/// Shared presentation for the removal confirmation and the coordinator-owned destination sheet.
/// The caller supplies all mutations; cancelling invokes none. `podcastName` is display context
/// only. The destination prompt is a sheet, not a popover: it arrives asynchronously, attached to
/// the screen rather than the menu item, so an arrow would point at nothing.
struct NativeEpisodeServerSaveSheets: ViewModifier {
  @Binding var removalConfirmation: NativeEpisodeServerSaveRemovalConfirmation?
  @Binding var choicePrompt: NativeEpisodeServerSaveChoicePrompt?
  let podcastName: String?
  let episodeCount: Int
  let savesShow: Bool
  let onRemoveConfirmed: (String) -> Void
  let onChoice: (ServerPodcastSaveChoice) -> Void
  let onChoiceCancelled: () -> Void

  func body(content: Content) -> some View {
    content
      .alert(
        NativeEpisodeServerSaveCopy.removeAction,
        isPresented: Binding(
          get: { removalConfirmation != nil },
          set: { if $0 == false { removalConfirmation = nil } }),
        presenting: removalConfirmation
      ) { confirmation in
        Button(NativeEpisodeServerSaveCopy.removeAction, role: .destructive) {
          removalConfirmation = nil
          onRemoveConfirmed(confirmation.episodeID)
        }
        Button(StorageCopy.cancel, role: .cancel) { removalConfirmation = nil }
      } message: { _ in
        Text(NativeEpisodeServerSaveCopy.removeConsequence)
      }
      .sheet(
        isPresented: Binding(
          get: { choicePrompt != nil },
          set: {
            // A submitted choice clears the pending prompt before SwiftUI reports the sheet's
            // dismissal. Only a still-pending prompt is a cancellation; otherwise this setter
            // would erase the status the choice just produced.
            if $0 == false, choicePrompt != nil {
              choicePrompt = nil
              onChoiceCancelled()
            }
          })
      ) {
        if let choicePrompt {
          NativeEpisodeServerSaveDestinationView(
            presentation: NativeEpisodeServerSaveDestinationPresentation(
              prompt: choicePrompt, podcastName: podcastName, episodeCount: episodeCount,
              savesShow: savesShow),
            onChoice: onChoice)
        }
      }
  }
}

extension View {
  func nativeEpisodeServerSaveSheets(
    removalConfirmation: Binding<NativeEpisodeServerSaveRemovalConfirmation?>,
    choicePrompt: Binding<NativeEpisodeServerSaveChoicePrompt?>,
    podcastName: String?,
    episodeCount: Int = 1,
    savesShow: Bool = false,
    onRemoveConfirmed: @escaping (String) -> Void,
    onChoice: @escaping (ServerPodcastSaveChoice) -> Void,
    onChoiceCancelled: @escaping () -> Void
  ) -> some View {
    modifier(
      NativeEpisodeServerSaveSheets(
        removalConfirmation: removalConfirmation,
        choicePrompt: choicePrompt,
        podcastName: podcastName,
        episodeCount: episodeCount,
        savesShow: savesShow,
        onRemoveConfirmed: onRemoveConfirmed,
        onChoice: onChoice,
        onChoiceCancelled: onChoiceCancelled))
  }
}

/// One sheet, two shapes. A sole destination (the Docker default) and an empty catalogue are a
/// compact card sized to its own content: symbol, title, the sentence with the show and the
/// destination emphasised, and stacked actions. A real choice is a medium sheet whose rows still
/// hand back opaque ids only.
private struct NativeEpisodeServerSaveDestinationView: View {
  let presentation: NativeEpisodeServerSaveDestinationPresentation
  let onChoice: (ServerPodcastSaveChoice) -> Void
  @Environment(\.dismiss) private var dismiss
  /// The card's measured height, so the sheet's detent hugs the content at every Dynamic Type
  /// size instead of opening to a fixed fraction of the screen. iOS clamps a detent taller than
  /// the screen to the large detent, and the card scrolls inside it.
  @State private var cardHeight: CGFloat = 0

  var body: some View {
    Group {
      switch presentation.layout {
      case .createInSoleDestination(let destination):
        card {
          primaryButton(for: destination)
          cancelButton
        }
      case .unavailable:
        card { cancelButton }
      case .chooseDestination(let libraries):
        picker { destinationRows(libraries) }
      case .chooseExistingShow(let candidates):
        picker { existingShowRows(candidates) }
      }
    }
    // The measured height applies only to the compact card. The shared modifier ignores
    // `compactDetents` on regular width, so a card never carries a fixed-height detent into the
    // fitted iPad presentation.
    .adaptiveSheetPresentation(role: sheetRole, compactDetents: compactDetents)
  }

  private var sheetRole: SheetViewPresentation.Role {
    switch presentation.layout {
    case .createInSoleDestination, .unavailable:
      .fitted
    case .chooseDestination, .chooseExistingShow:
      .form
    }
  }

  private var compactDetents: Set<PresentationDetent> {
    switch presentation.layout {
    case .createInSoleDestination, .unavailable:
      [cardHeight > 0 ? .height(cardHeight) : .medium]
    case .chooseDestination, .chooseExistingShow:
      [.medium, .large]
    }
  }

  // MARK: Compact card

  private func card(@ViewBuilder actions: () -> some View) -> some View {
    ScrollView {
      VStack(spacing: WhirrSpacing.large) {
        header
        VStack(spacing: WhirrSpacing.small) {
          actions()
        }
      }
      .padding(.horizontal, WhirrSpacing.large)
      .padding(.top, WhirrSpacing.xLarge)
      .padding(.bottom, WhirrSpacing.large)
      .onGeometryChange(for: CGFloat.self) {
        $0.size.height
      } action: {
        cardHeight = $0
      }
    }
    .scrollBounceBehavior(.basedOnSize)
  }

  private var header: some View {
    VStack(spacing: WhirrSpacing.small) {
      Image(systemName: presentation.systemImage)
        .font(.system(size: 34, weight: .medium))
        .foregroundStyle(WhirrColorToken.accent.color)
        .frame(width: 72, height: 72)
        .background(WhirrColorToken.accent.color.opacity(0.14), in: Circle())
        .accessibilityHidden(true)
        .padding(.bottom, WhirrSpacing.xxSmall)
      Text(presentation.title)
        .font(.title2.weight(.bold))
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
      explanationText
        .multilineTextAlignment(.center)
      if let footer = presentation.soleDestinationFooter {
        Text(footer)
          .font(.footnote)
          .foregroundStyle(WhirrColorToken.textSecondary.color)
          .multilineTextAlignment(.center)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .frame(maxWidth: .infinity)
    .accessibilityElement(children: .combine)
  }

  private func primaryButton(
    for destination: NativeEpisodeServerSaveDestinationPresentation.SoleDestination
  ) -> some View {
    Group {
      if let action = presentation.primaryAction {
        Button {
          onChoice(destination.choice)
        } label: {
          Text(action.title)
            .foregroundStyle(AppChrome.onTint)
            .frame(maxWidth: .infinity, minHeight: WhirrMetric.minimumTouchTarget)
            .fixedSize(horizontal: false, vertical: true)
        }
        .buttonStyle(.borderedProminent)
        .tint(AppChrome.tint)
        .controlSize(.large)
        .accessibilityLabel(action.accessibilityLabel)
        .accessibilityHint(action.hint)
      }
    }
  }

  private var cancelButton: some View {
    Button(role: .cancel) {
      dismiss()
    } label: {
      Text(StorageCopy.cancel)
        .frame(maxWidth: .infinity, minHeight: WhirrMetric.minimumTouchTarget)
    }
    .buttonStyle(.bordered)
    .controlSize(.large)
  }

  /// The sole destination draws its sentence from runs so the show and the destination are bold;
  /// every other layout draws the explanation as plain prose. Both wrap and never truncate.
  private var explanationText: some View {
    Group {
      if let runs = presentation.soleDestinationRuns {
        runs.reduce(Text("")) { text, run in
          switch run {
          case .plain(let value): Text("\(text)\(value)")
          case .emphasised(let value): Text("\(text)\(Text(value).fontWeight(.semibold))")
          }
        }
      } else {
        Text(presentation.explanation)
      }
    }
    .font(.body)
    .frame(maxWidth: .infinity)
    .fixedSize(horizontal: false, vertical: true)
  }

  // MARK: Pickers

  private func picker(@ViewBuilder rows: () -> some View) -> some View {
    NavigationStack {
      List {
        Section {
          explanationText
            .frame(maxWidth: .infinity, alignment: .leading)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())
        }
        rows()
        if let footer = presentation.pickerFooter {
          Section {
          } footer: {
            Text(footer)
          }
        }
      }
      .navigationTitle(presentation.title)
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button(StorageCopy.cancel) { dismiss() }
        }
      }
    }
  }

  private func destinationRows(_ libraries: [NativeEpisodeServerSaveLibraryChoice]) -> some View {
    ForEach(libraries, id: \.libraryID) { library in
      Section(library.displayName) {
        ForEach(library.folders, id: \.folderID) { folder in
          Button {
            onChoice(
              .libraryAndFolder(libraryID: library.libraryID, folderID: folder.folderID))
          } label: {
            VStack(alignment: .leading, spacing: WhirrSpacing.xxSmall) {
              Text(folder.displayName)
                .foregroundStyle(.primary)
              Text(presentation.destinationPreview(library: library, folder: folder))
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
          }
          .accessibilityLabel(
            presentation.folderRowAccessibilityLabel(library: library, folder: folder)
          )
          .accessibilityHint(NativeEpisodeServerSaveCopy.futureEpisodesHint)
        }
      }
    }
  }

  private func existingShowRows(
    _ candidates: [NativeEpisodeServerSaveExistingChoice]
  ) -> some View {
    Section {
      ForEach(candidates, id: \.serverItemID) { candidate in
        Button(candidate.displayName) {
          onChoice(.existing(serverItemID: candidate.serverItemID))
        }
        .accessibilityLabel(presentation.existingRowAccessibilityLabel(candidate))
        .accessibilityHint(presentation.existingRowHint)
      }
    }
  }
}
