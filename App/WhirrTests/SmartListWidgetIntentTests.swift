import AppIntents
import AppModel
import Foundation
import Persistence
import PlayerCore
import Testing
import WidgetProtocol

@testable import Whirr

@MainActor
@Suite("Smart list widget intents", .serialized)
struct SmartListWidgetIntentTests {
  @Test("a list row's token starts a run from that list, only through a bound account")
  func performerStartsARunFromTheList() async throws {
    let router = SiriPlaybackActionRouter()
    let handler = InertVoiceHandler()
    let starter = RecordingListStarter()
    let selection = CompanionSelection(
      source: try #require(PodcastSourceIdentity(itemId: "show-a")), episodeID: "episode-a")
    let row = WidgetTokenMap.ListSelection(listID: 4, selection: selection)
    func perform(_ resolve: @escaping @MainActor (String) -> WidgetTokenMap.ListSelection?) async
      -> SiriPlaybackIntentResponse
    {
      await SiriPlaybackIntentPerformer.perform(
        .playSmartListItem(token: "t"), router: router, resolveListToken: resolve)
    }

    #expect(await perform { _ in row } == .accountUnavailable)

    router.bind(handler)
    #expect(await perform { _ in row } == .accountUnavailable, "no smart lists composed")

    router.bind(handler, smartLists: starter)
    #expect(await perform { _ in nil } == .itemUnavailable)
    #expect(starter.calls.isEmpty)

    #expect(await perform { $0 == "t" ? row : nil } == .resuming)
    #expect(starter.calls == [.init(listID: 4, itemID: "show-a", episodeID: "episode-a")])
    #expect(handler.plays == 0, "a list row never goes through the shelf's plain play")

    starter.result = false
    #expect(await perform { _ in row } == .startFailed)

    router.unbind()
    #expect(await perform { _ in row } == .accountUnavailable)
  }

  @Test("a shelf token is not a list token, and the shelf intent never starts a run")
  func shelfAndListTokensStayApart() async throws {
    let router = SiriPlaybackActionRouter()
    let handler = InertVoiceHandler()
    let starter = RecordingListStarter()
    router.bind(handler, smartLists: starter)
    let selection = CompanionSelection(
      source: try #require(PodcastSourceIdentity(itemId: "show-a")), episodeID: "episode-a")

    #expect(
      await SiriPlaybackIntentPerformer.perform(
        .playWidgetItem(token: "t"), router: router, resolveWidgetToken: { _ in selection },
        resolveListToken: { _ in
          Issue.record("read the list map")
          return nil
        }) == .resuming)
    #expect(handler.plays == 1)
    #expect(starter.calls.isEmpty)
  }

  @Test("the list play intent is a hidden, lock-screen-safe audio intent carrying only the token")
  func playIntentShape() {
    #expect(PlaySmartListItemIntent.isDiscoverable == false)
    #expect(PlaySmartListItemIntent.supportedModes == .background)
    #expect(PlaySmartListItemIntent.authenticationPolicy == .alwaysAllowed)
    #expect(PlaySmartListItemIntent(token: "abc").token == "abc")
  }

  @Test("Edit Widget offers the published lists in order, and none when signed out")
  func entityQueryReadsThePublishedLists() async throws {
    let container = FileManager.default.temporaryDirectory.appendingPathComponent(
      "SmartListWidgetIntentTests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: container) }
    let file = WidgetStorageLayout.smartListsFile(inContainer: container)
    try FileManager.default.createDirectory(
      at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    let query = SmartListEntityQuery(reader: WidgetSmartListsReader(containerURL: container))

    #expect(try await query.suggestedEntities().isEmpty, "nothing published")

    let lists = try WidgetSmartLists(
      generatedAt: Date(timeIntervalSince1970: 1), accountStamp: WidgetPublicationTests.stamp("a"),
      isPlaying: false,
      lists: [
        WidgetSmartList(id: 9, name: "Morning", matchCount: 0, items: []),
        WidgetSmartList(id: 2, name: "Commute", matchCount: 0, items: []),
      ])
    try WidgetSmartListsCodec.encode(lists).write(to: file)

    #expect(try await query.suggestedEntities().map(\.name) == ["Morning", "Commute"])
    #expect(try await query.entities(for: ["2", "404"]).map(\.name) == ["Commute"])

    try WidgetSmartListsCodec.encode(.signedOut(generatedAt: Date(timeIntervalSince1970: 2))).write(to: file)
    #expect(try await query.suggestedEntities().isEmpty)
  }
}

@MainActor
private final class RecordingListStarter: SmartListPlaybackStarting {
  struct Call: Equatable {
    let listID: Int64
    let itemID: String
    let episodeID: String
  }

  var result = true
  private(set) var calls: [Call] = []

  func startFromList(listID: Int64, itemID: String, episodeID: String) async -> Bool {
    calls.append(Call(listID: listID, itemID: itemID, episodeID: episodeID))
    return result
  }
}

@MainActor
private final class InertVoiceHandler: VoicePlaybackActionHandling {
  private(set) var plays = 0

  func resumeLastPlayed() async -> VoicePlaybackActionResult { .performed }
  func pausePlayback() -> VoicePlaybackActionResult { .performed }
  func skip(by seconds: Double) async -> VoicePlaybackActionResult { .performed }
  func setSleepTimer(_ duration: SleepTimerDuration) -> VoicePlaybackActionResult { .performed }
  func extendSleepTimer(by seconds: Double) -> VoicePlaybackActionResult { .performed }

  func play(selection: CompanionSelection) async -> VoicePlaybackActionResult {
    plays += 1
    return .performed
  }
}
