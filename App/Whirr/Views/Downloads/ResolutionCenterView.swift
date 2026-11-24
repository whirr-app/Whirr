import AppModel
import DesignSystem
import SwiftUI
import SyncEngine

/// The resolution center: every open progress conflict, skew confirmation, dead letter, and
/// paused-auth download, each with its per-kind action set. Switches over
/// `ResolutionCenterModel`'s tested state only, and every string comes from
/// `ResolutionCenterCopy`.
struct ResolutionCenterView: View {
  private let access: any ResolutionCenterAccess

  // Built lazily. `ResolutionCenterModel.init` is pure today, but the convention is for a model
  // to subscribe synchronously in `init`, and eager construction would silently break once it
  // does. See `DeferredModel`.
  @State private var deferred = DeferredModel<ResolutionCenterModel>()

  private var model: ResolutionCenterModel {
    deferred.resolve { ResolutionCenterModel(access: access) }
  }

  @State private var isConfirmingTakeServerForAll = false

  @Environment(\.horizontalSizeClass) private var horizontalSizeClass
  private var layout: AdaptiveListLayout { .resolve(horizontalSizeClass: horizontalSizeClass) }

  init(access: any ResolutionCenterAccess) {
    self.access = access
  }

  var body: some View {
    content
      .accessibilityIdentifier(ScreenAccessibilityID.resolutionCenterScreen)
      .navigationTitle("Resolution Center")
      .task { await model.refresh() }
      .alert(
        ResolutionCenterCopy.actionErrorTitle,
        isPresented: Binding(
          get: { model.actionErrorMessage != nil },
          set: { isPresented in if isPresented == false { model.dismissActionError() } })
      ) {
        Button(ResolutionCenterCopy.dismiss, role: .cancel) { model.dismissActionError() }
      } message: {
        Text(model.actionErrorMessage ?? "")
      }
      .sheet(
        isPresented: Binding(
          get: { model.pendingSkewOverwriteConfirmation != nil },
          set: { isPresented in if isPresented == false { model.cancelPendingConfirmation() } }
        )
      ) {
        if let pending = model.pendingSkewOverwriteConfirmation {
          DestructivePurgeConfirmationView(
            title: ResolutionCenterCopy.keepLocalSkewOverwriteWarningTitle(itemTitle: pending.itemTitle),
            message: ResolutionCenterCopy.keepLocalSkewOverwriteWarningMessage,
            confirmLabel: ResolutionCenterCopy.confirmOverwrite,
            confirmAccessibilityHint: ResolutionCenterCopy.keepLocalSkewOverwriteWarningMessage,
            cancelLabel: ResolutionCenterCopy.cancel,
            onConfirm: { Task { await model.confirmKeepLocalSkew() } },
            onCancel: { model.cancelPendingConfirmation() }
          )
          .adaptiveSheetPresentation(role: .fitted, compactDetents: [.medium])
        }
      }
      .confirmationDialog(
        ResolutionCenterCopy.takeServerForAllProgressConflictsConfirmationTitle,
        isPresented: $isConfirmingTakeServerForAll,
        titleVisibility: .visible
      ) {
        Button(ResolutionCenterCopy.confirmTakeServerForAllProgressConflicts, role: .destructive) {
          Task { await model.takeServerForAllProgressConflicts() }
        }
        Button(ResolutionCenterCopy.cancel, role: .cancel) {}
      } message: {
        Text(ResolutionCenterCopy.takeServerForAllProgressConflictsConfirmationMessage)
      }
  }

