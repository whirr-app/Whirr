// Opt-in live smoke harness: exercises the real, composed `ABSClient` against an actual
// Audiobookshelf server. This is not a deterministic unit test. It is the documented
// live-verification exception (ARCHITECTURE.md). Every other test in this package
// stays offline, and this file is inert unless explicitly enabled.
//
// HOW TO RUN
// ==========
// From `Packages/Core/`:
//
//   ABS_LIVE_SMOKE=1 \
//   ABS_LIVE_SERVER_URL="https://your-server.example" \
//   ABS_LIVE_USERNAME="your-username" \
//   ABS_LIVE_PASSWORD="your-password" \
//   swift test --filter LiveSmoke
//
// PODCAST MODE
// ============
// Add ABS_LIVE_SMOKE_PODCASTS=1 alongside the variables above to also exercise podcast
// decoding. It does not log in a second time (API-CONVENTIONS.md rule 5a): it runs as extra
// steps inside the one `liveSmoke()` test, after the existing login. If no podcast library is
// visible to the account, or it has no items, this mode records a SKIP line and the run still
// passes. Podcast mode only ever issues `GET` requests; see SAFETY for the routes it avoids.
//
// Add ABS_LIVE_SMOKE_PODCAST_CAPTURE_PATH=/absolute/path.json to also write the raw expanded
// podcast response to disk. That file is unsanitised (real titles, ids, paths and feed URLs), so
// point it outside the repository and delete it once the sanitised fixture is committed.
// Without the variable, nothing is written.
//
// EBOOK MODE
// ==========
// Add ABS_LIVE_SMOKE_EBOOKS=1 alongside the variables above to locate one EPUB-bearing item
// through the paginated library-list route, inspect its expanded ebookFile shape, and issue one
// ranged plus one unranged ebook GET. It reuses the base run's single login and only adds GET
// requests; no ebook request is made unless both ABS_LIVE_SMOKE=1 and this switch are set.
// Ebook-file values are never printed, only field presence/type, status, safe response
// headers, and byte counts.
//
// SHELL HISTORY GUIDANCE
// =======================
// Do not type the password directly on a command line that lands in your shell history. Either:
//   - prefix the whole command with a leading space (many shells honor HISTCONTROL=ignorespace /
//     HIST_IGNORE_SPACE and will not record a line that starts with whitespace), or
//   - read the password interactively instead of embedding it literally. In zsh (the repo's
//     shell) the prompt goes inside the variable spec, as `-p` there means coprocess:
//       read -rs "ABS_LIVE_PASSWORD?ABS password: " && export ABS_LIVE_PASSWORD && echo
//     (bash equivalent: `read -rs -p "ABS password: " ABS_LIVE_PASSWORD`)
//     then export ABS_LIVE_SMOKE/ABS_LIVE_SERVER_URL/ABS_LIVE_USERNAME and run
//     `swift test --filter LiveSmoke`.
//
// GATING
// ======
// Normal `swift test` with no environment configured skips this entirely: the single `@Test`
// below is gated on `ABS_LIVE_SMOKE=1`. If that master switch is on but any other required
// variable is missing, the test still runs (so the omission is visible) and fails immediately,
// naming only the missing variable name, never a value.
//
// SAFETY
// ======
// - Login happens exactly once per run (API-CONVENTIONS.md rule 5a: the login route is rate
//   limited). `/auth/refresh` is a different, non-rate-limited route and is exercised twice
//   (proactive + reactive).
// - Read-only plus login/logout/refresh only. Never play/progress/session endpoints.
// - Podcast mode is `GET` (and `OPTIONS`) only. It never calls
//   `GET /api/podcasts/{id}/checknew` or `GET /api/podcasts/{id}/clear-queue`, which are `GET`
//   routes on the real server but have side effects (checknew triggers episode downloads;
//   clear-queue mutates the download queue), and never calls
//   `POST /api/podcasts/{id}/download-episodes`. It only reads via
//   `GET /api/libraries`, `GET /api/libraries/{id}/items`, and `GET /api/items/{id}`.
// - Tokens/passwords are never printed. Only status codes, counts, versions, non-sensitive header
//   names/values, and item/library ids reach stdout (SECURITY.md). Podcast mode also never
//   prints episode titles/ids/values, only presence (missing/null/present) and JSON type
//   (string/number/bool/array/object) of the fields it inspects.

import Foundation
import Testing

@testable import ABSApi

