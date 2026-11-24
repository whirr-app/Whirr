import ABSApi
import AppModel
import Foundation
import Persistence
import SyncEngine

@testable import Whirr

struct WatchSetupReading: ServerAccountReading, Sendable {
  let headerNames: [String]
  let profileUsername: String?

  init(headerNames: [String] = [], profileUsername: String? = "reader") {
    self.headerNames = headerNames
    self.profileUsername = profileUsername
  }

  func readDurableSettings() async throws -> ServerAccountDurableSettings {
    ServerAccountDurableSettings(
      serverVersion: "2.0.0", libraries: [],
      syncStatus: LibrarySyncStatus(isRunning: false, lastRunIncomplete: false, lastCompletedAt: nil),
      customHeaders: CustomHeaderSummary(names: headerNames))
  }

  func fetchProfile() async throws -> ServerAccountProfile {
    ServerAccountProfile(username: profileUsername, type: nil, librariesAccessible: [])
  }
}

struct WatchSetupUnavailableProfileReading: ServerAccountReading, Sendable {
  func readDurableSettings() async throws -> ServerAccountDurableSettings {
    ServerAccountDurableSettings(
      serverVersion: "2.0.0", libraries: [],
      syncStatus: LibrarySyncStatus(isRunning: false, lastRunIncomplete: false, lastCompletedAt: nil),
      customHeaders: CustomHeaderSummary(names: []))
  }

  func fetchProfile() async throws -> ServerAccountProfile {
    throw WatchSetupProfileUnavailable()
  }
}

struct WatchSetupProfileUnavailable: Error {}

actor WatchSetupRecoveringProfileReading: ServerAccountReading {
  private var profileRequests = 0

  func readDurableSettings() async throws -> ServerAccountDurableSettings {
    try await WatchSetupReading().readDurableSettings()
  }

  func fetchProfile() async throws -> ServerAccountProfile {
    profileRequests += 1
    if profileRequests == 1 { throw WatchSetupProfileUnavailable() }
    return ServerAccountProfile(username: "reader", type: nil, librariesAccessible: [])
  }
}

actor WatchSetupProfileGate {
  private var isOpen = false
  private var hasStarted = false
  private var waiters: [CheckedContinuation<Void, Never>] = []
  private var startedWaiters: [CheckedContinuation<Void, Never>] = []

  func wait() async {
    hasStarted = true
    let pending = startedWaiters
    startedWaiters.removeAll()
    for waiter in pending { waiter.resume() }
    if isOpen { return }
    await withCheckedContinuation { waiters.append($0) }
  }

  func waitUntilStarted() async {
    if hasStarted { return }
    await withCheckedContinuation { startedWaiters.append($0) }
  }

  func open() {
    isOpen = true
    let pending = waiters
    waiters.removeAll()
    for waiter in pending { waiter.resume() }
  }
}

struct WatchSetupDelayedProfileReading: ServerAccountReading, Sendable {
  let gate: WatchSetupProfileGate

  func readDurableSettings() async throws -> ServerAccountDurableSettings {
    ServerAccountDurableSettings(
      serverVersion: "2.0.0", libraries: [],
      syncStatus: LibrarySyncStatus(isRunning: false, lastRunIncomplete: false, lastCompletedAt: nil),
      customHeaders: CustomHeaderSummary(names: []))
  }

  func fetchProfile() async throws -> ServerAccountProfile {
    await gate.wait()
    return ServerAccountProfile(username: "stale-reader", type: nil, librariesAccessible: [])
  }
}

struct WatchSetupRetryReading: ServerAccountReading, Sendable {
  func readDurableSettings() async throws -> ServerAccountDurableSettings {
    ServerAccountDurableSettings(
      serverVersion: "2.0.0",
      libraries: [],
      syncStatus: LibrarySyncStatus(
        isRunning: false, lastRunIncomplete: false, lastCompletedAt: nil),
      customHeaders: CustomHeaderSummary(names: []))
  }

  func fetchProfile() async throws -> ServerAccountProfile {
    ServerAccountProfile(username: "reader", type: nil, librariesAccessible: [])
  }
}

extension WatchPhoneSetupModel.LoginMethod {
  /// What a fake login provider does with a password it was handed: release it at once.
  func releasePassword() {
    if case .password(let credentials) = self { credentials.releasePassword() }
  }
}
