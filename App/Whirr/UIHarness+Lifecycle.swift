#if DEBUG || PERF_INVESTIGATION
  import ABSApi
  import AppModel
  import DesignSystem
  import Foundation
  import MediaPlayer
  import Persistence
  import PlayerCore
  import ReaderCore
  import SwiftUI
  import SyncEngine
  import UIKit
  import os

  struct HarnessAccountLifecycle: AccountLifecycle {
    var isAuthenticated: Bool { true }

    func validateServer(url: URL, customHeaders: [String: String]) async throws -> ValidatedServer {
      throw CancellationError()
    }

    func login(server: ValidatedServer, username: String, password: String) async throws {}
    func logout() async throws {}
    func isRemovalPending() async throws -> Bool { false }
  }

  struct HarnessAppLifecycle: AppLifecycle {
    var isForeground: Bool { true }
    var transitions: AsyncStream<AppLifecycleTransition> { AsyncStream { _ in } }
  }
#endif
