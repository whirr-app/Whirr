import ABSApi
import Foundation
import Persistence

/// Transfer start: mint the one authorized request a transfer needs, then hand it to the
/// background adapter with its destination. Scheduling decides when; this decides what.
extension DownloadCoordinator {
  // MARK: - Starting transfers

  @discardableResult
  func startTransfer(
    row: DownloadRecord, downloadId: Int64, account: TokenAccount
  ) async -> Bool {
    guard let itemRecord = try? await itemDAO.fetchOneAsync(id: row.itemId),
      itemRecord.softDeleted == false,
      let authorized = try? await makeAuthorizedTransferRequest(
        for: row, itemID: itemRecord.serverItemId, account: account, renewing: false)
    else { return false }
    authRetriedDownloadIds.remove(downloadId)
    guard (try? await downloadStore.transitionAsync(downloadId: downloadId, to: .downloading)) != nil else {
      return false
    }
    // A fresh attempt restarts from byte zero (no resume data is persisted), so the throttle's
    // high-water decile from a previous attempt must not silence this one.
    progressTraceThrottle.forget(downloadId: downloadId)
    trace(downloadId, .start(expectedBytes: row.expectedBytes))

    await enqueueAuthorizedTransfer(authorized, for: row, downloadId: downloadId)
    return true
  }

  @discardableResult
  func startRSSTransfer(row: RSSDownloadRecord, downloadId: Int64) async -> Bool {
    guard let rssDownloadStore, let details = try? await rssDownloadStore.transferDetailsAsync(downloadId: downloadId),
      let url = URL(string: details.episode.enclosureURL),
      let mimeType = Self.normalizedRSSMIME(details.episode.enclosureType)
    else { return false }
    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    request.httpShouldHandleCookies = false
    // The enclosure URL comes from the feed document, so it is attacker-chosen whenever the feed
    // is. A credential may be stamped only onto the feed's own exact origin, as the artwork client
    // and playback stream authorization do. Cross-origin enclosures (the usual CDN shape) still
    // download, unauthenticated. The redirect policy cannot stand in for this check because it
    // acts only after the first request has been sent.
    if let feedID = details.feed.id, let feedURL = URL(string: details.feed.feedURL),
      FeedCredentialOrigin.carriesCredential(feedURL: feedURL, target: url),
      let credential = try? feedCredentialStore?.load(forFeedID: feedID)
    {
      request.setValue(credential.authorization, forHTTPHeaderField: "Authorization")
    }
    let authorized = AuthorizedTransferRequest(
      request: request, expectedMIMEType: mimeType, expectedBytes: details.download.expectedBytes,
      redirectPolicy: .feed)
    guard let rssFileStore,
      let destination = try? rssFileStore.transferDestinationURL(
        forRelativePath: row.relativePath)
    else { return false }
    guard (try? await rssDownloadStore.transitionAsync(downloadId: downloadId, to: .downloading)) != nil else {
      return false
    }
    rssEventFailedDownloadIds.remove(downloadId)
    // `0` is the progress throttle's unknown-length marker. The feed's declared length is
    // advisory, so this is the starting estimate, not a bound.
    rssTrace(downloadId, .start(expectedBytes: details.download.expectedBytes ?? 0))
    await backgroundTransferring.enqueue(
      authorized,
      destination: DownloadDestinationToken(identity: .rss(rowID: downloadId), destinationURL: destination))
    return true
  }

  private static func normalizedRSSMIME(_ value: String?) -> String? {
    guard let value else { return "audio/mpeg" }
    let mime = value.split(separator: ";", maxSplits: 1).first.map(String.init)!.trimmingCharacters(
      in: .whitespacesAndNewlines
    ).lowercased()
    guard mime.hasPrefix("audio/"), mime.count > 6 else { return nil }
    return mime
  }

  /// Chooses the ABSApi request constructor so the adapter boundary stays uniform. Ebook rows
  /// carry the fixed EPUB MIME and the same inode/expected-byte fields as audio rows; their
  /// item-level route is selected here, never by the adapter. Audio rows use `FileDownloadRequest`.
  func makeAuthorizedTransferRequest(
    for row: DownloadRecord,
    itemID: String,
    account: TokenAccount,
    renewing: Bool
  ) async throws -> AuthorizedTransferRequest {
    let authorized: AuthorizedDownloadRequest
    if row.expectedMimeType == EbookRequest.acceptedMIMETypes[0] {
      let request = try EbookRequest(itemID: itemID)
      let ebookFile = EbookFileInfo(
        ino: row.serverFileIno, ext: "epub", filename: nil, size: Int(row.expectedBytes))
      if renewing {
        authorized = try await client.renewAuthorizedEbookRequest(
          request, ebookFile: ebookFile, account: account)
      } else {
        authorized = try await client.makeAuthorizedEbookRequest(
          request, ebookFile: ebookFile, account: account)
      }
    } else {
      let request = try FileDownloadRequest(
        itemID: itemID, fileID: row.serverFileIno,
        expectedMIMEType: row.expectedMimeType, expectedSize: Int(row.expectedBytes))
      if renewing {
        authorized = try await client.renewAuthorizedDownloadRequest(request, account: account)
      } else {
        authorized = try await client.makeAuthorizedDownloadRequest(request, account: account)
      }
    }
    return AuthorizedTransferRequest(
      request: authorized.makeURLRequest(), expectedMIMEType: authorized.expectedMIMEType,
      expectedBytes: Int64(authorized.expectedSize), redirectPolicy: .abs,
      itemID: authorized.itemID, fileID: authorized.fileID)
  }

  /// The background adapter receives one already-authorized value for every media kind, so
  /// destination construction stays here and the adapter never branches on media kind.
  func enqueueAuthorizedTransfer(
    _ request: AuthorizedTransferRequest, for row: DownloadRecord, downloadId: Int64
  ) async {
    let destinationURL = downloadFileStore.absoluteURL(forRelativePath: row.destinationRelativePath)
    let token = DownloadDestinationToken(identity: .abs(rowID: downloadId), destinationURL: destinationURL)
    await backgroundTransferring.enqueue(request, destination: token)
  }
}
