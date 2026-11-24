import ABSApi
import Foundation
import PlayerCore

/// One downloadable audio file. `headers` carries the Bearer token the download needs, so the
/// textual forms and the mirror are hand-written and show neither headers nor URL (SECURITY.md
/// rule 7); the synthesized ones would print the token wherever a track or preparation is logged.
public struct WatchAudioTrack: Sendable, Equatable, CustomStringConvertible,
  CustomDebugStringConvertible, CustomReflectable
{
  public let index: Int
  public let url: URL
  public let headers: [String: String]

  public init(index: Int, url: URL, headers: [String: String]) {
    self.index = index
    self.url = url
    self.headers = headers
  }

  public var description: String { "WatchAudioTrack(index: \(index), <redacted>)" }
  public var debugDescription: String { description }
  public var customMirror: Mirror { Mirror(self, children: ["index": index], displayStyle: .struct) }
}

public struct WatchAudioPreparation: Sendable, Equatable {
  public let title: String?
  public let timeline: PlaybackTimeline
  public let tracks: [WatchAudioTrack]
  public let chapters: PlaybackChapterMap

  public init(
    title: String?, timeline: PlaybackTimeline, tracks: [WatchAudioTrack],
    chapters: PlaybackChapterMap = .init(chapters: [])
  ) {
    self.title = title
    self.timeline = timeline
    self.tracks = tracks
    self.chapters = chapters
  }

  /// The same preparation over a corrected timeline. The audio, its authorization and the chapter
  /// map are unaffected by a duration that under-ran the real file, so only the timeline moves
  /// (see `PlaybackTimeline.grown(toObservedLocalExtent:)`).
  public func replacingTimeline(_ timeline: PlaybackTimeline) -> WatchAudioPreparation {
    WatchAudioPreparation(title: title, timeline: timeline, tracks: tracks, chapters: chapters)
  }
}

/// Builds authorized audio values without owning playback lifecycle.
struct WatchAudioPreparationFactory: Sendable {
  let service: any WatchPlaybackService & WatchDownloadService
  let serverURL: URL

  func makeIndependentPreparation(
    descriptors: [WatchDownloadDescriptor], account: TokenAccount, renewAuthorization: Bool
  ) async throws -> WatchAudioPreparation {
    guard !descriptors.isEmpty else { throw WatchLibraryError.libraryUnavailable }
    let ordered = descriptors.sorted { $0.fileIndex < $1.fileIndex }
    var tracks: [WatchAudioTrack] = []
    tracks.reserveCapacity(ordered.count)
    for descriptor in ordered {
      guard case .audiobookshelf(let itemID, _) = descriptor.selection else {
        throw WatchLibraryError.nativeSelectionUnavailable
      }
      // `Int` is 32 bits on older Watches: a file too large for it cannot be asked for.
      guard let expectedSize = Int(exactly: descriptor.expectedBytes) else {
        throw WatchLibraryError.libraryUnavailable
      }
      let request: AuthorizedDownloadRequest
      if renewAuthorization && tracks.isEmpty {
        request = try await service.renewAudioDownload(
          account: account, itemID: itemID,
          fileID: descriptor.fileID, mimeType: descriptor.expectedMIMEType,
          expectedSize: expectedSize)
      } else {
        request = try await service.audioDownload(
          account: account, itemID: itemID,
          fileID: descriptor.fileID, mimeType: descriptor.expectedMIMEType,
          expectedSize: expectedSize)
      }
      let urlRequest = request.makeURLRequest()
      guard request.itemID == itemID,
        request.fileID == descriptor.fileID,
        request.expectedMIMEType == descriptor.expectedMIMEType,
        Int64(request.expectedSize) == descriptor.expectedBytes,
        let url = urlRequest.url,
        Self.admitsTrackURL(url, serverURL: serverURL),
        urlRequest.allHTTPHeaderFields?["Authorization"]?.hasPrefix("Bearer ") == true
      else { throw WatchLibraryError.libraryUnavailable }
      tracks.append(
        WatchAudioTrack(
          index: descriptor.fileIndex, url: url,
          headers: urlRequest.allHTTPHeaderFields ?? [:]))
    }
    let timeline = try PlaybackTimeline(
      tracks: ordered.map {
        PlaybackTrack(index: $0.fileIndex, startOffset: $0.startOffset, duration: $0.duration)
      })
    guard tracks.count == timeline.tracks.count else { throw WatchLibraryError.libraryUnavailable }
    return WatchAudioPreparation(
      title: ordered.first?.title, timeline: timeline, tracks: tracks,
      chapters: .init(chapters: ordered.flatMap(\.chapters)))
  }

  /// The one admission rule for a track URL: the account server's exact origin, no embedded
  /// userinfo on either URL, no query or fragment, and the ABS file route. The origin comparison
  /// is `FeedCredentialOrigin.sameOrigin`, which is fail-closed when either URL lacks a host, so
  /// two hostless URLs cannot collide into one empty origin.
  static func admitsTrackURL(_ url: URL, serverURL: URL) -> Bool {
    guard url.user == nil, url.password == nil,
      serverURL.user == nil, serverURL.password == nil,
      url.query == nil, url.fragment == nil,
      FeedCredentialOrigin.sameOrigin(url, serverURL),
      url.path.contains("/api/items/"), url.path.contains("/file/")
    else { return false }
    return true
  }
}
