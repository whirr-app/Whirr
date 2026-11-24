/// Debug builds' measurement of the coordinator's own matching work: the stage-1 audio queries a
/// pass runs and each library recompute. The app logs one line per unit; release builds pass none.
/// Counts only, never an episode or a name.
public protocol AdSkipMatchingMeasuring: Sendable {
  /// Called before the unit runs, so the measurer can read the device and the process.
  func willStart(_ unit: AdSkipMatchingUnit) async
  /// Called once the unit has run, or has thrown.
  func didFinish(_ unit: AdSkipMatchingUnit, _ detail: AdSkipMatchingDetail) async
}

public enum AdSkipMatchingUnit: String, Sendable {
  /// Choosing the next unit of work, which replans every episode whose stage-1 plan was dropped.
  /// Most such passes run no query.
  case replan
  /// One library recompute. Its own replanning is counted in its detail, not as a `replan`.
  case recompute
  /// The check of every plan an incremental replan kept against a full query, run once the
  /// worker is idle. Logged whether or not anything differs.
  case replanMismatch
}

public struct AdSkipMatchingDetail: Sendable, Equatable {
  /// Stage-1 audio queries the unit ran, each one episode against the whole library.
  public var queries: Int
  /// References in the audio library once the unit ended: episode prints, then learned ones.
  public var librarySize: Int?
  /// Candidates a recompute read, and rows it saved.
  public var episodesRead: Int?
  public var episodesSaved: Int?
  /// Kept episodes checked against an added print for shared audio, each a query against that
  /// one print.
  public var pairChecks: Int?
  /// Kept plans whose windows differ from a full query's (`replanMismatch` only).
  public var windowMismatches: Int?
  /// Seconds each learned creative a recompute matched had gone unseen, as the store held it before
  /// the pass, once per creative, ascending: how much the 90-day expiry costs. Tombstone vetoes and
  /// a teacher learning its own ad again are not matches.
  public var storeMatchAges: [Double]?
  public var succeeded: Bool

  public init(
    queries: Int, librarySize: Int? = nil, episodesRead: Int? = nil, episodesSaved: Int? = nil,
    pairChecks: Int? = nil, windowMismatches: Int? = nil, storeMatchAges: [Double]? = nil,
    succeeded: Bool = true
  ) {
    self.queries = queries
    self.librarySize = librarySize
    self.episodesRead = episodesRead
    self.episodesSaved = episodesSaved
    self.pairChecks = pairChecks
    self.windowMismatches = windowMismatches
    self.storeMatchAges = storeMatchAges
    self.succeeded = succeeded
  }
}
