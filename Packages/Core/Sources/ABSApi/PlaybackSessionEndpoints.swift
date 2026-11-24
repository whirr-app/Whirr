import Foundation

/// Options accepted by `POST /api/items/{id}/play[/{episodeId}]`: the `deviceInfo` fields
/// (`deviceId`, `clientVersion`, `manufacturer`, `model`, `sdkVersion`, `clientName`,
/// `deviceName`) plus the top-level `forceDirectPlay`, `forceTranscode`, `supportedMimeTypes` and
/// `mediaPlayer`. `ipAddress`, browser, OS and device type are derived by the server from the
/// User-Agent and IP, so they are not modelled. This type only shapes the request.
public struct StartPlaybackSessionOptions: Sendable, Equatable {
  public var deviceID: String?
  public var clientVersion: String?
  public var manufacturer: String?
  public var model: String?
  public var clientName: String?
  public var deviceName: String?
  public var forceDirectPlay: Bool?
  public var forceTranscode: Bool?
  public var supportedMimeTypes: [String]?
  public var mediaPlayer: String?

  public init(
    deviceID: String? = nil,
    clientVersion: String? = nil,
    manufacturer: String? = nil,
    model: String? = nil,
    clientName: String? = nil,
    deviceName: String? = nil,
    forceDirectPlay: Bool? = nil,
    forceTranscode: Bool? = nil,
    supportedMimeTypes: [String]? = nil,
    mediaPlayer: String? = nil
  ) {
    self.deviceID = deviceID
    self.clientVersion = clientVersion
    self.manufacturer = manufacturer
    self.model = model
    self.clientName = clientName
    self.deviceName = deviceName
    self.forceDirectPlay = forceDirectPlay
    self.forceTranscode = forceTranscode
    self.supportedMimeTypes = supportedMimeTypes
    self.mediaPlayer = mediaPlayer
  }
}

/// A playable stream descriptor from a `PlaybackSession` response's `audioTracks[]`: 1-based
/// `index`, cumulative `startOffset`, a bare `/api/items/{id}/file/{ino}` `contentUrl`. A track is
/// useless without `stream`, so tracks whose `contentUrl` is missing or fails
/// `PlaybackStreamResource.resolve` are dropped by `PlaybackSession.init(dto:id:server:)`.
public struct PlaybackSessionAudioTrack: Sendable, Equatable {
  public let index: Int?
  public let startOffset: Double?
  public let duration: Double?
  public let title: String?
  public let mimeType: String?
  public let stream: PlaybackStreamResource

  public init(
    index: Int?,
    startOffset: Double?,
    duration: Double?,
    title: String?,
    mimeType: String?,
    stream: PlaybackStreamResource
  ) {
    self.index = index
    self.startOffset = startOffset
    self.duration = duration
    self.title = title
    self.mimeType = mimeType
    self.stream = stream
  }

  /// Returns `nil` (never throws) when `contentUrl` is missing or resolves to nothing usable.
  /// `PlaybackSession`'s mapping escalates "zero usable tracks" to a decode error.
  init?(dto: PlaybackSessionAudioTrackDTO, server: ABSServerConfig) {
    guard let contentUrl = dto.contentUrl,
      let stream = PlaybackStreamResource.resolve(rawContentUrl: contentUrl, server: server)
    else {
      return nil
    }
    self.init(
      index: dto.index,
      startOffset: dto.startOffset,
      duration: dto.duration,
      title: dto.title,
      mimeType: dto.mimeType,
      stream: stream
    )
  }
}

/// A chapter boundary from a `PlaybackSession`: `{ id: <0-based int>, start, end, title }`.
/// `id`/`start`/`end` are required and `start`/`end` must be finite. Arithmetic over them is not
/// this layer's job. A malformed element is dropped rather than failing the session decode.
public struct PlaybackChapter: Sendable, Equatable {
  public let id: Int
  public let start: Double
  public let end: Double
  public let title: String?

  public init(id: Int, start: Double, end: Double, title: String?) {
    self.id = id
    self.start = start
    self.end = end
    self.title = title
  }

  init?(dto: PlaybackSessionChapterDTO) {
    guard let id = dto.id, let start = dto.start, start.isFinite, let end = dto.end, end.isFinite else {
      return nil
    }
    self.init(id: id, start: start, end: end, title: dto.title)
  }
}

