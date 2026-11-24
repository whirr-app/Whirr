/// How far analysis has got through the downloaded episodes, for the settings page.
public struct AdSkipProgress: Equatable, Sendable {
  public enum Activity: Equatable, Sendable {
    /// Work remains and the worker is on it. Once every episode counts as analysed, that work is
    /// windows a later recompute asked for: look-backs, or audio that now recurs elsewhere.
    case analysing
    /// Work remains, but analysis is held back: on battery, Low Power Mode, a hot phone, or the
    /// speech model still to arrive.
    case paused
    /// Nothing remains.
    case idle
  }

  /// Analysable episodes with a stored transcript.
  public var analysed: Int
  /// Analysable episodes analysis gave up on, or whose file could not be read.
  public var unanalysable: Int
  /// Downloaded episodes of shows that can be analysed.
  public var total: Int
  public var activity: Activity

  public init(analysed: Int, unanalysable: Int, total: Int, activity: Activity) {
    self.analysed = analysed
    self.unanalysable = unanalysable
    self.total = total
    self.activity = activity
  }

  /// Episodes still waiting for a transcription, including the one in progress.
  public var remaining: Int { total - analysed - unanalysable }
}
