import ABSApi
import Foundation
import WatchProtocol

public enum WatchLibraryError: Error, Sendable, Equatable {
  case notAuthenticated
  case invalidServer
  case invalidPage
  case accountMismatch
  case nativeSelectionUnavailable
  case libraryUnavailable
  case storageFailure
  case staleRequest
  case catalogueIncomplete
  /// The complete catalogue would exceed the bounded Watch browse budget. Callers should show
  /// the retryable/secondary-library affordance rather than presenting a first-page illusion.
  case catalogueTooLarge
}

public enum WatchMediaKind: String, Sendable, Equatable {
  case audiobook
  case podcast
}

public struct WatchLibrary: Sendable, Equatable, Identifiable {
  public let id: String
  public let name: String
  public let mediaType: String?

  public init(id: String, name: String, mediaType: String?) {
    self.id = id
    self.name = name
    self.mediaType = mediaType
  }
}

public struct WatchLibraryPage: Sendable, Equatable {
  public let items: [WatchLibraryItem]
  public let total: Int
  public let limit: Int
  public let page: Int

  public init(items: [WatchLibraryItem], total: Int, limit: Int, page: Int) {
    self.items = items
    self.total = total
    self.limit = limit
    self.page = page
  }
}

public struct WatchLibraryItem: Sendable, Equatable, Identifiable {
  public let id: String
  public let libraryID: String
  public let kind: WatchMediaKind
  public let title: String?
  public let author: String?
  public let selection: WatchSelection
  public let durationSeconds: Double?
  public let episodeCount: Int?
  public let series: String?
  public let addedAt: Date?
  /// The server's sequence order is retained when a future wire projection supplies it. A nil
  /// value never invents a sequence number; series browsing falls back to the server's sequence
  /// sort and stable title/id ties.
  public let seriesSequence: Double?

  public init(
    id: String,
    libraryID: String,
    kind: WatchMediaKind,
    title: String?,
    author: String?,
    selection: WatchSelection,
    durationSeconds: Double?,
    episodeCount: Int?,
    series: String? = nil,
    addedAt: Date? = nil,
    seriesSequence: Double? = nil
  ) {
    self.id = id
    self.libraryID = libraryID
    self.kind = kind
    self.title = title
    self.author = author
    self.selection = selection
    self.durationSeconds = durationSeconds
    self.episodeCount = episodeCount
    self.series = series
    self.addedAt = addedAt
    self.seriesSequence = seriesSequence
  }
}

public struct WatchBrowseAuthor: Sendable, Equatable, Identifiable {
  public let id: String
  public let name: String
  /// Count of visible audio books, rather than the server's raw all-format count.
  public let bookCount: Int

  public init(id: String, name: String, bookCount: Int) {
    self.id = id
    self.name = name
    self.bookCount = bookCount
  }
}

public struct WatchBrowseSeries: Sendable, Equatable, Identifiable {
  public let id: String
  public let name: String
  /// Count of visible audio books, rather than the server's raw all-format count.
  public let bookCount: Int

  public init(id: String, name: String, bookCount: Int) {
    self.id = id
    self.name = name
    self.bookCount = bookCount
  }
}

public enum WatchAudiobookSort: String, Sendable, Equatable, CaseIterable {
  case title
  case author
  case recentlyAdded
}

public enum WatchPodcastEpisodeSort: String, Sendable, Equatable, CaseIterable {
  case newest
  case oldest
}

public enum WatchPodcastEpisodeFilter: String, Sendable, Equatable, CaseIterable {
  case inProgress
  case unplayed
  case all
}

public struct WatchPodcastShow: Sendable, Equatable, Identifiable {
  public let id: String
  public let title: String
  public let author: String?
  public let episodeCount: Int
  public let selection: WatchSelection

  public init(
    id: String, title: String, author: String?, episodeCount: Int, selection: WatchSelection
  ) {
    self.id = id
    self.title = title
    self.author = author
    self.episodeCount = episodeCount
    self.selection = selection
  }
}

public struct WatchPodcastBrowseEpisode: Sendable, Equatable, Identifiable {
  public let id: String
  public let showID: String
  public let showTitle: String
  public let title: String
  public let selection: WatchSelection
  public let durationSeconds: Double?
  public let publishedAt: Date?
  public let isFinished: Bool
  public let audio: WatchAudioDescription?

  public init(
    id: String,
    showID: String,
    showTitle: String,
    title: String,
    selection: WatchSelection,
    durationSeconds: Double?,
    publishedAt: Date?,
    isFinished: Bool,
    audio: WatchAudioDescription?
  ) {
    self.id = id
    self.showID = showID
    self.showTitle = showTitle
    self.title = title
    self.selection = selection
    self.durationSeconds = durationSeconds
    self.publishedAt = publishedAt
    self.isFinished = isFinished
    self.audio = audio
  }
}