#if canImport(Security)

  private enum LiveSmokeConfigurationError: Error, CustomStringConvertible {
    case missingEnvironmentVariable(String)

    var description: String {
      switch self {
      case .missingEnvironmentVariable(let name):
        return "ABS live smoke harness requires the \(name) environment variable to be set."
      }
    }
  }

  /// Raised when a live server response structurally disagrees with what the production decoder
  /// infers. A live mismatch should become a sanitised fixture plus a failing deterministic test.
  /// Only counts/booleans are carried, never field values.
  private enum LiveMismatchError: Error, CustomStringConvertible {
    case tracksCountMismatch(decoded: Int, raw: Int)
    case chaptersCountMismatch(decoded: Int, raw: Int)
    case episodesCountMismatch(decoded: Int, raw: Int)
    case ebookFilePresenceMismatch(decodedPresent: Bool, rawPresent: Bool)

    var description: String {
      switch self {
      case .tracksCountMismatch(let decoded, let raw):
        return "Decoded \(decoded) audio tracks but the raw response has \(raw); rows were lossy-dropped."
      case .chaptersCountMismatch(let decoded, let raw):
        return "Decoded \(decoded) chapters but the raw response has \(raw); rows were lossy-dropped."
      case .episodesCountMismatch(let decoded, let raw):
        return "Decoded \(decoded) episodes but the raw response has \(raw); rows were lossy-dropped."
      case .ebookFilePresenceMismatch(let decodedPresent, let rawPresent):
        return
          "ebookFile decode presence (\(decodedPresent)) disagrees with the raw response "
          + "(\(rawPresent)); the inferred EbookFileDTO shape does not match real data."
      }
    }
  }

  /// Returns the wire-shape type of a raw decoded-JSON value, never the value itself. Backs
  /// podcast mode's "presence and type only" rule (SECURITY.md): a caller can log
  /// `presenceType(dict["title"])` safely, but never `dict["title"]` itself.
  private func presenceType(_ value: Any?) -> String {
    guard let value else { return "missing" }
    if value is NSNull { return "null" }
    if let number = value as? NSNumber {
      return CFGetTypeID(number) == CFBooleanGetTypeID() ? "bool" : "number"
    }
    if value is String { return "string" }
    if value is [Any] { return "array" }
    if value is [String: Any] { return "object" }
    return "other"
  }

  private func isEpubFormat(_ value: String?) -> Bool {
    guard let value else { return false }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.drop(while: { $0 == "." }).lowercased() == "epub"
  }

  /// Logs response header values only for an allowlist of names. Ebook smoke output is a live
  /// note, so a new server header must not become an accidental secret sink.
  private func safeResponseHeaderSummary(_ headers: [String: String]) -> String {
    let allowedHeaderNames = Set([
      "accept-ranges", "cache-control", "content-length", "content-range", "content-type", "etag",
      "last-modified",
    ])
    return
      headers
      .filter { allowedHeaderNames.contains($0.key.lowercased()) }
      .sorted { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }
      .map { "\($0.key)=\($0.value)" }
      .joined(separator: ", ")
  }

  /// Reports the captured and currently known ebookFile keys, including absent keys, as
  /// presence/type only. Also sees fields that `EbookFileInfo` does not model.
  private func ebookFileFieldPresenceSummary(rawMedia: [String: Any]?) -> String {
    guard let rawEbookFileValue = rawMedia?["ebookFile"] else {
      return "ebookFile=missing"
    }
    guard let rawEbookFile = rawEbookFileValue as? [String: Any] else {
      return "ebookFile=\(presenceType(rawEbookFileValue))"
    }

    var topLevelKeys = Set([
      "ino", "metadata", "isSupplementary", "addedAt", "updatedAt", "fileType", "ebookFormat",
    ])
    topLevelKeys.formUnion(rawEbookFile.keys)
    var fields = topLevelKeys.sorted().map { key in
      "ebookFile.\(key)=\(presenceType(rawEbookFile[key]))"
    }

    var metadataKeys = Set([
      "filename", "ext", "path", "relPath", "size", "mtimeMs", "ctimeMs", "birthtimeMs",
    ])
    let rawMetadata = rawEbookFile["metadata"] as? [String: Any]
    if let rawMetadata {
      metadataKeys.formUnion(rawMetadata.keys)
    }
    fields.append(
      contentsOf: metadataKeys.sorted().map { key in
        "ebookFile.metadata.\(key)=\(presenceType(rawMetadata?[key]))"
      }
    )
    return fields.joined(separator: ", ")
  }

  private func requiredEnvironmentVariable(_ name: String) throws -> String {
    guard let value = ProcessInfo.processInfo.environment[name], value.isEmpty == false else {
      throw LiveSmokeConfigurationError.missingEnvironmentVariable(name)
    }
    return value
  }

  /// One checklist line per step: an ISO8601 timestamp, the step name, and a PASS/detail summary.
  /// A human copies these printed lines into the private live-server notes.
  private final class LiveSmokeChecklist: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    private let timestampFormatter = ISO8601DateFormatter()

    func record(_ step: String, _ detail: String) {
      let line = "[\(timestampFormatter.string(from: Date()))] \(step): \(detail)"
      lock.lock()
      lines.append(line)
      lock.unlock()
      print(line)
    }

    func printSummary() {
      lock.lock()
      let summary = lines
      lock.unlock()
      print("\n===== LIVE SMOKE SUMMARY =====")
      for line in summary {
        print(line)
      }
      print("===== END SUMMARY =====\n")
    }
  }

  @Suite("Live smoke (opt-in)")
  struct LiveSmokeTests {
    // `/status` version comes from the JSON body, not a response header. `Content-Type` is the
    // only useful value-bearing header here; other names are presence-only so a proxy or
    // framework cannot turn CI output into a secret sink.
    private static let statusHeaderValueAllowlist: Set<String> = ["content-type"]

    static func statusHeaderLogEntries(_ headers: [String: String]) -> [String] {
      headers
        .sorted { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }
        .map { header in
          Self.statusHeaderValueAllowlist.contains(header.key.lowercased())
            ? header.key + "=" + header.value
            : header.key
        }
    }

    @Test func unusualStatusHeadersNeverLeakUnknownValues() {
      let marker = "status-header-secret-canary"
      let entries = Self.statusHeaderLogEntries([
        "Content-Type": "application/json",
        "X-Proxy-Secret": marker,
        "Authorization": "Bearer " + marker,
      ])
      let summary = entries.joined(separator: ", ")

      #expect(summary.contains("Content-Type=application/json"))
      #expect(summary.contains("X-Proxy-Secret"))
      #expect(summary.contains("Authorization"))
      #expect(summary.contains(marker) == false)
    }

    @Test(
      "exercises login, refresh, reads, and logout against a real ABS server",
      .enabled(if: ProcessInfo.processInfo.environment["ABS_LIVE_SMOKE"] == "1")
    )
    func liveSmoke() async throws {
      // Checked up front (not lazily) so a misconfigured run fails immediately, naming one
      // missing variable, before any network activity happens.
      let serverURLString = try requiredEnvironmentVariable("ABS_LIVE_SERVER_URL")
      let username = try requiredEnvironmentVariable("ABS_LIVE_USERNAME")
      let password = try requiredEnvironmentVariable("ABS_LIVE_PASSWORD")

      let checklist = LiveSmokeChecklist()
      let rawTransport = URLSessionHTTPClient()

      // Step 1: server config. This validates the scheme (http is allowed for private servers,
      // per SECURITY.md Transport).
      let serverURL = try #require(URL(string: serverURLString))
      let serverConfig = try ABSServerConfig(url: serverURL)
      let requestBuilder = RequestBuilder(server: serverConfig)
      checklist.record("1. Server config", "PASS (scheme accepted)")

      // Step 2: pre-login version + capability headers from the unauthenticated /status route.
      let statusRequest = try requestBuilder.makeRequest(
        method: .get,
        path: "/status",
        routeTemplate: "/status"
      )
      let statusResponse = try await rawTransport.send(statusRequest)
      try #require(statusResponse.statusCode == 200)

      struct StatusResponseDTO: Decodable { let serverVersion: String }
      let statusDTO = try JSONDecoder().decode(StatusResponseDTO.self, from: statusResponse.body)
      let detectedVersion = try ABSServerCompatibilityGate.validate(serverVersion: statusDTO.serverVersion)

      let capabilityHeaders = Self.statusHeaderLogEntries(statusResponse.headers)
        .joined(separator: ", ")
      checklist.record("2. Pre-login version", "PASS version=\(detectedVersion) headers=[\(capabilityHeaders)]")

      // Step 3: a dedicated Keychain namespace, never the production one, always cleaned up
      // wherever the test fails or succeeds.
      let serviceNamespace = "com.abs.livesmoke.\(UUID().uuidString)"
      let keychainStore = try KeychainTokenStore(serviceNamespace: serviceNamespace)
      var loggedInAccount: TokenAccount?
      defer {
        if let loggedInAccount {
          try? keychainStore.clear(for: loggedInAccount)
        }
      }
      checklist.record("3. Keychain store", "PASS dedicated namespace created")

      // Step 4: login exactly once (API-CONVENTIONS.md rule 5a).
      let client = ABSClient.production(server: serverConfig, tokenStore: keychainStore)
      let credentials = LoginCredentials(username: username, password: password)
      let loginSession = try await client.login(credentials: credentials)
      loggedInAccount = loginSession.account

      let accessExpiryDetail: String
      if let accessExpiry = loginSession.accessExpiry {
        let minutesOut = Int((accessExpiry.timeIntervalSinceNow / 60).rounded())
        accessExpiryDetail = "true (~\(minutesOut) min)"
      } else {
        accessExpiryDetail = "false"
      }
      checklist.record(
        "4. Login",
        "PASS userID=\(loginSession.userID) defaultLibraryIDPresent=\(loginSession.defaultLibraryID != nil) "
          + "accessExpiryParsed=\(accessExpiryDetail)"
      )

      // Step 5: Keychain persistence across a harness reconstruction.
      let reconstructedStore = try KeychainTokenStore(serviceNamespace: serviceNamespace)
      let reconstructedClient = ABSClient.production(server: serverConfig, tokenStore: reconstructedStore)
      _ = reconstructedClient
      let firstStoreTokens = try keychainStore.load(for: loginSession.account)
      let reconstructedTokens = try reconstructedStore.load(for: loginSession.account)
      #expect(firstStoreTokens != nil)
      #expect(reconstructedTokens == firstStoreTokens)
      checklist.record("5. Keychain persistence", "PASS reconstructed store matches original")

      // Step 6: reads through the composed client.
      let libraries = try await client.listLibraries(account: loginSession.account)
      #expect(libraries.isEmpty == false)
      let mediaTypesSummary = libraries.map { $0.mediaType ?? "unknown" }.joined(separator: ", ")
      checklist.record("6a. listLibraries", "PASS count=\(libraries.count) mediaTypes=[\(mediaTypesSummary)]")

      let firstLibrary = try #require(libraries.first)
      let itemsPage = try await client.listLibraryItems(
        account: loginSession.account,
        library: firstLibrary.id,
        limit: 10
      )
      checklist.record("6b. listLibraryItems", "PASS total=\(itemsPage.total) returned=\(itemsPage.items.count)")

      let firstItemSummary = try #require(itemsPage.items.first)
      let itemDetail = try await client.fetchItemDetail(account: loginSession.account, itemID: firstItemSummary.id)

      var itemDetailSummary = "mediaType=\(itemDetail.mediaType ?? "unknown")"
      switch itemDetail.media {
      case .book(let book):
        itemDetailSummary +=
          " tracks=\(book.tracks.count) chapters=\(book.chapters.count) ebookFilePresent=\(book.ebookFile != nil)"
      case .podcast(let podcast):
        itemDetailSummary += " episodes=\(podcast.episodes.count)"
      case nil:
        itemDetailSummary += " media=nil"
      }

      // Cross-check the decoded shape against the raw wire body. A disagreement means the
      // inferred DTO shape lossy-dropped or misread real data, so this throws rather than
      // silently reporting a clean-looking but wrong count.
      let preCrossCheckTokens = try keychainStore.load(for: loginSession.account)
      let tokensForCrossCheck = try #require(preCrossCheckTokens)
      let rawItemRequest = try requestBuilder.makeRequest(
        method: .get,
        path: "/api/items/\(firstItemSummary.id)",
        queryItems: [URLQueryItem(name: "expanded", value: "1")],
        bearerToken: tokensForCrossCheck.accessToken,
        routeTemplate: "/api/items/:id"
      )
      let rawItemResponse = try await rawTransport.send(rawItemRequest)
      try #require(rawItemResponse.statusCode == 200)
      let rawItemJSON = try JSONSerialization.jsonObject(with: rawItemResponse.body) as? [String: Any] ?? [:]
      let rawMedia = rawItemJSON["media"] as? [String: Any]

      switch itemDetail.media {
      case .book(let book):
        if let rawTracks = rawMedia?["tracks"] as? [Any], rawTracks.count != book.tracks.count {
          throw LiveMismatchError.tracksCountMismatch(decoded: book.tracks.count, raw: rawTracks.count)
        }
        if let rawChapters = rawMedia?["chapters"] as? [Any], rawChapters.count != book.chapters.count {
          throw LiveMismatchError.chaptersCountMismatch(decoded: book.chapters.count, raw: rawChapters.count)
        }
        if let rawMedia {
          let rawEbookPresent = rawMedia.keys.contains("ebookFile") && (rawMedia["ebookFile"] is NSNull) == false
          if rawEbookPresent != (book.ebookFile != nil) {
            throw LiveMismatchError.ebookFilePresenceMismatch(
              decodedPresent: book.ebookFile != nil,
              rawPresent: rawEbookPresent
            )
          }
        }
      case .podcast(let podcast):
        if let rawEpisodes = rawMedia?["episodes"] as? [Any], rawEpisodes.count != podcast.episodes.count {
          throw LiveMismatchError.episodesCountMismatch(decoded: podcast.episodes.count, raw: rawEpisodes.count)
        }
      case nil:
        break
      }
      checklist.record("6c. fetchItemDetail", "PASS \(itemDetailSummary) (raw cross-check agrees)")

      // Step 6d: podcast mode, opt-in via ABS_LIVE_SMOKE_PODCASTS. Inert unless that env var is
      // set, and never runs a second login (rule 5a). See `runPodcastMode` for what it touches.
      try await runPodcastMode(
        client: client,
        libraries: libraries,
        account: loginSession.account,
        requestBuilder: requestBuilder,
        rawTransport: rawTransport,
        keychainStore: keychainStore,
        checklist: checklist
      )

      // Step 6e: ebook mode, opt-in via ABS_LIVE_SMOKE_EBOOKS. It runs after the one login above,
      // so it adds no second login or separate credential path (API-CONVENTIONS.md rule 5a).
      try await runEbookMode(
        client: client,
        libraries: libraries,
        account: loginSession.account,
        requestBuilder: requestBuilder,
        rawTransport: rawTransport,
        keychainStore: keychainStore,
        checklist: checklist
      )

      // Step 7: cover GET, unauthenticated by design (ARCHITECTURE.md).
      let coverRequestSpec = try CoverRequest(itemID: firstItemSummary.id)
      let coverHTTPRequest = try coverRequestSpec.makeRequest(using: requestBuilder)
      #expect(coverHTTPRequest.url.absoluteString.lowercased().contains("token") == false)
      let coverResponse = try await rawTransport.send(coverHTTPRequest)
      #expect(coverResponse.statusCode == 200)
      let coverContentType =
        coverResponse.headers.first { $0.key.caseInsensitiveCompare("Content-Type") == .orderedSame }?.value
        ?? "unknown"
      checklist.record("7. Cover GET", "PASS status=\(coverResponse.statusCode) contentType=\(coverContentType)")

      // Step 8: a small Range GET, using an audio file identity taken from the expanded item
      // detail's contentUrl (`/api/items/{id}/file/{ino}`).
      let audioDescriptor: (contentUrl: String, mimeType: String?)? =
        switch itemDetail.media {
        case .book(let book):
          book.tracks.first.flatMap { track in track.contentUrl.map { (contentUrl: $0, mimeType: track.mimeType) } }
        case .podcast(let podcast):
          podcast.episodes.first.flatMap { episode in
            episode.contentUrl.map { (contentUrl: $0, mimeType: episode.mimeType) }
          }
        case nil:
          nil
        }
      let descriptor = try #require(audioDescriptor)
      let contentUrlPathOnly = descriptor.contentUrl.split(separator: "?", maxSplits: 1).first.map(String.init)
      let fileIDComponent = try #require((contentUrlPathOnly ?? descriptor.contentUrl).split(separator: "/").last)
      let fileID = String(fileIDComponent)
      // The audio file's expected size, when the item detail's AudioFileCatalog (book media only)
      // has an entry matching this inode. A podcast episode or unmatched inode has no source of
      // truth here, so falls back to 0.
      let expectedFileSize: Int = {
        guard case .book(let book) = itemDetail.media else { return 0 }
        return book.audioFiles.files.first(where: { $0.ino == fileID })?.expectedSize ?? 0
      }()

      let fileDownloadRequestSpec = try FileDownloadRequest(
        itemID: firstItemSummary.id,
        fileID: fileID,
        expectedMIMEType: descriptor.mimeType ?? "application/octet-stream",
        expectedSize: expectedFileSize,
        range: "bytes=0-1023"
      )
      let tokensForRange = try #require(try keychainStore.load(for: loginSession.account))
      let rangeHTTPRequest = try fileDownloadRequestSpec.makeRequest(
        using: requestBuilder,
        accessToken: tokensForRange.accessToken
      )
      #expect(rangeHTTPRequest.url.absoluteString.lowercased().contains("token") == false)
      let rangeResponse = try await rawTransport.send(rangeHTTPRequest)
      #expect(rangeResponse.statusCode == 206)
      let contentRange =
        rangeResponse.headers.first { $0.key.caseInsensitiveCompare("Content-Range") == .orderedSame }?.value
        ?? "none"
      checklist.record(
        "8. Range GET",
        "status=\(rangeResponse.statusCode) contentRange=\(contentRange) bytes=\(rangeResponse.body.count)"
      )

      // Step 9: proactive refresh, live. `AuthenticatedHTTPClient` is constructed directly via
      // @testable (the live-smoke transport exception, ARCHITECTURE.md) with a very
      // long lead time so the next send() takes the proactive-refresh path against the live
      // /auth/refresh route.
      let tokensBeforeProactiveRefresh = try #require(try keychainStore.load(for: loginSession.account))
      let proactiveClient = AuthenticatedHTTPClient(
        transport: URLSessionHTTPClient(),
        requestBuilder: requestBuilder,
        tokenStore: keychainStore,
        account: loginSession.account,
        initialTokens: tokensBeforeProactiveRefresh,
        proactiveRefreshLeadTime: 100 * 365 * 24 * 60 * 60
      )
      let librariesRequest = try requestBuilder.makeRequest(
        method: .get,
        path: "/api/libraries",
        routeTemplate: "/api/libraries"
      )
      let proactiveResponse = try await proactiveClient.send(librariesRequest)
      #expect(proactiveResponse.statusCode == 200)
      let tokensAfterProactiveRefresh = try keychainStore.load(for: loginSession.account)
      let proactiveRotated = tokensAfterProactiveRefresh != tokensBeforeProactiveRefresh
      #expect(proactiveRotated)
      checklist.record("9. Proactive refresh", "PASS rotationPersisted=\(proactiveRotated)")

      // Step 10: reactive refresh, live. A corrupted access token (real value, last 6 characters
      // replaced) paired with the current valid refresh token should 401, triggering reactive
      // refresh and one retry.
      let tokensBeforeReactiveRefresh = try #require(try keychainStore.load(for: loginSession.account))
      let refreshToken = try #require(tokensBeforeReactiveRefresh.refreshToken)
      let corruptedAccessToken = String(tokensBeforeReactiveRefresh.accessToken.dropLast(6)) + "aaaaaa"
      let corruptedTokens = TokenPair(
        accessToken: corruptedAccessToken,
        refreshToken: refreshToken
      )
      let reactiveClient = AuthenticatedHTTPClient(
        transport: URLSessionHTTPClient(),
        requestBuilder: requestBuilder,
        tokenStore: keychainStore,
        account: loginSession.account,
        initialTokens: corruptedTokens
      )
      let reactiveResponse = try await reactiveClient.send(librariesRequest)
      let tokensAfterReactiveRefresh = try keychainStore.load(for: loginSession.account)
      let reactiveRotated = tokensAfterReactiveRefresh != tokensBeforeReactiveRefresh

      if reactiveRotated {
        #expect(reactiveResponse.statusCode == 200)
        checklist.record(
          "10. Reactive refresh",
          "PASS rotationPersisted=true finalStatus=\(reactiveResponse.statusCode)"
        )
      } else {
        checklist.record(
          "10. Reactive refresh",
          "FINDING: corrupted access token did not trigger a refresh; server responded "
            + "\(reactiveResponse.statusCode) to a bad signature instead of 401"
        )
      }

      // Step 11: logout using the current (post-rotation) tokens, then confirm the Keychain
      // namespace is empty.
      try await client.logout(for: loginSession.account)
      let tokensAfterLogout = try keychainStore.load(for: loginSession.account)
      #expect(tokensAfterLogout == nil)
      checklist.record("11. Logout", "PASS keychainNamespaceEmpty=\(tokensAfterLogout == nil)")

      // Step 12: final summary for a human to paste into the private live-server notes.
      checklist.printSummary()
    }

    /// Ebook mode, opt-in via `ABS_LIVE_SMOKE_EBOOKS=1`. Reuses the caller's single login (rule 5a)
    /// and issues only `GET`s, with no preflight on the two ebook byte reads. Walks the fetched
    /// libraries with the paginated `minified=1` item endpoint until an item advertises
    /// `ebookFormat=epub`, then records its expanded ebookFile fields (nested metadata included) as
    /// presence/type only, never an inode, path, filename or other value. Ends with one ranged and
    /// one unranged `GET /api/items/{id}/ebook`, recording status, sanitised headers and byte
    /// counts.
    private func runEbookMode(
      client: ABSClient,
      libraries: [Library],
      account: TokenAccount,
      requestBuilder: RequestBuilder,
      rawTransport: URLSessionHTTPClient,
      keychainStore: KeychainTokenStore,
      checklist: LiveSmokeChecklist
    ) async throws {
      guard ProcessInfo.processInfo.environment["ABS_LIVE_SMOKE_EBOOKS"] == "1" else {
        checklist.record("6e. Ebook mode", "SKIP ABS_LIVE_SMOKE_EBOOKS not set")
        return
      }

      var scannedPages = 0
      var ebookCandidate: LibraryItemSummary?

      findCandidate: for library in libraries {
        var page = 0
        while true {
          let itemsPage = try await client.listLibraryItems(
            account: account,
            library: library.id,
            page: page,
            limit: 100
          )
          scannedPages += 1
          if let candidate = itemsPage.items.first(where: { isEpubFormat($0.ebookFormat) }) {
            ebookCandidate = candidate
            break findCandidate
          }

          let nextPage = itemsPage.page + 1
          guard itemsPage.items.isEmpty == false,
            itemsPage.limit > 0,
            nextPage * itemsPage.limit < itemsPage.total
          else {
            break
          }
          page = nextPage
        }
      }

      guard let ebookCandidate else {
        checklist.record("6e. Ebook candidate", "SKIP pagesScanned=\(scannedPages) candidate=missing")
        return
      }
      checklist.record("6e. Ebook candidate", "PASS pagesScanned=\(scannedPages) candidate=present")

      let itemDetail = try await client.fetchItemDetail(account: account, itemID: ebookCandidate.id)
      let decodedEbookFilePresent: Bool = {
        guard case .book(let book) = itemDetail.media else { return false }
        return book.ebookFile != nil
      }()

      let tokensForDetail = try #require(try keychainStore.load(for: account))
      let rawDetailRequest = try requestBuilder.makeRequest(
        method: .get,
        path: "/api/items/\(ebookCandidate.id)",
        queryItems: [URLQueryItem(name: "expanded", value: "1")],
        bearerToken: tokensForDetail.accessToken,
        routeTemplate: "/api/items/:id"
      )
      let rawDetailResponse = try await rawTransport.send(rawDetailRequest)
      try #require(rawDetailResponse.statusCode == 200)
      let rawDetailJSON =
        try JSONSerialization.jsonObject(with: rawDetailResponse.body) as? [String: Any] ?? [:]
      let rawMedia = rawDetailJSON["media"] as? [String: Any]
      let rawEbookFileSummary = ebookFileFieldPresenceSummary(rawMedia: rawMedia)
      checklist.record(
        "6e. Expanded ebook detail",
        "PASS decodedEbookFilePresent=\(decodedEbookFilePresent) fields=[\(rawEbookFileSummary)]"
      )

      let tokensForEbook = try #require(try keychainStore.load(for: account))
      let ebookRequest = try EbookRequest(itemID: ebookCandidate.id)
      let unrangedRequest = try ebookRequest.makeRequest(
        using: requestBuilder,
        accessToken: tokensForEbook.accessToken
      )
      let rangedRequest = try requestBuilder.makeRequest(
        method: .get,
        path: "/api/items/\(ebookCandidate.id)/ebook",
        headers: ["Range": "bytes=0-1023"],
        acceptedMIMETypes: EbookRequest.acceptedMIMETypes,
        bearerToken: tokensForEbook.accessToken,
        routeTemplate: "/api/items/:id/ebook"
      )

      let rangedResponse = try await rawTransport.send(rangedRequest)
      checklist.record(
        "6e. Ranged ebook GET",
        "status=\(rangedResponse.statusCode) headers=[\(safeResponseHeaderSummary(rangedResponse.headers))] "
          + "bytes=\(rangedResponse.body.count)"
      )

      let unrangedResponse = try await rawTransport.send(unrangedRequest)
      checklist.record(
        "6e. Unranged ebook GET",
        "status=\(unrangedResponse.statusCode) headers=[\(safeResponseHeaderSummary(unrangedResponse.headers))] "
          + "bytes=\(unrangedResponse.body.count)"
      )
    }

    /// Podcast mode, opt-in via `ABS_LIVE_SMOKE_PODCASTS=1`. Reuses the caller's single login (rule
    /// 5a).
    ///
    /// - `GET` only: `/api/libraries/{id}/items` and `/api/items/{id}` (with `?include=downloads`,
    ///   then `?include=progress&episode=`). Never `checknew` or `clear-queue` (`GET` routes with
    ///   side effects on the real server) or `POST .../download-episodes`.
    /// - Compares raw and decoded episode counts (as base step 6c does), throwing
    ///   `LiveMismatchError.episodesCountMismatch` on disagreement.
    /// - Records presence/type only, never values, for episode metadata, dates, duration,
    ///   track/file identity, per-episode progress and queued-download fields
    ///   (`episodeDownloadsQueued`/`episodesDownloading`).
    /// - A missing or empty podcast library, or an item that doesn't decode as podcast media,
    ///   records a SKIP/FINDING line and returns, so it never fails the base run.
    private func runPodcastMode(
      client: ABSClient,
      libraries: [Library],
      account: TokenAccount,
      requestBuilder: RequestBuilder,
      rawTransport: URLSessionHTTPClient,
      keychainStore: KeychainTokenStore,
      checklist: LiveSmokeChecklist
    ) async throws {
      guard ProcessInfo.processInfo.environment["ABS_LIVE_SMOKE_PODCASTS"] == "1" else {
        checklist.record("6d. Podcast mode", "SKIP ABS_LIVE_SMOKE_PODCASTS not set")
        return
      }
      guard let podcastLibrary = libraries.first(where: { $0.mediaType == "podcast" }) else {
        checklist.record("6d. Podcast mode", "SKIP no podcast library visible to this account")
        return
      }
      let podcastItemsPage = try await client.listLibraryItems(
        account: account,
        library: podcastLibrary.id,
        limit: 10
      )
      guard let podcastItemSummary = podcastItemsPage.items.first else {
        checklist.record("6d. Podcast mode", "SKIP podcast library has no items")
        return
      }

      let podcastItemDetail = try await client.fetchItemDetail(
        account: account,
        itemID: podcastItemSummary.id
      )
      guard case .podcast(let podcastMedia) = podcastItemDetail.media else {
        checklist.record(
          "6d. Podcast mode",
          "FINDING: podcast-library item decoded as non-podcast media"
        )
        return
      }

      let tokensForPodcastCheck = try #require(try keychainStore.load(for: account))
      let rawPodcastItemRequest = try requestBuilder.makeRequest(
        method: .get,
        path: "/api/items/\(podcastItemSummary.id)",
        queryItems: [
          URLQueryItem(name: "expanded", value: "1"),
          URLQueryItem(name: "include", value: "downloads"),
        ],
        bearerToken: tokensForPodcastCheck.accessToken,
        routeTemplate: "/api/items/:id"
      )
      let rawPodcastItemResponse = try await rawTransport.send(rawPodcastItemRequest)
      try #require(rawPodcastItemResponse.statusCode == 200)
      let rawPodcastItemJSON =
        try JSONSerialization.jsonObject(with: rawPodcastItemResponse.body) as? [String: Any] ?? [:]
      let rawPodcastMedia = rawPodcastItemJSON["media"] as? [String: Any]
      let rawEpisodes = rawPodcastMedia?["episodes"] as? [[String: Any]] ?? []

      if rawEpisodes.count != podcastMedia.episodes.count {
        throw LiveMismatchError.episodesCountMismatch(
          decoded: podcastMedia.episodes.count,
          raw: rawEpisodes.count
        )
      }

      // The stored-audio identity every offerable download depends on (API-CONVENTIONS rule 24).
      // Counted across every episode, not just the first, because episodes lacking it are
      // non-offerable.
      var episodesWithUsableIno = 0
      for rawEpisode in rawEpisodes {
        let audioFile = rawEpisode["audioFile"] as? [String: Any]
        switch audioFile?["ino"] {
        case let ino as String where ino.isEmpty == false: episodesWithUsableIno += 1
        case let ino as NSNumber where CFGetTypeID(ino) != CFBooleanGetTypeID():
          _ = ino
          episodesWithUsableIno += 1
        default: break
        }
      }

      var fieldPresenceSummary: [String] = []
      if let firstRawEpisode = rawEpisodes.first {
        let episodeFieldGroups: [(String, [String])] = [
          ("title", ["title"]),
          ("descriptionOrSubtitle", ["description", "subtitle"]),
          ("episodeNumberOrType", ["episode", "episodeType", "season"]),
          ("publicationOrUpdateDates", ["pubDate", "publishedAt", "addedAt", "updatedAt"]),
          ("duration", ["duration"]),
          ("audioTrackOrFileIdentity", ["audioFile", "audioTrack"]),
        ]
        for (concept, keys) in episodeFieldGroups {
          let types = keys.map { "\($0)=\(presenceType(firstRawEpisode[$0]))" }
          fieldPresenceSummary.append("\(concept)[\(types.joined(separator: ","))]")
        }
        let firstAudioFile = firstRawEpisode["audioFile"] as? [String: Any]
        let audioFileKeys = ["ino", "metadata", "mimeType", "duration", "index"]
        let audioFileTypes = audioFileKeys.map { "\($0)=\(presenceType(firstAudioFile?[$0]))" }
        fieldPresenceSummary.append("audioFile[\(audioFileTypes.joined(separator: ","))]")
        fieldPresenceSummary.append(
          "audioFileInoUsable=\(episodesWithUsableIno)/\(rawEpisodes.count)"
        )

        // A dedicated GET for episode-scoped progress (`?episode=`). Presence/type only; the
        // episode id used to build the request URL is never printed.
        if let episodeID = firstRawEpisode["id"] as? String {
          let rawProgressRequest = try requestBuilder.makeRequest(
            method: .get,
            path: "/api/items/\(podcastItemSummary.id)",
            queryItems: [
              URLQueryItem(name: "expanded", value: "1"),
              URLQueryItem(name: "include", value: "progress"),
              URLQueryItem(name: "episode", value: episodeID),
            ],
            bearerToken: tokensForPodcastCheck.accessToken,
            routeTemplate: "/api/items/:id"
          )
          let rawProgressResponse = try await rawTransport.send(rawProgressRequest)
          try #require(rawProgressResponse.statusCode == 200)
          let rawProgressJSON =
            try JSONSerialization.jsonObject(with: rawProgressResponse.body) as? [String: Any] ?? [:]
          fieldPresenceSummary.append(
            "progress=\(presenceType(rawProgressJSON["userMediaProgress"]))"
          )
        } else {
          fieldPresenceSummary.append("progress=skipped(noEpisodeId)")
        }
      } else {
        fieldPresenceSummary.append("noEpisodesToInspect")
      }
      fieldPresenceSummary.append(
        "episodeDownloadsQueued=\(presenceType(rawPodcastItemJSON["episodeDownloadsQueued"]))"
      )
      fieldPresenceSummary.append(
        "episodesDownloading=\(presenceType(rawPodcastItemJSON["episodesDownloading"]))"
      )

      // Diagnostic fields shown on the show screen in place of a feed-check control. If absent
      // here, there is nothing honest to display.
      let diagnosticKeys = ["autoDownloadEpisodes", "lastEpisodeCheck", "autoDownloadSchedule"]
      let diagnosticTypes = diagnosticKeys.map { "\($0)=\(presenceType(rawPodcastMedia?[$0]))" }
      fieldPresenceSummary.append("mediaDiagnostics[\(diagnosticTypes.joined(separator: ","))]")

      try captureRawPodcastItemIfRequested(
        rawItemBody: rawPodcastItemResponse.body,
        checklist: checklist
      )

      checklist.record(
        "6d. Podcast mode",
        "PASS episodes=\(podcastMedia.episodes.count) (raw cross-check agrees) "
          + "fields=[\(fieldPresenceSummary.joined(separator: ", "))]"
      )
    }

    /// Optional raw capture of the expanded-podcast body to `ABS_LIVE_SMOKE_PODCAST_CAPTURE_PATH`,
    /// for sanitising into a fixture. The file is unsanitised (real titles, ids, paths, feed URLs),
    /// so it must land outside the repository and be deleted once the sanitised fixture is
    /// committed (SECURITY.md). Prints only the byte count and destination.
    private func captureRawPodcastItemIfRequested(
      rawItemBody: Data,
      checklist: LiveSmokeChecklist
    ) throws {
      guard let path = ProcessInfo.processInfo.environment["ABS_LIVE_SMOKE_PODCAST_CAPTURE_PATH"],
        path.isEmpty == false
      else { return }
      guard path.hasPrefix("/") else {
        checklist.record(
          "6d. Podcast capture",
          "SKIP ABS_LIVE_SMOKE_PODCAST_CAPTURE_PATH must be an absolute path"
        )
        return
      }
      try rawItemBody.write(to: URL(fileURLWithPath: path), options: .atomic)
      checklist.record(
        "6d. Podcast capture",
        "WROTE \(rawItemBody.count) unsanitized bytes to \(path) - sanitize, then delete"
      )
    }
  }

#endif
