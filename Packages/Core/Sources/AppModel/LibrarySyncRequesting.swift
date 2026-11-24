import SyncEngine

/// Asks for one on-demand library sync. A saved episode that created a server show leaves no local
/// item row until the next library sync (`podcastFeedFingerprint` is written only by the library
/// list sync), so the save paths request one to show the show's settings without a relaunch.
///
/// Reuses the pull-to-refresh entry (`SyncCoordinating.refresh()`), which syncs every included
/// library then runs the outbox drains, as `SyncCoordinating` has no single-library entry.
public protocol LibrarySyncRequesting: Sendable {
  func requestLibrarySync() async
}

public struct NoOpLibrarySyncRequester: LibrarySyncRequesting, Sendable {
  public init() {}
  public func requestLibrarySync() async {}
}

public struct CoordinatorLibrarySyncRequester: LibrarySyncRequesting, Sendable {
  private let sync: any SyncCoordinating

  public init(sync: any SyncCoordinating) {
    self.sync = sync
  }

  public func requestLibrarySync() async {
    await sync.refresh()
  }
}

extension ServerPodcastSaveChoice {
  /// Only a chosen library and folder can create a show; `existing` reuses one.
  var createsShow: Bool {
    if case .libraryAndFolder = self { return true }
    return false
  }
}

extension NativeEpisodeServerSaveOutcome {
  /// The request went out and the server accepted it. A create is complete only on this outcome:
  /// uncertain, failed, in-progress and already-present results prove nothing was created now.
  var wasAccepted: Bool {
    if case .accepted = self { return true }
    return false
  }
}
