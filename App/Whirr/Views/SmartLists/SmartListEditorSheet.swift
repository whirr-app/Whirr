import AppModel
import DesignSystem
import Persistence
import SwiftUI

extension View {
  /// Presents the smart-list editor for a request. The models are built from the environment's
  /// access, so a host without smart lists presents nothing.
  func smartListEditorSheet(request: Binding<SmartListEditorRequest?>) -> some View {
    modifier(SmartListEditorSheetModifier(request: request))
  }
}

private struct SmartListEditorSheetModifier: ViewModifier {
  @Binding var request: SmartListEditorRequest?
  @Environment(\.smartLists) private var smartLists

  func body(content: Content) -> some View {
    content.sheet(item: $request) { request in
      Group {
        if let smartLists {
          SmartListEditorSheet(access: smartLists, request: request)
        }
      }
      .adaptiveSheetPresentation(role: .form, compactDetents: [.large])
    }
  }
}

/// The editor: a `Form` over the list's rules, a row that opens the show picker, the
/// auto-download switch and limit, and the live match count in a bar at the bottom.
struct SmartListEditorSheet: View {
  let access: SmartListsAccess
  let request: SmartListEditorRequest

  @Environment(\.dismiss) private var dismiss
  // Built once: the model opens observations (see `DeferredModel`).
  @State private var deferred = DeferredModel<SmartListEditorModel>()

  var body: some View {
    let model = deferred.resolve {
      access.makeEditorModel(mode: request.mode, template: request.template)
    }
    SmartListEditorForm(model: model, mode: request.mode, onDone: { dismiss() })
  }
}

private struct SmartListEditorForm: View {
  private enum LengthField {
    case longerThan
    case shorterThan
  }

  @Bindable var model: SmartListEditorModel
  let mode: SmartListEditorModel.Mode
  let onDone: () -> Void

  /// The length row whose wheel is open, one at a time, as Calendar opens a date.
  @State private var openLength: LengthField?