/// Public value type for the `PlaybackSession.toJSONForClient(libraryItem)` response. Undecoded,
/// having no consumer: `serverVersion`, `date`/`dayOfWeek`, `startTime`, `coverAspectRatio` and
/// the embedded `libraryItem{}`.
///
/// `playMethod` stays a raw `Int?`: the `DIRECTPLAY`/`TRANSCODE` names are documented but their
/// numeric wire values are not.
public struct PlaybackSession: Sendable, Equatable {
  public let id: String
  public let libraryItemID: String?
  public let episodeID: String?
  public let mediaType: String?
  public let displayTitle: String?
  public let displayAuthor: String?
  public let duration: Double?
  public let currentTime: Double?
  public let playMethod: Int?
  /// The session's `deviceInfo.deviceId`, echoed back by the server (which also adds its own
  /// `id`/`userId`/`ipAddress`/`clientVersion`). Lets a caller confirm a recovered session belongs
  /// to this installation.
  public let deviceID: String?
  /// The session's cumulative server-side listened total. `/sync` is additive and answers with no
  /// body, so this is the only ledger a client can read back to tell whether a `/sync` whose
  /// response it lost landed. Unlike `currentTime` it only grows, so a backward seek cannot make
  /// it read as less listening than happened.
  public let timeListening: Double?
  public let audioTracks: [PlaybackSessionAudioTrack]
  public let chapters: [PlaybackChapter]

  public init(
    id: String,
    libraryItemID: String?,
    episodeID: String?,
    mediaType: String?,
    displayTitle: String?,
    displayAuthor: String?,
    duration: Double?,
    currentTime: Double?,
    playMethod: Int?,
    deviceID: String?,
    timeListening: Double? = nil,
    audioTracks: [PlaybackSessionAudioTrack],
    chapters: [PlaybackChapter]
  ) {
    self.id = id
    self.libraryItemID = libraryItemID
    self.episodeID = episodeID
    self.mediaType = mediaType
    self.displayTitle = displayTitle
    self.displayAuthor = displayAuthor
    self.duration = duration
    self.currentTime = currentTime
    self.playMethod = playMethod
    self.deviceID = deviceID
    self.timeListening = timeListening
    self.audioTracks = audioTracks
    self.chapters = chapters
  }

  /// `server` resolves each track's raw `contentUrl` into a restricted `PlaybackStreamResource`.
  /// Fails closed (throws `APIError.decoding`) when zero tracks survive that mapping, since a
  /// session with no usable stream is not a session.
  init(dto: PlaybackSessionDTO, id: String, server: ABSServerConfig) throws {
    let tracks = dto.audioTracks.compactMap { PlaybackSessionAudioTrack(dto: $0, server: server) }
    guard tracks.isEmpty == false else { throw APIError.decoding }
    self.init(
      id: id,
      libraryItemID: dto.libraryItemId,
      episodeID: dto.episodeId,
      mediaType: dto.mediaType,
      displayTitle: dto.displayTitle,
      displayAuthor: dto.displayAuthor,
      duration: dto.duration,
      currentTime: dto.currentTime,
      playMethod: dto.playMethod,
      deviceID: dto.deviceInfo?.deviceId,
      timeListening: dto.timeListening,
      audioTracks: tracks,
      chapters: dto.chapters.compactMap(PlaybackChapter.init(dto:))
    )
  }
}

/// The sync/close body: `{ "currentTime": 1234.5, "timeListened": 15.0, "duration": 3600.0 }`.
/// The initialiser names the second field `deltaSeconds` so a call site cannot misread it:
/// `timeListened` is the delta since the last acknowledged sync, never cumulative (the server adds
/// it). The wire key is still `timeListened` (`CodingKeys` maps it).
public struct SessionSyncUpdate: Sendable, Equatable {
  public let currentTime: Double
  /// Encoded on the wire as `timeListened`. A delta, never a running total.
  public let deltaSeconds: Double
  public let duration: Double?

  public init(currentTime: Double, deltaSeconds: Double, duration: Double? = nil) {
    self.currentTime = currentTime
    self.deltaSeconds = deltaSeconds
    self.duration = duration
  }
}

extension SessionSyncUpdate: Encodable {
  private enum CodingKeys: String, CodingKey { case currentTime, timeListened, duration }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(currentTime, forKey: .currentTime)
    try container.encode(deltaSeconds, forKey: .timeListened)
    try container.encodeIfPresent(duration, forKey: .duration)
  }
}

/// `GET /api/sessions/open`'s lenient element cap. This device has one or two open sessions at
/// most, so a cap far below `EndpointDecodeLimits.standard.maximumArrayElements` (20,000) stops a
/// hostile response doing unbounded decode work without truncating a real result. Exceeding it
/// never throws: `OpenPlaybackSessionListDTO` stops decoding further elements.
enum OpenPlaybackSessionListBounds {
  static let maximum = 20
}

