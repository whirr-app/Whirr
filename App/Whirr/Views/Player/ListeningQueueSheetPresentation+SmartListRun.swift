import AppModel

/// What the Up Next sheet adds while a smart list runs (ADR 0016): the run first, in every state,
/// and the queue below it headed as playing after the list. Pure: no view, no environment.
nonisolated extension ListeningQueueSheetPresentation {
  struct RunRow: Sendable, Equatable, Identifiable {
    let id: String
    let title: String
    let subtitle: String
  }

  struct RunSection: Sendable, Equatable {
    let header: String
    let rows: [RunRow]
    /// Shown when the list has nothing left to play after the current episode.
    let emptyMessage: String?
    let stopLabel: String
    let stopHint: String
  }

  /// The sheet's composition: the optional run section, the queue's header (only with a run), and
  /// the queue's own state, unchanged.
  struct Layout: Sendable, Equatable {
    let runSection: RunSection?
    let queueHeader: String?
    let content: Content
  }

  static func layout(content: Content, run: SmartListRunModel.ActiveRun?) -> Layout {
    guard let run else { return Layout(runSection: nil, queueHeader: nil, content: content) }
    return Layout(
      runSection: runSection(for: run), queueHeader: queueHeader(listName: run.listName),
      content: content)
  }

  static func runSection(for run: SmartListRunModel.ActiveRun) -> RunSection {
    RunSection(
      header: playingFromHeader(listName: run.listName),
      rows: run.upcoming.map {
        RunRow(id: $0.id, title: $0.title, subtitle: $0.showTitle)
      },
      emptyMessage: run.upcoming.isEmpty ? runEmptyMessage : nil,
      stopLabel: stopLabel(listName: run.listName),
      stopHint: stopHint)
  }

  static func playingFromHeader(listName: String) -> String { "Playing from \(listName)" }
  static func queueHeader(listName: String) -> String { "Up Next after \(listName)" }
  static func stopLabel(listName: String) -> String { "Stop \(listName)" }

  static let runEmptyMessage = "Nothing else to play from this list."
  static let stopHint = "Ends the list. Up Next plays when this episode finishes."
}
