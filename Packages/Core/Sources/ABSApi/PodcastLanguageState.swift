import Foundation

/// The presence state of the podcast-only `media.metadata.language` field in a minified library
/// item. An omitted key says nothing, so SyncEngine keeps a previously known language; an explicit
/// null, empty, wrong-type or overlong value says the show has no usable tag, and clears it.
public enum PodcastLanguageState: Sendable, Equatable {
  case absent
  /// Trimmed but otherwise as the server sent it (`en-GB`, `EN-us`).
  case value(String)
  case cleared

  /// Generously above BCP 47's 35-character practical length; anything longer is not a tag.
  public static let maximumBytes = 64
}
