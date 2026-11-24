import SyncEngine
import Testing

@testable import AppModel

struct ConnectivityStatusCopyTests {
  @Test("no-network copy tells the user to reconnect")
  func noNetworkCopyTellsTheUserToReconnect() {
    let copy = ConnectivityStatusCopy.status(for: .noNetworkPath)

    #expect(copy.title == "You're Offline")
    #expect(copy.message.lowercased().contains("reconnect"))
    #expect(copy.message.lowercased().contains("wi-fi"))
    #expect(copy.systemImage == "wifi.slash")
    #expect(copy.retryTitle == ConnectivityStatusCopy.retryTitle)
  }

  @Test("server-unreachable copy tells the user to check the server")
  func serverUnreachableCopyTellsTheUserToCheckTheServer() {
    let copy = ConnectivityStatusCopy.status(for: .serverUnreachable)

    #expect(copy.title == "Can't Reach Your Server")
    #expect(copy.message.lowercased().contains("check your server"))
    #expect(copy.message.lowercased().contains("reconnect"))
    #expect(copy.systemImage == "server.rack")
    #expect(copy.retryTitle == ConnectivityStatusCopy.retryTitle)
  }

  @Test("the two unreachable reasons have distinct copy and symbols")
  func reasonsHaveDistinctCopyAndSymbols() {
    let noNetwork = ConnectivityStatusCopy.status(for: .noNetworkPath)
    let server = ConnectivityStatusCopy.status(for: .serverUnreachable)

    #expect(noNetwork != server)
    #expect(noNetwork.title != server.title)
    #expect(noNetwork.message != server.message)
    #expect(noNetwork.systemImage != server.systemImage)
  }

  /// The indicator renders as a bare glyph, so its title is what VoiceOver has to announce. A
  /// title that named the picture rather than the problem would leave the control unreadable.
  @Test("each title states the problem without needing the glyph")
  func eachTitleStatesTheProblem() {
    for reason in [ServerUnreachableReason.noNetworkPath, .serverUnreachable] {
      let title = ConnectivityStatusCopy.status(for: reason).title
      #expect(title.isEmpty == false)
      #expect(title.lowercased().contains("rack") == false)
      #expect(title.lowercased().contains("icon") == false)
    }
  }
}
