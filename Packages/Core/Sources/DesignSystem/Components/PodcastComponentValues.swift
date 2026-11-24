import SwiftUI

/// Audiobook and podcast content alike is ordinary scrollable content, never floating control
/// chrome.
public enum MediaContentSurface: Sendable, Equatable {
  case ordinaryContent
}

public enum MediaRowLayoutAxis: Sendable, Equatable {
  case horizontal
  case vertical
}

/// How a row lays out its side-by-side status labels. Long status copy (a held cellular download,
/// a failure reason) does not fit three labels on one phone-width line, and a squeezed line
/// truncates the neighbours rather than the offender, so the single-line form is only an offer.
public enum MediaRowStatusLayout: Sendable, Equatable {
  /// One line when all the labels genuinely fit at their natural size, stacked when they don't.
  case singleLineOrStacked
  /// Always stacked.
  case stacked
}

/// Pure, renderer-independent values for the Dynamic Type layout branch shared by the media rows
/// (podcast episode rows and the universal Up Next row alike; a queue row is routinely an
/// audiobook).
public struct MediaRowLayoutValues: Sendable, Equatable {
  public let axis: MediaRowLayoutAxis
  /// `nil` everywhere: essential row text wraps to as many lines as it needs and is never
  /// truncated or scaled down (no fixed-height essential text).
  public let essentialTextLineLimit: Int?
  public let statusLayout: MediaRowStatusLayout
  public let minimumActionDimension: CGFloat

  public static func resolve(isAccessibilitySize: Bool) -> MediaRowLayoutValues {
    MediaRowLayoutValues(
      axis: isAccessibilitySize ? .vertical : .horizontal,
      essentialTextLineLimit: nil,
      statusLayout: isAccessibilitySize ? .stacked : .singleLineOrStacked,
      minimumActionDimension: WhirrMetric.minimumTouchTarget)
  }
}

/// Whether one episode has a copy on the Apple Watch, as the row draws it. Its own leading mark,
/// distinct from the download control: pending is the same glyph in secondary ink, delivered is
/// primary, and a separate spoken label keeps it apart from "Downloaded".
public enum PodcastEpisodeWatchMark: Sendable, Equatable, CaseIterable {
  /// Wanted or waiting for the Watch, or downloading on it.
  case sending
  case onWatch

  public var systemImage: String {
    switch self {
    case .sending, .onWatch: "applewatch"
    }
  }

  /// VoiceOver's label for the mark alone. Never folded into the download status.
  public var accessibilityText: String {
    switch self {
    case .sending: "Sending to Apple Watch"
    case .onWatch: "On Apple Watch"
    }
  }

  /// `metadata` led by the mark, inline, as the episode row and the episode card both draw it.
  /// Delivered is primary ink and pending secondary; the line's own ink colours the metadata.
  public func leading(_ metadata: String) -> Text {
    let mark = Text(Image(systemName: systemImage))
      .foregroundStyle(self == .onWatch ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
    return Text("\(mark) \(metadata)")
  }
}

public enum PodcastEpisodePlaybackStatus: Sendable, Equatable, CaseIterable {
  case unplayed
  case inProgress
  case played

  public var systemImage: String {
    switch self {
    case .unplayed: "circle"
    case .inProgress: "circle.lefthalf.filled"
    case .played: "checkmark.circle.fill"
    }
  }
}

/// Whether the server has a stored audio identity for this episode. There is no
/// server-fetching/queued case: v1 models the one device transfer only.
public enum PodcastServerAudioAvailability: Sendable, Equatable, CaseIterable {
  case available
  case unavailable

  public var systemImage: String {
    switch self {
    case .available: "externaldrive.fill.badge.checkmark"
    case .unavailable: "externaldrive.badge.xmark"
    }
  }
}

/// Device-transfer presentation remains distinct from server availability and reuses the existing
/// exhaustive download-state kind without importing a domain model.
public struct PodcastEpisodeDeviceDownloadStatus: Sendable, Equatable {
  public let kind: DownloadControlKind
  public let text: String
  public let systemImage: String
  public let progressFraction: Double?
  public let isIndeterminate: Bool