extension ABSClient {
  /// `POST /api/items/{id}/play` or `POST /api/items/{id}/play/{episodeId}`. Builds the request
  /// and decodes the response; starting playback is PlayerCore's job.
  public func startPlaybackSession(
    account: TokenAccount,
    itemID: String,
    episodeID: String? = nil,
    options: StartPlaybackSessionOptions = StartPlaybackSessionOptions(),
    diagnostics: DecodeDiagnostics? = nil
  ) async throws -> PlaybackSession {
    let tokens = try loadTokens(for: account)
    let path: String
    let routeTemplate: String
    if let episodeID {
      path = "/api/items/\(itemID)/play/\(episodeID)"
      routeTemplate = "/api/items/:id/play/:episodeId"
    } else {
      path = "/api/items/\(itemID)/play"
      routeTemplate = "/api/items/:id/play"
    }

    let request = try requestBuilder.makeJSONRequest(
      method: .post,
      path: path,
      body: StartPlaybackSessionPayload(options: options),
      routeTemplate: routeTemplate
    )
    let response = try await authenticatedSend(request, account: account, initialTokens: tokens)
    try validateSuccess(response)

    let wire = try decoder.decode(
      PlaybackSessionDTO.self,
      from: response.body,
      endpoint: routeTemplate,
      diagnostics: diagnostics
    )
    // Top-level shape failure: a response with no session id is not a session.
    guard let id = wire.id else { throw APIError.decoding }
    return try PlaybackSession(dto: wire, id: id, server: server)
  }

  /// `GET /api/session/{id}` (API-CONVENTIONS.md): `200` while the session is open, `404` once it
  /// is closed. Used for lost-close recovery. A `404` means an absent session, not an error; every
  /// other non-2xx status throws. Paired with persisting the session id as soon as `/play` returns
  /// `200`, this is the reliable recovery path; `fetchOpenPlaybackSessions` is best-effort only.
  public func fetchPlaybackSession(
    account: TokenAccount,
    sessionID: String,
    diagnostics: DecodeDiagnostics? = nil
  ) async throws -> PlaybackSession? {
    let tokens = try loadTokens(for: account)
    let routeTemplate = "/api/session/:id"
    let request = try requestBuilder.makeRequest(
      method: .get,
      path: "/api/session/\(sessionID)",
      routeTemplate: routeTemplate
    )
    let response = try await authenticatedSend(request, account: account, initialTokens: tokens)
    guard response.statusCode != 404 else { return nil }
    try validateSuccess(response)

    let wire = try decoder.decode(
      PlaybackSessionDTO.self,
      from: response.body,
      endpoint: routeTemplate,
      diagnostics: diagnostics
    )
    guard let id = wire.id else { throw APIError.decoding }
    return try PlaybackSession(dto: wire, id: id, server: server)
  }

  /// `GET /api/sessions/open` (API-CONVENTIONS.md). Best-effort only: the route 404s for a normal
  /// account on the tested server version, and a `404` is an empty "no info" result. Callers cannot
  /// tell "no open sessions" from "route unavailable", so nothing may depend on it. The reliable
  /// recovery path is persisting the session id as soon as `/play` returns `200`, then confirming
  /// it with `fetchPlaybackSession`.
  ///
  /// Every other non-2xx status (401/403/429/5xx/transport/cancellation) propagates under the
  /// existing classifications. Decoding is bounded (`OpenPlaybackSessionListBounds.maximum`) and
  /// lenient: a malformed element, or one with no id or no usable streams, is dropped.
  public func fetchOpenPlaybackSessions(
    account: TokenAccount,
    diagnostics: DecodeDiagnostics? = nil
  ) async throws -> [PlaybackSession] {
    let tokens = try loadTokens(for: account)
    let routeTemplate = "/api/sessions/open"
    let request = try requestBuilder.makeRequest(
      method: .get,
      path: "/api/sessions/open",
      routeTemplate: routeTemplate
    )
    let response = try await authenticatedSend(request, account: account, initialTokens: tokens)
    guard response.statusCode != 404 else { return [] }
    try validateSuccess(response)

    let wire = try decoder.decode(
      OpenPlaybackSessionListDTO.self,
      from: response.body,
      endpoint: routeTemplate,
      diagnostics: diagnostics
    )
    return wire.sessions.compactMap { dto in
      guard let id = dto.id else { return nil }
      return try? PlaybackSession(dto: dto, id: id, server: server)
    }
  }

