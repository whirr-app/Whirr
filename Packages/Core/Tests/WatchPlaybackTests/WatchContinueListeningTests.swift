import ABSApi
import Foundation
import Testing

@testable import WatchPlayback

@Suite struct WatchContinueListeningTests {
  @Test func onlyUnfinishedAudioWithAResumePositionAppears() async throws {
    let service = try FakeService()
    service.progressValue = UserProgressSnapshot(
      progress: [
        row("listening", seconds: 15),
        row("reset", seconds: 0),
        row("reset-with-old-fraction", seconds: 0, fraction: 0.5),
        row("never-started", seconds: nil),
        row("ebook", seconds: nil, duration: nil, ebook: 0.5),
        row("ebook-zero-audio", seconds: 0, duration: 0, ebook: 0.5),
        row("mixed-book", seconds: 30, ebook: 0.5),
        row("fraction-only", seconds: nil, fraction: 0.25),
        row("finished", seconds: 50, finished: true),
        row("at-end", seconds: 100),
        row("past-end", seconds: 101),
        row("hidden", seconds: 50, hidden: true),
        row("negative", seconds: -1),
        row("nonfinite", seconds: .infinity),
        row("invalid-duration", seconds: 1, duration: .nan),
      ], hiddenSeriesIDs: [])
    let client = WatchLibraryClient(
      accountStore: WatchAccountStore(tokenStore: InMemoryTokenStore(), settings: LockedMemorySettings()),
      service: service)
    _ = try await client.login(apiToken: "fixture")

    let items = try await client.continueListening()
    #expect(items.map(\.id) == ["listening", "mixed-book", "fraction-only"])
    #expect(items.map(\.progressSeconds) == [15, 30, 25])
  }

  @Test func refreshedServerResetAndRemovalClearPreviousRows() async throws {
    let service = try FakeService()
    let client = WatchLibraryClient(
      accountStore: WatchAccountStore(tokenStore: InMemoryTokenStore(), settings: LockedMemorySettings()),
      service: service)
    _ = try await client.login(apiToken: "fixture")
    service.progressValue = UserProgressSnapshot(progress: [row("book", seconds: 15)], hiddenSeriesIDs: [])
    #expect(try await client.continueListening().count == 1)
    service.progressValue = UserProgressSnapshot(progress: [row("book", seconds: 0)], hiddenSeriesIDs: [])
    #expect(try await client.continueListening().isEmpty)
    service.progressValue = UserProgressSnapshot(progress: [], hiddenSeriesIDs: [])
    #expect(try await client.continueListening().isEmpty)
  }

  @Test func olderRefreshCannotRestoreRowsAfterANewerResetSnapshot() async throws {
    let service = try FakeService()
    let client = WatchLibraryClient(
      accountStore: WatchAccountStore(tokenStore: InMemoryTokenStore(), settings: LockedMemorySettings()),
      service: service)
    _ = try await client.login(apiToken: "fixture")
    let gate = BrowseResponseGate()
    service.progressValue = UserProgressSnapshot(progress: [row("book", seconds: 15)], hiddenSeriesIDs: [])
    service.progressGate = gate
    let older = Task { try await client.continueListening() }
    await gate.waitUntilEntered()
    service.progressGate = nil
    service.progressValue = UserProgressSnapshot(progress: [], hiddenSeriesIDs: [])
    #expect(try await client.continueListening().isEmpty)
    await gate.release()
    await #expect(throws: WatchLibraryError.staleRequest) { try await older.value }
  }

  @Test func progressResponseAfterLogoutIsDiscarded() async throws {
    let service = try FakeService()
    let client = WatchLibraryClient(
      accountStore: WatchAccountStore(tokenStore: InMemoryTokenStore(), settings: LockedMemorySettings()),
      service: service)
    _ = try await client.login(apiToken: "fixture")
    let gate = BrowseResponseGate()
    service.progressValue = UserProgressSnapshot(progress: [row("book", seconds: 15)], hiddenSeriesIDs: [])
    service.progressGate = gate
    let pending = Task { try await client.continueListening() }
    await gate.waitUntilEntered()
    try await client.logout()
    await gate.release()
    await #expect(throws: WatchLibraryError.staleRequest) { try await pending.value }
  }

  private func row(
    _ id: String, seconds: Double?, duration: Double? = 100, fraction: Double? = nil,
    ebook: Double? = nil, finished: Bool = false, hidden: Bool = false
  ) -> MediaProgress {
    MediaProgress(
      libraryItemID: id, episodeID: nil, mediaItemID: nil, mediaItemType: "book", duration: duration,
      progress: fraction, currentTime: seconds, isFinished: finished, hideFromContinueListening: hidden,
      ebookLocation: nil, ebookProgress: ebook, lastUpdate: Date(), startedAt: nil, finishedAt: nil)
  }
}
