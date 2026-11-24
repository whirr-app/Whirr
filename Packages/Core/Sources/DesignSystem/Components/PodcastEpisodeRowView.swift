import SwiftUI

/// One podcast episode row. Playback and device transfer are separate textual+symbolic values, so
/// none of the states relies on color alone. Server availability is spoken but never printed.
public struct PodcastEpisodeRowView: View {
  public let title: String
  /// One line of prose under the title: the server's episode subtitle, or the feed description
  /// reduced to plain text. Truncated rather than wrapped: the full text lives in the episode.
  public let synopsis: String?
  public let dateText: String
  public let durationText: String
  public let progressText: String?
  public let playbackProgressFraction: Double?
  public let playbackStatus: PodcastEpisodePlaybackStatus
  public let playbackStatusText: String
  public let serverAvailability: PodcastServerAudioAvailability
  public let serverAvailabilityText: String
  public let deviceStatus: PodcastEpisodeDeviceDownloadStatus
  /// What a tap on the trailing download control does, or `nil` for the states that answer no tap.
  public let downloadAction: MediaContextAction?
  /// The Apple Watch copy, in its own slot before the download control. `nil` for an episode with
  /// no Watch copy and no Watch app.
  public let watchMark: PodcastEpisodeWatchMark?
  /// The screen's cover accent, spent on this row's two marks and nowhere else (no fill, no text).
  /// Nil leaves both on their default ink.
  public let accent: Color?
  /// The episode is being checked for ads now; drawn only while it is downloaded.
  public let isCheckingForAds: Bool
  /// What tapping the row itself does. The caller names it, so the row can say "Opens the
  /// episode." on the show screen and something else elsewhere.
  public let selectionAccessibilityHint: String
  public let contextMenuAccessibilityLabel: String
  public let contextMenuAccessibilityHint: String
  /// Actions grouped exactly as they should appear in the native menu. Both the long-press menu
  /// and the visible ellipsis consume these sections, so their separators cannot drift apart.
  public let contextActionSections: [[MediaContextAction]]
  public var contextActions: [MediaContextAction] { contextActionSections.flatMap { $0 } }
  public let onSelect: () -> Void
  public let onSelectAction: (MediaContextAction) -> Void

  private static let ringDiameter: CGFloat = 20

  #if os(iOS)
    @Environment(\.editMode) private var editMode
  #endif

  private var isSelecting: Bool {
    #if os(iOS)
      editMode?.wrappedValue.isEditing == true
    #else
      false
    #endif
  }
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize

  public init(
    title: String,
    synopsis: String?,
    dateText: String,
    durationText: String,
    progressText: String?,
    playbackProgressFraction: Double?,
    playbackStatus: PodcastEpisodePlaybackStatus,
    playbackStatusText: String,
    serverAvailability: PodcastServerAudioAvailability,
    serverAvailabilityText: String,
    deviceStatus: PodcastEpisodeDeviceDownloadStatus,
    downloadAction: MediaContextAction?,
    watchMark: PodcastEpisodeWatchMark? = nil,
    accent: Color? = nil,
    isCheckingForAds: Bool = false,
    selectionAccessibilityHint: String,
    contextMenuAccessibilityLabel: String,
    contextMenuAccessibilityHint: String,
    contextActionSections: [[MediaContextAction]],
    onSelect: @escaping () -> Void,
    onSelectAction: @escaping (MediaContextAction) -> Void
  ) {
    self.title = title
    self.synopsis = synopsis
    self.dateText = dateText
    self.durationText = durationText
    self.progressText = progressText
    self.playbackProgressFraction = playbackProgressFraction
    self.playbackStatus = playbackStatus
    self.playbackStatusText = playbackStatusText
    self.serverAvailability = serverAvailability
    self.serverAvailabilityText = serverAvailabilityText
    self.deviceStatus = deviceStatus
    self.downloadAction = downloadAction
    self.watchMark = watchMark
    self.accent = accent
    self.isCheckingForAds = isCheckingForAds
    self.selectionAccessibilityHint = selectionAccessibilityHint
    self.contextMenuAccessibilityLabel = contextMenuAccessibilityLabel
    self.contextMenuAccessibilityHint = contextMenuAccessibilityHint
    self.contextActionSections = contextActionSections
    self.onSelect = onSelect
    self.onSelectAction = onSelectAction
  }

