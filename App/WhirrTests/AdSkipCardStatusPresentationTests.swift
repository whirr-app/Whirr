import AppModel
import Foundation
import TestSupport
import Testing

@testable import Whirr

/// The episode card's ad-skip status: a full copy, a short copy and a symbol for every state,
/// and nothing when there is nothing to say.
@MainActor
@Suite("Ad skip card status")
struct AdSkipCardStatusPresentationTests {
  typealias Presentation = AdSkipCardStatusPresentation

  private func content(
    _ status: AdSkipEpisodeStatus, _ reason: AdSkipPauseReason? = nil
  ) -> [String]? {
    Presentation.content(for: status, pauseReason: reason).map { [$0.full, $0.short, $0.systemImage] }
  }

  /// A ready status with `count` skips, whose own times do not matter to this copy.
  private func ready(_ count: Int) -> AdSkipEpisodeStatus {
    .ready(
      AdSkipBreaks(
        breaks: (0..<count).map {
          AdSkipBreaks.Break(start: Double($0) * 10, end: Double($0) * 10 + 5, endsItem: false)
        }))
  }

  @Test("an episode analysis does not cover says nothing")
  func none() {
    #expect(content(.none) == nil)
    #expect(content(.none, .notCharging) == nil)
  }

  @Test("queued and checking share a symbol, and only checking moves")
  func inTheQueue() {
    #expect(content(.queued) == ["Ad check queued", "Queued", "waveform"])
    #expect(content(.checking, .notCharging) == ["Checking for ads", "Checking", "waveform"])
    #expect(Presentation.content(for: .checking, pauseReason: nil)?.animatesSymbol == true)
    #expect(Presentation.content(for: .queued, pauseReason: nil)?.animatesSymbol == false)
  }

  @Test("each wait has its own copy")
  func waits() {
    #expect(
      content(.waiting(.conditions), .notCharging)
        == ["Checks for ads when charging", "When charging", "bolt"])
    #expect(
      content(.waiting(.conditions), .lowPowerMode)
        == ["Ad check paused in Low Power Mode", "Paused", "battery.25"])
    #expect(
      content(.waiting(.conditions), .warm)
        == ["Ad check paused while phone cools", "Paused", "thermometer.medium"])
    #expect(
      content(.waiting(.speechModel), .notCharging)
        == ["Ad check waiting for speech model", "Waiting", "arrow.down.circle"])
  }

  @Test("a held analysis whose reason has gone says nothing")
  func aWaitWithNoReason() {
    #expect(content(.waiting(.conditions)) == nil)
  }

  @Test("an analysed episode counts its breaks, singular and plural, or says none were found")
  func ready() {
    #expect(content(ready(3)) == ["Skips 3 ad breaks", "3 ad breaks", "forward.end"])
    #expect(content(ready(1)) == ["Skips 1 ad break", "1 ad break", "forward.end"])
    #expect(content(ready(0)) == ["No ads found", "No ads", "checkmark"])
  }

  @Test("a file analysis gave up on says so")
  func failed() {
    #expect(
      content(.failed, .notCharging)
        == ["Couldn't check for ads", "Not checked", "exclamationmark.triangle"])
  }

  @Test("no sentence uses a separator glyph or ends in a full stop")
  func plainCopy() {
    let statuses: [AdSkipEpisodeStatus] = [
      .queued, .checking, .waiting(.conditions), .waiting(.speechModel), ready(0),
      ready(2), .failed,
    ]
    for status in statuses {
      for reason in [AdSkipPauseReason.notCharging, .lowPowerMode, .warm] {
        guard let content = Presentation.content(for: status, pauseReason: reason) else { continue }
        for text in [content.full, content.short] {
          #expect(text.contains("·") == false && text.hasSuffix(".") == false, "\(text)")
        }
      }
    }
  }

  // MARK: - The model

  @Test("without a coordinator the card says nothing")
  func noCoordinator() async {
    let model = AdSkipCardStatusModel(itemID: "item", episodeID: "episode", source: nil)
    await model.follow()
    #expect(model.content == nil)
  }

  @Test("the model asks again on every change, and follows why analysis waits")
  func followsChanges() async {
    let statuses = StatusBox(.waiting(.conditions))
    let (changes, signal) = AsyncStream<Void>.makeStream()
    let (reasons, reason) = AsyncStream<AdSkipPauseReason?>.makeStream()
    let model = AdSkipCardStatusModel(
      itemID: "item", episodeID: "episode",
      source: .init(
        status: { itemID, episodeID in
          #expect(itemID == "item" && episodeID == "episode")
          return statuses.value
        }, changes: { changes }, pauseReasons: { reasons }))
    let following = Task { await model.follow() }
    defer { following.cancel() }

    // Held, with no reason yet.
    reason.yield(nil)
    signal.yield()
    #expect(model.content == nil)

    reason.yield(.notCharging)
    #expect(await waitUntil("waiting") { model.content?.short == "When charging" })

    statuses.set(.checking)
    signal.yield()
    #expect(await waitUntil("checking") { model.content?.short == "Checking" })

    statuses.set(ready(2))
    signal.yield()
    #expect(await waitUntil("ready") { model.content?.full == "Skips 2 ad breaks" })
    #expect(model.breaks?.count == 2)
  }
}

nonisolated private final class StatusBox: @unchecked Sendable {
  private let lock = NSLock()
  private var status: AdSkipEpisodeStatus

  init(_ status: AdSkipEpisodeStatus) { self.status = status }

  var value: AdSkipEpisodeStatus { lock.withLock { status } }

  func set(_ status: AdSkipEpisodeStatus) { lock.withLock { self.status = status } }
}
