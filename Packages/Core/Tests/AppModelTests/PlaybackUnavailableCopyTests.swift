import SyncEngine
import Testing

@testable import AppModel

struct PlaybackUnavailableCopyTests {
  @Test("no-network mini-player copy stays short and actionable")
  func noNetworkSubtitleIsShort() {
    #expect(PlaybackUnavailableCopy.subtitle(for: .noNetworkPath) == "Offline")
  }

  @Test("server-unreachable mini-player copy names the server")
  func serverUnreachableSubtitleNamesTheServer() {
    #expect(PlaybackUnavailableCopy.subtitle(for: .serverUnreachable) == "Server unavailable")
  }

  @Test("the two unreachable reasons have distinct mini-player copy")
  func reasonsHaveDistinctSubtitles() {
    #expect(
      PlaybackUnavailableCopy.subtitle(for: .noNetworkPath)
        != PlaybackUnavailableCopy.subtitle(for: .serverUnreachable))
  }
}
