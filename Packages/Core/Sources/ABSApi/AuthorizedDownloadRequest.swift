import Foundation

/// Redirect policy carried with an already-authorized transfer. Tagging the request, rather than
/// selecting policy from the URL or the adapter's global mode, makes ABS and RSS transfers safe to
/// interleave in one background session.
public enum TransferRedirectPolicy: String, Sendable, Equatable, Codable {
  case abs
  case feed
}

/// The common transfer boundary used by the background adapter. Holds a prebuilt URLRequest:
/// credentials are stamped by the owning client before this value crosses into App/SyncEngine.
/// Its textual forms never reflect the URL or headers.
public struct AuthorizedTransferRequest: Sendable, Equatable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  public let request: URLRequest
  public let expectedMIMEType: String
  public let expectedBytes: Int64?
  public let redirectPolicy: TransferRedirectPolicy
  public let itemID: String?
  public let fileID: String?

  public init(
    request: URLRequest,
    expectedMIMEType: String,
    expectedBytes: Int64? = nil,
    redirectPolicy: TransferRedirectPolicy = .abs,
    itemID: String? = nil,
    fileID: String? = nil
  ) {
    self.request = request
    self.expectedMIMEType = expectedMIMEType
    self.expectedBytes = expectedBytes
    self.redirectPolicy = redirectPolicy
    self.itemID = itemID
    self.fileID = fileID
  }

  /// The request as sent. Kept for tests that assert the stamped URL without exposing the token.
  public func makeURLRequest() -> URLRequest { request }

  public var description: String {
    let size = expectedBytes.map(String.init) ?? "nil"
    return
      "AuthorizedTransferRequest(expectedMIMEType: \(expectedMIMEType), expectedBytes: \(size), redirectPolicy: \(redirectPolicy.rawValue))"
  }

  public var debugDescription: String { description }
}

/// A restricted, already-authorized media download request. The App's background-download adapter
/// executes it without seeing the tokens, minting an endpoint, or inspecting headers. No public
/// initializer: obtain one from `ABSClient.makeAuthorizedDownloadRequest`/
/// `renewAuthorizedDownloadRequest` (audio) or `makeAuthorizedEbookRequest`/
/// `renewAuthorizedEbookRequest` (EPUB), which stamp the current access token (renewal forces the
/// single-flight refresh first).
///
/// `description`/`debugDescription` are hand-written: the synthesized default would print the
/// private `HTTPRequest`'s `Authorization` header, which SECURITY.md forbids.
public struct AuthorizedDownloadRequest: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
  public let itemID: String
  public let fileID: String
  public let expectedMIMEType: String
  public let expectedSize: Int
  private let request: HTTPRequest

  fileprivate init(
    itemID: String,
    fileID: String,
    expectedMIMEType: String,
    expectedSize: Int,
    request: HTTPRequest
  ) {
    self.itemID = itemID
    self.fileID = fileID
    self.expectedMIMEType = expectedMIMEType
    self.expectedSize = expectedSize
    self.request = request
  }

  /// The App adapter's only way to obtain a `URLRequest`. The Bearer header is already baked in,
  /// so the caller never handles the token.
  public func makeURLRequest() -> URLRequest {
    var urlRequest = URLRequest(url: request.url)
    urlRequest.httpMethod = request.method.rawValue
    urlRequest.timeoutInterval = request.timeout
    urlRequest.httpShouldHandleCookies = request.httpShouldHandleCookies
    for (field, value) in request.headers {
      urlRequest.setValue(value, forHTTPHeaderField: field)
    }
    return urlRequest
  }

  public var description: String {
    "AuthorizedDownloadRequest(itemID: \(itemID), fileID: \(fileID), "
      + "expectedMIMEType: \(expectedMIMEType), expectedSize: \(expectedSize))"
  }

  public var debugDescription: String { description }
}

/// Construction failures specific to the authorized EPUB path. A missing `ebookFile` or
/// `ebookFile.size` is not recoverable at transfer time: `expectedSize` is part of the adapter's
/// scheduling and completion contract, so this path never substitutes a sentinel.
public enum EbookDownloadRequestError: Error, Sendable, Equatable {
  case missingEbookFile
  case missingExpectedSize
  case invalidFileID
}

