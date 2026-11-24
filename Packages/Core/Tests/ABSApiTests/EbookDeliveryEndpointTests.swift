import Foundation
import TestSupport
import Testing

@testable import ABSApi

/// Wire contract for the server's send-ebook-to-device feature. The shapes mirror
/// `Auth.getUserLoginResponsePayload` and `EmailController.sendEBookToDevice` in the server source.
@Suite("Ebook delivery endpoints")
struct EbookDeliveryEndpointTests {

  // MARK: - Device list

  @Test("reads device names from POST /api/authorize and nothing else")
  func readsDeviceNamesOnly() async throws {
    let payload: [String: Any] = [
      "user": ["id": "user_fixture", "username": "reader", "token": "canary-legacy-token"],
      "userDefaultLibraryId": "library_book_fixture",
      "serverSettings": ["version": "2.36.0"],
      "ereaderDevices": [
        [
          "name": "Rhys's Kindle", "email": "canary-address@kindle.example",
          "availabilityOption": "userOrUp", "users": [],
        ],
        [
          "name": "PocketBook", "email": "canary-second@pbsync.example",
          "availabilityOption": "specificUsers", "users": ["user_fixture"],
        ],
      ],
      "Source": "server",
    ]
    let (client, http, account) = try makeClient(responses: [jsonResponse(object: payload)])

    let devices = try await client.fetchEreaderDevices(account: account)

    #expect(devices == [EreaderDevice(name: "Rhys's Kindle"), EreaderDevice(name: "PocketBook")])
    let request = try #require(http.requests.first)
    #expect(request.method == .post)
    #expect(request.url.path == "/api/authorize")
    #expect(request.routeTemplate == "/api/authorize")
    #expect(request.body == nil)
    #expect(String(describing: devices).contains("canary") == false)
  }

  @Test("an absent, null, or malformed device list is empty rather than an error")
  func absentListIsEmpty() async throws {
    for devices in [nil, NSNull(), "not-an-array", 42] as [Any?] {
      var payload: [String: Any] = ["user": ["id": "user_fixture"]]
      if let devices { payload["ereaderDevices"] = devices }
      let (client, _, account) = try makeClient(responses: [jsonResponse(object: payload)])

      #expect(try await client.fetchEreaderDevices(account: account).isEmpty)
    }
  }

  @Test("unnamed, blank, oversized, non-object, and duplicate devices are dropped")
  func dropsUnusableDevices() async throws {
    let payload: [String: Any] = [
      "ereaderDevices": [
        ["name": "Kept"],
        ["email": "canary@kindle.example"],
        ["name": NSNull()],
        ["name": 42],
        ["name": ""],
        ["name": "   "],
        ["name": String(repeating: "x", count: EreaderDevice.maximumNameBytes + 1)],
        "not-an-object",
        ["name": "Kept"],
        ["name": String(repeating: "y", count: EreaderDevice.maximumNameBytes)],
      ]
    ]
    let (client, _, account) = try makeClient(responses: [jsonResponse(object: payload)])

    let names = try await client.fetchEreaderDevices(account: account).map(\.name)

    #expect(names == ["Kept", String(repeating: "y", count: EreaderDevice.maximumNameBytes)])
  }

  @Test("a device name is carried verbatim, because the server matches it exactly")
  func namesAreNotNormalized() async throws {
    let payload: [String: Any] = ["ereaderDevices": [["name": " Kindle Oasis "]]]
    let (client, _, account) = try makeClient(responses: [jsonResponse(object: payload)])

    #expect(try await client.fetchEreaderDevices(account: account).map(\.name) == [" Kindle Oasis "])
  }

