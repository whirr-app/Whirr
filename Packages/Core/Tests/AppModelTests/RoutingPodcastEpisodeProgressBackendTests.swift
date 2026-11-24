import AppModel
import Persistence
import Testing

@Suite struct RoutingPodcastEpisodeProgressBackendTests {
  @Test("dispatches every progress write to the identity's backend")
  func dispatchesEveryWrite() async throws {
    let episodes = [EpisodeProgressChange(episodeID: "episode-42", currentTime: 12.5)]
    let rows:
      [(
        name: String, expected: (String) -> RecordingCall,
        invoke: (RoutingPodcastEpisodeProgressBackend, String) async throws -> Void
      )] = [
        (
          "markFinished", { .markFinished($0, "episode-42", 99.25) },
          { try await $0.markFinished(itemID: $1, episodeID: "episode-42", duration: 99.25) }
        ),
        (
          "resetProgress", { .resetProgress($0, "episode-42") },
          { try await $0.resetProgress(itemID: $1, episodeID: "episode-42") }
        ),
        (
          "hideFromContinueListening", { .hide($0, "episode-42") },
          { try await $0.hideFromContinueListening(itemID: $1, episodeID: "episode-42") }
        ),
        (
          "setFinished", { .setFinished($0, episodes, true) },
          { try await $0.setFinished(itemID: $1, episodes: episodes, isFinished: true) }
        ),
      ]

    for itemID in ["li_abc", "rss:7"] {
      for row in rows {
        let abs = RecordingProgressBackend()
        let rss = RecordingProgressBackend()
        let router = RoutingPodcastEpisodeProgressBackend(abs: abs, rss: rss)
        try await row.invoke(router, itemID)
        let selected = itemID.hasPrefix("rss:") ? rss : abs
        let untouched = itemID.hasPrefix("rss:") ? abs : rss
        #expect(await selected.calls == [row.expected(itemID)], "\(row.name), \(itemID)")
        #expect(await untouched.calls.isEmpty, "\(row.name), \(itemID) touched the wrong backend")
      }
    }
  }

  @Test("rejects undecodable ids without touching either backend")
  func rejectsUndecodableIDs() async throws {
    for itemID in ["", "rss:007"] {
      let abs = RecordingProgressBackend()
      let rss = RecordingProgressBackend()
      let router = RoutingPodcastEpisodeProgressBackend(abs: abs, rss: rss)
      do {
        try await router.markFinished(itemID: itemID, episodeID: "episode", duration: nil)
        Issue.record("markFinished unexpectedly succeeded for \(itemID.debugDescription)")
      } catch let error as PodcastEpisodeIntentFailure {
        #expect(error.message == PodcastCopy.actionFailed)
      }
      do {
        try await router.setFinished(itemID: itemID, episodes: [], isFinished: false)
        Issue.record("setFinished unexpectedly succeeded for \(itemID.debugDescription)")
      } catch let error as PodcastEpisodeIntentFailure {
        #expect(error.message == PodcastCopy.actionFailed)
      }
      #expect(await abs.calls.isEmpty)
      #expect(await rss.calls.isEmpty)
    }
  }

  @Test("propagates a backend error unchanged")
  func propagatesBackendError() async throws {
    let router = RoutingPodcastEpisodeProgressBackend(
      abs: RecordingProgressBackend(error: PodcastEpisodeIntentFailure(message: "boom")),
      rss: RecordingProgressBackend())

    do {
      try await router.resetProgress(itemID: "li_abc", episodeID: "episode")
      Issue.record("resetProgress unexpectedly succeeded")
    } catch let error as PodcastEpisodeIntentFailure {
      #expect(error == PodcastEpisodeIntentFailure(message: "boom"))
    }
  }
}

private enum RecordingCall: Equatable, Sendable {
  case markFinished(String, String, Double?)
  case resetProgress(String, String)
  case hide(String, String)
  case setFinished(String, [EpisodeProgressChange], Bool)
}

private actor RecordingProgressBackend: PodcastEpisodeProgressBackend {
  private(set) var calls: [RecordingCall] = []
  private let error: (any Error)?

  init(error: (any Error)? = nil) {
    self.error = error
  }

  func markFinished(itemID: String, episodeID: String, duration: Double?) async throws {
    try record(.markFinished(itemID, episodeID, duration))
  }

  func resetProgress(itemID: String, episodeID: String) async throws {
    try record(.resetProgress(itemID, episodeID))
  }

  func hideFromContinueListening(itemID: String, episodeID: String) async throws {
    try record(.hide(itemID, episodeID))
  }

  func setFinished(
    itemID: String, episodes: [EpisodeProgressChange], isFinished: Bool
  ) async throws {
    try record(.setFinished(itemID, episodes, isFinished))
  }

  private func record(_ call: RecordingCall) throws {
    if let error { throw error }
    calls.append(call)
  }
}
