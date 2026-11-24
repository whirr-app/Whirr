import ABSApi

/// Owns RSS/Atom feed fetch, parsing, and OPML for RSS-origin traffic (ADR 0004).
public enum PodcastFeeds {}

/// AppModel reaches the feed-credential store only through its existing PodcastFeeds dependency;
/// the alias preserves that layering while the concrete primitive remains low enough for the
/// independent SyncEngine enclosure mint to use through ABSApi.
public typealias PodcastFeedCredentialStoring = ABSApi.FeedCredentialStoring
public typealias PodcastFeedCredential = ABSApi.FeedCredential
