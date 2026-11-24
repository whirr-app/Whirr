import Foundation
import GRDB
import Persistence
import TestSupport
import Testing

@testable import AppModel

@MainActor
@Suite("SmartListModel")
struct SmartListModelTests {
  private func make(
    episodes: [(String, TimeInterval)] = [("new", 60), ("old", 3_600)],
    rules: SmartListRules = .default,
    playback: SmartListPlaybackSpy? = nil,
    nativeEnabled: Bool = true
  ) async throws -> (SmartListFixture, SmartList, Int64, SmartListModel) {
    let fixture = try SmartListFixture(nativeEnabled: nativeEnabled)
    let feed = try await fixture.feed("https://a.example/feed", title: "Show A")
    for (key, age) in episodes { try await fixture.episode(feed: feed, key, ageSeconds: age) }
    let list = try await fixture.services.store.create(name: "Commute", rules: rules)
    let model = SmartListModel(listID: list.id, services: fixture.services, playback: playback)
    return (fixture, list, feed, model)
  }

  @Test("loads the list's rows in order and its name")
  func loadsRows() async throws {
    let (_, list, feed, model) = try await make()
    #expect(await waitUntil("loaded") { model.state == .loaded && model.episodes.count == 2 })
    #expect(model.list?.name == "Commute")
    #expect(model.episodes.map(\.title) == ["T-new", "T-old"])
    #expect(model.episodes.first?.itemID == "rss:\(feed)")
    #expect(model.matchCount == 2)
    #expect(model.hasMore == false)
    #expect(model.listID == list.id)
  }

  @Test("unavailable when native is off and nobody is signed in")
  func unavailable() async throws {
    let (fixture, _, _, model) = try await make(nativeEnabled: false)
    #expect(await waitUntil("unavailable") { model.state == .unavailable })
    #expect(model.episodes.isEmpty)

    await fixture.preference.setEnabled(true)
    #expect(await waitUntil("loaded") { model.state == .loaded && model.episodes.count == 2 })
  }

  @Test("a deleted list is missing")
  func missingList() async throws {
    let (fixture, list, _, model) = try await make()
    #expect(await waitUntil("loaded") { model.episodes.count == 2 })
    try await fixture.services.store.delete(id: list.id)
    await model.reload()
    #expect(model.state == .missing)
    #expect(model.list == nil)
  }

  @Test("the first page is 200 rows and more load on scroll up to the end")
  func pagination() async throws {
    let episodes = (0..<250).map { ("e\($0)", TimeInterval($0)) }
    let (_, _, _, model) = try await make(episodes: episodes)
    #expect(await waitUntil("first page") { model.episodes.count == 200 })
    #expect(model.hasMore)
    #expect(model.matchCount == 250)
    #expect(model.limit == 200)

    model.loadMore()
    #expect(await waitUntil("second page") { model.episodes.count == 250 })
    #expect(model.hasMore == false)
    #expect(model.limit == 400)

    model.loadMore()
    #expect(model.limit == 400)
  }

  @Test("hiding removes the row and unhiding brings it back")
  func hideAndUnhide() async throws {
    let (fixture, list, _, model) = try await make()
    #expect(await waitUntil("loaded") { model.episodes.count == 2 })
    let target = try #require(model.episodes.first)

    await model.hide(target)
    #expect(await waitUntil("row hidden") { model.episodes.map(\.title) == ["T-old"] })
    #expect(model.lastHidden?.episodeID == target.episodeID)
    let hidden = try await fixture.services.hiddenEpisodes.hiddenEpisodes(listID: list.id)
    #expect(hidden.map(\.episodeID) == [target.episodeID])

    await model.unhide(itemID: target.itemID, episodeID: target.episodeID)
    #expect(await waitUntil("row back") { model.episodes.count == 2 })
    #expect(model.lastHidden == nil)
    #expect(model.error == nil)
  }