  /// `POST /api/session/{id}/sync`. The response is a bare 200/500 status with no JSON body, so
  /// this only validates the status.
  public func syncPlaybackSession(
    account: TokenAccount,
    sessionID: String,
    update: SessionSyncUpdate
  ) async throws {
    let tokens = try loadTokens(for: account)
    let request = try requestBuilder.makeJSONRequest(
      method: .post,
      path: "/api/session/\(sessionID)/sync",
      body: update,
      routeTemplate: "/api/session/:id/sync",
      transportClass: .progressSync
    )
    let response = try await authenticatedSend(request, account: account, initialTokens: tokens)
    try validateSuccess(response)
  }

  /// `POST /api/session/{id}/close`. The body is optional and carries the final position in the
  /// shape `/sync` uses; without it the server persists whatever the session already has. Always
  /// attempts the close, unlike the official iOS app, which never calls `/close`.
  public func closePlaybackSession(
    account: TokenAccount,
    sessionID: String,
    finalPosition: SessionSyncUpdate? = nil
  ) async throws {
    let tokens = try loadTokens(for: account)
    let routeTemplate = "/api/session/:id/close"
    let request: HTTPRequest
    if let finalPosition {
      request = try requestBuilder.makeJSONRequest(
        method: .post,
        path: "/api/session/\(sessionID)/close",
        body: finalPosition,
        routeTemplate: routeTemplate,
        transportClass: .progressSync
      )
    } else {
      request = try requestBuilder.makeRequest(
        method: .post,
        path: "/api/session/\(sessionID)/close",
        routeTemplate: routeTemplate,
        transportClass: .progressSync
      )
    }
    let response = try await authenticatedSend(request, account: account, initialTokens: tokens)
    try validateSuccess(response)
  }
}

private struct StartPlaybackSessionPayload: Encodable, Sendable {
  let forceDirectPlay: Bool?
  let forceTranscode: Bool?
  let supportedMimeTypes: [String]?
  let mediaPlayer: String?
  let deviceInfo: DeviceInfoPayload?

  init(options: StartPlaybackSessionOptions) {
    forceDirectPlay = options.forceDirectPlay
    forceTranscode = options.forceTranscode
    supportedMimeTypes = options.supportedMimeTypes
    mediaPlayer = options.mediaPlayer
    let hasDeviceInfo =
      options.deviceID != nil || options.clientVersion != nil || options.manufacturer != nil
      || options.model != nil || options.clientName != nil || options.deviceName != nil
    deviceInfo = hasDeviceInfo ? DeviceInfoPayload(options: options) : nil
  }

  private enum CodingKeys: String, CodingKey {
    case forceDirectPlay, forceTranscode, supportedMimeTypes, mediaPlayer, deviceInfo
  }
}

/// The fields `server/objects/DeviceInfo.js` accepts.
private struct DeviceInfoPayload: Encodable, Sendable {
  let deviceId: String?
  let clientVersion: String?
  let manufacturer: String?
  let model: String?
  let clientName: String?
  let deviceName: String?

  init(options: StartPlaybackSessionOptions) {
    deviceId = options.deviceID
    clientVersion = options.clientVersion
    manufacturer = options.manufacturer
    model = options.model
    clientName = options.clientName
    deviceName = options.deviceName
  }
}

/// The `GET /api/sessions/open` response shape, unconfirmed against a live server (see
/// `ABSClient.fetchOpenPlaybackSessions`). Assumed to be `{ "sessions": [...] }`, like the other
/// wrapped-array list endpoints (`LibraryListDTO`'s `{ "libraries": [...] }`), not a bare array.
///
/// Hand-rolled because `decodeLossyArray`/`LossyArray` throw once the general bound is exceeded,
/// whereas here "too many elements" must silently stop decoding. A malformed element is skipped
/// using `LossyArray`'s `superDecoder()`-advances-regardless-of-throw technique.
struct OpenPlaybackSessionListDTO: Decodable {
  let sessions: [PlaybackSessionDTO]

  private enum CodingKeys: String, CodingKey { case sessions }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    guard container.contains(.sessions) else {
      sessions = []
      return
    }
    var nested = try container.nestedUnkeyedContainer(forKey: .sessions)
    var decoded: [PlaybackSessionDTO] = []
    while nested.isAtEnd == false, decoded.count < OpenPlaybackSessionListBounds.maximum {
      let elementDecoder = try nested.superDecoder()
      if let element = try? PlaybackSessionDTO(from: elementDecoder) {
        decoded.append(element)
      }
    }
    sessions = decoded
  }
}

