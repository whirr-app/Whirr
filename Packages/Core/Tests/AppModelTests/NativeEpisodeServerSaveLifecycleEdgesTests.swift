import Persistence
import Testing

@testable import AppModel

@Suite struct NativeEpisodeServerSaveLifecycleEdgesTests {
  private typealias SubscriptionsEdge = NativeEpisodeServerSaveLifecycleEdges.SubscriptionsEdge
  private typealias AccountEdge = NativeEpisodeServerSaveLifecycleEdges.AccountEdge

  // MARK: - Native subscriptions

  @Test func anEnabledBaselineIsNoEvent() {
    var edge = SubscriptionsEdge()
    #expect(edge.next(true) == nil)
  }

  @Test func everyDisabledValueClears() {
    var edge = SubscriptionsEdge()
    #expect(edge.next(false) == .clear(.nativeSubscriptionsDisabled))
    #expect(edge.next(false) == .clear(.nativeSubscriptionsDisabled))
  }

  @Test func turningBackOnReenables() {
    var edge = SubscriptionsEdge()
    #expect(edge.next(true) == nil)
    #expect(edge.next(false) == .clear(.nativeSubscriptionsDisabled))
    #expect(edge.next(true) == .reenabled)
  }

  @Test func stayingOnIsNoEvent() {
    var edge = SubscriptionsEdge()
    #expect(edge.next(true) == nil)
    #expect(edge.next(true) == nil)
  }

  // MARK: - Account identity

  @Test func theBaselineIdentityClearsNothing() {
    var signedIn = AccountEdge()
    #expect(signedIn.next(Self.alice) == nil)

    var signedOut = AccountEdge()
    #expect(signedOut.next(nil) == nil)
  }

  @Test func signingOutIsUnavailable() {
    var edge = AccountEdge()
    _ = edge.next(Self.alice)
    #expect(edge.next(nil) == .accountUnavailable)
  }

  @Test func repeatedSignedOutValuesClearEachTime() {
    var edge = AccountEdge()
    _ = edge.next(Self.alice)
    #expect(edge.next(nil) == .accountUnavailable)
    #expect(edge.next(nil) == .accountUnavailable)
  }

  @Test func aDifferentIdentityIsAReplacement() {
    var edge = AccountEdge()
    _ = edge.next(Self.alice)
    #expect(edge.next(Self.bob) == .accountReplaced)
  }

  @Test func anEqualIdentityIsNoEvent() {
    var edge = AccountEdge()
    _ = edge.next(Self.alice)
    #expect(edge.next(Self.alice) == nil)
  }

  @Test func signingInAfterTheBaselineIsAReplacement() {
    var edge = AccountEdge()
    _ = edge.next(nil)
    #expect(edge.next(Self.alice) == .accountReplaced)
  }

  // MARK: - Capability invalidation

  @Test func onlyAnAccountChangeInvalidatesTheCapability() {
    #expect(
      NativeEpisodeServerSaveLifecycleTrigger.nativeSubscriptionsDisabled
        .invalidatesCapability == false)
    #expect(NativeEpisodeServerSaveLifecycleTrigger.accountUnavailable.invalidatesCapability)
    #expect(NativeEpisodeServerSaveLifecycleTrigger.accountReplaced.invalidatesCapability)
  }

  private static let alice = AccountIdentity(
    id: 1, clientUUID: "client-a", serverIdentityFingerprint: "fingerprint-a")
  private static let bob = AccountIdentity(
    id: 2, clientUUID: "client-b", serverIdentityFingerprint: "fingerprint-b")
}