  var body: some View {
    NavigationStack {
      Form {
        if let loadError = model.loadError {
          Section { Text(loadError.message).foregroundStyle(.secondary) }
        } else {
          nameSection
          showsSection
          episodesSection
          lengthSection
          orderSection
          errorSection
        }
      }
      .safeAreaInset(edge: .bottom) { matchBar }
      .navigationTitle(title)
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button(SmartListEditorLabels.cancel, action: onDone)
        }
        ToolbarItem(placement: .confirmationAction) {
          Button(SmartListEditorLabels.save) {
            Task {
              if await model.save() != nil { onDone() }
            }
          }
          .disabled(model.canSave == false)
        }
      }
      .task { await model.load() }
      .onChange(of: model.matchCount) { _, count in
        // Polite: an announcement queues behind what VoiceOver is saying, and the count itself is
        // also a live element below, so a reader who is not listening loses nothing.
        if let text = SmartListsPresentation.announcement(matchCount: count) {
          AccessibilityNotification.Announcement(text).post()
        }
      }
    }
  }

  private var title: String {
    switch mode {
    case .create: SmartListsPresentation.newListTitle
    case .edit: SmartListsPresentation.editListTitle
    }
  }

  private var nameSection: some View {
    Section {
      TextField(SmartListEditorLabels.namePrompt, text: $model.name)
        .accessibilityLabel(SmartListEditorLabels.nameField)
      switch model.nameValidation {
      case .valid: EmptyView()
      case .empty: validationText(SmartListEditorLabels.emptyName)
      case .tooLong: validationText(SmartListEditorLabels.longName)
      }
    }
  }

  private func validationText(_ text: String) -> some View {
    Text(text).font(WhirrTypeToken.caption.font).foregroundStyle(.red)
  }

  private var showsSection: some View {
    Section {
      NavigationLink {
        SmartListShowsPickerView(model: model)
      } label: {
        LabeledContent(
          SmartListEditorLabels.showsSection,
          value: SmartListShowChoice.summary(
            scope: model.rules.showScope, roles: model.pickerShows.map(\.role)))
      }
    }
  }

  private var episodesSection: some View {
    Section(SmartListEditorLabels.episodesSection) {
      statusMenu
      Picker(SmartListEditorLabels.downloadPicker, selection: downloadChoice) {
        ForEach(SmartListDownloadChoice.allCases, id: \.self) { choice in
          Text(SmartListEditorLabels.download(choice)).tag(choice)
        }
      }
      Picker(SmartListEditorLabels.releasePicker, selection: $model.rules.releaseWindow) {
        Text(SmartListEditorLabels.release(nil)).tag(SmartListReleaseWindow?.none)
        ForEach(SmartListReleaseWindow.allCases, id: \.self) { window in
          Text(SmartListEditorLabels.release(window)).tag(SmartListReleaseWindow?.some(window))
        }
      }
      Toggle(SmartListEditorLabels.savedOnly, isOn: $model.rules.savedOnly)
        .tint(AppChrome.brandTint)
    }
  }

  private var downloadChoice: Binding<SmartListDownloadChoice> {
    Binding(
      get: { SmartListDownloadChoice(model.rules) },
      set: { $0.apply(to: &model.rules) })
  }

  /// Three statuses in one row. The menu stays open between taps, since choosing two is usual.
  private var statusMenu: some View {
    Menu {
      statusItem(SmartListEditorLabels.unplayed, \.includeUnplayed)
      statusItem(SmartListEditorLabels.inProgress, \.includeInProgress)
      statusItem(SmartListEditorLabels.played, \.includePlayed)
    } label: {
      LabeledContent {
        HStack(spacing: WhirrSpacing.xxSmall) {
          Text(SmartListEditorLabels.statusSummary(model.rules))
          Image(systemName: "chevron.up.chevron.down").imageScale(.small)
        }
      } label: {
        Text(SmartListEditorLabels.statusPicker).foregroundStyle(.primary)
      }
    }
    .menuActionDismissBehavior(.disabled)
  }

  private func statusItem(_ title: String, _ keyPath: WritableKeyPath<SmartListRules, Bool>)
    -> some View
  {
    Button {
      model.rules[keyPath: keyPath].toggle()
    } label: {
      if model.rules[keyPath: keyPath] {
        Label(title, systemImage: "checkmark")
      } else {
        Text(title)
      }
    }
  }

  private var lengthSection: some View {
    Section {
      Toggle(SmartListEditorLabels.durationToggle, isOn: $model.rules.durationFilter)
        .tint(AppChrome.brandTint)
      if model.rules.durationFilter {
        lengthRow(
          SmartListEditorLabels.longerThan, field: .longerThan,
          minutes: $model.rules.longerThanMinutes, range: 0...599)
        lengthRow(
          SmartListEditorLabels.shorterThan, field: .shorterThan,
          minutes: $model.rules.shorterThanMinutes, range: 1...600)
      }
    }
  }

  @ViewBuilder
  private func lengthRow(
    _ title: String, field: LengthField, minutes: Binding<Int>, range: ClosedRange<Int>
  ) -> some View {
    let isOpen = openLength == field
    Button {
      withAnimation { openLength = isOpen ? nil : field }
    } label: {
      LabeledContent {
        Text(
          minutes.wrappedValue == 0
            ? SmartListEditorLabels.noMinimum
            : SmartListEditorLabels.length(minutes: minutes.wrappedValue)
        )
        .foregroundStyle(isOpen ? AnyShapeStyle(AppChrome.brandTint) : AnyShapeStyle(.secondary))
      } label: {
        Text(title).foregroundStyle(.primary)
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    if isOpen {
      SmartListDurationWheel(minutes: minutes, range: range)
    }
  }

  private var orderSection: some View {
    Section {
      Picker(SmartListEditorLabels.orderPicker, selection: $model.rules.sortOrder) {
        ForEach(SmartListSortOrder.allCases, id: \.self) { order in
          Text(SmartListEditorLabels.order(order)).tag(order)
        }
      }
      Toggle(SmartListEditorLabels.autoDownload, isOn: $model.autoDownload)
        .tint(AppChrome.brandTint)
        .disabled(model.canAutoDownload == false)
      if model.autoDownload {
        Picker(SmartListEditorLabels.autoDownloadLimit, selection: $model.autoDownloadLimit) {
          ForEach(SmartListAutoDownloadLimit.allCases, id: \.self) { limit in
            Text(SmartListEditorLabels.limit(limit)).tag(limit)
          }
        }
      }
    } footer: {
      Text(
        model.canAutoDownload
          ? SmartListEditorLabels.autoDownloadFooter
          : SmartListEditorLabels.autoDownloadNeedsBothStatesFooter)
    }
  }

  /// The live count, kept above the keyboard and the fold so each rule's effect shows as it is
  /// changed.
  @ViewBuilder
  private var matchBar: some View {
    if model.loadError == nil,
      let text = SmartListsPresentation.announcement(matchCount: model.matchCount)
    {
      HStack(spacing: WhirrSpacing.xSmall) {
        if model.isUpdatingShows { ProgressView() }
        Text(model.isUpdatingShows ? SmartListsPresentation.updatingShows : text)
          .font(WhirrTypeToken.subheadline.font)
          .contentTransition(.numericText())
      }
      .padding(.horizontal, WhirrSpacing.medium)
      .padding(.vertical, WhirrSpacing.xSmall)
      .glassEffect(.regular, in: .capsule)
      .padding(.bottom, WhirrSpacing.xSmall)
      .accessibilityElement(children: .combine)
      .accessibilityAddTraits(.updatesFrequently)
    }
  }

  @ViewBuilder
  private var errorSection: some View {
    if let rulesError = model.rulesError {
      Section { validationText(SmartListEditorLabels.rulesError(rulesError)) }
    }
    if let saveError = model.saveError {
      Section { validationText(saveError.message) }
    }
  }
}

/// Hours and minutes on two wheels, the way Clock sets a timer.
private struct SmartListDurationWheel: View {
  @Binding var minutes: Int
  let range: ClosedRange<Int>

  var body: some View {
    HStack(spacing: 0) {
      Picker(SmartListEditorLabels.hours, selection: column(hours: true)) {
        ForEach(0...(range.upperBound / 60), id: \.self) { Text("\($0) hr").tag($0) }
      }
      Picker(SmartListEditorLabels.minutesColumn, selection: column(hours: false)) {
        ForEach(0..<60, id: \.self) { Text("\($0) min").tag($0) }
      }
    }
    .pickerStyle(.wheel)
    .frame(height: 160)
  }

  private func column(hours: Bool) -> Binding<Int> {
    Binding(
      get: { hours ? minutes / 60 : minutes % 60 },
      set: { value in
        minutes = SmartListEditorLabels.clampedMinutes(
          hours: hours ? value : minutes / 60, minutes: hours ? minutes % 60 : value, in: range)
      })
  }
}
