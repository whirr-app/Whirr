import Testing

@testable import AppModel

/// The pure rule both "Your Shows" surfaces apply to the visible sequence.
@Suite struct ShowOrderingPolicyTests {
  @Test func previewTruncatesWithoutReordering() {
    #expect(ShowOrderingPolicy.preview(["d", "c", "b", "a"], limit: 2) == ["d", "c"])
    #expect(ShowOrderingPolicy.preview(["d", "c", "b", "a"], limit: 10) == ["d", "c", "b", "a"])
    #expect(ShowOrderingPolicy.preview(["a", "b"], limit: 0).isEmpty)
    #expect(ShowOrderingPolicy.preview(["a", "b"], limit: -3).isEmpty)
  }

  @Test func movingAnUnknownIDLeavesTheSequenceAlone() {
    #expect(ShowOrderingPolicy.reorder(["a", "b", "c"], moving: "missing", to: 0) == ["a", "b", "c"])
  }

  @Test func destinationClampsToTheSequenceEnds() {
    #expect(ShowOrderingPolicy.reorder(["a", "b", "c"], moving: "a", to: -1) == ["a", "b", "c"])
    #expect(ShowOrderingPolicy.reorder(["a", "b", "c"], moving: "a", to: 99) == ["b", "c", "a"])
  }

  @Test func destinationIndexesTheSequenceAfterTheMove() {
    #expect(ShowOrderingPolicy.reorder(["a", "b", "c"], moving: "b", to: 2) == ["a", "c", "b"])
    #expect(ShowOrderingPolicy.reorder(["a", "b", "c"], moving: "c", to: 0) == ["c", "a", "b"])
    #expect(ShowOrderingPolicy.reorder(["a", "b", "c"], moving: "b", to: 1) == ["a", "b", "c"])
  }
}
