import AdSkip
import Foundation
import Persistence

/// The signature store as one recompute pass leaves it: the store as loaded, with its copies of
/// one ad merged, plus everything the pass has learned so far. Learning reads and writes this
/// draft, so it sees an ad made earlier in the same pass; the database changes once, at the end.
struct LearnedAdDraft {
  private struct Entry {
    var creative: SignatureCreative
    var print: AudioPrint?
    /// Made, changed or confirmed by this pass's learning, so not a stale ad to replace.
    var written = false
  }

  /// The loaded store after expiry and the collapse, tombstones included: what the pass matches
  /// against. Learning does not change it.
  let collapsed: [SignatureCreative]

  private let loaded: [Int64: SignatureCreative]
  /// Live learned ads by id. An ad the pass made has a negative id until the store names it.
  private var entries: [Int64: Entry] = [:]
  /// The ads that hold each hash. An id stays listed after its ad is gone.
  private var holders: [UInt64: [Int64]] = [:]
  private var deletions: Set<Int64>
  /// Each ad that was replaced or merged away, and the ad that holds it now.
  private var renames: [Int64: Int64]
  private var seen: [Int64: Date] = [:]
  private var nextNew: Int64 = -1

  init(loaded: [SignatureCreative], expired: Set<Int64>, prints: [Int64: AudioPrint]) {
    let current = loaded.filter { !expired.contains($0.id) }
    let collapse = LearnedAdMerging.collapse(current, prints: prints)
    self.loaded = Dictionary(current.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    collapsed = collapse.creatives
    deletions = expired.union(collapse.absorbed.keys)
    renames = collapse.absorbed
    // A confirmed ad is held out of the entries, so no case of `learn` replaces, absorbs or
    // refreshes it: it stays as the listener's mark taught it.
    for creative in collapse.creatives where creative.kind == .learned && creative.confirmed == false {
      entries[creative.id] = Entry(creative: creative, print: prints[creative.id].flatMap { $0.isEmpty ? nil : $0 })
      for hash in creative.hashes { holders[hash, default: []].append(creative.id) }
      // A refresh addressed to an absorbed ad goes with it, so the survivor takes the later date.
      if let before = self.loaded[creative.id], creative.lastSeen > before.lastSeen {
        seen[creative.id] = creative.lastSeen
      }
    }
  }

  /// Older first: stored ads by id, then this pass's in the order made.
  private static func isOlder(_ first: Int64, _ second: Int64) -> Bool {
    (first < 0 ? 1 : 0, abs(first)) < (second < 0 ? 1 : 0, abs(second))
  }

  private mutating func rename(_ old: Int64, to new: Int64) {
    for (key, value) in renames where value == old { renames[key] = new }
    renames[old] = new
  }

  private mutating func remove(_ id: Int64) {
    entries[id] = nil
    seen[id] = nil
    if id >= 0 { deletions.insert(id) }
  }

  /// Takes in one range a teaching episode kept. The first case that applies, in this order:
  /// already held, re-taught, the same ad as one in the draft, new. The order is what keeps ids
  /// stable: an episode that carries an ad twice merges the second range into the first's ad, and
  /// on the next pass both find their hashes already held.
  mutating func learn(_ learned: NewSignatureCreative, print: AudioPrint?, now: Date) {
    let print = print.flatMap { $0.isEmpty ? nil : $0 }
    var shared: [Int64: Int] = [:]
    for hash in learned.hashes {
      for id in holders[hash] ?? [] where entries[id] != nil { shared[id, default: 0] += 1 }
    }
    let sharing = shared.keys.sorted(by: Self.isOlder)

    // Already held. Without the print condition an ad with no print would never gain one.
    if let held = sharing.first(where: { id in
      guard let entry = entries[id], shared[id] == learned.hashes.count else { return false }
      return entry.creative.teachers.isSuperset(of: learned.teachers) && (entry.print != nil || print == nil)
    }) {
      entries[held]?.written = true
      if held >= 0 { seen[held] = now }
      return
    }

    // Re-taught: what only this group taught for an overlapping range is replaced. "Only" keeps a
    // merged ad out, whose range belongs to another episode's timeline.
    let replaced = entries.values.filter {
      $0.written == false && $0.creative.teachers.isEmpty == false
        && $0.creative.teachers.isSubset(of: learned.teachers)
        && $0.creative.start < learned.end && $0.creative.end > learned.start
    }.map(\.creative.id)
    for id in replaced { remove(id) }

    // The same ad as one in the draft, or new.
    var merged = Entry(
      creative: SignatureCreative(
        id: nextNew, kind: .learned, lastSeen: now, start: learned.start, end: learned.end,
        teachers: learned.teachers, hashes: learned.hashes),
      print: print, written: true)
    var gone: [Int64] = []
    for id in sharing {
      guard let candidate = entries[id],
        LearnedAdMerging.canAbsorb(candidate.creative.hashes, into: merged.creative.hashes),
        LearnedAdMerging.isSameAd(
          LearnedAdMerging.Content(hashes: merged.creative.hashes, print: merged.print),
          LearnedAdMerging.Content(hashes: candidate.creative.hashes, print: candidate.print))
      else { continue }
      let takesOver =
        LearnedAdMerging.outlives(candidate.print, merged.print)
        || (LearnedAdMerging.outlives(merged.print, candidate.print) == false
          && Self.isOlder(candidate.creative.id, merged.creative.id))
      let (kept, lost) = takesOver ? (candidate, merged) : (merged, candidate)
      merged = Entry(
        creative: SignatureCreative(
          id: kept.creative.id, kind: .learned,
          lastSeen: max(kept.creative.lastSeen, lost.creative.lastSeen),
          start: kept.creative.start, end: kept.creative.end,
          teachers: LearnedAdMerging.teachers(kept.creative.teachers, adding: lost.creative.teachers),
          hashes: kept.creative.hashes.union(lost.creative.hashes)),
        print: kept.print, written: true)
      gone.append(lost.creative.id)
    }
    let survivor = merged.creative.id
    for id in gone where id != nextNew {
      remove(id)
      rename(id, to: survivor)
    }
    for id in replaced { rename(id, to: survivor) }
    let held = entries[survivor]?.creative.hashes ?? []
    for hash in merged.creative.hashes where held.contains(hash) == false {
      holders[hash, default: []].append(survivor)
    }
    entries[survivor] = merged
    if survivor == nextNew {
      nextNew -= 1
    } else {
      seen[survivor] = now
    }
  }

  /// The pass's one store change. `matched` is what matching refreshed; a later date wins.
  func change(matched: [Int64: Date], now: Date) -> AdSignatureStoreChange {
    var additions: [Int64: AdSignatureAddition] = [:]
    for (id, entry) in entries where id >= 0 {
      guard let before = loaded[id] else { continue }
      let teachers = entry.creative.teachers.subtracting(before.teachers)
      let hashes = entry.creative.hashes.subtracting(before.hashes)
      if teachers.isEmpty == false || hashes.isEmpty == false {
        additions[id] = AdSignatureAddition(teachers: Set(teachers.map(\.rawValue)), hashes: hashes)
      }
    }
    let insertions = newIDs.compactMap { entries[$0] }.map { entry in
      NewAdSignatureCreative(
        kind: .learned, lastSeen: now, startTime: entry.creative.start, endTime: entry.creative.end,
        teachers: Set(entry.creative.teachers.map(\.rawValue)), hashes: entry.creative.hashes,
        audioPrint: entry.print?.data)
    }
    return AdSignatureStoreChange(
      deletions: deletions, insertions: insertions, additions: additions,
      seen: seen.merging(matched) { max($0, $1) }.filter { !deletions.contains($0.key) })
  }

  /// The ads the pass made, in the order `change` inserts them.
  private var newIDs: [Int64] { entries.keys.filter { $0 < 0 }.sorted(by: >) }

  /// Each stored ad that was replaced or merged away, and the stored ad that holds it now, so a
  /// range matched against the old ad names the new one. `inserted` is what the store returned for
  /// `change`'s insertions.
  func successors(inserted: [Int64], surviving: Set<Int64>) -> [Int64: Int64] {
    let stored = Dictionary(uniqueKeysWithValues: zip(newIDs, inserted))
    var result: [Int64: Int64] = [:]
    for (old, holder) in renames where old >= 0 {
      guard let id = holder < 0 ? stored[holder] : holder, surviving.contains(id) else { continue }
      result[old] = id
    }
    return result
  }
}
