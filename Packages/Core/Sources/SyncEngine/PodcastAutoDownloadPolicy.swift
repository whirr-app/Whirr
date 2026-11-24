import Foundation

/// Named budgets for the automatic-download pass, kept together so call sites never use literals.
public struct PodcastAutoDownloadPolicy: Sendable, Equatable {
  /// The per-show cap `PodcastAutoDownloadSelectionStore.fetchCandidates(maxPerShow:)` enforces.
  public var maxEpisodesPerShow: Int
  /// The whole-pass cap the same query enforces.
  public var maxEpisodesPerPass: Int

  public init(maxEpisodesPerShow: Int = 5, maxEpisodesPerPass: Int = 20) {
    self.maxEpisodesPerShow = maxEpisodesPerShow
    self.maxEpisodesPerPass = maxEpisodesPerPass
  }
}