extension ABSClient {
  /// Stamps the account's currently cached access token onto `download`. A pure value transform
  /// over the token store, never a network call. Downloads are their own two-transfer pool
  /// (API-CONVENTIONS.md rule 13), so this never touches `ServerRequestGate` or any transport.
  public func makeAuthorizedDownloadRequest(
    _ download: FileDownloadRequest,
    account: TokenAccount
  ) throws -> AuthorizedDownloadRequest {
    let tokens = try loadTokens(for: account)
    return try stampedAuthorizedDownloadRequest(download, accessToken: tokens.accessToken)
  }

  /// The adapter's single renewed retry after a 401 pause. Forces one run of the account's
  /// single-flight refresh (`AuthenticatedHTTPClient.forceRefresh()`), which concurrent renewals
  /// and other authenticated calls for this account share, then stamps a fresh request. A failed
  /// refresh surfaces as `APIError.unauthorized`; there is no retry loop here.
  public func renewAuthorizedDownloadRequest(
    _ download: FileDownloadRequest,
    account: TokenAccount
  ) async throws -> AuthorizedDownloadRequest {
    let initialTokens = try loadTokens(for: account)
    let refreshed = try await authenticatedTransport(for: account, initialTokens: initialTokens).forceRefresh()
    return try stampedAuthorizedDownloadRequest(download, accessToken: refreshed.accessToken)
  }

  /// Stamps the account's current access token onto the item-level EPUB endpoint. The row is keyed
  /// by `ebookFile.ino`, which travels as `AuthorizedDownloadRequest.fileID` but is not part of
  /// the URL, because `GET /api/items/{id}/ebook` is an item-level route. A pure value transform
  /// over the token store that never touches `ServerRequestGate` or any transport
  /// (API-CONVENTIONS.md rules 13 and 24).
  public func makeAuthorizedEbookRequest(
    _ request: EbookRequest,
    ebookFile: EbookFileInfo?,
    account: TokenAccount
  ) throws -> AuthorizedDownloadRequest {
    let metadata = try ebookDownloadMetadata(from: ebookFile)
    let tokens = try loadTokens(for: account)
    return try stampedAuthorizedEbookRequest(
      request, fileID: metadata.fileID, expectedSize: metadata.expectedSize,
      accessToken: tokens.accessToken)
  }

  /// Forces one run of the account's single-flight refresh, then re-stamps the item-level EPUB
  /// route with the fresh access token. The inode stays the request's `fileID` and never becomes
  /// a URL path segment. A failed refresh is terminal, as in the audio renewal path.
  public func renewAuthorizedEbookRequest(
    _ request: EbookRequest,
    ebookFile: EbookFileInfo?,
    account: TokenAccount
  ) async throws -> AuthorizedDownloadRequest {
    let metadata = try ebookDownloadMetadata(from: ebookFile)
    let initialTokens = try loadTokens(for: account)
    let refreshed = try await authenticatedTransport(for: account, initialTokens: initialTokens).forceRefresh()
    return try stampedAuthorizedEbookRequest(
      request, fileID: metadata.fileID, expectedSize: metadata.expectedSize,
      accessToken: refreshed.accessToken)
  }

  private func stampedAuthorizedDownloadRequest(
    _ download: FileDownloadRequest,
    accessToken: String
  ) throws -> AuthorizedDownloadRequest {
    let httpRequest = try download.makeRequest(using: requestBuilder, accessToken: accessToken)
    return AuthorizedDownloadRequest(
      itemID: download.itemID,
      fileID: download.fileID,
      expectedMIMEType: download.expectedMIMEType,
      expectedSize: download.expectedSize,
      request: httpRequest
    )
  }

  private func stampedAuthorizedEbookRequest(
    _ request: EbookRequest,
    fileID: String,
    expectedSize: Int,
    accessToken: String
  ) throws -> AuthorizedDownloadRequest {
    let httpRequest = try request.makeRequest(using: requestBuilder, accessToken: accessToken)
    return AuthorizedDownloadRequest(
      itemID: request.itemID,
      fileID: fileID,
      expectedMIMEType: EbookRequest.acceptedMIMETypes[0],
      expectedSize: expectedSize,
      request: httpRequest
    )
  }

  private func ebookDownloadMetadata(
    from ebookFile: EbookFileInfo?
  ) throws -> (fileID: String, expectedSize: Int) {
    guard let ebookFile else { throw EbookDownloadRequestError.missingEbookFile }
    guard ebookFile.ino.isEmpty == false else { throw EbookDownloadRequestError.invalidFileID }
    guard let expectedSize = ebookFile.size else {
      throw EbookDownloadRequestError.missingExpectedSize
    }
    return (fileID: ebookFile.ino, expectedSize: expectedSize)
  }

}
