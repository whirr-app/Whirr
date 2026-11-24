import ABSApi
import AppModel
import DesignSystem
import SwiftUI

/// "Smart Lists": every list, with new, reorder and delete. A `List`, because reorder and delete
/// are the system's edit-mode gestures; the section heading on the Podcasts tab opens it. A row
/// opens the list, or its editor while the screen is editing; a long press offers Edit too.
struct EditSmartListsView: View {
  let access: SmartListsAccess
  let coverClient: any ArtworkServing
  let onOpenList: (Int64) -> Void

  @Environment(\.editMode) private var editMode
  @State private var editorRequest: SmartListEditorRequest?
  @State private var pendingDelete: SmartListSummary?

  var body: some View {
    let model = access.model
    List {
      Section {
        ForEach(model.lists) { list in
          SmartListRowView(
            list: list, coverClient: coverClient, detail: .rules,
            onOpen: { open(list) }
          )
          .swipeActions(edge: .trailing) {
            // Not `.destructive`: that role removes the row at once, and it springs back while the
            // confirmation is asked, or for good if the delete is cancelled.
            Button {
              pendingDelete = list
            } label: {
              Label(SmartListsPresentation.deleteTitle, systemImage: "trash")
            }
            .tint(.red)
          }
          .contextMenu {
            Button(SmartListsPresentation.playTitle, systemImage: "play") {
              Task { _ = await access.play(listID: list.id) }
            }
            .disabled(list.matchCount == 0)
            Button(SmartListsPresentation.editTitleShort, systemImage: "slider.horizontal.3") {
              edit(list)
            }
            Button(SmartListsPresentation.deleteTitle, systemImage: "trash", role: .destructive) {
              pendingDelete = list
            }
          }
          // On the row, not the list: the dialog points at the list it is about to delete.
          .confirmationDialog(
            SmartListsPresentation.deleteConfirmation(name: list.name),
            isPresented: Binding(
              get: { pendingDelete?.id == list.id },
              set: { if $0 == false { pendingDelete = nil } }),
            titleVisibility: .visible
          ) {
            Button(SmartListsPresentation.deleteTitle, role: .destructive) {
              pendingDelete = nil
              Task { await model.delete(id: list.id) }
            }
          }
        }
        .onMove { source, destination in
          var ids = model.lists.map(\.id)
          ids.move(fromOffsets: source, toOffset: destination)
          Task { await model.reorder(ids: ids) }
        }
        .onDelete { offsets in
          pendingDelete = offsets.first.map { model.lists[$0] }
        }
      } footer: {
        if model.canCreate == false { Text(SmartListsCopy.listLimitReached) }
      }
    }
    .overlay {
      if model.lists.isEmpty {
        ContentUnavailableView {
          Label(SmartListsPresentation.noListsTitle, systemImage: "line.3.horizontal.decrease")
        } description: {
          Text(SmartListsPresentation.emptyMessage)
        } actions: {
          Button(SmartListsPresentation.blankTemplateTitle) { create(.blank) }
        }
      }
    }
    .navigationTitle(SmartListsPresentation.manageTitle)
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      if model.lists.isEmpty == false {
        ToolbarItem(placement: .topBarTrailing) { EditButton() }
      }
      ToolbarItem(placement: .primaryAction) { newMenu(model) }
    }
    .smartListEditorSheet(request: $editorRequest)
    .alert(
      SmartListsPresentation.errorTitle,
      isPresented: Binding(
        get: { model.error != nil },
        set: { if $0 == false { model.clearError() } })
    ) {
      Button("OK", role: .cancel) {}
    } message: {
      Text(model.error?.message ?? "")
    }
  }

  private func open(_ list: SmartListSummary) {
    if editMode?.wrappedValue.isEditing == true {
      edit(list)
    } else {
      onOpenList(list.id)
    }
  }

  /// A blank list first, so a list of one's own is the plain choice and a template the shortcut.
  private func newMenu(_ model: SmartListsModel) -> some View {
    Menu {
      Button(SmartListsPresentation.blankTemplateTitle, systemImage: "plus") { create(.blank) }
      Section(SmartListsPresentation.templatesHeading) {
        ForEach(SmartListsPresentation.templates, id: \.name) { template in
          Button(SmartListsPresentation.templateTitle(template)) { create(template) }
        }
      }
    } label: {
      Label(SmartListsPresentation.newTitle, systemImage: "plus")
    }
    .disabled(model.canCreate == false)
    .accessibilityHint(SmartListsPresentation.newHint)
  }

  private func edit(_ list: SmartListSummary) {
    editorRequest = SmartListEditorRequest(mode: .edit(listID: list.id), template: .blank)
  }

  private func create(_ template: SmartListTemplate) {
    editorRequest = SmartListEditorRequest(mode: .create, template: template)
  }
}
