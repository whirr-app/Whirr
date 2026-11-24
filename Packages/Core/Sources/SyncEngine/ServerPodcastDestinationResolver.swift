import ABSApi
import Foundation
import Persistence

/// A feed-identity match from the server catalogue. The feed identity is opaque: only its
/// lowercase SHA-256 fingerprint crosses this boundary, never a normalized URL.
public struct ServerPodcastMatch: Sendable, Equatable, Hashable, CustomStringConvertible,
  CustomDebugStringConvertible, CustomReflectable
{
  public let serverItemID: String
  public let libraryID: String
  public let feedFingerprint: String
  public let displayName: String

  public init(
    serverItemID: String,
    libraryID: String,
    feedFingerprint: String,
    displayName: String
  ) {
    self.serverItemID = serverItemID
    self.libraryID = libraryID
    self.feedFingerprint = feedFingerprint
    self.displayName = displayName
  }

  public var description: String {
    "ServerPodcastMatch(serverItemID: <redacted>, libraryID: <redacted>, "
      + "feedURL: <redacted>, displayName: <redacted>)"
  }

  public var debugDescription: String { description }

  public var customMirror: Mirror { Mirror(self, unlabeledChildren: []) }
}

/// The validated destination used by the later coordinator. The server-declared folder path stays
/// internal to SyncEngine so a picker can carry only ids and display names; `childPath` is minted
/// by the pure path generator and is never accepted as free-form input.
public struct ServerPodcastDestination: Sendable, Equatable, CustomStringConvertible,
  CustomDebugStringConvertible, CustomReflectable
{
  public let libraryID: String
  public let folderID: String
  public let childPath: String

  let folderFullPath: String

  public init?(libraryID: String, folder: LibraryFolder, nativeFeedTitle: String) {
    guard libraryID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
      folder.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    else { return nil }
    guard
      case .success(let childPath) = ServerPodcastPathGeneration.generate(
        folderFullPath: folder.fullPath,
        nativeFeedTitle: nativeFeedTitle)
    else { return nil }

    self.libraryID = libraryID
    folderID = folder.id
    folderFullPath = folder.fullPath
    self.childPath = childPath
  }

  public var description: String {
    "ServerPodcastDestination(libraryID: <redacted>, folderID: <redacted>, childPath: <redacted>)"
  }

  public var debugDescription: String { description }

  public var customMirror: Mirror { Mirror(self, unlabeledChildren: []) }
}

/// The bounded folder row a picker may render. It has no server filesystem path.
public struct ServerPodcastFolderChoice: Sendable, Equatable, Hashable, CustomStringConvertible,
  CustomDebugStringConvertible, CustomReflectable
{
  public let folderID: String
  public let displayName: String

  public init(folderID: String, displayName: String) {
    self.folderID = folderID
    self.displayName = displayName
  }

  public var id: String { folderID }
  public var name: String { displayName }

  public var description: String {
    "ServerPodcastFolderChoice(folderID: <redacted>, displayName: <redacted>)"
  }

  public var debugDescription: String { description }

  public var customMirror: Mirror { Mirror(self, unlabeledChildren: []) }
}

/// The bounded library row a picker may render, including only its folder ids/display names.
public struct ServerPodcastLibraryChoice: Sendable, Equatable, Hashable, CustomStringConvertible,
  CustomDebugStringConvertible, CustomReflectable
{
  public let libraryID: String
  public let displayName: String
  public let folders: [ServerPodcastFolderChoice]

  public init(
    libraryID: String,
    displayName: String,
    folders: [ServerPodcastFolderChoice]
  ) {
    self.libraryID = libraryID
    self.displayName = displayName
    self.folders = folders
  }

  public var id: String { libraryID }
  public var name: String { displayName }

  public var description: String {
    "ServerPodcastLibraryChoice(libraryID: <redacted>, displayName: <redacted>, "
      + "folderCount: \(folders.count))"
  }

  public var debugDescription: String { description }

  public var customMirror: Mirror { Mirror(self, unlabeledChildren: []) }
}

