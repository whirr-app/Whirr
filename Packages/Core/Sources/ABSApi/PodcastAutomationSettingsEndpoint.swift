import Foundation

/// The only schedules Whirr will write to a show's automatic-download setting. Free text cannot be
/// constructed: the case set is the whole vocabulary, declared in presentation order.
public enum PodcastAutomationSchedulePreset: String, Sendable, Equatable, CaseIterable {
  case hourly
  case everySixHours
  case everyTwelveHours
  case daily
  case weekly

  public var cronExpression: String {
    switch self {
    case .hourly: return "0 * * * *"
    case .everySixHours: return "0 */6 * * *"
    case .everyTwelveHours: return "0 */12 * * *"
    case .daily: return "0 0 * * *"
    case .weekly: return "0 0 * * 0"
    }
  }

  /// The preset a stored cron string names, or `nil` for a custom or empty schedule.
  public init?(cronExpression: String) {
    guard let match = Self.allCases.first(where: { $0.cronExpression == cronExpression }) else {
      return nil
    }
    self = match
  }
}

/// Bounds for the two numeric automation settings. The server stores any number and reads a
/// new-episode limit of `0` as unlimited, so Whirr never sends `0` for it.
public enum PodcastAutomationBounds {
  public static let maxNewEpisodesToDownload = 1...100
  public static let maxEpisodesToKeep = 0...1000
}

/// The body sent to `PATCH /api/items/:id/media`. Audiobookshelf's route is the general media edit
/// (metadata, tags, cover), so this closed encoder is the only thing limiting the write to the four
/// automation keys. Only keys that are set are emitted, at the top level, and never as null.
public struct PodcastAutomationSettingsRequest: Encodable, Sendable, Equatable,
  CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable
{
  public let autoDownloadEpisodes: Bool?
  public let autoDownloadSchedule: PodcastAutomationSchedulePreset?
  public let maxNewEpisodesToDownload: Int?
  public let maxEpisodesToKeep: Int?

  /// Values are validated when the request is sent, so an out-of-range value or an empty request
  /// fails with `PodcastWriteError.invalidValue` before any network call.
  public init(
    autoDownloadEpisodes: Bool? = nil,
    autoDownloadSchedule: PodcastAutomationSchedulePreset? = nil,
    maxNewEpisodesToDownload: Int? = nil,
    maxEpisodesToKeep: Int? = nil
  ) {
    self.autoDownloadEpisodes = autoDownloadEpisodes
    self.autoDownloadSchedule = autoDownloadSchedule
    self.maxNewEpisodesToDownload = maxNewEpisodesToDownload
    self.maxEpisodesToKeep = maxEpisodesToKeep
  }

  private enum CodingKeys: String, CodingKey {
    case autoDownloadEpisodes, autoDownloadSchedule, maxNewEpisodesToDownload, maxEpisodesToKeep
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encodeIfPresent(autoDownloadEpisodes, forKey: .autoDownloadEpisodes)
    try container.encodeIfPresent(
      autoDownloadSchedule?.cronExpression, forKey: .autoDownloadSchedule)
    try container.encodeIfPresent(maxNewEpisodesToDownload, forKey: .maxNewEpisodesToDownload)
    try container.encodeIfPresent(maxEpisodesToKeep, forKey: .maxEpisodesToKeep)
  }

  func validate() throws {
    guard
      autoDownloadEpisodes != nil || autoDownloadSchedule != nil
        || maxNewEpisodesToDownload != nil || maxEpisodesToKeep != nil
    else { throw PodcastWriteError.invalidValue(field: .automationSettings) }
    if let value = maxNewEpisodesToDownload,
      PodcastAutomationBounds.maxNewEpisodesToDownload.contains(value) == false
    {
      throw PodcastWriteError.invalidValue(field: .maxNewEpisodesToDownload)
    }
    if let value = maxEpisodesToKeep,
      PodcastAutomationBounds.maxEpisodesToKeep.contains(value) == false
    {
      throw PodcastWriteError.invalidValue(field: .maxEpisodesToKeep)
    }
  }

  public var description: String {
    "PodcastAutomationSettingsRequest(autoDownloadEpisodes: \(autoDownloadEpisodes.map(String.init(describing:)) ?? "nil"), "
      + "schedule: \(autoDownloadSchedule?.rawValue ?? "nil"), "
      + "maxNew: \(maxNewEpisodesToDownload.map(String.init) ?? "nil"), "
      + "maxKeep: \(maxEpisodesToKeep.map(String.init) ?? "nil"))"
  }

  public var debugDescription: String { description }
  public var customMirror: Mirror { Mirror(self, unlabeledChildren: []) }
}