  @Test("a failed device read surfaces the status as an APIError")
  func deviceReadFailureThrows() async throws {
    let (client, _, account) = try makeClient(responses: [status(500)])

    await #expect(throws: APIError.serverFailure(statusCode: 500)) {
      try await client.fetchEreaderDevices(account: account)
    }
  }

  // MARK: - Send request

  @Test("sends exactly libraryItemId and deviceName, with the long delivery timeout")
  func sendRequestShape() async throws {
    let (client, http, account) = try makeClient(responses: [status(200)])

    let result = await client.sendEbookToDevice(
      account: account, libraryItemID: "li_fixture", deviceName: "Rhys's Kindle")

    #expect(result == .sent)
    let request = try #require(http.requests.first)
    #expect(request.method == .post)
    #expect(request.url.path == "/api/emails/send-ebook-to-device")
    #expect(request.routeTemplate == "/api/emails/send-ebook-to-device")
    #expect(request.timeout == EbookDeliveryTimeout.request)
    #expect(request.timeout > HTTPTransportClass.ordinaryAPI.requestTimeout)
    #expect(request.timeout <= HTTPTransportClass.ordinaryAPI.resourceTimeout)
    let body = try #require(request.body)
    let object = try #require(try JSONSerialization.jsonObject(with: body) as? [String: String])
    #expect(object == ["libraryItemId": "li_fixture", "deviceName": "Rhys's Kindle"])
  }

  @Test("the device-list read keeps the ordinary timeout")
  func deviceReadKeepsOrdinaryTimeout() async throws {
    let (client, http, account) = try makeClient(responses: [jsonResponse(object: [:])])

    _ = try await client.fetchEreaderDevices(account: account)

    #expect(http.requests.first?.timeout == HTTPTransportClass.ordinaryAPI.requestTimeout)
  }

  @Test("an empty or oversized identifier is refused locally without a request")
  func invalidInputIsRefusedLocally() async throws {
    let cases: [(String, String)] = [
      ("", "Kindle"),
      ("li_fixture", ""),
      ("li_fixture", String(repeating: "x", count: EreaderDevice.maximumNameBytes + 1)),
      (String(repeating: "i", count: PodcastWriteBounds.maximumStringBytes + 1), "Kindle"),
    ]
    for (itemID, deviceName) in cases {
      let (client, http, account) = try makeClient(responses: [status(200)])

      let result = await client.sendEbookToDevice(
        account: account, libraryItemID: itemID, deviceName: deviceName)

      #expect(result == .notSent(.invalidRequest))
      #expect(http.requests.isEmpty)
    }
  }

  // MARK: - Status mapping

  @Test(
    "maps each documented server response",
    arguments: [
      (200, "", EbookDeliveryResult.sent),
      (
        400, "Failed to verify SMTP connection configuration",
        EbookDeliveryResult.notSent(.serverEmailUnavailable)
      ),
      (400, "Message size exceeds fixed maximum message size", .notSent(.rejectedByMailServer)),
      (400, "", .notSent(.rejectedByMailServer)),
      (403, "", .notSent(.notPermitted)),
      (404, "Ereader device not found", .notSent(.deviceNotFound)),
      (404, "Library item not found", .notSent(.noEbookFile)),
      (404, "Ebook file not found", .notSent(.noEbookFile)),
    ] as [(Int, String, EbookDeliveryResult)])
  func mapsDocumentedStatuses(statusCode: Int, body: String, expected: EbookDeliveryResult)
    async throws
  {
    let (client, _, account) = try makeClient(responses: [status(statusCode, body: body)])

    let result = await client.sendEbookToDevice(
      account: account, libraryItemID: "li_fixture", deviceName: "Kindle")

    #expect(result == expected)
  }

  @Test(
    "a 5xx may come from a proxy that gave up while the server was still sending",
    arguments: [500, 502, 503, 504])
  func serverErrorsAreUncertain(statusCode: Int) async throws {
    let (client, _, account) = try makeClient(responses: [status(statusCode)])

    let result = await client.sendEbookToDevice(
      account: account, libraryItemID: "li_fixture", deviceName: "Kindle")

    #expect(result == .uncertain)
  }

  @Test("other statuses are refusals: the server answered without sending")
  func otherStatusesAreRefusals() async throws {
    for statusCode in [405, 413, 429, 302] {
      let (client, _, account) = try makeClient(responses: [status(statusCode)])

      let result = await client.sendEbookToDevice(
        account: account, libraryItemID: "li_fixture", deviceName: "Kindle")

      #expect(result == .notSent(.refused))
    }
  }

  @Test("server error text never reaches the result")
  func serverTextIsNotCarried() async throws {
    let (client, _, account) = try makeClient(
      responses: [status(400, body: "connect ECONNREFUSED smtp.canary.internal:587")])

    let result = await client.sendEbookToDevice(
      account: account, libraryItemID: "li_fixture", deviceName: "Kindle")

    #expect(String(describing: result).contains("canary") == false)
  }

  @Test("a rejected sign-in is reported as such after the transport's single refresh")
  func unauthorizedAfterRefresh() async throws {
    let refreshed: [String: Any] = [
      "user": ["accessToken": "canary-access-2", "refreshToken": "canary-refresh-2"]
    ]
    let (client, http, account) = try makeClient(
      responses: [status(401), jsonResponse(object: refreshed), status(401)])

    let result = await client.sendEbookToDevice(
      account: account, libraryItemID: "li_fixture", deviceName: "Kindle")

    #expect(result == .notSent(.signInRequired))
    let sends = http.requests.filter { $0.routeTemplate == "/api/emails/send-ebook-to-device" }
    #expect(sends.count == 2)
  }

  // MARK: - Transport failures

  @Test(
    "a failure before the request could reach the server is definitely not sent",
    arguments: [
      URLError.Code.notConnectedToInternet, .cannotFindHost, .cannotConnectToHost,
      .dnsLookupFailed, .dataNotAllowed, .internationalRoamingOff, .secureConnectionFailed,
      .serverCertificateUntrusted, .appTransportSecurityRequiresSecureConnection,
    ])
  func preSendFailuresAreNotSent(code: URLError.Code) async throws {
    let (client, _, account) = try makeClient(responses: [], transportFailure: URLError(code))

    let result = await client.sendEbookToDevice(
      account: account, libraryItemID: "li_fixture", deviceName: "Kindle")

    #expect(result == .notSent(.unreachable))
  }

  @Test(
    "a failure after the request may have reached the server is uncertain",
    arguments: [
      URLError.Code.timedOut, .networkConnectionLost, .cancelled, .badServerResponse,
      .cannotParseResponse, .unknown,
    ])
  func inFlightFailuresAreUncertain(code: URLError.Code) async throws {
    let (client, _, account) = try makeClient(responses: [], transportFailure: URLError(code))

    let result = await client.sendEbookToDevice(
      account: account, libraryItemID: "li_fixture", deviceName: "Kindle")

    #expect(result == .uncertain)
  }

  @Test("an unclassified transport error is uncertain rather than a false failure")
  func unknownErrorsAreUncertain() async throws {
    struct Opaque: Error {}
    let (client, _, account) = try makeClient(responses: [], transportFailure: Opaque())

    let result = await client.sendEbookToDevice(
      account: account, libraryItemID: "li_fixture", deviceName: "Kindle")

    #expect(result == .uncertain)
  }

  @Test("missing credentials are not sent")
  func missingTokensAreNotSent() async throws {
    let server = try ABSServerConfig(url: #require(URL(string: "https://books.example.test")))
    let account = try TokenAccount(server: server, userID: "user_fixture")
    let http = FakeHTTPClient(responses: [status(200)])
    let client = ABSClient(server: server, httpClient: http, tokenStore: InMemoryTokenStore())

    let result = await client.sendEbookToDevice(
      account: account, libraryItemID: "li_fixture", deviceName: "Kindle")

    #expect(result == .notSent(.signInRequired))
    #expect(http.requests.isEmpty)
  }
}

private func makeClient(
  responses: [HTTPResponse],
  transportFailure: (any Error)? = nil
) throws -> (client: ABSClient, http: FakeHTTPClient, account: TokenAccount) {
  let serverURL = try #require(ABSClientFixture.serverURL as URL?)
  return try ABSClientFixture.make(
    responses: responses, transportFailure: transportFailure, serverURL: serverURL)
}

private func jsonResponse(object: Any) throws -> HTTPResponse {
  HTTPResponse(
    statusCode: 200,
    headers: ["Content-Type": "application/json"],
    body: try JSONSerialization.data(withJSONObject: object))
}

private func status(_ code: Int, body: String = "") -> HTTPResponse {
  HTTPResponse(
    statusCode: code, headers: ["Content-Type": "text/html; charset=utf-8"],
    body: Data(body.utf8))
}