/// Explicit product outcomes from destination resolution. Empty catalogue states are represented
/// here rather than converted into force unwraps or programmer errors.
public enum ServerPodcastResolution: Sendable, Equatable, CustomStringConvertible,
  CustomDebugStringConvertible, CustomReflectable
{
  case reuse(ServerPodcastMatch)
  case chooseExisting([ServerPodcastMatch])
  case chooseLibraryAndFolder([ServerPodcastLibraryChoice])
  case noAccessiblePodcastLibraries

  public var description: String {
    switch self {
    case .reuse:
      return "ServerPodcastResolution(reuse)"
    case .chooseExisting(let candidates):
      return "ServerPodcastResolution(chooseExisting, candidateCount: \(candidates.count))"
    case .chooseLibraryAndFolder(let libraries):
      return "ServerPodcastResolution(chooseLibraryAndFolder, libraryCount: \(libraries.count))"
    case .noAccessiblePodcastLibraries:
      return "ServerPodcastResolution(noAccessiblePodcastLibraries)"
    }
  }

  public var debugDescription: String { description }

  public var customMirror: Mirror { Mirror(self, unlabeledChildren: []) }
}

public enum ServerPodcastDestinationResolverError: Error, Sendable, Equatable, CustomStringConvertible {
  case invalidFeedURL
  case invalidPagination
  case pageCeilingReached
  case invalidChoice

  public var description: String {
    switch self {
    case .invalidFeedURL:
      return "The native podcast feed URL is invalid."
    case .invalidPagination:
      return "The Audiobookshelf catalogue returned invalid pagination."
    case .pageCeilingReached:
      return "The Audiobookshelf catalogue exceeded the local page limit."
    case .invalidChoice:
      return "The selected Audiobookshelf podcast destination is no longer available."
    }
  }
}

/// Narrow read-only catalogue seam used by the resolver. ABSClient's endpoint methods remain the
/// only production wire owner; tests can supply deterministic pages without live HTTP.
public protocol ServerPodcastCatalogReading: Sendable {
  func listPodcastCatalogLibraries(account: TokenAccount) async throws -> [Library]
  func listPodcastCatalogItems(
    account: TokenAccount,
    libraryID: String,
    page: Int,
    limit: Int
  ) async throws -> LibraryItemsPage
}

// The requirement names are distinct from `ABSClient`'s own endpoint methods. A
// same-named requirement would add a SyncEngine-declared overload of an ABSApi method, and an
// existing call such as `LibrarySelectionDiscoveryService`'s `listLibraries(account:)` would
// silently rebind to the wrapper wherever SyncEngine is imported.
extension ABSClient: ServerPodcastCatalogReading {
  public func listPodcastCatalogLibraries(account: TokenAccount) async throws -> [Library] {
    try await listLibraries(account: account, diagnostics: nil)
  }

  public func listPodcastCatalogItems(
    account: TokenAccount,
    libraryID: String,
    page: Int,
    limit: Int
  ) async throws -> LibraryItemsPage {
    try await listLibraryItems(
      account: account,
      library: libraryID,
      page: page,
      limit: limit,
      sort: nil,
      filter: nil,
      diagnostics: nil)
  }
}

/// Reads all accessible podcast-library pages up to a finite ceiling, then maps exact feed
/// feed identity to an explicit reuse or picker outcome. A book library is excluded before any
/// item can become a destination: live Audiobookshelf accepts that create but hides the item.
public struct ServerPodcastDestinationResolver: Sendable {
  public static let defaultPageLimit = 100
  public static let defaultPageCeiling = 100
  public static let maximumPageCeiling = 100

  private let catalog: any ServerPodcastCatalogReading
  private let pageLimit: Int
  private let pageCeiling: Int

