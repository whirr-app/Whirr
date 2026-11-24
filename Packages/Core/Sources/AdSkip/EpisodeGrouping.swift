import Foundation

/// Episodes that are copies of one another, so programme never matches itself. The harness pooled
/// by file name; here identity links come first (an RSS episode and its ABS copy, or equal file
/// fingerprints) and a Jaccard fallback catches reruns, grouped by transitive closure. Containment
/// is never used, so a trailer is not absorbed by its full episode.
public struct EpisodeGroups: Sendable {
  /// A pair joined by the Jaccard fallback, kept to measure how often it fires.
  public struct JaccardLink: Sendable, Equatable {
    public let first: EpisodeKey
    public let second: EpisodeKey
    public let index: Double
  }

  /// Pairs whose Jaccard index reached the threshold, `first < second`, sorted by `first` then
  /// `second`.
  public let jaccardLinks: [JaccardLink]

  private let groupOf: [EpisodeKey: Int]
  private let groupMembers: [Int: Set<EpisodeKey>]

  init(
    jaccardLinks: [JaccardLink], groupOf: [EpisodeKey: Int], groupMembers: [Int: Set<EpisodeKey>]
  ) {
    self.jaccardLinks = jaccardLinks
    self.groupOf = groupOf
    self.groupMembers = groupMembers
  }

  /// Every episode in `key`'s group, including `key`. An unknown key is a group of one.
  public func members(of key: EpisodeKey) -> Set<EpisodeKey> {
    guard let group = groupOf[key], let members = groupMembers[group] else { return [key] }
    return members
  }
}

public enum EpisodeGrouping {
  /// Measured over 417 hold-out, training and replay copies: every pair at or above 0.2 was the
  /// same audio, and the lowest same-episode pair was 0.457.
  public static let jaccardThreshold = 0.4
  /// Under audio gating a Jaccard link also needs this share of each episode's audio in common:
  /// index views hold mostly recurring audio, so episodes sharing ads reach the Jaccard threshold.
  /// On hold-outs 3 and 4 such pairs shared at most 14.1% of their audio, copies at least 93.0%.
  public static let sharedAudioThreshold = 0.5

  /// Groups `shingles`' keys. Identity links naming a key absent from `shingles` are ignored. Two
  /// empty shingle sets have index 0 and are never joined by Jaccard. A pair reaching the Jaccard
  /// threshold joins only if `confirmsJaccardLink` (asked with `first < second`) agrees.
  public static func groups(
    shingles: [EpisodeKey: Set<UInt64>], identityLinks: [(EpisodeKey, EpisodeKey)],
    jaccardThreshold: Double = EpisodeGrouping.jaccardThreshold,
    confirmsJaccardLink: ((EpisodeKey, EpisodeKey) -> Bool)? = nil
  ) -> EpisodeGroups {
    groups(
      occurrences: ShingleOccurrences(shingles: shingles), identityLinks: identityLinks,
      jaccardThreshold: jaccardThreshold, confirmsJaccardLink: confirmsJaccardLink)
  }

  /// As `groups(shingles:...)`, over a prebuilt occurrence table.
  public static func groups(
    occurrences: ShingleOccurrences, identityLinks: [(EpisodeKey, EpisodeKey)],
    jaccardThreshold: Double = EpisodeGrouping.jaccardThreshold,
    confirmsJaccardLink: ((EpisodeKey, EpisodeKey) -> Bool)? = nil
  ) -> EpisodeGroups {
    let keys = occurrences.keys
    let n = keys.count
    let ordinal = Dictionary(uniqueKeysWithValues: keys.enumerated().map { ($1, $0) })
    var parent = Array(0..<n)
    func find(_ x: Int) -> Int {
      var root = x
      while parent[root] != root { root = parent[root] }
      var node = x
      while parent[node] != root {
        let next = parent[node]
        parent[node] = root
        node = next
      }
      return root
    }
    func union(_ a: Int, _ b: Int) {
      let rootA = find(a)
      let rootB = find(b)
      if rootA != rootB { parent[max(rootA, rootB)] = min(rootA, rootB) }
    }
    for (a, b) in identityLinks {
      if let i = ordinal[a], let j = ordinal[b] { union(i, j) }
    }

    // Pair intersections in a flat upper triangle (row i holds j > i), counted by walking the
    // runs of equal hash, so only pairs sharing a hash are touched.
    func slot(_ i: Int, _ j: Int) -> Int { i * n - i * (i + 1) / 2 + (j - i - 1) }
    var shared = [UInt32](repeating: 0, count: n * (n - 1) / 2)
    occurrences.forEachSharedRun { run in
      for x in run.lowerBound..<run.upperBound {
        let i = occurrences.ordinal(at: x)
        for y in (x + 1)..<run.upperBound {
          shared[slot(i, occurrences.ordinal(at: y))] += 1
        }
      }
    }
    var links: [EpisodeGroups.JaccardLink] = []
    for i in 0..<n {
      for j in (i + 1)..<max(n, i + 1) {
        let both = Int(shared[slot(i, j)])
        if both == 0 { continue }
        let union = occurrences.hashCounts[i] + occurrences.hashCounts[j] - both
        let value = Double(both) / Double(union)
        if value >= jaccardThreshold, confirmsJaccardLink?(keys[i], keys[j]) ?? true {
          links.append(.init(first: keys[i], second: keys[j], index: value))
        }
      }
    }
    links.sort { ($0.first, $0.second) < ($1.first, $1.second) }
    for link in links { union(ordinal[link.first]!, ordinal[link.second]!) }

    var groupOf: [EpisodeKey: Int] = [:]
    var groupMembers: [Int: Set<EpisodeKey>] = [:]
    for (i, key) in keys.enumerated() {
      let root = find(i)
      groupOf[key] = root
      groupMembers[root, default: []].insert(key)
    }
    return EpisodeGroups(jaccardLinks: links, groupOf: groupOf, groupMembers: groupMembers)
  }

  public static func jaccard(_ a: Set<UInt64>, _ b: Set<UInt64>) -> Double {
    let shared = a.count <= b.count ? a.intersection(b).count : b.intersection(a).count
    let union = a.count + b.count - shared
    return union == 0 ? 0 : Double(shared) / Double(union)
  }
}
