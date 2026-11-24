import AppModel
import DesignSystem
import SwiftUI

struct ServerAddressRowPresentation: Equatable {
  let securitySymbol: String
  let showsPreferredBadge: Bool
  let showsUnreachableBadge: Bool
  let showsActiveCheckmark: Bool
  let canRemove: Bool
  let canSetPreferred: Bool

  var showsStatusLine: Bool { showsPreferredBadge || showsUnreachableBadge }

  init(row: ServerAddressesModel.Row, rowCount: Int) {
    securitySymbol = row.securitySymbol
    showsPreferredBadge = row.isPreferred
    // Only a failed probe earns a badge. A never-probed address is the ordinary new state.
    showsUnreachableBadge = row.reachability == .failed
    showsActiveCheckmark = row.isActive
    canRemove = rowCount > 1
    canSetPreferred = row.isPreferred == false
  }
}

enum ServerAddressesViewPresentation {
  /// The address line's icon column. Fixed so the status line can indent to the address's leading
  /// edge instead of a glyph whose width varies by symbol.
  static let securityIconWidth: CGFloat = 20

  static func row(_ row: ServerAddressesModel.Row, rowCount: Int) -> ServerAddressRowPresentation {
    ServerAddressRowPresentation(row: row, rowCount: rowCount)
  }
}

struct ServerAddressesView: View {
  @Bindable var model: ServerAddressesModel
  @State private var isAddPresented = false

  var body: some View {
    List {
      ForEach(model.rows) { row in
        let presentation = ServerAddressesViewPresentation.row(row, rowCount: model.rows.count)
        addressRow(row, presentation: presentation)
          .accessibilityElement(children: .combine)
          .accessibilityIdentifier(ScreenAccessibilityID.serverAddressRowPrefix + String(row.id))
          .contextMenu {
            if presentation.canSetPreferred {
              Button(ServerAddressesCopy.setPreferred, systemImage: "star") {
                Task { await model.setPreferred(id: row.id) }
              }
            }
            Button(ServerAddressesCopy.removeAddress, systemImage: "trash", role: .destructive) {
              Task { await model.remove(id: row.id) }
            }
            .disabled(presentation.canRemove == false)
          }
          .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(ServerAddressesCopy.removeAddress, systemImage: "trash", role: .destructive) {
              Task { await model.remove(id: row.id) }
            }
            .disabled(presentation.canRemove == false)
            .tint(.red)

            if presentation.canSetPreferred {
              Button(ServerAddressesCopy.setPreferred, systemImage: "star") {
                Task { await model.setPreferred(id: row.id) }
              }
              .tint(.yellow)
            }
          }
      }
      .onMove { source, destination in
        Task { await model.move(from: source, to: destination) }
      }
    }
    .listStyle(.insetGrouped)
    .navigationTitle(ServerAddressesCopy.listTitle)
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        Button(ServerAddressesCopy.addAddress, systemImage: "plus") {
          isAddPresented = true
        }
        .accessibilityIdentifier(ScreenAccessibilityID.serverAddressAddButton)
      }
    }
    .task {
      // Always reload: the switch coordinator may have changed the active address since the
      // last visit.
      await model.load()
    }
    .sheet(isPresented: $isAddPresented) {
      AddServerAddressView(model: model)
        // The form reuses the setup flow's fields, whose prominent Continue button needs the
        // flow's brand tint; the neutral app tint is near-white in dark appearance.
        .tint(SetupFlowView.tint)
        // One detent only. The form focuses its address field on appear, and a `.medium` sheet
        // would resize the moment the keyboard arrives.
        .adaptiveSheetPresentation(role: .form, compactDetents: [.large])
    }
    .alert(ServerAddressesCopy.listTitle, isPresented: failedAlertBinding) {
      Button("OK", role: .cancel) { model.dismissFailure() }
    } message: {
      if case .failed(let message) = model.phase { Text(message) }
    }
  }

  @ViewBuilder
  private func addressRow(
    _ row: ServerAddressesModel.Row, presentation: ServerAddressRowPresentation
  ) -> some View {
    VStack(alignment: .leading, spacing: WhirrSpacing.xxSmall) {
      HStack(spacing: WhirrSpacing.small) {
        Image(systemName: presentation.securitySymbol)
          .foregroundStyle(WhirrColorToken.textSecondary.color)
          .frame(width: ServerAddressesViewPresentation.securityIconWidth)
          .accessibilityHidden(true)
        // Middle truncation: the port ends the address and distinguishes entries for one host.
        Text(row.displayAddress)
          .lineLimit(2)
          .truncationMode(.middle)
          .frame(maxWidth: .infinity, alignment: .leading)
        if presentation.showsActiveCheckmark {
          Image(systemName: "checkmark")
            .foregroundStyle(.tint)
            .accessibilityLabel(ServerAddressesCopy.active)
        }
      }

      if presentation.showsStatusLine {
        HStack(spacing: WhirrSpacing.small) {
          if presentation.showsPreferredBadge {
            HStack(spacing: WhirrSpacing.xxSmall) {
              Image(systemName: "star.fill")
                .accessibilityHidden(true)
              Text(ServerAddressesCopy.preferred)
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(.yellow)
            .padding(.horizontal, WhirrSpacing.small)
            .padding(.vertical, WhirrSpacing.xxSmall)
            .background(.yellow.opacity(0.12), in: Capsule())
          }
          if presentation.showsUnreachableBadge {
            Label(ServerAddressesCopy.unreachableBadge, systemImage: "exclamationmark.triangle.fill")
              .foregroundStyle(.red)
          }
        }
        .font(.caption)
        .padding(.leading, ServerAddressesViewPresentation.securityIconWidth + WhirrSpacing.small)
      }
    }
    .padding(.vertical, WhirrSpacing.xxSmall)
  }

  private var failedAlertBinding: Binding<Bool> {
    Binding(
      get: {
        if case .failed = model.phase { return true }
        return false
      },
      set: { _ in }
    )
  }
}
