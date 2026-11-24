import AppModel
import DesignSystem
import Foundation
import SyncEngine

/// What selecting one row of the shared item menu does: a `MediaItemAction`, or one choice inside
/// a submenu. `id` is the `MediaContextAction.id` the row carries, so the menu dispatches on the
/// value `MediaActionMenuItems` hands back, with no second table of closures to keep in step.
enum ItemMenuSelection: Equatable {
  case action(MediaItemAction)
  case downloadFormat(ItemDownloadFormat)
  case sendToEreader(deviceName: String)
  case creatorLink
  case narratorLink
  /// The screen's own `ItemMenuClosingAction`, drawn as the menu's last row.
  case closingAction
  /// A book's send past the Watch's last reported free space, confirmed in its submenu.
  case sendToWatchAnyway

  private static let devicePrefix = "send-to-ereader.device:"

  var id: String {
    switch self {
    case .action(let action): action.actionID
    case .downloadFormat(.audio): "download.audio"
    case .downloadFormat(.ebook): "download.ebook"
    case .downloadFormat(.both): "download.both"
    case .sendToEreader(let deviceName): Self.devicePrefix + deviceName
    case .creatorLink: "more-from.creator"
    case .narratorLink: "more-from.narrator"
    case .closingAction: "closing-action"
    case .sendToWatchAnyway: "send-to-watch.anyway"
    }
  }

  init?(id: String) {
    if let action = MediaItemAction(actionID: id) {
      self = .action(action)
    } else if id.hasPrefix(Self.devicePrefix) {
      self = .sendToEreader(deviceName: String(id.dropFirst(Self.devicePrefix.count)))
    } else {
      switch id {
      case "download.audio": self = .downloadFormat(.audio)
      case "download.ebook": self = .downloadFormat(.ebook)
      case "download.both": self = .downloadFormat(.both)
      case "more-from.creator": self = .creatorLink
      case "more-from.narrator": self = .narratorLink
      case "closing-action": self = .closingAction
      case "send-to-watch.anyway": self = .sendToWatchAnyway
      default: return nil
      }
    }
  }
}

extension ItemContextMenuPresentation {
  /// Everything the presented menu resolved for one item, so its rows are a pure function a test
  /// can call. Built in the menu's own body, never on the scroll path: `playback` reads the player.
  struct RowContext: Equatable {
    /// An episode downloads in one step; a book picks a format.
    var isEpisode: Bool
    var playback: PlaybackButton
    /// A removal in flight: the coarse presence reports only `.unavailable`.
    var isDownloadInert = false
    var downloadFormats: [ItemDownloadFormat] = []
    var delivery: EbookDeliveryMenuEntry? = nil
    var sendingDeviceNames: Set<String> = []
    var creatorLabel: String? = nil
    /// `nil` where the menu offers no narrator link.
    var narratorLabel: String? = nil
    var usesEbookProgress = false
    /// A book's send larger than the Watch's last reported free space: the question it asks first.
    var bookWatchOversizedMessage: String? = nil
  }

  /// The menu's sections as rows, an action with nothing to draw leaving no empty section behind.
  /// Progress entries fold into one submenu (`MediaItemMenuLayout`). A screen's own closing action
  /// joins a trailing removal section rather than sitting under a divider of its own.
  static func menuSections(
    _ sections: [MediaItemActionSection], context: RowContext, closing: MediaContextAction? = nil
  ) -> [[MediaContextAction]] {
    var drawn = sections.compactMap { section -> (MediaItemMenuSection, [MediaContextAction])? in
      let rows = foldedRows(
        section.actions.compactMap { action in row(action, context: context).map { (action, $0) } })
      return rows.isEmpty ? nil : (section.kind, rows)
    }
    if let closing {
      if drawn.last?.0 == .destructive {
        drawn[drawn.count - 1].1.append(closing)
      } else {
        drawn.append((.destructive, [closing]))
      }
    }
    return drawn.map(\.1)
  }

