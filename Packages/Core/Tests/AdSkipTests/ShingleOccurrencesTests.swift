import Testing

@testable import AdSkip

@Suite struct ShingleOccurrencesTests {
  /// Hashes drawn from a small pool so many occur in 1, 2 and many episodes; two planted pairs
  /// share 50%, 39% and 41% of their hashes.
  private func library(seed: UInt64) -> [EpisodeKey: Set<UInt64>] {
    var rng = SplitMix64(seed: seed)
    var shingles: [EpisodeKey: Set<UInt64>] = [:]
    for i in 0..<14 {
      var set: Set<UInt64> = []
      for _ in 0..<Int.random(in: 0...120, using: &rng) {
        set.insert(UInt64.random(in: 0..<400, using: &rng))
      }
      shingles[EpisodeKey("ep\(i)")] = set
    }
    // Each "b" is the first s hashes of its 100-hash "a", so Jaccard is s / 100.
    for (name, offset, shared) in [("p0", 1_000_000, 50), ("p1", 2_000_000, 39), ("p2", 3_000_000, 41)] {
      let full = Set((0..<100).map { UInt64(offset + $0) })
      shingles[EpisodeKey(name + "a")] = full
      shingles[EpisodeKey(name + "b")] = Set(full.sorted().prefix(shared))
    }
    shingles[EpisodeKey("empty1")] = []
    shingles[EpisodeKey("empty2")] = []
    return shingles
  }

  @Test func incrementalShuffledBuildEqualsDictionaryBuild() {
    let shingles = library(seed: 1)
    var rng = SplitMix64(seed: 2)
    var builder = ShingleOccurrences.Builder()
    for key in shingles.keys.shuffled(using: &rng) {
      builder.add(key, hashes: shingles[key]!.shuffled(using: &rng))
    }
    let built = builder.build()
    let direct = ShingleOccurrences(shingles: shingles)
    #expect(built == direct)
    #expect(direct.keys == shingles.keys.sorted())
    #expect(direct.count == shingles.values.reduce(0) { $0 + $1.count })
    for (i, key) in direct.keys.enumerated() { #expect(direct.hashCounts[i] == shingles[key]!.count) }
  }

  @Test func libraryIndexAgreesWithBruteForce() {
    let shingles = library(seed: 3)
    let index = LibraryIndex(occurrences: ShingleOccurrences(shingles: shingles))
    let legacy = LibraryIndex(shingles: shingles)
    let keys = shingles.keys.sorted()
    var rng = SplitMix64(seed: 4)
    var groups: [Set<EpisodeKey>] = [[], [keys[0]]]
    for size in [2, 3, 5, 9] { groups.append(Set(keys.shuffled(using: &rng).prefix(size))) }
    groups.append(Set(keys))
    var probes = Set<UInt64>(0..<420)
    probes.formUnion([1_000_000, 1_000_049, 1_000_050, 2_000_010, UInt64.max, 95_001])
    for group in groups {
      for hash in probes {
        let expected = shingles.contains { !group.contains($0.key) && $0.value.contains(hash) }
        #expect(index.occursOutside(hash, group: group) == expected)
        #expect(legacy.occursOutside(hash, group: group) == expected)
      }
    }
  }

  @Test func groupsAgreeWithBruteForceJaccard() {
    for seed in [5, 6, 7] as [UInt64] {
      let shingles = library(seed: seed)
      let keys = shingles.keys.sorted()
      let identity = [(keys[0], keys[3]), (keys[3], keys[7]), (keys[10], EpisodeKey("ghost"))]
      let groups = EpisodeGrouping.groups(
        occurrences: ShingleOccurrences(shingles: shingles), identityLinks: identity)
      var expected: [EpisodeGroups.JaccardLink] = []
      for i in keys.indices {
        for j in (i + 1)..<max(keys.count, i + 1) {
          let a = shingles[keys[i]]!
          let b = shingles[keys[j]]!
          let value = EpisodeGrouping.jaccard(a, b)
          if value >= EpisodeGrouping.jaccardThreshold {
            expected.append(.init(first: keys[i], second: keys[j], index: value))
          }
        }
      }
      #expect(groups.jaccardLinks == expected)
      #expect(groups.jaccardLinks.contains { $0.first.rawValue == "p0a" })
      let viaDictionary = EpisodeGrouping.groups(shingles: shingles, identityLinks: identity)
      #expect(viaDictionary.jaccardLinks == expected)

      // Reference closure by repeated merging.
      var sets = keys.map { Set([$0]) }
      let pairs = identity.map { ($0, $1) } + expected.map { ($0.first, $0.second) }
      for (x, y) in pairs {
        guard let i = sets.firstIndex(where: { $0.contains(x) }),
          let j = sets.firstIndex(where: { $0.contains(y) }), i != j
        else { continue }
        sets[i].formUnion(sets[j])
        sets.remove(at: j)
      }
      for key in keys {
        #expect(groups.members(of: key) == sets.first { $0.contains(key) })
        #expect(viaDictionary.members(of: key) == groups.members(of: key))
      }
    }
  }

  @Test func plantedThresholdEdges() {
    let shingles = library(seed: 8)
    let groups = EpisodeGrouping.groups(shingles: shingles, identityLinks: [])
    #expect(groups.members(of: EpisodeKey("p1a")) == [EpisodeKey("p1a")])
    #expect(groups.members(of: EpisodeKey("p2a")) == [EpisodeKey("p2a"), EpisodeKey("p2b")])
    #expect(groups.members(of: EpisodeKey("p0a")) == [EpisodeKey("p0a"), EpisodeKey("p0b")])
  }

  @Test func emptyLibrary() {
    let occurrences = ShingleOccurrences(shingles: [:])
    #expect(occurrences.keys.isEmpty)
    #expect(occurrences.count == 0)
    let groups = EpisodeGrouping.groups(occurrences: occurrences, identityLinks: [])
    #expect(groups.jaccardLinks.isEmpty)
    #expect(!LibraryIndex(occurrences: occurrences).occursOutside(1, group: []))
  }

  @Test func singleEpisode() {
    let key = EpisodeKey("only")
    let occurrences = ShingleOccurrences(shingles: [key: [1, 2, 3]])
    let groups = EpisodeGrouping.groups(occurrences: occurrences, identityLinks: [])
    #expect(groups.jaccardLinks.isEmpty)
    #expect(groups.members(of: key) == [key])
    let index = LibraryIndex(occurrences: occurrences)
    #expect(!index.occursOutside(1, group: [key]))
    #expect(index.occursOutside(1, group: []))
  }

  @Test func emptyHashSetsAreNeverJoined() {
    let a = EpisodeKey("a")
    let b = EpisodeKey("b")
    let c = EpisodeKey("c")
    let groups = EpisodeGrouping.groups(
      occurrences: ShingleOccurrences(shingles: [a: [], b: [], c: [1]]), identityLinks: [])
    #expect(groups.jaccardLinks.isEmpty)
    #expect(groups.members(of: a) == [a])
  }
}
