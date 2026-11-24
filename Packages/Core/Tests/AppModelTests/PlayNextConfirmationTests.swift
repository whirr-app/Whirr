import Foundation
import Persistence
import SyncEngine
import Testing

@testable import AppModel

/// Play Next queues behind an active smart list run (ADR 0016), so every site that builds its
/// confirmation names the list; with no run the copy is what it always was.
@MainActor
@Suite("Play Next confirmation copy")
struct PlayNextConfirmationTests {
  @Test("the helper names the list during a run and falls back otherwise")
  func helper() {
    #expect(ListeningQueueCopy.playNextConfirmation(afterList: "Commute") == "Plays after Commute")
    #expect(ListeningQueueCopy.playNextConfirmation(afterList: nil) == ListeningQueueCopy.playingNext)
    #expect(ListeningQueueCopy.playNextConfirmation(afterList: "") == ListeningQueueCopy.playingNext)
  }

  @Test("both forms are recognised as a Play Next confirmation, and nothing else is")
  func recognition() {
    #expect(ListeningQueueCopy.isPlayNextConfirmation(ListeningQueueCopy.playingNext))
    #expect(ListeningQueueCopy.isPlayNextConfirmation("Plays after Commute"))
    #expect(ListeningQueueCopy.isPlayNextConfirmation("Plays after 🚗 Drive"))
    #expect(ListeningQueueCopy.isPlayNextConfirmation(ListeningQueueCopy.addedToUpNext) == false)
    #expect(ListeningQueueCopy.isPlayNextConfirmation(ListeningQueueCopy.alreadyInUpNext) == false)
  }

  @Test("the episode card says Plays after the list during a run")
  func episodeCard() async {
    let model = PodcastEpisodeCardModel(
      itemID: "show-1", episodeID: "episode-1", reading: NoOpPodcastReading(),
      activeSmartListName: { "Commute" })
    await model.performAction(.playNext)
    #expect(model.queueFeedbackMessage == "Plays after Commute")
  }

  @Test("the episode card keeps the existing copy with no run")
  func episodeCardWithoutRun() async {
    let model = PodcastEpisodeCardModel(
      itemID: "show-1", episodeID: "episode-1", reading: NoOpPodcastReading())
    await model.performAction(.playNext)
    #expect(model.queueFeedbackMessage == ListeningQueueCopy.playingNext)
  }

  @Test("the show page says Plays after the list during a run")
  func showPage() async {
    let model = PodcastShowModel(
      itemID: "show-1", reading: NoOpPodcastReading(), activeSmartListName: { "Commute" })
    await model.playNext("episode-1")
    #expect(model.queueFeedbackMessage == "Plays after Commute")
  }

  @Test("the show page keeps the existing copy with no run")
  func showPageWithoutRun() async {
    let model = PodcastShowModel(itemID: "show-1", reading: NoOpPodcastReading())
    await model.playNext("episode-1")
    #expect(model.queueFeedbackMessage == ListeningQueueCopy.playingNext)
  }

  @Test("the item actions say Plays after the list during a run, and read it per call")
  func itemActions() async {
    let name = NameBox("Commute")
    let model = ItemActionsModel(
      downloadStatus: DownloadStatusStore(downloadReading: NoOpDownloadReading()),
      downloadIntents: NoOpDownloadIntents(), progressIntents: NoOpItemProgressIntents(),
      extrasAccess: NoOpItemDetailExtrasAccess(), activeSmartListName: { name.value })
    await model.playNext(itemID: "book-1", episodeID: nil)
    #expect(model.queueFeedbackMessage == "Plays after Commute")

    name.value = nil
    await model.playNext(itemID: "book-1", episodeID: nil)
    #expect(model.queueFeedbackMessage == ListeningQueueCopy.playingNext)
  }

  @MainActor
  final class NameBox {
    var value: String?
    init(_ value: String?) { self.value = value }
  }
}
