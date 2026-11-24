/// The pauses cut from one downloaded episode, and the two timelines that cutting creates
/// (source time is the file, played time is what is kept). Everything in PlayerCore (positions,
/// seeks, chapters, skip ranges, the sleep timer) stays in source time. The engine crosses to
/// played time, and the reducer predicts ticks, only through this map, so they agree on splices.
///
/// A map describes a single-file item, whose file time is also its global time.
public struct PlayerTrimMap: Sendable, Equatable, Hashable {
  /// One cut: source time `start..<end` is not played. A time exactly at `start` is inside it.
  public struct Cut: Sendable, Equatable, Hashable {
    public let start: Double
    public let end: Double

    public init(start: Double, end: Double) {
      self.start = start
      self.end = end
    }

    var duration: Double { end - start }
  }

  /// The composition's timescale. Every edge is quantised to it on construction, so the engine
  /// inserting segments at this timescale and the reducer predicting ticks compute from identical
  /// values, and splice rounding never reaches the reducer's 10 ms jump tolerance.
  public static let timescale: Int32 = 44_100

  /// Sorted and non-overlapping; touching cuts are merged.
  public let cuts: [Cut]
  /// Seconds cut before each cut starts: `trimmedBefore[i]` is the sum of `cuts[0..<i]`.
  private let trimmedBefore: [Double]

  /// Cuts with a non-finite or empty span are dropped, a negative start is clamped to zero, and
  /// overlapping or touching cuts are joined.
  public init(cuts: [Cut]) {
    let scale = Double(Self.timescale)
    func quantised(_ seconds: Double) -> Double { (seconds * scale).rounded() / scale }

    let valid =
      cuts
      .filter { $0.start.isFinite && $0.end.isFinite }
      .map { Cut(start: quantised(max(0, $0.start)), end: quantised($0.end)) }
      .filter { $0.start < $0.end }
      .sorted { $0.start < $1.start }

    var merged: [Cut] = []
    for cut in valid {
      if let last = merged.last, cut.start <= last.end {
        merged[merged.count - 1] = Cut(start: last.start, end: max(last.end, cut.end))
      } else {
        merged.append(cut)
      }
    }

    var before: [Double] = []
    before.reserveCapacity(merged.count)
    var running = 0.0
    for cut in merged {
      before.append(running)
      running += cut.duration
    }
    self.cuts = merged
    self.trimmedBefore = before
  }

  public var isEmpty: Bool { cuts.isEmpty }

  public var totalTrimmed: Double {
    guard let last = cuts.last, let before = trimmedBefore.last else { return 0 }
    return before + last.duration
  }

  /// Where `source` is heard in the composition. A time inside a cut maps to the splice instant.
  public func playedTime(forSource source: Double) -> Double {
    guard let index = lastIndex(where: { cuts[$0].start <= source }) else { return source }
    let cut = cuts[index]
    if source < cut.end { return cut.start - trimmedBefore[index] }
    return source - trimmedBefore[index] - cut.duration
  }

  /// The source time heard at `played`. A splice instant maps to the end of its cut.
  public func sourceTime(forPlayed played: Double) -> Double {
    guard let index = lastIndex(where: { spliceInstant(of: $0) <= played }) else { return played }
    return played + trimmedBefore[index] + cuts[index].duration
  }

  /// The source time reached by playing `playedSeconds` of the composition from `source`.
  public func sourceTime(advancing playedSeconds: Double, from source: Double) -> Double {
    sourceTime(forPlayed: playedTime(forSource: source) + playedSeconds)
  }

  /// `source` moved to the end of the cut it falls in, if any. Where the engine lands for a seek
  /// to `source`.
  public func snapped(_ source: Double) -> Double {
    guard let index = lastIndex(where: { cuts[$0].start <= source }), source < cuts[index].end else {
      return source
    }
    return cuts[index].end
  }

  /// Seconds of cut source time between `from` and `to`; zero for a backward span.
  public func trimmedSeconds(from: Double, to: Double) -> Double {
    guard to > from else { return 0 }
    return max(0, trimmed(upTo: to) - trimmed(upTo: from))
  }

  // MARK: - Private

  private func trimmed(upTo source: Double) -> Double {
    source - playedTime(forSource: source)
  }

  private func spliceInstant(of index: Int) -> Double {
    cuts[index].start - trimmedBefore[index]
  }

  /// The last index for which `isAtOrBefore` holds, given that it holds for a prefix of `cuts`.
  /// Both `start` and the splice instants are strictly increasing, which is what makes this a
  /// binary search.
  private func lastIndex(where isAtOrBefore: (Int) -> Bool) -> Int? {
    var low = 0
    var high = cuts.count
    while low < high {
      let middle = (low + high) / 2
      if isAtOrBefore(middle) { low = middle + 1 } else { high = middle }
    }
    return low == 0 ? nil : low - 1
  }
}
