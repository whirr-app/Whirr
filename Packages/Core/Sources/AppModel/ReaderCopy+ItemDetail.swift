/// User-facing copy for the detail screen's reader affordance, separate from the reader screen's
/// copy catalog.
public enum ReaderDetailCopy {
  public static let read = "Read"
  /// A finished book's action. It opens at the position it was left at (the end), as a finished
  /// audiobook's play button resumes at its own end. The Contents tab goes back to the start.
  public static let readAgain = "Read Again"
  public static let advertisedButUnavailable =
    "This book is advertised as an EPUB, but it isn't available to read."
  public static let protected = "This book is protected and can't be opened here."

  /// The visible row title. No percentage: the row already renders `percentRead` as its subtitle
  /// and a determinate ring beside it.
  public static let continueReadingTitle = "Continue reading"

  public static func percentRead(percent: Int) -> String {
    "\(percent)%"
  }

  /// The spoken label. VoiceOver reads the row as one element, so this keeps the percentage that
  /// `continueReadingTitle` drops.
  public static func continueReading(percent: Int) -> String {
    "Continue reading \(percent)%"
  }

  public static func downloading(progress: Double) -> String {
    let percent = Int((min(max(progress, 0), 1) * 100).rounded())
    return "Downloading… \(percent)%"
  }

  public static func text(for state: ReadAffordanceState) -> String? {
    switch state {
    case .none:
      return nil
    case .read:
      return read
    case .continueReading(let percent):
      return continueReading(percent: percent)
    case .downloading(let progress):
      return downloading(progress: progress)
    case .advertisedButUnavailable:
      return advertisedButUnavailable
    case .protected:
      return protected
    }
  }

  /// The detail screen's primary reader action, as the single line its prominent bar renders.
  /// `isFinished` is the screen's own finished projection (`FinishedStatusStore`), not a reader
  /// state: it renames the action without withdrawing it.
  /// "37% left" is the reading remainder for the detail progress line beside the bar. Gated like
  /// `detailReadingFraction`, so the figure and the bar always appear together.
  public static func detailReadingRemaining(for state: ReadAffordanceState) -> String? {
    guard let fraction = detailReadingFraction(for: state) else { return nil }
    return "\(100 - Int((fraction * 100).rounded()))% left"
  }

  /// The detail progress bar's fill for an ebook: present only while genuinely part-read, matching
  /// the audiobook control's `progressFraction` policy.
  public static func detailReadingFraction(for state: ReadAffordanceState) -> Double? {
    guard case .continueReading(let percent) = state else { return nil }
    let clamped = min(max(percent, 0), 100)
    guard clamped > 0, clamped < 100 else { return nil }
    return Double(clamped) / 100
  }

  public static func detailActionTitle(
    for state: ReadAffordanceState, isFinished: Bool
  ) -> String? {
    switch state {
    case .read where isFinished, .continueReading where isFinished:
      return readAgain
    case .read:
      return read
    case .continueReading:
      // The percentage lives on the detail progress line: a button names its tap, not the state
      // it acts on.
      return continueReadingTitle
    case .none, .downloading, .advertisedButUnavailable, .protected:
      return nil
    }
  }
}