  /// Not the screen tint: a blue progress bar is rejected by the design. `textPrimary` is white in
  /// the dark appearance and stays legible in the light one, which a literal `.white` would not.
  public static let progressTint: Color = PlaybackProgressBar.progressTint

  /// Whether this row was handed a cover accent to spend.
  public var usesAccentMarks: Bool { accent != nil }

  /// The bar takes the accent when there is one; `progressTint` is the fallback for a screen
  /// with no palette.
  public var progressBarTint: Color { accent ?? Self.progressTint }

  /// The leading glyph takes the accent only while the episode still has something to offer. A
  /// played one keeps the receding secondary style, since the accent is for what to hear next.
  public var playbackGlyphTint: Color? {
    guard let accent, playbackStatus != .played else { return nil }
    return accent
  }

  public static let surface: MediaContentSurface = .ordinaryContent
  public let isButton = true
  /// The row answers a long press with the same actions its ellipsis button lists. The explicit
  /// button stays: it is the only discoverable and VoiceOver-reachable affordance, and a
  /// `.contextMenu` alone is neither.
  public let presentsActionsOnLongPress = true
  public let selectionMinimumHeight: CGFloat = WhirrMetric.minimumTouchTarget
  public let contextActionMinimumWidth: CGFloat = WhirrMetric.minimumTouchTarget
  public let contextActionMinimumHeight: CGFloat = WhirrMetric.minimumTouchTarget
  public var metadataTexts: [String] { [dateText, durationText] }
  public let synopsisLineLimit = 2
  /// What `body` draws, in order. The row iterates this, so the order asserted in tests is the
  /// order on screen.
  public var contentLines: [PodcastEpisodeRowLine] {
    var lines: [PodcastEpisodeRowLine] = [.title, .metadata]
    if let synopsis, synopsis.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
      lines.append(.synopsis)
    }
    if visiblePlaybackProgressFraction != nil {
      if let progressText, progressText.isEmpty == false { lines.append(.progressCaption) }
      lines.append(.progressBar)
    }
    return lines
  }
  /// A bar means "part way through". Neither end of the range draws one, as the leading glyph
  /// already says as much. A played episode is not at the end of the range when the listener
  /// marked it done partway (the stopped position survives the mark), so the state, not the
  /// fraction alone, closes that end of the range.
  public var visiblePlaybackProgressFraction: Double? {
    guard playbackStatus != .played,
      let fraction = clampedPlaybackProgressFraction, fraction > 0, fraction < 1
    else {
      return nil
    }
    return fraction
  }
  public var clampedPlaybackProgressFraction: Double? {
    playbackProgressFraction.map(PlaybackProgressBar.clamp)
  }
  public var updatesFrequently: Bool { deviceStatus.updatesFrequently }
  /// The status strings the row prints as prose: none. Server availability says nothing an
  /// Audiobookshelf client can contradict, and playback and device state are each one glyph.
  /// All of it still reaches VoiceOver; see `accessibilityValue`.
  public var visibleStatusTexts: [String] { [] }
  /// Progress belongs to a thing in motion. `.completed` carries a fraction of `1`, which would
  /// pin a full-width bar under every downloaded episode.
  public var downloadProgressFraction: Double? {
    guard deviceStatus.kind == .downloading else { return nil }
    return deviceStatus.clampedProgressFraction
  }
  /// The download control is a button when the caller named an action for this state, and an inert
  /// glyph when it did not.
  public var isDownloadControlInteractive: Bool { downloadAction != nil }
  /// The playback state, as one leading glyph instead of a sentence. Distinct in shape per state,
  /// never in colour alone (see `episodeRowGlyphsAreShapeDistinct`).
  public var playbackGlyphSystemImage: String { playbackStatus.systemImage }
  public var essentialTextLineLimit: Int? { layoutValues.essentialTextLineLimit }
  private var layoutValues: MediaRowLayoutValues {
    MediaRowLayoutValues.resolve(isAccessibilitySize: dynamicTypeSize.isAccessibilitySize)
  }
  public var accessibilityLabel: String {
    [title, synopsis]
      .compactMap { value in
        guard let value, value.isEmpty == false else { return nil }
        return value
      }
      .joined(separator: ". ")
  }
  /// The downloaded glyph gives way to the ad check's only while the file is here.
  public var showsCheckingForAds: Bool { isCheckingForAds && deviceStatus.kind == .completed }

  /// The device state as VoiceOver hears it, with the ad check after it.
  public var deviceStatusText: String {
    showsCheckingForAds
      ? "\(deviceStatus.text), \(CheckingForAdsGlyph.accessibilityText)" : deviceStatus.text
  }

  public var accessibilityValue: String {
    [
      dateText, durationText, progressText, playbackStatusText, serverAvailabilityText,
      deviceStatusText, watchMark?.accessibilityText,
    ]
    .compactMap { value in
      guard let value, value.isEmpty == false else { return nil }
      return value
    }
    .joined(separator: ". ")
  }

  public var body: some View {
    Group {
      if isSelecting {
        // The enclosing List owns selection, hit testing, and accessibility selection traits.
        // No nested buttons or playback-state circles compete with its native edit controls.
        rowText
          .frame(maxWidth: .infinity, minHeight: selectionMinimumHeight, alignment: .leading)
          .contentShape(Rectangle())
          .accessibilityElement(children: .ignore)
          .accessibilityLabel(accessibilityLabel)
          .accessibilityValue(accessibilityValue)
      } else if layoutValues.axis == .vertical {
        VStack(alignment: .leading, spacing: WhirrSpacing.xSmall) {
          selectionButton
          HStack(spacing: WhirrSpacing.small) {
            downloadControl.layoutPriority(1)
            contextMenu.layoutPriority(1)
          }
        }
      } else {
        HStack(alignment: .top, spacing: WhirrSpacing.small) {
          selectionButton
          downloadControl.layoutPriority(1)
          contextMenu.layoutPriority(1)
        }
      }
    }
    .padding(.vertical, WhirrSpacing.xSmall)
  }

  private var playbackGlyphStyle: AnyShapeStyle {
    if let playbackGlyphTint { return AnyShapeStyle(playbackGlyphTint) }
    return playbackStatus == .played ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary)
  }

  private var selectionButton: some View {
    Button(action: onSelect) {
      HStack(alignment: .top, spacing: WhirrSpacing.small) {
        Image(systemName: playbackGlyphSystemImage)
          .font(WhirrTypeToken.headline.font)
          .foregroundStyle(playbackGlyphStyle)
          .accessibilityHidden(true)
        rowText
      }
      .frame(maxWidth: .infinity, minHeight: selectionMinimumHeight, alignment: .leading)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(accessibilityLabel)
    .accessibilityValue(accessibilityValue)
    .accessibilityHint(selectionAccessibilityHint)
    .accessibilityAddTraits(
      updatesFrequently
        ? (isButton ? .isButton.union(.updatesFrequently) : .updatesFrequently)
        : (isButton ? .isButton : [])
    )
    // Long press raises the same sectioned list the ellipsis lists, so neither its entries nor its
    // separators can drift apart. Equatable so a caller re-rendering the row on a playhead tick
    // does not rebuild the menu under the listener; see `PodcastEpisodeRowActionMenu`.
    .contextMenu {
      MediaActionMenuItems(
        sections: contextActionSections, onSelectAction: onSelectAction
      )
      .equatable()
    }
  }

  private var rowText: some View {
    VStack(alignment: .leading, spacing: WhirrSpacing.xSmall) {
      ForEach(contentLines, id: \.self) { line in
        contentLine(line)
      }
    }
  }

  @ViewBuilder private func contentLine(_ line: PodcastEpisodeRowLine) -> some View {
    switch line {
    case .title:
      Text(title)
        .font(WhirrTypeToken.headline.font)
        .fixedSize(horizontal: false, vertical: true)
    case .metadata:
      metadataText
        .font(WhirrTypeToken.caption.font)
        .foregroundStyle(WhirrColorToken.textSecondary.color)
        .fixedSize(horizontal: false, vertical: true)
    case .synopsis:
      // The one place truncation is right: the full text belongs to the episode, not the row.
      Text(synopsis ?? "")
        .font(WhirrTypeToken.body.font)
        .foregroundStyle(WhirrColorToken.textSecondary.color)
        .lineLimit(synopsisLineLimit)
    case .progressCaption:
      Text(progressText ?? "")
        .font(WhirrTypeToken.caption.font)
        .foregroundStyle(WhirrColorToken.textSecondary.color)
        .fixedSize(horizontal: false, vertical: true)
    case .progressBar:
      PlaybackProgressBar(fraction: visiblePlaybackProgressFraction ?? 0, tint: progressBarTint)
    }
  }

  /// The date and duration, led by the Apple Watch mark when the episode has a Watch copy. Inline
  /// rather than a trailing slot, so the mark appearing never narrows the title. Delivered is
  /// primary ink and pending secondary; VoiceOver reads it as its own phrase in the row's value.
  private var metadataText: Text {
    let metadata = metadataTexts.joined(separator: " · ")
    guard let watchMark else { return Text(metadata) }
    return watchMark.leading(metadata)
  }

  /// The device-transfer state, as one trailing control. A tap performs the state's single primary
  /// action; the destructive and secondary ones stay behind the ellipsis, where they need a
  /// deliberate second gesture.
  @ViewBuilder private var downloadControl: some View {
    if let downloadAction {
      Button {
        onSelectAction(downloadAction)
      } label: {
        downloadControlGlyph
      }
      .buttonStyle(.plain)
      .accessibilityLabel(
        showsCheckingForAds
          ? "\(downloadAction.label), \(CheckingForAdsGlyph.accessibilityText)" : downloadAction.label
      )
      .accessibilityHint(downloadAction.hint)
    } else {
      downloadControlGlyph
        .accessibilityLabel(deviceStatusText)
    }
  }

  /// An indeterminate spinner is used until an RSS transfer has a declared total. A determinate
  /// ring is used once bytes can be measured; iOS has no determinate circular `ProgressView`, so
  /// that ring is drawn rather than styled.
  @ViewBuilder private var downloadControlGlyph: some View {
    Group {
      if deviceStatus.isIndeterminate {
        ProgressView()
          .progressViewStyle(.circular)
          .frame(width: Self.ringDiameter, height: Self.ringDiameter)
      } else if let downloadProgressFraction {
        DownloadProgressRing(
          progressFraction: downloadProgressFraction,
          systemImage: nil
        )
        .frame(width: Self.ringDiameter, height: Self.ringDiameter)
      } else if showsCheckingForAds {
        CheckingForAdsGlyph()
          .font(WhirrTypeToken.headline.font)
      } else {
        Image(systemName: deviceStatus.systemImage)
          .font(WhirrTypeToken.headline.font)
      }
    }
    .frame(
      minWidth: contextActionMinimumWidth,
      minHeight: contextActionMinimumHeight
    )
    .contentShape(Rectangle())
  }

  @ViewBuilder private var contextMenu: some View {
    if contextActions.isEmpty == false {
      PodcastEpisodeRowActionMenu(
        sections: contextActionSections,
        accessibilityLabel: contextMenuAccessibilityLabel,
        accessibilityHint: contextMenuAccessibilityHint,
        minimumWidth: contextActionMinimumWidth,
        minimumHeight: contextActionMinimumHeight,
        onSelectAction: onSelectAction
      )
      .equatable()
    }
  }
}