  /// One section's rows with `MediaItemMenuLayout`'s folds applied, for every renderer that
  /// draws `MediaContextAction`s: this menu, the show page's rows, and the episode card.
  nonisolated static func foldedRows(
    _ rows: [(action: MediaItemAction, row: MediaContextAction)]
  ) -> [MediaContextAction] {
    // A queue action takes its compact title only inside the group: a lone row keeps its own.
    MediaItemMenuLayout.fold(
      rows, key: { MediaItemMenuLayout.fold(for: $0.action) },
      make: { fold, members in
        switch fold {
        case .controlGroup:
          let children = members.map { member in
            member.row.withCompactLabel(MediaItemMenuLayout.compactTitle(for: member.action))
          }
          return (
            action: members[0].action,
            row: MediaContextAction(
              id: fold.id, label: "", hint: "", systemImage: "", children: children,
              childrenStyle: .controlGroup)
          )
        case .submenu(let submenu):
          return (
            action: members[0].action,
            row: MediaContextAction(
              id: fold.id, label: submenu.label.title, hint: "",
              systemImage: submenu.label.systemImage, children: members.map(\.row))
          )
        }
      }
    ).map(\.row)
  }

  /// A screen's `ItemMenuClosingAction` as a row; its closure stays with the menu that runs it.
  static func closingRow(_ closing: ItemMenuClosingAction) -> MediaContextAction {
    MediaContextAction(
      id: ItemMenuSelection.closingAction.id, label: closing.title, hint: "",
      systemImage: closing.systemImage, role: .destructive, isEnabled: closing.isDisabled == false)
  }

  /// One action's row. Long-press rows carry no hint, as they never have; the show page's rows,
  /// which do, are `PodcastShowViewPresentation.contextAction`. `ItemMenuCopyConsistencyTests` holds
  /// the two to the same titles and glyphs.
  static func row(_ action: MediaItemAction, context: RowContext) -> MediaContextAction? {
    switch action {
    case .playPause:
      return row(.action(.playPause), context.playback.title, context.playback.systemImage)
    case .playNext:
      return row(.action(.playNext), queueEntry(.playNext))
    case .addToUpNext:
      return row(.action(.addToUpNext), queueEntry(.addToUpNext))
    case .saveForLater, .removeFromSaved:
      return row(.action(action), savedEntry(isSaved: action == .removeFromSaved))
    case .download:
      return downloadRow(context)
    // Unreachable here: `podcastEpisodeSections` explains why the coarse presence this menu reads
    // never produces them.
    case .pauseDownload, .resumeDownload:
      return nil
    case .removeDownload:
      return context.isDownloadInert
        ? row(.action(.removeDownload), removingDownloadEntry, isEnabled: false)
        : row(.action(.removeDownload), removeDownloadEntry)
    case .markAsFinished:
      return row(.action(action), progressEntry(.markAsFinished))
    case .resetProgress:
      return row(.action(action), progressEntry(.resetProgress))
    case .removeFromContinueListening:
      let entry = progressEntry(
        .removeFromContinueListening, usesEbookProgress: context.usesEbookProgress)
      return MediaContextAction(
        id: ItemMenuSelection.action(action).id, label: entry.title, hint: "",
        systemImage: entry.systemImage,
        accessibilityIdentifier: HomeAccessibilityID.removeFromContinueListeningAction)
    // Server saves are the show page's and the episode card's, which hold the save state.
    case .saveToServer, .removeFromServer:
      return nil
    case .openShow:
      return row(.action(.openShow), viewEpisodesEntry)
    case .moreFromCreator:
      return creatorRow(context)
    case .transcript:
      return row(.action(.transcript), MenuEntry(MediaActionCopy.transcript))
    case .sendToWatch:
      return context.isEpisode
        ? row(.action(.sendToWatch), MenuEntry(MediaActionCopy.sendToWatch))
        : bookWatchRow(.sendToWatch, context)
    case .removeFromWatch:
      return context.isEpisode
        ? row(.action(.removeFromWatch), MenuEntry(MediaActionCopy.removeFromWatch))
        : bookWatchRow(.removeFromWatch, context)
    case .read:
      return row(.action(.read), readButton)
    case .moreFrom:
      return moreFromRow(context)
    case .sendToEreader:
      return sendToEreaderRow(context)
    case .viewDetails:
      return row(.action(.viewDetails), viewDetailsEntry)
    }
  }

