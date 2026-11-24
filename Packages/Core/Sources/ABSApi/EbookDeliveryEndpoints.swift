import Foundation

/// An e-reader the server may email this user's ebooks to. Only the name crosses this boundary;
/// the email address, availability rule and user list are not Whirr's to hold (SECURITY.md, device
/// addresses). The name is the device's identity on the send route and matched verbatim, so it is
/// carried verbatim, never trimmed or truncated.
public struct EreaderDevice: Sendable, Equatable, Hashable {
  public static let maximumNameBytes = 256

  public let name: String

  public init(name: String) {
    self.name = name
  }
}

/// Why a send did not happen. Every case means the server did not email the file.
public enum EbookDeliveryFailure: Sendable, Equatable {
  /// The server's SMTP settings are missing or its mail server could not be reached.
  case serverEmailUnavailable
  /// The mail server refused the message, typically because the attachment is too large.
  case rejectedByMailServer
  /// This user may not use the device, or may not access the item.
  case notPermitted
  /// No device of that name exists on the server any more.
  case deviceNotFound
  /// The item is gone or has no primary ebook file.
  case noEbookFile
  /// The request never reached the server.
  case unreachable
  /// The account's sign-in was rejected or is missing.
  case signInRequired
  /// The server answered with a status outside the send route's contract.
  case refused
  /// The identifiers were empty or out of bounds; nothing was sent.
  case invalidRequest
}

/// The server sends synchronously and without idempotency, so a request that may have reached it
/// but produced no answer is `uncertain` rather than a failure: retrying it could email the file
/// twice.
public enum EbookDeliveryResult: Sendable, Equatable {
  case sent
  case notSent(EbookDeliveryFailure)
  case uncertain
}

/// The server writes its response only after SMTP accepts the attachment, which can outlast the
/// ordinary 15-second inactivity timeout. This stays inside `ordinaryAPI`'s resource bound, which
/// caps the whole exchange regardless.
public enum EbookDeliveryTimeout {
  public static let request: TimeInterval = 120
}

extension ABSClient {
  /// `POST /api/authorize`: the login payload for the current token, whose `ereaderDevices` the
  /// server has already filtered to the devices this user may target. `GET /api/me` does not carry
  /// the list, and the `/login` copy is captured only at sign-in.
  public func fetchEreaderDevices(
    account: TokenAccount,
    diagnostics: DecodeDiagnostics? = nil
  ) async throws -> [EreaderDevice] {
    let tokens = try loadTokens(for: account)
    let request = try requestBuilder.makeRequest(
      method: .post,
      path: "/api/authorize",
      routeTemplate: "/api/authorize"
    )
    let response = try await authenticatedSend(request, account: account, initialTokens: tokens)
    try validateSuccess(response)

    let wire = try decoder.decode(
      AuthorizeDevicesDTO.self,
      from: response.body,
      endpoint: "/api/authorize",
      diagnostics: diagnostics
    )
    var seen = Set<String>()
    return wire.names.compactMap { name in
      guard seen.insert(name).inserted else { return nil }
      return EreaderDevice(name: name)
    }
  }

  /// `POST /api/emails/send-ebook-to-device`: asks the server to email the item's primary ebook
  /// file to the named device. Never throws and never retries beyond the transport's single
  /// post-401 resend; see `EbookDeliveryResult` for why a lost answer is not a failure.
  public func sendEbookToDevice(
    account: TokenAccount,
    libraryItemID: String,
    deviceName: String
  ) async -> EbookDeliveryResult {
    guard Self.isDeliverable(libraryItemID: libraryItemID, deviceName: deviceName) else {
      return .notSent(.invalidRequest)
    }

    let tokens: TokenPair
    let request: HTTPRequest
    do {
      tokens = try loadTokens(for: account)
      request = try requestBuilder.makeJSONRequest(
        method: .post,
        path: "/api/emails/send-ebook-to-device",
        body: SendEbookBody(libraryItemId: libraryItemID, deviceName: deviceName),
        acceptedMIMETypes: [],
        routeTemplate: "/api/emails/send-ebook-to-device",
        timeout: EbookDeliveryTimeout.request
      )
    } catch APIError.unauthorized {
      return .notSent(.signInRequired)
    } catch {
      return .notSent(.invalidRequest)
    }

    let response: HTTPResponse
    do {
      response = try await authenticatedSend(request, account: account, initialTokens: tokens)
    } catch {
      return Self.deliveryResult(forThrown: error)
    }
    return Self.deliveryResult(for: response)
  }