public struct WatchLibraryBrowsePage<T: Sendable & Equatable>: Sendable, Equatable {
  public let items: [T]
  public let total: Int
  public let limit: Int
  public let page: Int
  public let hasMore: Bool

  public init(items: [T], total: Int, limit: Int, page: Int, hasMore: Bool) {
    self.items = items
    self.total = total
    self.limit = limit
    self.page = page
    self.hasMore = hasMore
  }
}

public struct WatchEpisode: Sendable, Equatable, Identifiable {
  public let id: String
  public let parentItemID: String
  public let title: String?
  public let selection: WatchSelection
  public let durationSeconds: Double?
  public let publishedAt: Date?
  public let audio: WatchAudioDescription?

  public init(
    id: String,
    parentItemID: String,
    title: String?,
    selection: WatchSelection,
    durationSeconds: Double?,
    publishedAt: Date?,
    audio: WatchAudioDescription?
  ) {
    self.id = id
    self.parentItemID = parentItemID
    self.title = title
    self.selection = selection
    self.durationSeconds = durationSeconds
    self.publishedAt = publishedAt
    self.audio = audio
  }
}

public struct WatchAudioDescription: Sendable, Equatable {
  public let fileIdentity: String?
  public let expectedSize: Int?
  public let mimeType: String?
  public let durationSeconds: Double?

  public init(
    fileIdentity: String?, expectedSize: Int?, mimeType: String?, durationSeconds: Double?
  ) {
    self.fileIdentity = fileIdentity
    self.expectedSize = expectedSize
    self.mimeType = mimeType
    self.durationSeconds = durationSeconds
  }
}

/// One read of the server's progress: every row, and the Continue list derived from them.
public struct WatchServerProgress: Sendable, Equatable {
  public let rows: [MediaProgress]
  public let continued: [WatchContinueItem]

  public init(rows: [MediaProgress], continued: [WatchContinueItem]) {
    self.rows = rows
    self.continued = continued
  }
}

public struct WatchContinueItem: Sendable, Equatable, Identifiable {
  public let id: String
  public let selection: WatchSelection
  public let progressSeconds: Double?
  public let durationSeconds: Double?
  public let isFinished: Bool
  public let lastUpdate: Date?

  /// Ebook reading progress and reset records do not establish an audio resume point.
  public var isResumableAudio: Bool {
    guard !isFinished, let progressSeconds, let durationSeconds,
      progressSeconds.isFinite, durationSeconds.isFinite, durationSeconds > 0
    else { return false }
    return progressSeconds > 0 && progressSeconds < durationSeconds
  }

  public init(
    id: String,
    selection: WatchSelection,
    progressSeconds: Double?,
    durationSeconds: Double?,
    isFinished: Bool,
    lastUpdate: Date?
  ) {
    self.id = id
    self.selection = selection
    self.progressSeconds = progressSeconds
    self.durationSeconds = durationSeconds
    self.isFinished = isFinished
    self.lastUpdate = lastUpdate
  }
}

public struct WatchLoginResult: Sendable, Equatable {
  public let serverURL: URL
  public let account: TokenAccount
  public let userID: String
  public let defaultLibraryID: String?
  public let accessExpiry: Date?

  public init(
    serverURL: URL, account: TokenAccount, userID: String, defaultLibraryID: String?, accessExpiry: Date?
  ) {
    self.serverURL = serverURL
    self.account = account
    self.userID = userID
    self.defaultLibraryID = defaultLibraryID
    self.accessExpiry = accessExpiry
  }
}

public struct WatchAccountRecord: Codable, Sendable, Equatable {
  public let serverURL: URL
  public let userID: String
  public let username: String?
  public let defaultLibraryID: String?

  public init(
    serverURL: URL, userID: String, username: String? = nil, defaultLibraryID: String? = nil
  ) throws {
    guard !userID.isEmpty, userID.utf8.count <= 512,
      userID.unicodeScalars.allSatisfy({ scalar in
        scalar.value >= 0x20 && !(0x7F...0x9F).contains(scalar.value)
      })
    else { throw WatchLibraryError.invalidServer }
    _ = try ABSServerConfig(url: serverURL)
    self.serverURL = serverURL
    self.userID = userID
    self.username = username
    self.defaultLibraryID = defaultLibraryID
  }

  public var server: ABSServerConfig? { try? ABSServerConfig(url: serverURL) }

  public func tokenAccount() throws -> TokenAccount {
    guard let server else { throw WatchLibraryError.invalidServer }
    return try TokenAccount(server: server, userID: userID)
  }

  /// Stable, credential-free identity used to fence Watch catalogue/session state. The hashes
  /// include no token, password, or user-facing URL beyond its normalized server
  /// identity.
  public func authenticatedStamp() throws -> WatchAccountStamp {
    let serverIdentity = try TokenAccount.normalizedServerIdentity(from: serverURL)
    return try WatchAccountStamp.authenticated(serverIdentity: serverIdentity, userID: userID)
  }
}
