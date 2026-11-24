import Foundation
import TestSupport
import Testing

@testable import AppModel

@MainActor
@Suite(.timeLimit(.minutes(1))) struct PodcastAutoBackupModelTests {
  private struct TestError: Error {}

  /// Counts exports and can hold them open until the test releases them; a test waits for a held
  /// export to start with `gate.waitUntilParked()`.
  private actor Exporter: PodcastBackupExporting {
    // A held export runs to completion regardless of cancellation, as the real one does.
    nonisolated let gate = TestGate<Void>(label: "Exporter exportBackup", ignoresCancellation: true)
    private(set) var calls = 0
    private var failing = false
    private var empty = false

    func setFailing(_ value: Bool) { failing = value }
    /// A database with no shows or episodes, as after a reinstall.
    func setEmpty(_ value: Bool) { empty = value }
    func holdNextExport() { gate.hold() }
    func release() { gate.release() }

    func exportBackup(at date: Date) async throws -> PodcastBackupExport {
      calls += 1
      await gate.pass()
      if failing { throw TestError() }
      let count = empty ? 0 : 1
      return PodcastBackupExport(
        data: Data("backup \(date.timeIntervalSince1970)".utf8), showCount: count, episodeCount: count)
    }
  }

  private actor Folder: PodcastBackupFolderWriting {
    struct Write: Equatable {
      let name: String
      let bookmark: Data
    }
    private(set) var writes: [Write] = []
    var writeError: PodcastBackupFolderError?
    var pickError: PodcastBackupFolderError?
    var refreshedBookmark: Data?
    /// Whether the folder already holds a backup. Any write leaves one behind.
    private(set) var holdsBackups = false

    func set(holdsBackups: Bool) { self.holdsBackups = holdsBackups }
    func set(writeError: PodcastBackupFolderError?) { self.writeError = writeError }
    func set(pickError: PodcastBackupFolderError?) { self.pickError = pickError }
    func set(refreshedBookmark: Data?) { self.refreshedBookmark = refreshedBookmark }

    func choose(pickedFolder url: URL) async throws -> PodcastBackupFolderChoice {
      if let pickError { throw pickError }
      return PodcastBackupFolderChoice(bookmark: Data(url.lastPathComponent.utf8), name: url.lastPathComponent)
    }

    func write(
      _ data: Data, named filename: String, toFolder bookmark: Data, keepingExistingBackups: Bool
    ) async throws -> Data? {
      if let writeError { throw writeError }
      if keepingExistingBackups, holdsBackups { throw PodcastBackupFolderError.existingBackupsKept }
      writes.append(Write(name: filename, bookmark: bookmark))
      holdsBackups = true
      return refreshedBookmark
    }
  }

  private final class Store: PodcastAutoBackupStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: PodcastAutoBackupState
    init(_ state: PodcastAutoBackupState = PodcastAutoBackupState()) { stored = state }
    var state: PodcastAutoBackupState { lock.withLock { stored } }
    func load() -> PodcastAutoBackupState { state }
    func save(_ state: PodcastAutoBackupState) { lock.withLock { stored = state } }
  }

  private final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date(timeIntervalSince1970: 1_790_000_000)
    var now: Date { lock.withLock { value } }
    func advance(hours: Double) { lock.withLock { value += hours * 3_600 } }
  }

  private let exporter = Exporter()
  private let folder = Folder()
  private let clock = Clock()
  private let picked = URL(fileURLWithPath: "/picked/Whirr Backups", isDirectory: true)

  private func model(_ store: Store) -> PodcastAutoBackupModel {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Europe/London")!
    let clock = clock
    return PodcastAutoBackupModel(
      exporter: exporter, folder: folder, store: store, now: { clock.now }, calendar: calendar)
  }

  @Test func startsOffAndDoesNothingWhenOff() async {
    let model = model(Store())
    #expect(model.isOn == false)
    await model.runIfDue()
    #expect(await exporter.calls == 0)
  }

  @Test func choosingAFolderBacksUpAtOnceAndOnlyThenTurnsOn() async {
    let store = Store()
    let model = model(store)
    await model.choose(folder: picked)

    #expect(model.isOn)
    #expect(model.state.folderName == "Whirr Backups")
    #expect(model.state.lastSuccess == clock.now)
    #expect(model.choiceFailed == false)
    #expect(store.state == model.state)
    #expect(
      await folder.writes
        == [.init(name: "Whirr Podcasts 2026-09-21.whirrpodcasts.json", bookmark: Data("Whirr Backups".utf8))])
  }

  @Test func aFailedFirstBackupLeavesItOff() async {
    await folder.set(writeError: .writeFailed)
    let store = Store()
    let model = model(store)
    await model.choose(folder: picked)

    #expect(model.isOn == false)
    #expect(model.choiceFailed)
    #expect(store.state == PodcastAutoBackupState())
  }

  @Test func nothingToBackUpNeverTouchesAFolderThatAlreadyHoldsBackups() async {
    await exporter.setEmpty(true)
    await folder.set(holdsBackups: true)
    let store = Store()
    let model = model(store)
    await model.choose(folder: picked)

    #expect(await folder.writes.isEmpty)
    #expect(model.isOn == false)
    #expect(model.choiceKeptExistingBackups)
    #expect(model.choiceFailed == false)
    #expect(store.state == PodcastAutoBackupState())

    // Once there is something to back up, the same folder is accepted.
    await exporter.setEmpty(false)
    await model.choose(folder: picked)
    #expect(model.isOn)
    #expect(model.choiceKeptExistingBackups == false)
    #expect(await folder.writes.count == 1)
  }

  @Test func anEmptyLibraryCanTurnOnWithAFolderHoldingNoBackups() async {
    await exporter.setEmpty(true)
    let model = model(Store())
    await model.choose(folder: picked)

    #expect(model.isOn)
    #expect(model.choiceKeptExistingBackups == false)
    #expect(await folder.writes.count == 1)
  }

  @Test func aFolderChangeWithNothingToBackUpKeepsTheCurrentFolder() async {
    let store = Store()
    let model = model(store)
    await model.choose(folder: picked)
    let before = model.state

    await exporter.setEmpty(true)
    await model.choose(folder: URL(fileURLWithPath: "/picked/Elsewhere", isDirectory: true))
    #expect(model.state == before)
    #expect(store.state == before)
    #expect(model.choiceKeptExistingBackups)
    #expect(await folder.writes.count == 1)
  }

  @Test func aDailyRunWithNothingToBackUpLeavesExistingBackupsAlone() async {
    let store = Store()
    let model = model(store)
    await model.choose(folder: picked)
    let success = model.state.lastSuccess

    // The database was lost: the daily run must neither replace nor prune what is in the folder.
    await exporter.setEmpty(true)
    clock.advance(hours: 24)
    await model.runIfDue()
    #expect(await folder.writes.count == 1)
    #expect(model.isOn)
    #expect(model.state.lastSuccess == success)
    #expect(model.state.failure == .nothingToBackUp)
    #expect(store.state.failure == .nothingToBackUp)

    // After a restore the next attempt backs up as usual.
    await exporter.setEmpty(false)
    clock.advance(hours: 1)
    await model.runIfDue()
    #expect(await folder.writes.count == 2)
    #expect(model.state.failure == nil)
    #expect(model.state.lastSuccess == clock.now)
  }

  @Test func aFailedFolderChangeKeepsTheCurrentFolder() async {
    let store = Store()
    let model = model(store)
    await model.choose(folder: picked)
    let before = model.state

    await folder.set(pickError: .folderUnavailable)
    await model.choose(folder: URL(fileURLWithPath: "/picked/Elsewhere", isDirectory: true))
    #expect(model.state == before)
    #expect(store.state == before)
    #expect(model.choiceFailed)
  }

  @Test func runsOnceADay() async {
    let model = model(Store())
    await model.choose(folder: picked)

    clock.advance(hours: 23)
    await model.runIfDue()
    #expect(await folder.writes.count == 1)

    clock.advance(hours: 1)
    await model.runIfDue()
    #expect(await folder.writes.count == 2)
    #expect(model.state.lastSuccess == clock.now)
  }

  @Test func aFailedRunKeepsTheLastSuccessAndWaitsAnHour() async {
    let store = Store()
    let model = model(store)
    await model.choose(folder: picked)
    let success = model.state.lastSuccess

    clock.advance(hours: 24)
    await folder.set(writeError: .folderUnavailable)
    await model.runIfDue()
    #expect(model.state.lastSuccess == success)
    #expect(model.state.failure == .folderUnavailable)
    #expect(store.state.failure == .folderUnavailable)
    #expect(model.isOn)

    await folder.set(writeError: nil)
    clock.advance(hours: 0.5)
    await model.runIfDue()
    #expect(await folder.writes.count == 1)

    clock.advance(hours: 0.5)
    await model.runIfDue()
    #expect(await folder.writes.count == 2)
    #expect(model.state.failure == nil)
    #expect(model.state.lastFailure == nil)
  }

  @Test func anExportFailureCountsAsAWriteFailure() async {
    let model = model(Store())
    await model.choose(folder: picked)
    clock.advance(hours: 24)
    await exporter.setFailing(true)
    await model.runIfDue()
    #expect(model.state.failure == .writeFailed)
  }

  @Test func aStaleBookmarkIsReplacedByTheRefreshedOne() async {
    let store = Store()
    let model = model(store)
    await model.choose(folder: picked)
    await folder.set(refreshedBookmark: Data("fresh".utf8))

    clock.advance(hours: 24)
    await model.runIfDue()
    #expect(model.state.folderBookmark == Data("fresh".utf8))
    #expect(store.state.folderBookmark == Data("fresh".utf8))
  }

  @Test func overlappingTriggersRunOnce() async {
    let model = model(Store())
    await model.choose(folder: picked)
    clock.advance(hours: 24)

    await exporter.holdNextExport()
    let first = Task { await model.runIfDue() }
    await exporter.gate.waitUntilParked()
    #expect(model.isRunning)
    await model.runIfDue()
    await exporter.release()
    await first.value

    #expect(await exporter.calls == 2)
    #expect(await folder.writes.count == 2)
    #expect(model.isRunning == false)
  }

  @Test func turningOffForgetsTheFolderAndARunInFlightDoesNotRevive() async {
    let store = Store()
    let model = model(store)
    await model.choose(folder: picked)
    clock.advance(hours: 24)

    await exporter.holdNextExport()
    let run = Task { await model.runIfDue() }
    await exporter.gate.waitUntilParked()
    model.turnOff()
    await exporter.release()
    await run.value

    #expect(model.isOn == false)
    #expect(model.state == PodcastAutoBackupState())
    #expect(store.state == PodcastAutoBackupState())
  }

  @Test func restoresItsStateFromTheStore() {
    let saved = PodcastAutoBackupState(
      folderBookmark: Data("b".utf8), folderName: "Backups", lastSuccess: Date(timeIntervalSince1970: 5),
      lastFailure: nil, failure: nil)
    let model = model(Store(saved))
    #expect(model.isOn)
    #expect(model.state == saved)
  }
}
