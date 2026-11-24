import AppModel
import Persistence
import SwiftUI

/// The smart-list models a screen needs, reached through the environment. The Podcasts tab shares
/// one `SmartListsModel`; a list's screen and the editor each build their own, because each opens
/// its own observation and lives only as long as the screen.
///
/// Carried in the environment, as `ShowPlaybackEffectsAccess` is, so the shell's initializer does
/// not grow a parameter for every surface that lists a smart list. Nil where smart lists are not
/// composed (the setup graph), and every consumer draws nothing then.
@MainActor
final class SmartListsAccess {
  let model: SmartListsModel
  private let services: SmartListServices
  private let playback: any SmartListPlaybackStarting

  init(services: SmartListServices, playback: any SmartListPlaybackStarting) {
    self.services = services
    self.playback = playback
    model = SmartListsModel(services: services)
  }

  func makeListModel(listID: Int64) -> SmartListModel {
    SmartListModel(listID: listID, services: services, playback: playback)
  }

  /// Starts an episode as part of a list's run; false when playback did not start.
  func startFromList(listID: Int64, itemID: String, episodeID: String) async -> Bool {
    await playback.startFromList(listID: listID, itemID: itemID, episodeID: episodeID)
  }

  /// Starts a list from its first unfinished episode; false when it has none or the start failed.
  func play(listID: Int64) async -> Bool {
    guard let candidate = await model.firstPlayable(listID: listID) else { return false }
    return await playback.startFromList(
      listID: listID, itemID: candidate.itemID, episodeID: candidate.episodeID)
  }

  func makeEditorModel(
    mode: SmartListEditorModel.Mode, template: SmartListTemplate = .blank
  ) -> SmartListEditorModel {
    SmartListEditorModel(services: services, mode: mode, template: template)
  }
}

private struct SmartListsAccessKey: EnvironmentKey {
  static let defaultValue: SmartListsAccess? = nil
}

extension EnvironmentValues {
  /// A custom value, so sheet and popover content inherits it (see `windowHorizontalSizeClass`).
  var smartLists: SmartListsAccess? {
    get { self[SmartListsAccessKey.self] }
    set { self[SmartListsAccessKey.self] = newValue }
  }
}

/// A request to open the editor: a new list from a template, or an existing list.
struct SmartListEditorRequest: Identifiable, Equatable {
  let mode: SmartListEditorModel.Mode
  let template: SmartListTemplate

  var id: String {
    switch mode {
    case .create: "create/\(template.name)"
    case .edit(let listID): "edit/\(listID)"
    }
  }

  static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
}
