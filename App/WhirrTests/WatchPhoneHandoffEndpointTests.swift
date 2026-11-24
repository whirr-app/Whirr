import AppModel
import Foundation
import Persistence
import Testing
import WatchProtocol

@testable import Whirr

/// On the phone: pause whatever is loaded, keep it loaded, reply first and flush afterwards.
@MainActor
@Suite("Watch phone handoff endpoint")
struct WatchPhoneHandoffEndpointTests {
  private let account = try! WatchAccountStamp(
    accountIdentityHash: "account-hash", serverIdentityHash: "server-hash")
  private let now = Date(timeIntervalSinceReferenceDate: 1_000)

  @MainActor
  final class Phone {
    var loaded: CompanionPlaybackPeerState?
    var stamp: WatchAccountStamp?
    var pauses = 0
    var events: [String] = []

    func endpoint(now: Date) -> WatchPhoneHandoffEndpoint {
      WatchPhoneHandoffEndpoint(
        authenticatedStamp: { self.stamp },
        peer: WatchPhoneHandoffEndpoint.Peer(
          state: { self.loaded },
          pause: {
            self.pauses += 1
            return self.loaded
          },
          flush: { self.events.append("flush") }),
        clock: { now })
    }
  }

  private func state(_ itemID: String, episode: String? = nil, position: Double, playing: Bool)
    -> CompanionPlaybackPeerState
  {
    CompanionPlaybackPeerState(
      selection: CompanionSelection(source: PodcastSourceIdentity(itemId: itemID)!, episodeID: episode),
      positionSeconds: position, wasPlaying: playing)
  }

  private func request(id: UUID = UUID(), stamp: WatchAccountStamp? = nil, issuedAt: Date? = nil) throws -> Data {
    try WatchWireCodec.encode(
      WatchHandoffRequest(
        handoffID: id, accountStamp: stamp ?? account,
        selection: WatchABSSelection(itemID: "other", episodeID: nil), issuedAt: issuedAt ?? now))
  }

  private func admit(_ endpoint: WatchPhoneHandoffEndpoint, _ data: Data, phone: Phone? = nil) async throws
    -> WatchHandoffReply
  {
    var reply: WatchHandoffReply?
    await endpoint.admit(data: data) { message in
      phone?.events.append("reply")
      if let payload = message[WatchPhoneHandoffEndpoint.payloadKey] as? Data {
        reply = try? WatchWireCodec.decode(WatchHandoffReply.self, from: payload)
      }
    }
    return try #require(reply)
  }

  @Test("a playing ABS title is paused, kept loaded, and reported with a listen time of now")
  func pausesAndReportsAPlayingTitle() async throws {
    let phone = Phone()
    phone.stamp = account
    phone.loaded = state("book", episode: "ep", position: 37.5, playing: true)
    let endpoint = phone.endpoint(now: now)

    let reply = try await admit(endpoint, try request(), phone: phone)

    #expect(reply.status == .paused)
    #expect(reply.selection == (try WatchABSSelection(itemID: "book", episodeID: "ep")))
    #expect(reply.positionSeconds == 37.5)
    #expect(reply.lastListenedAt == now)
    #expect(phone.pauses == 1)
  }

  @Test("the reply is sent before progress is flushed")
  func repliesBeforeFlushing() async throws {
    let phone = Phone()
    phone.stamp = account
    phone.loaded = state("book", position: 10, playing: true)

    _ = try await admit(phone.endpoint(now: now), try request(), phone: phone)

    #expect(phone.events == ["reply", "flush"])
  }

  @Test("a title that was already paused carries no listen time")
  func alreadyPausedHasNoListenTime() async throws {
    let phone = Phone()
    phone.stamp = account
    phone.loaded = state("book", position: 10, playing: false)

    let reply = try await admit(phone.endpoint(now: now), try request())

    #expect(reply.status == .paused)
    #expect(reply.lastListenedAt == nil)
  }

