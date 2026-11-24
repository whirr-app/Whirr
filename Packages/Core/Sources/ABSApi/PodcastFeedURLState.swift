import Foundation

/// The presence state of the podcast-only `media.metadata.feedUrl` field in a minified library
/// item. Optional strings cannot distinguish an older/minified response that omitted the field
/// from a response that explicitly supplied unusable data, and SyncEngine needs that distinction
/// to preserve an already-known identity only in the former case.
public enum PodcastFeedURLState: Sendable, Equatable, CustomStringConvertible,
  CustomDebugStringConvertible, CustomReflectable
{
  case absent
  case value(String)
  case invalid

  public var description: String {
    switch self {
    case .absent: return "PodcastFeedURLState(absent)"
    case .value: return "PodcastFeedURLState(value: <redacted>)"
    case .invalid: return "PodcastFeedURLState(invalid)"
    }
  }

  public var debugDescription: String { description }

  public var customMirror: Mirror { Mirror(self, unlabeledChildren: []) }
}
