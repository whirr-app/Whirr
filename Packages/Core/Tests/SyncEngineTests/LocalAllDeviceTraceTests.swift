import Testing

@testable import SyncEngine

@Suite struct LocalAllDeviceTraceTests {
  @Test func eachLocalAllRecordRendersExactly() {
    #expect(
      LocalAllDeviceTrace.line(.drainStart(.init(coalesced: 0)))
        == "WHIRRSYNC localall drain=start coalesced=0")
    #expect(
      LocalAllDeviceTrace.line(.batch(.init(index: 1, sessions: 7, result: .ok, accepted: 7, rejected: 0)))
        == "WHIRRSYNC localall batch=1 sessions=7 result=ok accepted=7 rejected=0")
    #expect(
      LocalAllDeviceTrace.line(.drainEnd(.init(batches: 1, sessions: 7)))
        == "WHIRRSYNC localall drain=end batches=1 sessions=7")
  }

  @Test func aHaltedDrainEndMakesTheHaltVisible() {
    #expect(
      LocalAllDeviceTrace.line(.drainEnd(.init(batches: 1, sessions: 7, halted: true)))
        == "WHIRRSYNC localall drain=end batches=1 sessions=7 halted=1")
  }
}
