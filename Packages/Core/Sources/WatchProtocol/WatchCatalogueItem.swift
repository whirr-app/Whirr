import Foundation

public enum WatchCatalogueSection: String, Codable, Sendable, Equatable {
  case continueListening = "continue_listening"
  case recentBooks = "recent_books"
  case recentEpisodes = "recent_episodes"
  case downloads
}

/// Capabilities describe destinations, never URLs. In particular, a phone-local native download
/// must not imply that the Watch can play the file.
///
/// The ABS-only guarantee on the handoff and pending-progress selections stands, and no value here
/// claims Watch-local RSS playback. The playing report names an RSS episode only through its own
/// optional native field, so the phone can avoid a concurrent start; playability for that episode
/// is derived on the Watch from a received copy, never claimed on the wire (ADR 0019 decision 3).
public struct WatchSelectionCapabilities: Codable, Sendable, Equatable {
  public let phonePlayable: Bool
  public let watchPlayable: Bool
  public let phoneLocalDownload: Bool
  public let watchLocalDownload: Bool

  public init(
    phonePlayable: Bool,
    watchPlayable: Bool,
    phoneLocalDownload: Bool = false,
    watchLocalDownload: Bool = false
  ) {
    self.phonePlayable = phonePlayable
    self.watchPlayable = watchPlayable
    self.phoneLocalDownload = phoneLocalDownload
    self.watchLocalDownload = watchLocalDownload
  }
}

public struct WatchCatalogueItem: Codable, Sendable, Equatable, Identifiable {
  public let id: String
  public let selection: WatchSelection
  public let section: WatchCatalogueSection
  public let title: String
  public let subtitle: String?
  public let progressSeconds: Double
  public let durationSeconds: Double?
  public let chapterTitle: String?
  public let chapterStartSeconds: Double?
  public let chapterEndSeconds: Double?
  public let isCurrentPlayback: Bool
  public let capabilities: WatchSelectionCapabilities
  /// The cover revision the phone knows for this row's book or show; absent on older replies and
  /// on rows the phone cannot date, which keep whatever revision the Watch already learned.
  public let artworkRevision: String?
  /// When the phone last listened to this title itself, sent on its current row while that
  /// title is loaded. Absent from older phones and from a phone that has not played it since launch.
  public let lastListenedAt: Date?

  public init(
    id: String,
    selection: WatchSelection,
    title: String,
    subtitle: String? = nil,
    section: WatchCatalogueSection = .continueListening,
    progressSeconds: Double = 0,
    durationSeconds: Double? = nil,
    isCurrentPlayback: Bool = false,
    chapterTitle: String? = nil, chapterStartSeconds: Double? = nil, chapterEndSeconds: Double? = nil,
    capabilities: WatchSelectionCapabilities,
    artworkRevision: String? = nil,
    lastListenedAt: Date? = nil
  ) throws {
    try selection.validate()
    if let artworkRevision { try WatchArtworkReference.validate(revision: artworkRevision) }
    try Self.validateMetadata(id)
    try Self.validateMetadata(title)
    if let subtitle { try Self.validateMetadata(subtitle) }
    try Self.validateProgress(progressSeconds: progressSeconds, durationSeconds: durationSeconds)
    try Self.validateCapabilities(selection: selection, capabilities: capabilities)
    self.id = id
    self.selection = selection
    self.section = section
    self.title = title
    self.subtitle = subtitle
    self.progressSeconds = progressSeconds
    self.durationSeconds = durationSeconds
    self.isCurrentPlayback = isCurrentPlayback
    self.capabilities = capabilities
    self.chapterTitle = chapterTitle
    self.chapterStartSeconds = chapterStartSeconds
    self.chapterEndSeconds = chapterEndSeconds
    self.artworkRevision = artworkRevision
    self.lastListenedAt = lastListenedAt
    try validateChapter()
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let id = try container.decode(String.self, forKey: .id)
    let selection = try container.decode(WatchSelection.self, forKey: .selection)
    let section = try container.decodeIfPresent(WatchCatalogueSection.self, forKey: .section) ?? .continueListening
    let title = try container.decode(String.self, forKey: .title)
    let subtitle = try container.decodeIfPresent(String.self, forKey: .subtitle)
    let progressSeconds = try container.decodeIfPresent(Double.self, forKey: .progressSeconds) ?? 0
    let durationSeconds = try container.decodeIfPresent(Double.self, forKey: .durationSeconds)
    let isCurrentPlayback = try container.decodeIfPresent(Bool.self, forKey: .isCurrentPlayback) ?? false
    let capabilities = try container.decode(WatchSelectionCapabilities.self, forKey: .capabilities)
    try self.init(
      id: id, selection: selection, title: title, subtitle: subtitle, section: section,
      progressSeconds: progressSeconds, durationSeconds: durationSeconds, isCurrentPlayback: isCurrentPlayback,
      chapterTitle: container.decodeIfPresent(String.self, forKey: .chapterTitle),
      chapterStartSeconds: container.decodeIfPresent(Double.self, forKey: .chapterStartSeconds),
      chapterEndSeconds: container.decodeIfPresent(Double.self, forKey: .chapterEndSeconds), capabilities: capabilities,
      artworkRevision: container.decodeIfPresent(String.self, forKey: .artworkRevision),
      lastListenedAt: container.decodeIfPresent(Date.self, forKey: .lastListenedAt))
  }

