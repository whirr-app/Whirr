import AppModel
import Foundation
import Testing

@testable import Whirr

@Suite struct PodcastBackupFolderTests {
  nonisolated private final class AccessLog: @unchecked Sendable {
    private let lock = NSLock()
    private var counts = (starts: 0, stops: 0)
    var starts: Int { lock.withLock { counts.starts } }
    var stops: Int { lock.withLock { counts.stops } }
    func start() { lock.withLock { counts.starts += 1 } }
    func stop() { lock.withLock { counts.stops += 1 } }
  }

  private func makeFolder() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("PodcastBackupFolderTests-\(UUID())")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private func writer(_ log: AccessLog, granted: Bool = true) -> PodcastBackupFolder {
    PodcastBackupFolder(
      startAccess: { _ in
        log.start()
        return granted
      },
      stopAccess: { _ in log.stop() })
  }

  private func name(_ day: Int) -> String {
    "Whirr Podcasts 2026-09-\(String(format: "%02d", day)).whirrpodcasts.json"
  }

  @Test func writesAVerifiedBackupAndKeepsTheThreeNewest() async throws {
    let folder = try makeFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    for day in 20...23 { try Data("old \(day)".utf8).write(to: folder.appendingPathComponent(name(day))) }
    try Data("mine".utf8).write(to: folder.appendingPathComponent("Notes.txt"))
    let log = AccessLog()
    let writer = writer(log)

    let choice = try await writer.choose(pickedFolder: folder)
    #expect(choice.name == folder.lastPathComponent)
    let data = Data("new backup".utf8)
    _ = try await writer.write(data, named: name(25), toFolder: choice.bookmark, keepingExistingBackups: false)

    let remaining = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
    #expect(remaining == ["Notes.txt", name(22), name(23), name(25)])
    #expect(try Data(contentsOf: folder.appendingPathComponent(name(25))) == data)
    #expect(log.starts == 2)
    #expect(log.stops == log.starts)
  }

  @Test func sameDayBackupReplacesTheEarlierFile() async throws {
    let folder = try makeFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    try Data("manual".utf8).write(to: folder.appendingPathComponent(name(25)))
    let writer = writer(AccessLog())
    let choice = try await writer.choose(pickedFolder: folder)

    _ = try await writer.write(
      Data("automatic".utf8), named: name(25), toFolder: choice.bookmark, keepingExistingBackups: false)
    #expect(try Data(contentsOf: folder.appendingPathComponent(name(25))) == Data("automatic".utf8))
  }

  @Test func keepingExistingBackupsNeitherReplacesNorPrunesThem() async throws {
    let folder = try makeFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    for day in 20...25 { try Data("old \(day)".utf8).write(to: folder.appendingPathComponent(name(day))) }
    let log = AccessLog()
    let writer = writer(log)
    let choice = try await writer.choose(pickedFolder: folder)

    // Today's file exists and so do more than three generations: neither may change.
    await #expect(throws: PodcastBackupFolderError.existingBackupsKept) {
      _ = try await writer.write(
        Data("empty".utf8), named: name(25), toFolder: choice.bookmark, keepingExistingBackups: true)
    }
    await #expect(throws: PodcastBackupFolderError.existingBackupsKept) {
      _ = try await writer.write(
        Data("empty".utf8), named: name(26), toFolder: choice.bookmark, keepingExistingBackups: true)
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted() == (20...25).map(name))
    for day in 20...25 {
      #expect(try Data(contentsOf: folder.appendingPathComponent(name(day))) == Data("old \(day)".utf8))
    }
    #expect(log.stops == log.starts)
  }

  @Test func keepingExistingBackupsCountsAnUndownloadedOne() async throws {
    let folder = try makeFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    try Data().write(to: folder.appendingPathComponent(".\(name(20)).icloud"))
    let writer = writer(AccessLog())
    let choice = try await writer.choose(pickedFolder: folder)

    await #expect(throws: PodcastBackupFolderError.existingBackupsKept) {
      _ = try await writer.write(
        Data("empty".utf8), named: name(25), toFolder: choice.bookmark, keepingExistingBackups: true)
    }
    #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent(name(25)).path) == false)
  }

  @Test func keepingExistingBackupsStillWritesToAFolderWithNone() async throws {
    let folder = try makeFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    try Data("mine".utf8).write(to: folder.appendingPathComponent("Notes.txt"))
    let writer = writer(AccessLog())
    let choice = try await writer.choose(pickedFolder: folder)

    let data = Data("empty".utf8)
    _ = try await writer.write(data, named: name(25), toFolder: choice.bookmark, keepingExistingBackups: true)
    #expect(try Data(contentsOf: folder.appendingPathComponent(name(25))) == data)
    #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted() == ["Notes.txt", name(25)])
  }

  @Test func aFailedWriteDeletesNothing() async throws {
    let folder = try makeFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    for day in 20...23 { try Data("old \(day)".utf8).write(to: folder.appendingPathComponent(name(day))) }
    // A directory where the new file should go makes the write fail.
    try FileManager.default.createDirectory(
      at: folder.appendingPathComponent(name(25)), withIntermediateDirectories: false)
    let log = AccessLog()
    let writer = writer(log)
    let choice = try await writer.choose(pickedFolder: folder)

    await #expect(throws: PodcastBackupFolderError.writeFailed) {
      _ = try await writer.write(
        Data("new".utf8), named: name(25), toFolder: choice.bookmark, keepingExistingBackups: false)
    }
    for day in 20...23 {
      #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent(name(day)).path))
    }
    #expect(log.stops == log.starts)
  }

  @Test func refusedAccessIsAnUnavailableFolder() async throws {
    let folder = try makeFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let choice = try await writer(AccessLog()).choose(pickedFolder: folder)
    let refused = writer(AccessLog(), granted: false)

    await #expect(throws: PodcastBackupFolderError.folderUnavailable) {
      _ = try await refused.choose(pickedFolder: folder)
    }
    await #expect(throws: PodcastBackupFolderError.folderUnavailable) {
      _ = try await refused.write(
        Data("x".utf8), named: name(25), toFolder: choice.bookmark, keepingExistingBackups: false)
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
  }

  @Test func aDeletedFolderIsUnavailable() async throws {
    let folder = try makeFolder()
    let writer = writer(AccessLog())
    let choice = try await writer.choose(pickedFolder: folder)
    try FileManager.default.removeItem(at: folder)

    await #expect(throws: PodcastBackupFolderError.folderUnavailable) {
      _ = try await writer.write(
        Data("x".utf8), named: name(25), toFolder: choice.bookmark, keepingExistingBackups: false)
    }
    #expect(FileManager.default.fileExists(atPath: folder.path) == false)
  }

  @Test func storeRoundTripsAndStartsOff() throws {
    let suite = "PodcastBackupFolderTests-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = UserDefaultsPodcastAutoBackupStore(defaults: defaults)
    #expect(store.load() == PodcastAutoBackupState())

    let state = PodcastAutoBackupState(
      folderBookmark: Data("b".utf8), folderName: "Backups", lastSuccess: Date(timeIntervalSince1970: 10),
      lastFailure: Date(timeIntervalSince1970: 20), failure: .folderUnavailable)
    store.save(state)
    #expect(UserDefaultsPodcastAutoBackupStore(defaults: defaults).load() == state)
  }

  @Test func automaticBackupStaysOutOfTheICloudAllowlist() {
    #expect(ICloudSettingsSync.syncedKeys.contains(UserDefaultsPodcastAutoBackupStore.key) == false)
  }
}