  /// A book's Watch pair keeps its own IDs and hints. A send larger than the Watch's last
  /// reported free space asks first, as a submenu naming both sizes: a menu row cannot
  /// raise an alert of its own once the menu has closed.
  private static func bookWatchRow(
    _ action: MediaItemAction, _ context: RowContext
  ) -> MediaContextAction {
    let entry = action == .sendToWatch ? BookWatchPresentation.send : BookWatchPresentation.remove
    guard action == .sendToWatch, let question = context.bookWatchOversizedMessage else {
      return MediaContextAction(
        id: ItemMenuSelection.action(action).id, label: entry.label, hint: entry.hint,
        systemImage: entry.systemImage, accessibilityIdentifier: entry.id)
    }
    let sendAnyway = MediaContextAction(
      id: ItemMenuSelection.sendToWatchAnyway.id, label: BookWatchPresentation.sendAnyway,
      hint: entry.hint, systemImage: entry.systemImage)
    return MediaContextAction(
      id: ItemMenuSelection.action(action).id, label: entry.label, hint: "",
      systemImage: entry.systemImage, children: [sendAnyway], childrenTitle: question,
      accessibilityIdentifier: entry.id)
  }

  /// A mixed audiobook and EPUB asks which format; every other item downloads its one format
  /// without asking. An episode has one step and no format.
  private static func downloadRow(_ context: RowContext) -> MediaContextAction? {
    if context.isEpisode {
      return row(.action(.download), downloadEntry)
    }
    switch context.downloadFormats.count {
    case 0:
      return nil
    case 1:
      return row(.downloadFormat(context.downloadFormats[0]), downloadEntry)
    default:
      return submenu(
        .action(.download), downloadEntry,
        children: context.downloadFormats.map { row(.downloadFormat($0), downloadFormatEntry($0)) })
    }
  }

  /// Author and narrator are two routes into the same discovery task, so both together share one
  /// "More from…" row rather than spend two of the menu's rows on secondary navigation.
  private static func moreFromRow(_ context: RowContext) -> MediaContextAction? {
    let creator = creatorRow(context)
    let narrator = context.narratorLabel.map { label in
      MediaContextAction(
        id: ItemMenuSelection.narratorLink.id, label: label, hint: "", systemImage: "waveform",
        titleLineLimit: 1)
    }
    guard let creator, let narrator else { return creator ?? narrator }
    return submenu(
      .action(.moreFrom), MenuEntry(MediaActionCopy.moreFrom), children: [creator, narrator])
  }

  /// A long author or publisher name is the one title here that could wrap a row onto a second
  /// line, so it truncates instead.
  private static func creatorRow(_ context: RowContext) -> MediaContextAction? {
    context.creatorLabel.map { label in
      MediaContextAction(
        id: ItemMenuSelection.creatorLink.id, label: label, hint: "",
        systemImage: context.isEpisode ? "dot.radiowaves.left.and.right" : "person",
        titleLineLimit: 1)
    }
  }

  /// One device is one row; several are a submenu of the server's own labels, in server order.
  private static func sendToEreaderRow(_ context: RowContext) -> MediaContextAction? {
    func device(_ name: String, label: String, systemImage: String) -> MediaContextAction {
      MediaContextAction(
        id: ItemMenuSelection.sendToEreader(deviceName: name).id, label: label, hint: "",
        systemImage: systemImage, isEnabled: context.sendingDeviceNames.contains(name) == false)
    }
    switch context.delivery {
    case .single(let only):
      return device(
        only.name, label: EbookDeliveryCopy.sendTo(only.name),
        systemImage: EbookDeliveryCopy.systemImage)
    case .submenu(let devices):
      return submenu(
        .action(.sendToEreader),
        MenuEntry(title: EbookDeliveryCopy.submenuTitle, systemImage: EbookDeliveryCopy.systemImage),
        children: devices.map { device($0.name, label: $0.name, systemImage: "") })
    case nil:
      return nil
    }
  }

  private static func row(
    _ selection: ItemMenuSelection, _ entry: MenuEntry, isEnabled: Bool = true
  ) -> MediaContextAction {
    MediaContextAction(
      id: selection.id, label: entry.title, hint: "", systemImage: entry.systemImage,
      role: entry.role, isEnabled: isEnabled)
  }

  private static func row(
    _ selection: ItemMenuSelection, _ title: String, _ systemImage: String
  ) -> MediaContextAction {
    MediaContextAction(id: selection.id, label: title, hint: "", systemImage: systemImage)
  }

  private static func row(_ selection: ItemMenuSelection, _ entry: QueueEntry) -> MediaContextAction {
    row(selection, entry.title, entry.systemImage)
  }

  private static func submenu(
    _ selection: ItemMenuSelection, _ entry: MenuEntry, children: [MediaContextAction]
  ) -> MediaContextAction {
    MediaContextAction(
      id: selection.id, label: entry.title, hint: "", systemImage: entry.systemImage,
      children: children)
  }
}
