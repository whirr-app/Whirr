import Testing

@testable import AdSkip

@Suite struct EpisodeGroupingTests {
  private let a = EpisodeKey("a")
  private let b = EpisodeKey("b")
  private let c = EpisodeKey("c")
  private let d = EpisodeKey("d")

  private func range(_ r: Range<UInt64>) -> Set<UInt64> { Set(r) }

  @Test func jaccardBasics() {
    #expect(EpisodeGrouping.jaccard([], []) == 0)
    #expect(EpisodeGrouping.jaccard([1, 2], [1, 2]) == 1)
    #expect(EpisodeGrouping.jaccard([1, 2], [3]) == 0)
    #expect(EpisodeGrouping.jaccard([1, 2, 3], [2, 3, 4]) == 0.5)
  }

  @Test func identityLinksJoinWithoutOverlap() {
    let groups = EpisodeGrouping.groups(
      shingles: [a: [1], b: [2], c: [3]], identityLinks: [(a, b)])
    #expect(groups.members(of: a) == [a, b])
    #expect(groups.members(of: c) == [c])
    #expect(groups.jaccardLinks.isEmpty)
  }

  @Test func identityLinksNamingUnknownKeysAreIgnored() {
    let groups = EpisodeGrouping.groups(
      shingles: [a: [1], b: [2]], identityLinks: [(a, EpisodeKey("ghost"))])
    #expect(groups.members(of: a) == [a])
    #expect(groups.members(of: EpisodeKey("ghost")) == [EpisodeKey("ghost")])
  }

  @Test func closureIsTransitive() {
    let groups = EpisodeGrouping.groups(
      shingles: [a: [1], b: [2], c: [3], d: [4]], identityLinks: [(a, b), (c, b)])
    #expect(groups.members(of: a) == [a, b, c])
    #expect(groups.members(of: d) == [d])
  }

  @Test func jaccardAtExactlyTheThresholdJoins() {
    // 2 shared of 5 distinct = 0.4.
    let groups = EpisodeGrouping.groups(
      shingles: [a: [1, 2, 3], b: [2, 3, 4, 5]], identityLinks: [])
    #expect(groups.members(of: a) == [a, b])
    #expect(groups.jaccardLinks == [.init(first: a, second: b, index: 0.4)])
  }

  @Test func justUnderTheThresholdDoesNotJoin() {
    let groups = EpisodeGrouping.groups(
      shingles: [a: [1, 2, 3, 4, 5, 6], b: [5, 6, 7, 8, 9]], identityLinks: [])  // 2 / 9
    #expect(groups.members(of: a) == [a])
    #expect(groups.jaccardLinks.isEmpty)
  }

  @Test func emptySetsNeverJoin() {
    let groups = EpisodeGrouping.groups(shingles: [a: [], b: []], identityLinks: [])
    #expect(groups.members(of: a) == [a])
    #expect(groups.jaccardLinks.isEmpty)
  }

  @Test func containmentDoesNotJoinAShortSubset() {
    let groups = EpisodeGrouping.groups(
      shingles: [a: range(0..<100), b: range(0..<10)], identityLinks: [])
    #expect(groups.members(of: a) == [a])
    #expect(groups.members(of: b) == [b])
  }

  @Test func jaccardChainsAndLinksAreSortedWithFirstBeforeSecond() {
    let groups = EpisodeGrouping.groups(
      shingles: [c: [1, 2], b: [1, 2], a: [1, 2]], identityLinks: [])
    #expect(groups.members(of: c) == [a, b, c])
    #expect(
      groups.jaccardLinks.map { [$0.first, $0.second] } == [[a, b], [a, c], [b, c]])
  }

  @Test func identityAndJaccardLinksCloseTogether() {
    let groups = EpisodeGrouping.groups(
      shingles: [a: [1], b: [2, 3], c: [2, 3], d: [9]], identityLinks: [(a, b)])
    #expect(groups.members(of: c) == [a, b, c])
    #expect(groups.members(of: d) == [d])
  }

  @Test func aJaccardLinkTheCheckRejectsDoesNotJoin() {
    let shingles: [EpisodeKey: Set<UInt64>] = [a: [1, 2, 3], b: [1, 2, 3], c: [1, 2, 3], d: [9]]
    var asked: [[EpisodeKey]] = []
    let groups = EpisodeGrouping.groups(
      shingles: shingles, identityLinks: [(c, d)],
      confirmsJaccardLink: { first, second in
        asked.append([first, second])
        return first == a && second == b
      })
    #expect(groups.members(of: a) == [a, b])
    #expect(groups.members(of: c) == [c, d])
    #expect(groups.jaccardLinks.map { [$0.first, $0.second] } == [[a, b]])
    #expect(asked.allSatisfy { $0[0] < $0[1] })
  }

  @Test func thresholdIsConfigurable() {
    let shingles: [EpisodeKey: Set<UInt64>] = [a: [1, 2, 3, 4], b: [4, 5, 6, 7]]  // 1/7
    #expect(EpisodeGrouping.groups(shingles: shingles, identityLinks: []).members(of: a) == [a])
    let loose = EpisodeGrouping.groups(
      shingles: shingles, identityLinks: [], jaccardThreshold: 0.1)
    #expect(loose.members(of: a) == [a, b])
  }
}
