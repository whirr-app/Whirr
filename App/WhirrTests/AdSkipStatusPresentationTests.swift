import AppModel
import Foundation
import Testing

@testable import Whirr

/// The expanded player's ad-analysis status copy: one plain sentence per state, no separator
/// glyphs, and Check Now only for the charging wait.
@Suite("Ad skip status")
struct AdSkipStatusPresentationTests {
  typealias Presentation = AdSkipStatusPresentation

  @Test("a ready episode, or none analysis covers, says nothing")
  func none() {
    #expect(Presentation.content(for: .none, pauseReason: nil) == nil)
    #expect(Presentation.content(for: .none, pauseReason: .notCharging) == nil)
  }

  @Test("off is the offer's to say, so the status line stays silent")
  func notEnabled() {
    #expect(Presentation.content(for: .notEnabled, pauseReason: nil) == nil)
    #expect(Presentation.content(for: .notEnabled, pauseReason: .notCharging) == nil)
  }

  @Test("checking says so, without Check Now")
  func checking() throws {
    let content = try #require(Presentation.content(for: .checking, pauseReason: .notCharging))
    #expect(content.text == "Checking this episode for ads")
    #expect(content.offersCheckNow == false)
  }

  @Test("each pause reason has its own sentence, and only the charging wait offers Check Now")
  func waits() throws {
    let charging = try #require(Presentation.content(for: .waiting(.conditions), pauseReason: .notCharging))
    #expect(charging.text == "Ads will be checked when your phone is charging")
    #expect(charging.offersCheckNow)

    let lowPower = try #require(Presentation.content(for: .waiting(.conditions), pauseReason: .lowPowerMode))
    #expect(lowPower.text == "Ad checks are paused in Low Power Mode")
    #expect(lowPower.offersCheckNow == false)

    let warm = try #require(Presentation.content(for: .waiting(.conditions), pauseReason: .warm))
    #expect(warm.text == "Ad checks are paused while your phone cools down")
    #expect(warm.offersCheckNow == false)

    let model = try #require(Presentation.content(for: .waiting(.speechModel), pauseReason: nil))
    #expect(model.text == "Ad checks start once the speech model has downloaded")
    #expect(model.offersCheckNow == false)
  }

  @Test("a held analysis whose reason has gone says nothing rather than something stale")
  func goneReason() {
    #expect(Presentation.content(for: .waiting(.conditions), pauseReason: nil) == nil)
  }

  @Test("no copy uses a separator glyph")
  func noSeparators() {
    let statuses: [PlaybackAdAnalysisStatus] = [.checking, .waiting(.speechModel), .waiting(.conditions)]
    let reasons: [AdSkipPauseReason?] = [nil, .notCharging, .lowPowerMode, .warm]
    for status in statuses {
      for reason in reasons {
        guard let text = Presentation.content(for: status, pauseReason: reason)?.text else { continue }
        #expect(text.contains("·") == false && text.contains("•") == false && text.contains("—") == false)
      }
    }
  }
}