  @ViewBuilder
  private var content: some View {
    switch model.state {
    case .loading:
      LoadingStateView(message: ResolutionCenterCopy.loading)
    case .error:
      ErrorStateView(
        title: ResolutionCenterCopy.fetchErrorTitle,
        message: ResolutionCenterCopy.fetchErrorMessage,
        systemImage: "exclamationmark.triangle",
        retryTitle: ResolutionCenterCopy.retry
      ) {
        Task { await model.refresh() }
      }
    case .empty:
      EmptyStateView(
        title: ResolutionCenterCopy.emptyStateTitle,
        message: ResolutionCenterCopy.emptyStateMessage,
        systemImage: "checkmark.circle"
      )
      .accessibilityIdentifier(ScreenAccessibilityID.resolutionCenterEmptyState)
    case .loaded:
      ScrollView {
        if model.canTakeServerForAllProgressConflicts {
          Button(ResolutionCenterCopy.takeServerForAllProgressConflicts) {
            isConfirmingTakeServerForAll = true
          }
          .disabled(model.isTakingServerForAllProgressConflicts)
          .padding(.bottom, WhirrSpacing.small)
        }
        switch layout {
        case .singleColumn:
          rows
        case .measuredSingleColumn(let maxWidth):
          // This screen resolves through `resolve(horizontalSizeClass:)`, which never produces
          // this case. Handled as a capped column so the branch stays correct if it ever adopts
          // the measured resolver.
          rows
            .frame(maxWidth: maxWidth)
            .frame(maxWidth: .infinity, alignment: .center)
        case .grid(let columns):
          LazyVGrid(
            columns: Array(repeating: GridItem(.flexible()), count: columns),
            spacing: WhirrSpacing.small
          ) {
            ForEach(model.items) { rowView($0) }
          }
        }
      }
      .padding(WhirrSpacing.large)
      .accessibilityIdentifier(ScreenAccessibilityID.resolutionCenterList)
    }
  }

  private var rows: some View {
    VStack(spacing: WhirrSpacing.small) {
      ForEach(model.items) { rowView($0) }
    }
  }

  private func rowView(_ item: ResolutionOpenItem) -> some View {
    ResolutionListRowView(
      title: ResolutionCenterCopy.title(for: item.kind, itemTitle: item.itemTitle),
      message: ResolutionCenterCopy.message(for: item.kind),
      systemImage: systemImage(for: item.kind),
      actions: ResolutionCenterCopy.actions(for: item.kind).map { action in
        ResolutionListRowView.Action(
          label: ResolutionCenterCopy.label(for: action),
          accessibilityHint: ResolutionCenterCopy.message(for: item.kind),
          isDestructive: action == .discardDeadLetter
        )
      },
      onSelectAction: { index in
        let action = ResolutionCenterCopy.actions(for: item.kind)[index]
        Task { await perform(action, on: item) }
      }
    )
    .accessibilityIdentifier(ScreenAccessibilityID.resolutionCenterRowPrefix + item.id)
  }

  private func systemImage(for kind: ResolutionOpenItem.Kind) -> String {
    switch kind {
    case .progressConflict: return "arrow.triangle.2.circlepath"
    case .skewConfirmation: return "clock.arrow.circlepath"
    case .deadLetter: return "exclamationmark.triangle"
    case .pausedAuthDownload: return "lock.slash"
    }
  }

  private func perform(_ action: ResolutionCenterCopy.Action, on item: ResolutionOpenItem) async {
    switch (action, item.kind) {
    case (.keepLocalProgress, .progressConflict(let conflictId)):
      await model.keepLocalProgress(conflictId: conflictId)
    case (.takeServerProgress, .progressConflict(let conflictId)):
      await model.takeServerProgress(conflictId: conflictId)
    case (.keepLocalSkew, .skewConfirmation(let operationId, let sessionId)):
      model.requestKeepLocalSkew(operationId: operationId, sessionId: sessionId, itemTitle: item.itemTitle)
    case (.takeServerSkew, .skewConfirmation(let operationId, let sessionId)):
      await model.takeServerSkew(operationId: operationId, sessionId: sessionId)
    case (.discardDeadLetter, .deadLetter(let operationId, _)):
      await model.discardDeadLetter(operationId: operationId)
    case (.refreshMetadata, .deadLetter(let operationId, _)):
      await model.refreshMetadataDeadLetter(operationId: operationId)
    case (.reAuthenticate, .pausedAuthDownload):
      await model.requestReAuthentication()
    default:
      break
    }
  }
}
