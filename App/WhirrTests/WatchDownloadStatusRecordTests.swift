import Foundation
import Testing

@testable import Whirr

@Suite("Watch download status record")
struct WatchDownloadStatusRecordTests {
  private let installID = "0f0e0d0c-0b0a-4908-8706-050403020100"

  private func scratch() -> (defaults: UserDefaults, suite: String) {
    let suite = "watch.download.status.record.tests.\(UUID().uuidString)"
    return (UserDefaults(suiteName: suite)!, suite)
  }

  private var projection: [Int64: WatchEpisodeDownloadStatus] {
    [
      41: WatchEpisodeDownloadStatus(revision: 3, state: .downloading, progress: 0.42),
      42: WatchEpisodeDownloadStatus(revision: 1, state: .waitingForNetwork, progress: nil),
    ]
  }

  @Test func aProjectionRoundTripsItsRevisionsStatesAndProgress() {
    let (defaults, suite) = scratch()
    defer { defaults.removePersistentDomain(forName: suite) }
    let record = WatchDownloadStatusRecord(defaults: defaults)

    record.save(watchInstallID: installID, statuses: projection)

    #expect(record.load(watchInstallID: installID) == projection)
  }

  @Test func aProjectionFromAnotherInstallReadsNothing() {
    let (defaults, suite) = scratch()
    defer { defaults.removePersistentDomain(forName: suite) }
    let record = WatchDownloadStatusRecord(defaults: defaults)

    record.save(watchInstallID: installID, statuses: projection)

    #expect(record.load(watchInstallID: "another-install") == nil)
  }

  @Test func anEmptyProjectionOverwritesThePreviousOne() {
    let (defaults, suite) = scratch()
    defer { defaults.removePersistentDomain(forName: suite) }
    let record = WatchDownloadStatusRecord(defaults: defaults)
    record.save(watchInstallID: installID, statuses: projection)

    record.save(watchInstallID: installID, statuses: [:])

    // An empty answer is a real latest answer, not silence.
    #expect(record.load(watchInstallID: installID) == [:])
  }

  @Test func clearingRemovesTheRecordForEveryInstall() {
    let (defaults, suite) = scratch()
    defer { defaults.removePersistentDomain(forName: suite) }
    let record = WatchDownloadStatusRecord(defaults: defaults)
    record.save(watchInstallID: installID, statuses: projection)

    record.clear()

    #expect(record.load(watchInstallID: installID) == nil)
    #expect(defaults.data(forKey: "watch.download.status.record.v1") == nil)
  }
}
