import Foundation
import Testing

@testable import ABSApi
@testable import SyncEngine

@Suite("Bounded logging")
struct BoundedLoggingTests {
  @Test func podcastFailureMessageDoesNotIncludeErrorDescription() {
    let marker = "podcast-error-secret-canary"
    let error = NSError(
      domain: "CanaryDomain",
      code: 37,
      userInfo: [NSLocalizedDescriptionKey: "server said " + marker])

    let message = PodcastRefreshCoordinator.failureMessage(
      itemID: "item-fixture", stage: "fetch", error: error)

    #expect(message.hasPrefix("WHIRRPOD"))
    #expect(message.contains("statusClass=clientError"))
    #expect(message.contains("domain=CanaryDomain"))
    #expect(message.contains("code=37"))
    #expect(message.contains(marker) == false)
  }

  @Test func apiFailureMessageUsesOnlyTheBareCaseName() {
    let message = PodcastRefreshCoordinator.failureMessage(
      itemID: "item-fixture", stage: "fetch", error: APIError.serverFailure(statusCode: 503))

    #expect(message.contains("apiError=serverFailure"))
    #expect(message.contains("503") == false)
  }
}