/// The four settings the server reports after a write, read from `libraryItem.media`. Each is
/// `nil` when the server omitted it or sent the wrong type; the schedule is the raw stored string
/// because a custom cron is representable on the server.
///
/// A 200 with an unparseable body yields every field `nil`, not a throw: the write has landed, so
/// reporting failure would invite a retry. Callers treat that as "not confirmed" and refresh.
public struct PodcastAutomationSettingsResult: Sendable, Equatable {
  public let autoDownloadEpisodes: Bool?
  public let autoDownloadSchedule: String?
  public let maxNewEpisodesToDownload: Int?
  public let maxEpisodesToKeep: Int?

  public init(
    autoDownloadEpisodes: Bool? = nil,
    autoDownloadSchedule: String? = nil,
    maxNewEpisodesToDownload: Int? = nil,
    maxEpisodesToKeep: Int? = nil
  ) {
    self.autoDownloadEpisodes = autoDownloadEpisodes
    self.autoDownloadSchedule = autoDownloadSchedule
    self.maxNewEpisodesToDownload = maxNewEpisodesToDownload
    self.maxEpisodesToKeep = maxEpisodesToKeep
  }

  /// Whether the response carried any stored value at all.
  public var hasStoredValues: Bool {
    autoDownloadEpisodes != nil || autoDownloadSchedule != nil
      || maxNewEpisodesToDownload != nil || maxEpisodesToKeep != nil
  }

  static func parse(_ body: Data) -> PodcastAutomationSettingsResult {
    guard let root = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
      let item = root["libraryItem"] as? [String: Any],
      let media = item["media"] as? [String: Any]
    else { return PodcastAutomationSettingsResult() }
    return PodcastAutomationSettingsResult(
      autoDownloadEpisodes: strictBool(media["autoDownloadEpisodes"]),
      autoDownloadSchedule: (media["autoDownloadSchedule"] as? String).flatMap {
        $0.utf8.count <= PodcastWriteBounds.maximumStringBytes ? $0 : nil
      },
      maxNewEpisodesToDownload: strictInt(media["maxNewEpisodesToDownload"]),
      maxEpisodesToKeep: strictInt(media["maxEpisodesToKeep"]))
  }

  // JSONSerialization bridges numbers and booleans to NSNumber, so tell them apart by CF type.
  private static func strictBool(_ value: Any?) -> Bool? {
    guard let number = value as? NSNumber,
      CFGetTypeID(number) == CFBooleanGetTypeID()
    else { return nil }
    return number.boolValue
  }

  private static func strictInt(_ value: Any?) -> Int? {
    guard let number = value as? NSNumber,
      CFGetTypeID(number) != CFBooleanGetTypeID()
    else { return nil }
    let double = number.doubleValue
    guard double.isFinite, double == double.rounded(), let int = Int(exactly: double) else {
      return nil
    }
    return int
  }
}

extension ABSClient {
  /// `PATCH /api/items/:id/media` with only the automation keys that are set. Requires the
  /// server's `update` permission: `403` is `APIError.forbidden`, `404` is `.notFound`, and a
  /// rejected body is `.badRequest`. There is no retry beyond the transport's one post-`401`
  /// resend.
  public func updatePodcastAutomationSettings(
    account: TokenAccount,
    itemID: String,
    request: PodcastAutomationSettingsRequest
  ) async throws -> PodcastAutomationSettingsResult {
    try checkPodcastWriteCancellation()
    try validateIdentifier(itemID, field: .itemID)
    try request.validate()

    let tokens = try loadTokens(for: account)
    let httpRequest = try requestBuilder.makeJSONRequest(
      method: .patch,
      path: "/api/items/" + itemID + "/media",
      body: request,
      routeTemplate: "/api/items/:id/media"
    )
    try checkPodcastWriteCancellation()

    let response = try await sendPodcastMutation(
      httpRequest, account: account, initialTokens: tokens)
    try validateSuccess(response)
    return PodcastAutomationSettingsResult.parse(response.body)
  }
}