  @Test("Play starts the first unfinished episode within the list, and writes no run itself")
  func playStartsFirstWithoutWritingRun() async throws {
    let spy = SmartListPlaybackSpy()
    let (fixture, list, feed, model) = try await make(playback: spy)
    #expect(await waitUntil("loaded") { model.episodes.count == 2 })

    let started = await model.play()
    #expect(started)
    #expect(spy.calls.count == 1)
    #expect(spy.calls.first?.listID == list.id)
    #expect(spy.calls.first?.itemID == "rss:\(feed)")
    #expect(spy.calls.first?.episodeID == model.episodes.first?.episodeID)
    #expect(try await fixture.services.runs.current() == nil)
    #expect(model.error == nil)
  }

  @Test("Play skips finished episodes")
  func playSkipsFinished() async throws {
    let spy = SmartListPlaybackSpy()
    let (fixture, _, feed, model) = try await make(
      rules: SmartListRules(includePlayed: true), playback: spy)
    #expect(await waitUntil("loaded") { model.episodes.count == 2 })
    let newest = try #require(model.episodes.first)
    let newestRow = try await fixture.database.readAsync { db in
      try Int64.fetchOne(
        db, sql: "SELECT id FROM rssEpisode WHERE feedId = ? AND identityKey = ?",
        arguments: [feed, newest.episodeID])
    }
    try await fixture.finish(try #require(newestRow))
    #expect(await waitUntil("finished") { model.episodes.first?.isFinished == true })

    await model.play()
    #expect(spy.calls.first?.episodeID == model.episodes.last?.episodeID)
  }

  @Test("a row starts that episode within the list")
  func playRow() async throws {
    let spy = SmartListPlaybackSpy()
    let (_, list, _, model) = try await make(playback: spy)
    #expect(await waitUntil("loaded") { model.episodes.count == 2 })
    let row = try #require(model.episodes.last)

    #expect(await model.play(row))
    #expect(spy.calls == [.init(listID: list.id, itemID: row.itemID, episodeID: row.episodeID)])
  }

  @Test("a failed start reports an error and leaves no run")
  func failedStart() async throws {
    let spy = SmartListPlaybackSpy()
    spy.succeeds = false
    let (fixture, _, _, model) = try await make(playback: spy)
    #expect(await waitUntil("loaded") { model.episodes.count == 2 })

    #expect(await model.play() == false)
    #expect(model.error == .startFailed)
    #expect(model.isRunActive == false)
    #expect(try await fixture.services.runs.current() == nil)
    #expect(model.isStarting == false)
  }

  @Test("the run is active only once playback has begun it")
  func runActiveAfterPlaybackBeginsIt() async throws {
    let spy = SmartListPlaybackSpy()
    let (fixture, list, _, model) = try await make(playback: spy)
    spy.onStart = {
      try? await fixture.services.runs.begin(listID: list.id)
    }
    #expect(await waitUntil("loaded") { model.episodes.count == 2 })
    #expect(model.isRunActive == false)

    await model.play()
    #expect(model.isRunActive)
  }

  @Test("nothing to play is reported, and nothing starts")
  func nothingToPlay() async throws {
    let spy = SmartListPlaybackSpy()
    let (_, _, _, model) = try await make(episodes: [], playback: spy)
    #expect(await waitUntil("loaded") { model.state == .loaded })

    #expect(await model.play() == false)
    #expect(model.error == .nothingToPlay)
    #expect(spy.calls.isEmpty)
  }

  @Test("an edit to the rules reaches the rows")
  func ruleEditReachesRows() async throws {
    let (fixture, list, _, model) = try await make()
    #expect(await waitUntil("loaded") { model.episodes.count == 2 })
    try await fixture.services.store.updateRules(
      id: list.id, rules: SmartListRules(includeUnplayed: false, includeInProgress: true))
    #expect(await waitUntil("narrowed") { model.episodes.count == 0 })
  }

  @Test("a rename elsewhere reaches the list screen")
  func renameElsewherePushes() async throws {
    let (fixture, list, _, model) = try await make()
    #expect(await waitUntil("loaded") { model.list?.name == "Commute" })
    try await fixture.services.store.rename(id: list.id, to: "Gym")
    #expect(await waitUntil("renamed") { model.list?.name == "Gym" })
  }
}
