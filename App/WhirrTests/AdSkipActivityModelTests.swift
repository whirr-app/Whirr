import AppModel
import Foundation
import Persistence
import TestSupport
import Testing

@testable import Whirr

/// Which tiles show the ad check: the RSS episode under analysis, its linked server copy, and an
/// ABS episode, matched by item and episode whatever the account.
@MainActor
@Suite("Ad skip activity")
struct AdSkipActivityModelTests {
  static let rss = AdSkipEpisodeIdentity(source: .rss, accountId: nil, itemID: "rss:1", episodeID: "e1")
  static let server = AdSkipEpisodeIdentity(source: .abs, accountId: 7, itemID: "show", episodeID: "s1")

  private func model(
    _ activity: AdSkipAnalysisActivity?
  ) async -> (AdSkipActivityModel, AsyncStream<AdSkipAnalysisActivity?>.Continuation) {
    let (stream, continuation) = AsyncStream<AdSkipAnalysisActivity?>.makeStream()
    let model = AdSkipActivityModel(updates: stream)
    continuation.yield(activity)
    #expect(await waitUntil("the activity arrives") { model.activity == activity })
    return (model, continuation)
  }

  @Test("an RSS episode and its linked server copy both show the check")
  func rssAndLinked() async {
    let (model, _) = await model(AdSkipAnalysisActivity(identities: [Self.rss, Self.server]))
    #expect(model.isAnalysing(itemID: "rss:1", episodeID: "e1"))
    #expect(model.isAnalysing(itemID: "show", episodeID: "s1"))
    #expect(model.isAnalysing(itemID: "show", episodeID: "s2") == false)
    #expect(model.isAnalysing(itemID: "show", episodeID: nil) == false)
  }

  @Test("an ABS episode matches whatever the account")
  func absIgnoresAccount() async {
    let (model, _) = await model(AdSkipAnalysisActivity(identities: [Self.server]))
    #expect(model.isAnalysing(itemID: "show", episodeID: "s1"))
  }

  @Test("the check goes when the coordinator says nothing is analysed")
  func clears() async {
    let (model, continuation) = await model(AdSkipAnalysisActivity(identities: [Self.rss]))
    continuation.yield(nil)
    #expect(await waitUntil("the activity clears") { model.activity == nil })
    #expect(model.isAnalysing(itemID: "rss:1", episodeID: "e1") == false)
  }
}
