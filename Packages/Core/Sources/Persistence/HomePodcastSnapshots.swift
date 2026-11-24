import Foundation

/// The two bounded views of the Home Recently Added item projection.
///
/// `all` is the ordinary account-scoped ABS result. `nativePreferred` is ranked and limited
/// independently after omitting only server podcast shows with a valid, exact RSS feed identity.
/// One value holding both lets callers choose a source policy without re-querying.
public struct HomeRecentlyAddedSnapshot: Sendable, Equatable, RandomAccessCollection {
  public typealias Element = HomeItem
  public typealias Index = Int

  public let all: [HomeItem]
  public let nativePreferred: [HomeItem]

  public init(all: [HomeItem], nativePreferred: [HomeItem]) {
    self.all = all
    self.nativePreferred = nativePreferred
  }

  // Collection compatibility keeps existing lightweight Home readers source-compatible while
  // callers migrate to the explicit `.all` / `.nativePreferred` policy arrays.
  public var startIndex: Int { all.startIndex }
  public var endIndex: Int { all.endIndex }
  public subscript(position: Int) -> HomeItem { all[position] }

  public static func == (lhs: Self, rhs: [HomeItem]) -> Bool {
    lhs.all == rhs && lhs.nativePreferred == rhs
  }

  public static func == (lhs: [HomeItem], rhs: Self) -> Bool {
    rhs == lhs
  }
}

/// The two bounded views of the ABS Latest Episodes projection.
///
/// `all` contains the ordinary eligible server episodes. `nativePreferred` independently applies
/// the exact native twin policy (account-fenced NP12 attempt, live paired RSS rows, equal valid
/// fingerprints, current native identity, and native Latest eligibility) before its own limit.
public struct HomeLatestPodcastEpisodesSnapshot: Sendable, Equatable, RandomAccessCollection {
  public typealias Element = HomePodcastEpisode
  public typealias Index = Int

  public let all: [HomePodcastEpisode]
  public let nativePreferred: [HomePodcastEpisode]

  public init(all: [HomePodcastEpisode], nativePreferred: [HomePodcastEpisode]) {
    self.all = all
    self.nativePreferred = nativePreferred
  }

  // Collection compatibility for existing callers that only consume the ABS array.
  public var startIndex: Int { all.startIndex }
  public var endIndex: Int { all.endIndex }
  public subscript(position: Int) -> HomePodcastEpisode { all[position] }

  public static func == (lhs: Self, rhs: [HomePodcastEpisode]) -> Bool {
    lhs.all == rhs && lhs.nativePreferred == rhs
  }

  public static func == (lhs: [HomePodcastEpisode], rhs: Self) -> Bool {
    rhs == lhs
  }
}