  private static func isDeliverable(libraryItemID: String, deviceName: String) -> Bool {
    libraryItemID.isEmpty == false
      && libraryItemID.utf8.count <= PodcastWriteBounds.maximumStringBytes
      && deviceName.isEmpty == false
      && deviceName.utf8.count <= EreaderDevice.maximumNameBytes
  }

  /// Bodies are matched against the server's fixed strings only to choose a case; the text itself
  /// can name SMTP hosts and is never carried upward.
  static func deliveryResult(for response: HTTPResponse) -> EbookDeliveryResult {
    let body = String(decoding: response.body.prefix(512), as: UTF8.self)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    switch response.statusCode {
    case 200..<300:
      return .sent
    case 400:
      return body == "Failed to verify SMTP connection configuration"
        ? .notSent(.serverEmailUnavailable) : .notSent(.rejectedByMailServer)
    case 401:
      return .notSent(.signInRequired)
    case 403:
      return .notSent(.notPermitted)
    case 404:
      return body == "Ereader device not found" ? .notSent(.deviceNotFound) : .notSent(.noEbookFile)
    case 500...599:
      // A reverse proxy answers 502/504 when its read timeout expires, while the server behind it
      // is still uploading the attachment.
      return .uncertain
    default:
      return .notSent(.refused)
    }
  }

  static func deliveryResult(forThrown error: any Error) -> EbookDeliveryResult {
    if let urlError = error as? URLError {
      return Self.requestNeverLeft.contains(urlError.code) ? .notSent(.unreachable) : .uncertain
    }
    switch error as? APIError {
    case .unauthorized:
      return .notSent(.signInRequired)
    case .cancelled, .payloadTooLarge, nil:
      // Cancellation can land mid-upload, and an oversized answer means the server did answer.
      return .uncertain
    case .some:
      // Every other `APIError` here comes from the proactive refresh, which runs before the send.
      return .notSent(.unreachable)
    }
  }

  /// Failures that occur before any request bytes can reach the server: no route, no name, no
  /// connection, or a TLS handshake that did not complete. Everything else is treated as possibly
  /// delivered.
  private static let requestNeverLeft: Set<URLError.Code> = [
    .notConnectedToInternet, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed,
    .dataNotAllowed, .internationalRoamingOff, .callIsActive, .secureConnectionFailed,
    .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateNotYetValid,
    .serverCertificateHasUnknownRoot, .clientCertificateRejected, .clientCertificateRequired,
    .appTransportSecurityRequiresSecureConnection, .badURL, .unsupportedURL,
  ]
}

private struct SendEbookBody: Encodable, Sendable {
  let libraryItemId: String
  let deviceName: String
}

/// Decodes `ereaderDevices[].name` and nothing else from the login payload; the user object,
/// tokens and settings beside it are skipped without being materialized.
private struct AuthorizeDevicesDTO: Decodable {
  let names: [String]

  private enum CodingKeys: String, CodingKey { case ereaderDevices }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    guard (try? container.decodeNil(forKey: .ereaderDevices)) == false else {
      names = []
      return
    }
    let devices =
      (try? container.decodeLossyArray(forKey: .ereaderDevices) as [DeviceDTO]) ?? []
    names = devices.compactMap(\.name)
  }
}

private struct DeviceDTO: Decodable {
  let name: String?

  private enum CodingKeys: String, CodingKey { case name }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let raw = try container.decode(LossyOptional<String>.self, forKey: .name).wrappedValue
    guard let raw,
      raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
      raw.utf8.count <= EreaderDevice.maximumNameBytes
    else {
      name = nil
      return
    }
    name = raw
  }
}
