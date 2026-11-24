import Foundation
import Testing

@testable import Whirr

/// The transcript session's pacing: a lead ahead of what is final, widened on a stall, nothing fed
/// while held. The analyser itself runs only on the phone.
@Suite("Transcript feed pacer")
struct TranscriptFeedPacerTests {

  @Test("feeds while the analyser is less than the lead behind")
  func feedsInsideTheLead() {
    var pacer = TranscriptFeedPacer()
    #expect(pacer.decide(at: 0, fed: 0, finalized: 0, isHeld: false) == .feed)
    #expect(pacer.decide(at: 1, fed: 29, finalized: 0, isHeld: false) == .feed)
  }

  @Test("waits for the analyser once a full lead is queued")
  func waitsAtTheLead() {
    var pacer = TranscriptFeedPacer()
    _ = pacer.decide(at: 0, fed: 0, finalized: 0, isHeld: false)
    #expect(pacer.decide(at: 1, fed: 30, finalized: 0, isHeld: false) == .waitForProgress)
    #expect(pacer.decide(at: 1.5, fed: 30, finalized: 10, isHeld: false) == .feed)
  }

  @Test("a resumed session's lead counts from where it started")
  func leadFromAResumePoint() {
    var pacer = TranscriptFeedPacer()
    #expect(pacer.decide(at: 0, fed: 1_200, finalized: 1_200, isHeld: false) == .feed)
    #expect(pacer.decide(at: 0.1, fed: 1_230, finalized: 1_200, isHeld: false) == .waitForProgress)
  }

  @Test("widens the lead by one after a stall")
  func widensOnAStall() {
    var pacer = TranscriptFeedPacer()
    _ = pacer.decide(at: 0, fed: 30, finalized: 0, isHeld: false)
    #expect(pacer.decide(at: 1.9, fed: 30, finalized: 0, isHeld: false) == .waitForProgress)
    #expect(pacer.decide(at: 2, fed: 30, finalized: 0, isHeld: false) == .feed)
    #expect(pacer.stalls == 1)
    #expect(pacer.decide(at: 2.1, fed: 59, finalized: 0, isHeld: false) == .feed)
    #expect(pacer.decide(at: 2.2, fed: 60, finalized: 0, isHeld: false) == .waitForProgress)
  }

  @Test("feeds nothing while held, and time held is not a stall")
  func holds() {
    var pacer = TranscriptFeedPacer()
    _ = pacer.decide(at: 0, fed: 30, finalized: 0, isHeld: false)
    #expect(pacer.decide(at: 1, fed: 30, finalized: 0, isHeld: true) == .hold)
    #expect(pacer.decide(at: 100, fed: 30, finalized: 30, isHeld: true) == .hold)
    #expect(pacer.decide(at: 101, fed: 30, finalized: 30, isHeld: false) == .feed)
    #expect(pacer.decide(at: 101.5, fed: 60, finalized: 30, isHeld: false) == .waitForProgress)
    #expect(pacer.stalls == 0)
  }
}
