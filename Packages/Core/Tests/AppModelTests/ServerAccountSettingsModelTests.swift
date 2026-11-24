import Foundation
import Persistence
import SyncEngine
import Testing

@testable import AppModel

@MainActor
@Suite struct ServerAccountSettingsModelTests {
  @Test func durableRowsRemainWhenTheLiveProfileIsUnavailable() async {
    let durable = Self.durableSettings()
    let reading = FakeServerAccountReading(
      durableResult: .success(durable), profileResult: .failure(FakeReadingError.offline))
    let model = ServerAccountSettingsModel(reading: reading)

    await model.load()

    #expect(model.loadState == .loaded)
    #expect(model.profileState == .unavailable)
    #expect(model.durableSettings == durable)
    #expect(model.profile == nil)
    #expect(ServerAccountSettingsCopy.profileUnavailableMessage.contains("Saved server"))
  }

  @Test func successfulProfileReadExposesOnlyTheBoundedFields() async {
    let profile = ServerAccountProfile(
      username: "fixture-user",
      type: "user",
      librariesAccessible: ["library-book", "library-podcast"])
    let reading = FakeServerAccountReading(
      durableResult: .success(Self.durableSettings()), profileResult: .success(profile))
    let model = ServerAccountSettingsModel(reading: reading)

    await model.load()

    #expect(model.loadState == .loaded)
    #expect(model.profileState == .available)
    #expect(model.profile == profile)
    #expect(model.profile?.librariesAccessible == ["library-book", "library-podcast"])
  }

  @Test func durableReadFailureIsAnExplicitFailedState() async {
    let reading = FakeServerAccountReading(
      durableResult: .failure(FakeReadingError.missingAccount),
      profileResult: .success(
        ServerAccountProfile(username: "unused", type: "user", librariesAccessible: [])))
    let model = ServerAccountSettingsModel(reading: reading)

    await model.load()

    #expect(model.loadState == .failed)
    #expect(model.profileState == .unavailable)
    #expect(model.durableSettings == nil)
    #expect(model.profile == nil)
  }

  /// A second load after the server comes back must clear the unavailable state, not leave the
  /// screen claiming an outage that has ended.
  @Test func aSuccessfulProfileReadClearsTheUnavailableState() async {
    let reading = FakeServerAccountReading(
      durableResult: .success(Self.durableSettings()), profileResult: .failure(FakeReadingError.offline))
    let model = ServerAccountSettingsModel(reading: reading)

    await model.load()
    #expect(model.profileState == .unavailable)

    reading.profileResult = .success(
      ServerAccountProfile(username: "user", type: "user", librariesAccessible: []))
    await model.load()

    #expect(model.profileState == .available)
  }

  @Test func headerSummarySortsNamesAndExposesNoValues() {
    let summary = CustomHeaderSummary(names: ["X-Second", "X-First"])

    #expect(summary.names == ["X-First", "X-Second"])
    #expect(summary.count == 2)
    #expect(ServerAccountSettingsCopy.headersFooter.contains("never displayed"))
  }

  @Test func syncCopyNamesTheExistingOldestLibraryProjection() {
    let status = LibrarySyncStatus(
      isRunning: false, lastRunIncomplete: false, lastCompletedAt: Date(timeIntervalSince1970: 1))

    #expect(ServerAccountSettingsCopy.syncStatus(for: status) == ServerAccountSettingsCopy.syncReady)
    #expect(ServerAccountSettingsCopy.oldestLibraryCompletion.lowercased().contains("oldest"))
  }

  private static func durableSettings() -> ServerAccountDurableSettings {
    ServerAccountDurableSettings(
      serverVersion: "2.35.1",
      libraries: [
        ServerAccountLibrary(id: "library-book", name: "Books", mediaType: "book"),
        ServerAccountLibrary(id: "library-podcast", name: "Podcasts", mediaType: "podcast"),
      ],
      syncStatus: LibrarySyncStatus(
        isRunning: false, lastRunIncomplete: false, lastCompletedAt: Date(timeIntervalSince1970: 1)),
      customHeaders: CustomHeaderSummary(names: ["CF-Access-Client-Id"])
    )
  }
}

private enum FakeReadingError: Error {
  case offline
  case missingAccount
}

private final class FakeServerAccountReading: ServerAccountReading, @unchecked Sendable {
  let durableResult: Result<ServerAccountDurableSettings, Error>
  var profileResult: Result<ServerAccountProfile, Error>

  init(
    durableResult: Result<ServerAccountDurableSettings, Error>,
    profileResult: Result<ServerAccountProfile, Error>
  ) {
    self.durableResult = durableResult
    self.profileResult = profileResult
  }

  func readDurableSettings() async throws -> ServerAccountDurableSettings {
    try durableResult.get()
  }

  func fetchProfile() async throws -> ServerAccountProfile {
    try profileResult.get()
  }
}