  public init(
    kind: DownloadControlKind,
    text: String,
    systemImage: String,
    progressFraction: Double? = nil,
    isIndeterminate: Bool = false
  ) {
    self.kind = kind
    self.text = text
    self.systemImage = systemImage
    self.progressFraction = progressFraction
    self.isIndeterminate = isIndeterminate
  }

  public var updatesFrequently: Bool { kind == .downloading }
  public var clampedProgressFraction: Double? {
    progressFraction.map { min(max($0, 0), 1) }
  }
}

public enum MediaActionRole: Sendable, Equatable {
  case standard
  case destructive
}

/// A caller-owned row context action, for an episode or a whole audiobook. The view forwards the
/// selected value and owns no business logic or app copy.
///
/// An action with `children` is a submenu (a book's download formats, e-reader devices, or author
/// and narrator links). Selecting a child forwards the child; the parent is never selected. `id`
/// must be unique across a whole menu, children included, since it is what the caller dispatches
/// on.
/// How a `MediaContextAction`'s children are drawn.
public enum MediaContextChildrenStyle: Sendable, Equatable {
  /// A submenu opened from the parent row, which carries its title and glyph.
  case submenu
  /// One horizontal row of buttons in place of the parent, as Apple Music draws its queue actions.
  /// The parent's title and glyph are not drawn.
  case controlGroup
}

public struct MediaContextAction: Sendable, Equatable, Identifiable {
  public let id: String
  public let label: String
  public let hint: String
  public let systemImage: String
  public let role: MediaActionRole
  public let isEnabled: Bool
  public let children: [MediaContextAction]
  /// A submenu's header above its choices, such as the question a large Watch send asks first.
  public let childrenTitle: String?
  /// How `children` are drawn: a submenu behind this row, or one horizontal row of buttons.
  public let childrenStyle: MediaContextChildrenStyle
  /// The title drawn in place of `label` inside a control group, whose titles share one narrow
  /// line. VoiceOver still reads `label`.
  public let compactLabel: String?
  /// For a UI test to find one row, such as Home's Remove from Continue Listening.
  public let accessibilityIdentifier: String?
  /// `1` for a title built from a server name (an author, a narrator), which truncates rather than
  /// wrap a row. `nil` leaves the system's wrapping alone: a fixed title fits one line already.
  public let titleLineLimit: Int?

  public init(
    id: String,
    label: String,
    hint: String,
    systemImage: String,
    role: MediaActionRole = .standard,
    isEnabled: Bool = true,
    children: [MediaContextAction] = [],
    childrenTitle: String? = nil,
    childrenStyle: MediaContextChildrenStyle = .submenu,
    compactLabel: String? = nil,
    accessibilityIdentifier: String? = nil,
    titleLineLimit: Int? = nil
  ) {
    self.id = id
    self.label = label
    self.hint = hint
    self.systemImage = systemImage
    self.role = role
    self.isEnabled = isEnabled
    self.children = children
    self.childrenTitle = childrenTitle
    self.childrenStyle = childrenStyle
    self.compactLabel = compactLabel
    self.accessibilityIdentifier = accessibilityIdentifier
    self.titleLineLimit = titleLineLimit
  }

  public var isSubmenu: Bool { children.isEmpty == false }

  /// This action with `compactLabel` set, for a row that joins a control group.
  public func withCompactLabel(_ compactLabel: String?) -> MediaContextAction {
    MediaContextAction(
      id: id, label: label, hint: hint, systemImage: systemImage, role: role,
      isEnabled: isEnabled, children: children, childrenTitle: childrenTitle,
      childrenStyle: childrenStyle, compactLabel: compactLabel,
      accessibilityIdentifier: accessibilityIdentifier, titleLineLimit: titleLineLimit)
  }
}

/// The episode row's content lines, in the order the row draws them. Named rather than positional
/// so a reordering is a visible diff and a test can assert the order without rendering `body`.
public enum PodcastEpisodeRowLine: String, Sendable, Hashable, CaseIterable {
  case title
  case metadata
  case synopsis
  case progressCaption
  case progressBar
}