  public init(
    client: any ServerPodcastCatalogReading,
    pageLimit: Int = Self.defaultPageLimit,
    pageCeiling: Int = Self.defaultPageCeiling
  ) {
    catalog = client
    self.pageLimit = min(max(1, pageLimit), Self.defaultPageLimit)
    self.pageCeiling = min(max(1, pageCeiling), Self.maximumPageCeiling)
  }

  public func resolve(feedURL: URL, account: TokenAccount) async throws -> ServerPodcastResolution {
    try await resolve(feedURL: feedURL.absoluteString, account: account)
  }

  public func resolve(feedURL: String, account: TokenAccount) async throws -> ServerPodcastResolution {
    guard let feedFingerprint = PodcastFeedIdentity.fingerprint(feedURL) else {
      throw ServerPodcastDestinationResolverError.invalidFeedURL
    }
    return try await resolve(feedFingerprint: feedFingerprint, account: account)
  }

  /// Adapts the resolver's catalogue result to the save coordinator's opaque-id boundary. A
  /// folder selection is revalidated against the current catalogue before its server-local path
  /// is used to build a create request.
  public func resolveNativeEpisodeServerSaveDestination(
    feedURL: URL,
    nativeFeedTitle: String,
    account: TokenAccount,
    choice: ServerPodcastSaveChoice?
  ) async throws -> NativeEpisodeServerSaveDestinationResolution {
    let resolution = try await resolve(feedURL: feedURL, account: account)
    switch resolution {
    case .noAccessiblePodcastLibraries:
      guard choice == nil else { throw ServerPodcastDestinationResolverError.invalidChoice }
      return .noAccessiblePodcastLibraries
    case .reuse(let match):
      guard choice == nil else {
        guard case .existing(let selectedID) = choice, selectedID == match.serverItemID else {
          throw ServerPodcastDestinationResolverError.invalidChoice
        }
        return .reuse(serverItemID: match.serverItemID)
      }
      return .reuse(serverItemID: match.serverItemID)
    case .chooseExisting(let matches):
      guard let choice else {
        return .needsChoice(
          .existing(
            candidates: matches.map {
              NativeEpisodeServerSaveExistingChoice(
                serverItemID: $0.serverItemID, displayName: $0.displayName)
            }))
      }
      guard case .existing(let selectedID) = choice,
        let match = matches.first(where: { $0.serverItemID == selectedID })
      else { throw ServerPodcastDestinationResolverError.invalidChoice }
      return .reuse(serverItemID: match.serverItemID)
    case .chooseLibraryAndFolder(let libraries):
      guard let choice else {
        return .needsChoice(
          .libraryAndFolder(
            libraries: libraries.map {
              NativeEpisodeServerSaveLibraryChoice(
                libraryID: $0.libraryID,
                displayName: $0.displayName,
                folders: $0.folders.map {
                  NativeEpisodeServerSaveFolderChoice(
                    folderID: $0.folderID, displayName: $0.displayName)
                })
            }))
      }
      guard case .libraryAndFolder(let libraryID, let folderID) = choice,
        let selectedLibrary = libraries.first(where: { $0.libraryID == libraryID }),
        selectedLibrary.folders.contains(where: { $0.folderID == folderID })
      else { throw ServerPodcastDestinationResolverError.invalidChoice }
      return try await createDestination(
        libraryID: libraryID,
        folderID: folderID,
        nativeFeedTitle: nativeFeedTitle,
        account: account)
    }
  }

  private func createDestination(
    libraryID: String,
    folderID: String,
    nativeFeedTitle: String,
    account: TokenAccount
  ) async throws -> NativeEpisodeServerSaveDestinationResolution {
    let libraries = try await catalog.listPodcastCatalogLibraries(account: account)
    guard
      let library = libraries.first(where: {
        $0.id == libraryID && $0.mediaType == "podcast"
      }), let folder = library.folders.first(where: { $0.id == folderID }),
      let destination = ServerPodcastDestination(
        libraryID: libraryID, folder: folder, nativeFeedTitle: nativeFeedTitle)
    else { throw ServerPodcastDestinationResolverError.invalidChoice }
    return .create(destination)
  }

