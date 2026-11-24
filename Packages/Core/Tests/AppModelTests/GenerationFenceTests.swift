import Testing

@testable import AppModel

/// The fence every generation-guarded model shares: only the token from the latest advance is
/// current, at equal, older and newer generations.
@Suite struct GenerationFenceTests {
  @Test func aFenceHoldsNoTokenUntilItAdvances() {
    let fence = GenerationFence()
    var advanced = GenerationFence()
    _ = advanced.advance()
    #expect(fence.isCurrent(advanced.advance()) == false)
  }

  @Test func aCapturedTokenIsCurrentAtItsOwnGeneration() {
    var fence = GenerationFence()
    let token = fence.advance()
    #expect(fence.isCurrent(token))
  }

  @Test func theLatestTokenIsCurrentAndOlderTokensAreNot() {
    var fence = GenerationFence()
    let first = fence.advance()
    let second = fence.advance()

    #expect(fence.isCurrent(second))
    #expect(fence.isCurrent(first) == false)
  }

  @Test func advancingPastATokenRetiresItWithoutReinstatingIt() {
    var fence = GenerationFence()
    let first = fence.advance()
    _ = fence.advance()
    let third = fence.advance()

    #expect(fence.isCurrent(third))
    #expect(fence.isCurrent(first) == false)
  }
}