  @Test("a native feed title pauses but is not named")
  func nativeFeedTitleReplyHasNoSelection() async throws {
    let phone = Phone()
    phone.stamp = account
    phone.loaded = state("rss:42", episode: "e1", position: 99, playing: true)

    let reply = try await admit(phone.endpoint(now: now), try request())

    #expect(reply.status == .paused)
    #expect(reply.selection == nil)
    #expect(reply.positionSeconds == nil)
    #expect(phone.pauses == 1)
  }

  @Test("nothing loaded replies idle and flushes nothing")
  func nothingLoadedIsIdle() async throws {
    let phone = Phone()
    phone.stamp = account

    let reply = try await admit(phone.endpoint(now: now), try request(), phone: phone)

    #expect(reply.status == .idle)
    #expect(phone.events == ["reply"])
  }

  @Test("a repeated request reports the current state and does not pause again")
  func repeatDoesNotPauseAgain() async throws {
    let phone = Phone()
    phone.stamp = account
    phone.loaded = state("book", position: 10, playing: true)
    let endpoint = phone.endpoint(now: now)
    let id = UUID()

    _ = try await admit(endpoint, try request(id: id))
    phone.loaded = state("book", position: 55, playing: true)
    let repeated = try await admit(endpoint, try request(id: id), phone: phone)

    #expect(phone.pauses == 1)
    #expect(repeated.status == .paused)
    #expect(repeated.positionSeconds == 55)
    #expect(phone.events == ["flush", "reply"])
  }

  @Test("another account is rejected without pausing")
  func wrongAccountIsRejected() async throws {
    let phone = Phone()
    phone.stamp = account
    phone.loaded = state("book", position: 10, playing: true)
    let other = try WatchAccountStamp(accountIdentityHash: "other", serverIdentityHash: "server-hash")

    let reply = try await admit(phone.endpoint(now: now), try request(stamp: other))

    #expect(reply.status == .rejected)
    #expect(reply.rejection == .wrongAccount)
    #expect(phone.pauses == 0)
  }

  @Test("a request outside the admission window is rejected without pausing")
  func expiredIsRejected() async throws {
    let phone = Phone()
    phone.stamp = account
    phone.loaded = state("book", position: 10, playing: true)
    let old = now.addingTimeInterval(-(WatchProtocolVersion.commandAdmissionWindow + 1))

    let reply = try await admit(phone.endpoint(now: now), try request(issuedAt: old))

    #expect(reply.rejection == .expired)
    #expect(phone.pauses == 0)
  }

  @Test func admissionBoundaryIsHalfOpen() async throws {
    for (age, expired) in [(119.0, false), (120.0, true), (121.0, true)] {
      let phone = Phone()
      phone.stamp = account
      phone.loaded = state("book", position: 10, playing: true)
      let issuedAt = now.addingTimeInterval(-age)

      let reply = try await admit(phone.endpoint(now: now), try request(issuedAt: issuedAt))

      #expect((reply.rejection == .expired) == expired)
      #expect(phone.pauses == (expired ? 0 : 1))
    }
  }

  @Test("an account change forgets admitted requests")
  func accountChangeResetsTheResponder() async throws {
    let phone = Phone()
    phone.stamp = account
    phone.loaded = state("book", position: 10, playing: true)
    let endpoint = phone.endpoint(now: now)
    let id = UUID()
    let other = try WatchAccountStamp(accountIdentityHash: "other", serverIdentityHash: "server-hash")

    _ = try await admit(endpoint, try request(id: id))
    phone.stamp = other
    _ = try await admit(endpoint, try request(id: id, stamp: other))

    #expect(phone.pauses == 2)
  }

  @Test("a malformed payload gets an empty reply")
  func malformedPayload() async {
    let phone = Phone()
    phone.stamp = account
    let endpoint = phone.endpoint(now: now)
    var replies: [[String: Any]] = []

    await endpoint.admit(data: Data("nonsense".utf8)) { replies.append($0) }

    #expect(replies.count == 1)
    #expect(replies.allSatisfy { $0.isEmpty })
    #expect(phone.pauses == 0)
  }
}