  private func resolve(
    feedFingerprint: String,
    account: TokenAccount
  ) async throws -> ServerPodcastResolution {
    let libraries = try await catalog.listPodcastCatalogLibraries(account: account)
    let eligibleLibraries = libraries.filter {
      $0.mediaType == "podcast"
        && $0.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }
    guard eligibleLibraries.isEmpty == false else {
      return .noAccessiblePodcastLibraries
    }

    var foundMatches = [ServerPodcastMatch]()
    var seenMatches = Set<ServerPodcastMatch>()
    for library in eligibleLibraries {
      let libraryMatches = try await matches(
        in: library,
        account: account,
        feedFingerprint: feedFingerprint)
      for match in libraryMatches where seenMatches.insert(match).inserted {
        foundMatches.append(match)
      }
    }

    switch foundMatches.count {
    case 0:
      return .chooseLibraryAndFolder(eligibleLibraries.map(Self.libraryChoice))
    case 1:
      return .reuse(foundMatches[0])
    default:
      return .chooseExisting(foundMatches)
    }
  }

  private func matches(
    in library: Library,
    account: TokenAccount,
    feedFingerprint: String
  ) async throws -> [ServerPodcastMatch] {
    var requestedPage = 0
    var fetchedPages = 0
    var seenPages = Set<Int>()
    var matches = [ServerPodcastMatch]()

    while true {
      try Task.checkCancellation()
      guard fetchedPages < pageCeiling else {
        throw ServerPodcastDestinationResolverError.pageCeilingReached
      }

      let response = try await catalog.listPodcastCatalogItems(
        account: account,
        libraryID: library.id,
        page: requestedPage,
        limit: pageLimit)
      try Task.checkCancellation()

      guard response.total >= 0, response.page == requestedPage, response.page >= 0,
        seenPages.insert(response.page).inserted
      else { throw ServerPodcastDestinationResolverError.invalidPagination }

      fetchedPages += 1
      guard response.limit > 0 else {
        guard response.total == 0, response.items.isEmpty else {
          throw ServerPodcastDestinationResolverError.invalidPagination
        }
        return matches
      }

      for item in response.items {
        guard case .value(let feedURL) = item.feedURLState,
          let itemFingerprint = PodcastFeedIdentity.fingerprint(feedURL),
          itemFingerprint == feedFingerprint,
          item.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        else { continue }
        matches.append(
          ServerPodcastMatch(
            serverItemID: item.id,
            libraryID: library.id,
            feedFingerprint: itemFingerprint,
            displayName: Self.boundedDisplayName(item.title ?? "", fallback: "Untitled podcast")))
      }

      // `total`, `limit`, and the server-provided zero-based `page` decide whether another page is
      // needed. A ceiling above this loop handles a server that reports an impossible total.
      let lastRequiredPage = (response.total - 1) / response.limit
      guard response.page < lastRequiredPage else { return matches }
      let (nextPage, overflow) = response.page.addingReportingOverflow(1)
      guard overflow == false else { throw ServerPodcastDestinationResolverError.invalidPagination }
      requestedPage = nextPage
    }
  }

  private static func libraryChoice(_ library: Library) -> ServerPodcastLibraryChoice {
    let folders = library.folders.filter {
      $0.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }
    return ServerPodcastLibraryChoice(
      libraryID: library.id,
      displayName: boundedDisplayName(library.name, fallback: "Podcasts"),
      folders: distinctFolderChoices(folders))
  }

