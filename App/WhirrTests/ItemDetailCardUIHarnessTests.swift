#if DEBUG
  import Testing

  @testable import Whirr

  @Suite("Item-detail card UI harness")
  struct ItemDetailCardUIHarnessTests {
    @Test("detail-card screen routing keeps the player fallback")
    func detailCardScreenRouting() {
      #expect(UIHarness.screen(for: "detail-card") == .detailCard)
      #expect(UIHarness.screen(for: "detail") == .detail)
      #expect(UIHarness.screen(for: "not-a-screen") == .player)
    }
  }
#endif
