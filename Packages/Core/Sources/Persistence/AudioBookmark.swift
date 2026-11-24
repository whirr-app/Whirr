import Foundation

/// An Audiobookshelf bookmark's identity. The server stores no id, so a bookmark is the pair of its
/// item and its `time`, compared as exact doubles.
public struct AudioBookmarkKey: Sendable, Hashable {
  public let serverItemID: String
  public let time: Double

  public init(serverItemID: String, time: Double) {
    self.serverItemID = serverItemID
    self.time = AudioBookmark.normalizedTime(time)
  }
}

/// An Audiobookshelf audio bookmark as the rest of the app sees it. Not to be confused with
/// `PlaybackBookmark`, which is the "last played item" record.
public struct AudioBookmark: Sendable, Hashable, Identifiable {
  public let serverItemID: String
  /// Seconds from the start of the item, exactly as the server stores it. Bookmarks Whirr creates
  /// are whole seconds; ones made elsewhere may carry a fraction, which must be sent back unchanged.
  public let time: Double
  public let title: String
  public let createdAt: Date?

  public init(serverItemID: String, time: Double, title: String, createdAt: Date?) {
    self.serverItemID = serverItemID
    self.time = Self.normalizedTime(time)
    self.title = title
    self.createdAt = createdAt
  }

  public var id: AudioBookmarkKey { AudioBookmarkKey(serverItemID: serverItemID, time: time) }

  /// `-0.0` and `0.0` are the same bookmark to the server; folding the sign keeps the outbox
  /// coalescing key, which uses the bit pattern, from treating them as two.
  static func normalizedTime(_ time: Double) -> Double {
    time == 0 ? 0 : time
  }
}

extension AudioBookmark {
  init(record: AudioBookmarkRecord) {
    self.init(
      serverItemID: record.serverItemId, time: record.time, title: record.title,
      createdAt: record.createdAt)
  }
}
