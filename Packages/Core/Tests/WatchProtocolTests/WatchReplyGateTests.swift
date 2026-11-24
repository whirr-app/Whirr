import Testing
import WatchProtocol

@Suite("WatchProtocol reply gate")
struct WatchProtocolTestsReplyGate {
  @Test func waitThenFinish() async {
    let gate = WatchReplyGate<Int>()
    async let result = gate.wait()
    await Task.yield()
    gate.finish(42)
    #expect(await result == 42)
    #expect(await gate.wait() == 42)
  }

  @Test func finishThenWait() async {
    let gate = WatchReplyGate<Int>()
    gate.finish(42)
    #expect(await gate.wait() == 42)
  }

  @Test func doubleFinishKeepsFirstValue() async {
    let gate = WatchReplyGate<Int>()
    gate.finish(42)
    gate.finish(99)
    #expect(await gate.wait() == 42)
  }

  @Test func nilFinishIsRetained() async {
    let gate = WatchReplyGate<Int>()
    gate.finish(nil)
    gate.finish(99)
    #expect(await gate.wait() == nil)
  }

  @Test func detachedFinish() async {
    let gate = WatchReplyGate<Int>()
    let producer = Task.detached { gate.finish(42) }
    #expect(await gate.wait() == 42)
    await producer.value
  }
}
