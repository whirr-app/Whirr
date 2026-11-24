import Persistence

/// The source-qualified identity needed to start a catalogue row. `PodcastSourceIdentity` is
/// validated at construction by the persisted readers' established API; callers never inspect or
/// split the reserved `rss:` spelling.
public struct CompanionSelection: Sendable, Equatable, Hashable, Identifiable {
  public let source: PodcastSourceIdentity
  public let episodeID: String?

  public var id: Self { self }
  public var itemID: String { source.itemId }

  public init(source: PodcastSourceIdentity, episodeID: String? = nil) {
    self.source = source
    self.episodeID = episodeID
  }
}
