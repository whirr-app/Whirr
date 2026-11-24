import AppModel
import Foundation
import Persistence
import Testing

@testable import Whirr

@Suite("Home shelf card actions")
@MainActor
struct HomeShelfCardActionsTests {
  @Test("each destination reaches exactly its matching callback")
  func performRoutesEachDestination() {
    let summary = HomeItem(
      serverItemId: "item", title: "Title", author: "Author", category: .audiobook,
      durationSeconds: 3_600, progressSeconds: 600, isFinished: false,
      addedAt: Date(timeIntervalSince1970: 1), isDownloaded: false,
      episodeID: nil, episodeTitle: nil
    ).itemSummary
    let selections: [(HomeCardSelection, String)] = [
      (.item(summary), "item:item"),
      (.downloadedPodcast(summary), "downloaded:item"),
      (.episode(itemID: "show", episodeID: "ep"), "episode:show/ep"),
      (.resume(itemID: "book", episodeID: nil), "resume:book/-"),
      (.resume(itemID: "show", episodeID: "ep"), "resume:show/ep"),
      (.read(itemID: "book", title: "T", category: .ebook), "read:book/T"),
    ]

    for (selection, expected) in selections {
      var calls: [String] = []
      let actions = HomeShelfCardActions(
        onSelectItem: { calls.append("item:\($0.id)") },
        onPresentReader: { id, title, _ in calls.append("read:\(id)/\(title)") },
        onResumeListening: { id, episode in calls.append("resume:\(id)/\(episode ?? "-")") },
        onSelectDownloadedPodcast: { calls.append("downloaded:\($0.id)") },
        onSelectEpisode: { id, episode in calls.append("episode:\(id)/\(episode)") },
        onSearch: { calls.append("search:\($0)") })

      actions.perform(selection)

      #expect(calls == [expected])
    }
  }
}
