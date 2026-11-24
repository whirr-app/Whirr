import AppModel
import DesignSystem
import Persistence
import SwiftUI

/// The editor's shows screen: which shows the list draws on, and which of them play first. The
/// scope decides what a tick means, so there is one mark to read and no role to pick per show.
struct SmartListShowsPickerView: View {
  @Bindable var model: SmartListEditorModel

  var body: some View {
    let scope = model.rules.showScope
    Form {
      Section {
        Picker(SmartListEditorLabels.scopePicker, selection: $model.rules.showScope) {
          ForEach(SmartListEditorLabels.scopes, id: \.self) { scope in
            Text(SmartListEditorLabels.scope(scope)).tag(scope)
          }
        }
        .pickerStyle(.segmented)
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets())
      } footer: {
        Text(SmartListEditorLabels.scopeFooter(scope))
      }

      Section {
        if model.pickerShows.isEmpty {
          Text(SmartListEditorLabels.noShows).foregroundStyle(.secondary)
        }
        ForEach(model.pickerShows) { show in
          row(show, scope: scope)
        }
      } footer: {
        if model.pickerShows.isEmpty == false { Text(SmartListEditorLabels.prioritySection) }
      }
    }
    .navigationTitle(SmartListEditorLabels.showsSection)
    .navigationBarTitleDisplayMode(.inline)
  }

  private func row(_ show: SmartListPickerShow, scope: SmartListShowScope) -> some View {
    let isMarked = SmartListShowChoice.isMarked(show.role, scope: scope)
    let isStarred = show.role == .priority
    return HStack(spacing: WhirrSpacing.small) {
      Button {
        model.setRole(SmartListShowChoice.toggled(show.role, scope: scope), for: show.ref)
      } label: {
        HStack(spacing: WhirrSpacing.small) {
          if scope != .all {
            Image(systemName: markSymbol(isMarked: isMarked, scope: scope))
              .imageScale(.large)
              .foregroundStyle(markStyle(isMarked: isMarked, scope: scope))
          }
          VStack(alignment: .leading, spacing: WhirrSpacing.xxSmall) {
            Text(show.title).foregroundStyle(.primary)
            if let note = SmartListsPresentation.availabilityNote(show.availability) {
              Text(note).font(WhirrTypeToken.caption.font).foregroundStyle(.secondary)
            }
          }
          Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .disabled(scope == .all)
      .accessibilityAddTraits(isMarked ? .isSelected : [])

      Button {
        model.setRole(SmartListShowChoice.priorityToggled(show.role, scope: scope), for: show.ref)
      } label: {
        Image(systemName: isStarred ? "star.fill" : "star")
          .foregroundStyle(isStarred ? AnyShapeStyle(.yellow) : AnyShapeStyle(.tertiary))
          .frame(
            width: WhirrMetric.minimumTouchTarget, height: WhirrMetric.minimumTouchTarget
          )
          .contentShape(Rectangle())
      }
      .buttonStyle(.borderless)
      .accessibilityLabel(SmartListEditorLabels.star)
      .accessibilityAddTraits(isStarred ? .isSelected : [])
    }
  }

  /// A tick chooses a show; under "All except" the same tap leaves one out, so it reads as a minus.
  private func markSymbol(isMarked: Bool, scope: SmartListShowScope) -> String {
    guard isMarked else { return "circle" }
    return scope == .allExcept ? "minus.circle.fill" : "checkmark.circle.fill"
  }

  private func markStyle(isMarked: Bool, scope: SmartListShowScope) -> AnyShapeStyle {
    guard isMarked else { return AnyShapeStyle(.tertiary) }
    return scope == .allExcept ? AnyShapeStyle(.red) : AnyShapeStyle(AppChrome.brandTint)
  }
}
