import AppModel
import Foundation
import Testing

@testable import Whirr

/// The Up Next sheet with an active smart list run (ADR 0016): the run section comes first in
/// every state, only with a run, and the queue under it says when it plays.
@Suite("Up Next sheet smart list run section")
struct ListeningQueueSheetSmartListRunTests {
  private typealias Presentation = ListeningQueueSheetPresentation

  private static let states: [Presentation.Content] = [.loading, .empty, .cleared, .rows]

  private static func run(upcoming: Int = 3) -> SmartListRunModel.ActiveRun {
    SmartListRunModel.ActiveRun(
      listID: 1, listName: "Commute",
      upcoming: (0..<upcoming).map {
        SmartListRunModel.Upcoming(
          itemID: "rss:1", episodeID: "e\($0)", title: "Title \($0)", showTitle: "Show")
      })
  }

  @Test("with no run the sheet is exactly the queue, in every state")
  func noRunNoSection() {
    for state in Self.states {
      let layout = Presentation.layout(content: state, run: nil)
      #expect(layout.runSection == nil)
      #expect(layout.queueHeader == nil)
      #expect(layout.content == state)
    }
  }

  @Test("with a run the section and the queue header are present in every state")
  func runShowsInEveryState() throws {
    for state in Self.states {
      let layout = Presentation.layout(content: state, run: Self.run())
      let section = try #require(layout.runSection)
      #expect(section.header == "Playing from Commute")
      #expect(section.stopLabel == "Stop Commute")
      #expect(section.rows.map(\.title) == ["Title 0", "Title 1", "Title 2"])
      #expect(section.rows.map(\.subtitle) == ["Show", "Show", "Show"])
      #expect(section.emptyMessage == nil)
      #expect(layout.queueHeader == "Up Next after Commute")
      #expect(layout.content == state)
    }
  }

  @Test("a run with nothing left after the current episode says so")
  func drainedRun() throws {
    let section = try #require(Presentation.layout(content: .rows, run: Self.run(upcoming: 0)).runSection)
    #expect(section.rows.isEmpty)
    #expect(section.emptyMessage == Presentation.runEmptyMessage)
  }

  @Test("Stop clears the model's run")
  @MainActor
  func stopClearsTheRun() async {
    let model = SmartListRunModel()
    await model.stop()
    #expect(model.run == nil)
  }
}