/// The `PlaybackSession.toJSONForClient` wire shape. Internal like the module's other DTOs.
struct PlaybackSessionDTO: Decodable {
  let id: String?
  let libraryItemId: String?
  let episodeId: String?
  let mediaType: String?
  let displayTitle: String?
  let displayAuthor: String?
  let duration: Double?
  let currentTime: Double?
  let playMethod: Int?
  let deviceInfo: DeviceInfoDTO?
  let timeListening: Double?
  let audioTracks: [PlaybackSessionAudioTrackDTO]
  let chapters: [PlaybackSessionChapterDTO]

  private enum CodingKeys: String, CodingKey {
    case id, libraryItemId, episodeId, mediaType, displayTitle, displayAuthor, duration, currentTime, playMethod,
      deviceInfo, timeListening, audioTracks, chapters
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    // `.reject` + `try?`: a truncated session id would address a different `/api/session/{id}`
    // and would be persisted as this device's recovery key. A `nil` id fails the single-session
    // routes as a top-level shape error and drops the element from the open-session list.
    id = try? container.decodeBoundedString(forKey: .id, policy: .reject)
    libraryItemId = try container.decodeIfPresent(String.self, forKey: .libraryItemId)
    episodeId = try container.decodeIfPresent(String.self, forKey: .episodeId)
    mediaType = try container.decodeIfPresent(String.self, forKey: .mediaType)
    displayTitle = try container.decodeBoundedString(forKey: .displayTitle)
    displayAuthor = try container.decodeBoundedString(forKey: .displayAuthor)
    duration = try container.decode(LossyOptional<Double>.self, forKey: .duration).wrappedValue
    currentTime = try container.decode(LossyOptional<Double>.self, forKey: .currentTime).wrappedValue
    playMethod = try container.decode(LossyOptional<Int>.self, forKey: .playMethod).wrappedValue
    // A malformed `deviceInfo` (wrong type, etc.) is treated as absent rather than failing the
    // session decode. It is metadata, not a fail-closed requirement.
    deviceInfo = try? container.decodeIfPresent(DeviceInfoDTO.self, forKey: .deviceInfo)
    timeListening = try container.decode(LossyOptional<Double>.self, forKey: .timeListening).wrappedValue
    audioTracks = try container.decodeLossyArrayIfPresent(forKey: .audioTracks)
    chapters = try container.decodeLossyArrayIfPresent(forKey: .chapters)
  }
}

struct PlaybackSessionAudioTrackDTO: Decodable {
  let index: Int?
  let startOffset: Double?
  let duration: Double?
  let title: String?
  let contentUrl: String?
  let mimeType: String?

  private enum CodingKeys: String, CodingKey { case index, startOffset, duration, title, contentUrl, mimeType }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    index = try container.decode(LossyOptional<Int>.self, forKey: .index).wrappedValue
    startOffset = try container.decode(LossyOptional<Double>.self, forKey: .startOffset).wrappedValue
    duration = try container.decode(LossyOptional<Double>.self, forKey: .duration).wrappedValue
    title = try container.decodeBoundedString(forKey: .title)
    contentUrl = try container.decodeBoundedString(forKey: .contentUrl)
    mimeType = try container.decodeBoundedString(forKey: .mimeType)
  }
}

/// Chapter wire shape: `{ id: <0-based int>, start, end, title }`.
struct PlaybackSessionChapterDTO: Decodable {
  let id: Int?
  let start: Double?
  let end: Double?
  let title: String?

  private enum CodingKeys: String, CodingKey { case id, start, end, title }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(LossyOptional<Int>.self, forKey: .id).wrappedValue
    start = try container.decode(LossyOptional<Double>.self, forKey: .start).wrappedValue
    end = try container.decode(LossyOptional<Double>.self, forKey: .end).wrappedValue
    title = try container.decodeBoundedString(forKey: .title)
  }
}

/// The response echoes the sent `deviceId`/`clientName` and adds server-side
/// `id`/`userId`/`ipAddress`/`clientVersion`. Only `deviceId` is decoded, since
/// `PlaybackSession` needs nothing else.
struct DeviceInfoDTO: Decodable {
  let deviceId: String?

  private enum CodingKeys: String, CodingKey { case deviceId }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    deviceId = try container.decodeBoundedString(forKey: .deviceId)
  }
}