  public func encode(to encoder: Encoder) throws {
    try validate()
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, forKey: .id)
    try container.encode(selection, forKey: .selection)
    try container.encode(section, forKey: .section)
    try container.encode(title, forKey: .title)
    try container.encodeIfPresent(subtitle, forKey: .subtitle)
    try container.encode(progressSeconds, forKey: .progressSeconds)
    try container.encodeIfPresent(durationSeconds, forKey: .durationSeconds)
    try container.encode(isCurrentPlayback, forKey: .isCurrentPlayback)
    try container.encode(capabilities, forKey: .capabilities)
    try container.encodeIfPresent(chapterTitle, forKey: .chapterTitle)
    try container.encodeIfPresent(chapterStartSeconds, forKey: .chapterStartSeconds)
    try container.encodeIfPresent(chapterEndSeconds, forKey: .chapterEndSeconds)
    try container.encodeIfPresent(artworkRevision, forKey: .artworkRevision)
    try container.encodeIfPresent(lastListenedAt, forKey: .lastListenedAt)
  }

  public func validate() throws {
    try validateChapter()
    try selection.validate()
    try Self.validateMetadata(id)
    try Self.validateMetadata(title)
    if let subtitle { try Self.validateMetadata(subtitle) }
    try Self.validateProgress(progressSeconds: progressSeconds, durationSeconds: durationSeconds)
    try Self.validateCapabilities(selection: selection, capabilities: capabilities)
    if let artworkRevision { try WatchArtworkReference.validate(revision: artworkRevision) }
  }

  private func validateChapter() throws {
    guard chapterStartSeconds != nil || chapterEndSeconds != nil || chapterTitle != nil else { return }
    guard let start = chapterStartSeconds, let end = chapterEndSeconds,
      start.isFinite, end.isFinite, start >= 0, end > start,
      durationSeconds.map({ end <= $0 }) ?? true
    else { throw WatchProtocolCodingError.invalidValue }
    if let chapterTitle { try Self.validateMetadata(chapterTitle) }
  }

  private static func validateProgress(progressSeconds: Double, durationSeconds: Double?) throws {
    guard progressSeconds.isFinite, progressSeconds >= 0 else {
      throw WatchProtocolCodingError.invalidValue
    }
    if let durationSeconds {
      guard durationSeconds.isFinite, durationSeconds > 0, progressSeconds <= durationSeconds else {
        throw WatchProtocolCodingError.invalidValue
      }
    }
  }

  private static func validateCapabilities(
    selection: WatchSelection,
    capabilities: WatchSelectionCapabilities
  ) throws {
    if case .nativeFeed = selection, capabilities.watchPlayable || capabilities.watchLocalDownload {
      throw WatchProtocolCodingError.invalidValue
    }
  }

  private static func validateMetadata(_ value: String) throws {
    guard !value.isEmpty, !WatchProtocolValidation.containsControlCharacter(value) else {
      throw WatchProtocolCodingError.invalidValue
    }
    guard !value.contains("://"), !value.lowercased().hasPrefix("file:"), !value.hasPrefix("/") else {
      throw WatchProtocolCodingError.forbiddenMetadata
    }
    guard value.utf8.count <= WatchProtocolVersion.maxMetadataStringBytes else {
      throw WatchProtocolCodingError.oversizedMetadata
    }
  }

  private enum CodingKeys: String, CodingKey {
    case id, selection, section, title, subtitle, progressSeconds, durationSeconds, isCurrentPlayback,
      capabilities, chapterTitle, chapterStartSeconds, chapterEndSeconds, artworkRevision, lastListenedAt
  }
}
