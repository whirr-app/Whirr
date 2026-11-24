import AVFoundation
import PlayerCore
import Testing

@testable import Whirr

/// When `AVQueuePlayerAudioEngine` attaches Voice Boost's tap, and when it cancels one, using the
/// same fakes as the adapter tests.
@MainActor
@Suite("Voice Boost engine wiring")
struct VoiceBoostEngineTests {

  private struct SUT {
    let engine: AVQueuePlayerAudioEngine
    let queue: FakeQueuePlayer
    let factory: FakeItemFactory
    let voiceBoost: VoiceBoostTapFactory
  }

  private func makeSUT(trackCount: Int = 2) -> SUT {
    let queue = FakeQueuePlayer()
    let factory = FakeItemFactory()
    let voiceBoost = VoiceBoostTapFactory()
    let engine = AVQueuePlayerAudioEngine(
      queuePlayer: queue, itemFactory: factory,
      session: AudioSessionConfigurator(session: FakeAudioSessionControlling()), voiceBoost: voiceBoost)
    engine.configure(tracks: (0..<trackCount).map(Self.resource))
    return SUT(engine: engine, queue: queue, factory: factory, voiceBoost: voiceBoost)
  }

  private static func resource(_ index: Int) -> PlaybackTrackResource {
    PlaybackTrackResource(trackIndex: index, url: URL(string: "https://example.com/\(index).mp3")!)
  }

  private func load(_ sut: SUT, track: Int, generation: Int) {
    sut.engine.load(
      track: PlaybackTrack(index: track, duration: 10), localOffset: 0, rate: 1, generation: generation)
  }

  @Test("while on, the loaded item and its lookahead both get the tap")
  func attachesOnLoadAndLookaheadWhileOn() {
    let sut = makeSUT()
    sut.engine.setVoiceBoostEnabled(true)
    load(sut, track: 0, generation: 1)

    #expect(sut.factory.madeItems.count == 2)
    #expect(sut.factory.madeItems.allSatisfy { $0.attachedProcessor === sut.voiceBoost })
    #expect(sut.voiceBoost.isEnabled)
  }

  @Test("while off, no item is asked to attach")
  func noAttachWhileOff() {
    let sut = makeSUT()
    load(sut, track: 0, generation: 1)

    #expect(sut.factory.madeItems.count == 2)
    #expect(sut.factory.madeItems.allSatisfy { $0.attachCalls.isEmpty })
    #expect(sut.voiceBoost.isEnabled == false)
  }

  @Test("turning it on attaches to every queued item, read from the queue after an auto-advance")
  func turningOnAttachesToTheQueueAfterAutoAdvance() {
    let sut = makeSUT(trackCount: 3)
    load(sut, track: 0, generation: 1)
    // The engine's own references lag: `currentItem` names the finished track 0 and
    // `lookaheadItem` the playing track 1, until PlayerCore's next `load`.
    sut.queue.simulateAutoAdvance()

    sut.engine.setVoiceBoostEnabled(true)

    let playing = sut.factory.madeItems[1]
    #expect(sut.queue.items().first === playing)
    #expect(playing.attachedProcessor === sut.voiceBoost)
    #expect(sut.factory.madeItems[0].attachCalls.isEmpty, "the finished item is not attached")
    #expect(sut.voiceBoost.isEnabled)
  }

  @Test("turning it off lowers the switch and asks nothing to detach")
  func turningOffMakesNoDetachCalls() {
    let sut = makeSUT()
    sut.engine.setVoiceBoostEnabled(true)
    load(sut, track: 0, generation: 1)
    let callsBefore = sut.factory.madeItems.map(\.attachCalls.count)

    sut.engine.setVoiceBoostEnabled(false)

    #expect(sut.voiceBoost.isEnabled == false)
    #expect(sut.factory.madeItems.map(\.attachCalls.count) == callsBefore)
    #expect(sut.factory.madeItems.allSatisfy { $0.attachedProcessor === sut.voiceBoost })
    #expect(sut.factory.madeItems.allSatisfy { $0.cancelAttachCallCount == 0 })
  }

  @Test("an adopted lookahead keeps its tap and is not attached again")
  func adoptedLookaheadKeepsItsTap() {
    let sut = makeSUT()
    sut.engine.setVoiceBoostEnabled(true)
    load(sut, track: 0, generation: 1)
    let lookahead = sut.factory.madeItems[1]
    sut.queue.simulateAutoAdvance()

    load(sut, track: 1, generation: 2)

    #expect(sut.factory.madeItems.count == 2, "the lookahead was adopted, not rebuilt")
    #expect(lookahead.attachedProcessor === sut.voiceBoost)
    #expect(lookahead.attachCalls.count == 1)
    #expect(lookahead.cancelAttachCallCount == 0)
    #expect(sut.factory.madeItems[0].cancelAttachCallCount == 1, "the finished item was let go")
  }

  @Test("a reconfigure that discards the lookahead cancels its pending attach")
  func discardedLookaheadCancelsItsAttach() {
    let sut = makeSUT()
    sut.factory.holdsAttach = true
    sut.engine.setVoiceBoostEnabled(true)
    load(sut, track: 0, generation: 1)
    let lookahead = sut.factory.madeItems[1]

    sut.engine.configure(tracks: [
      Self.resource(0),
      PlaybackTrackResource(trackIndex: 1, url: URL(string: "https://example.com/1-renamed.mp3")!),
    ])
    lookahead.completePendingAttach()

    #expect(lookahead.cancelAttachCallCount == 1)
    #expect(lookahead.attachedProcessor == nil, "an attach landing after the discard does nothing")
  }

  @Test("an attach landing after a replacing load does nothing")
  func attachAfterTeardownDoesNothing() {
    let sut = makeSUT(trackCount: 3)
    sut.factory.holdsAttach = true
    sut.engine.setVoiceBoostEnabled(true)
    load(sut, track: 0, generation: 1)
    let first = sut.factory.madeItems[0]

    load(sut, track: 2, generation: 2)
    first.completePendingAttach()

    #expect(first.cancelAttachCallCount >= 1)
    #expect(first.attachedProcessor == nil)
    let replacement = sut.factory.madeItems[2]
    replacement.completePendingAttach()
    #expect(replacement.attachedProcessor === sut.voiceBoost)
  }
}