  /// Two configured folders of one library may share a leaf name (`/media/a/Podcasts` and
  /// `/media/b/Podcasts`). A picker showing "Podcasts" twice offers an indistinguishable choice,
  /// so a colliding leaf is widened by one parent component, and a leaf that still collides is
  /// numbered. Only the trailing components ever reach the row; the absolute server directory
  /// stays inside SyncEngine.
  static func distinctFolderChoices(_ folders: [LibraryFolder]) -> [ServerPodcastFolderChoice] {
    let leaves = folders.map { folderDisplayName($0.fullPath, trailingComponents: 1) }
    var counts = [String: Int]()
    for leaf in leaves { counts[leaf, default: 0] += 1 }

    var names = [String]()
    for (index, folder) in folders.enumerated() {
      let leaf = leaves[index]
      names.append(
        counts[leaf, default: 0] > 1
          ? folderDisplayName(folder.fullPath, trailingComponents: 2) : leaf)
    }

    // A numbered label is allocated against every label already handed out, so a folder whose
    // own leaf happens to read "Podcasts (1)" cannot coincide with a number given to another.
    var reserved = Set<String>()
    var choices = [ServerPodcastFolderChoice]()
    for (index, folder) in folders.enumerated() {
      let name = names[index]
      let occurrences = names.filter { $0 == name }.count
      var displayName = name
      var ordinal = 1
      while occurrences > 1 || reserved.contains(displayName) {
        displayName = boundedDisplayName("\(name) (\(ordinal))", fallback: "Folder")
        ordinal += 1
        if reserved.contains(displayName) == false { break }
      }
      reserved.insert(displayName)
      choices.append(ServerPodcastFolderChoice(folderID: folder.id, displayName: displayName))
    }
    return choices
  }

  private static func folderDisplayName(_ fullPath: String, trailingComponents: Int) -> String {
    let components = fullPath.split(separator: "/", omittingEmptySubsequences: true)
      .suffix(max(1, trailingComponents))
      .map { component -> String in
        let raw = String(component)
        return raw.removingPercentEncoding ?? raw
      }
    return boundedDisplayName(components.joined(separator: "/"), fallback: "Folder")
  }

  /// Bidirectional controls and isolates. Server-supplied text carrying these can reorder or
  /// visually overlay the row that follows it, so one picker entry can impersonate another.
  ///
  /// Named explicitly, not the whole Unicode `.format` category, which also holds ZWNJ (needed by
  /// Persian and Indic scripts), ZWJ (emoji sequences, Indic conjuncts) and the emoji variation
  /// selector; dropping those would corrupt ordinary titles.
  private static let bidirectionalControlScalars: Set<Unicode.Scalar> = [
    "\u{200E}", "\u{200F}", "\u{061C}",
    "\u{202A}", "\u{202B}", "\u{202C}", "\u{202D}", "\u{202E}",
    "\u{2066}", "\u{2067}", "\u{2068}", "\u{2069}",
  ]

  /// The one sanitizer for every server- or feed-supplied name a picker or sheet may draw. Public
  /// so AppModel can apply the same rule to the native feed title it shows beside a destination.
  public static func boundedDisplayName(_ value: String, fallback: String) -> String {
    var sanitized = String.UnicodeScalarView()
    for scalar in value.unicodeScalars {
      guard bidirectionalControlScalars.contains(scalar) == false else { continue }
      switch scalar.properties.generalCategory {
      case .control, .lineSeparator, .paragraphSeparator:
        // A separator becomes a space rather than vanishing, so a two-line title reads as
        // "Title Subtitle" instead of fusing into "TitleSubtitle".
        sanitized.append(" ")
      default:
        sanitized.append(scalar)
      }
    }

    let collapsed =
      sanitized
      .split(whereSeparator: { $0.properties.isWhitespace })
      .map(String.init)
      .joined(separator: " ")
    let trimmed = collapsed.trimmingCharacters(in: .whitespacesAndNewlines)
    return String((trimmed.isEmpty ? fallback : trimmed).prefix(256))
  }
}
