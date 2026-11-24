/// How an item menu's sections become top-level rows.
///
/// One rule set for every item menu, so the shape changes in one place: entries that share a fold
/// become one element when two or more of them apply, and a single one stays a plain row, since a
/// group of one costs space or a tap and saves nothing.
///
/// - Play/Pause, Play Next and Add to Up Next become one horizontal `ControlGroup` row at the top,
///   as Apple Music draws its queue actions (an owner decision).
/// - The progress entries fold into the "Progress" submenu.
/// - Navigation never folds: Transcript and Look Back are frequent actions and stay top-level rows
///   in every menu that offers them.
public enum MediaItemMenuLayout {
  public enum Submenu: Sendable, Equatable, Hashable, CaseIterable {
    /// Mark as Finished, Reset Progress, and Remove from Continue Listening.
    case progress

    /// The row identifier of the submenu's parent, which is never dispatched.
    public var id: String {
      switch self {
      case .progress: "submenu.progress"
      }
    }

    public var label: MediaActionLabel {
      switch self {
      case .progress: MediaActionCopy.progress
      }
    }
  }

  /// How a run of entries is drawn as one element.
  public enum Fold: Sendable, Equatable, Hashable {
    /// One horizontal row of buttons, each still its own action. It has no title of its own.
    case controlGroup
    case submenu(Submenu)

    /// The identifier of the element that holds the run, which is never dispatched.
    public var id: String {
      switch self {
      case .controlGroup: "group.queue"
      case .submenu(let submenu): submenu.id
      }
    }
  }

  /// The shorter title `action` takes inside the control group, if its own title would wrap there.
  public static func compactTitle(for action: MediaItemAction) -> String? {
    switch action {
    case .addToUpNext: MediaActionCopy.addToUpNext.compactTitle
    default: nil
    }
  }

  /// The fewest entries that fold together.
  public static let minimumFoldEntries = 2

  /// The fold `action` belongs to, if any. Every case is named so a new action has to decide.
  public static func fold(for action: MediaItemAction) -> Fold? {
    switch action {
    case .playPause, .playNext, .addToUpNext:
      .controlGroup
    case .markAsFinished, .resetProgress, .removeFromContinueListening:
      .submenu(.progress)
    case .read, .saveForLater, .removeFromSaved, .openShow, .moreFromCreator, .moreFrom,
      .viewDetails, .transcript, .download, .pauseDownload, .resumeDownload, .sendToWatch,
      .removeFromWatch, .saveToServer, .sendToEreader, .removeDownload, .removeFromServer:
      nil
    }
  }

  /// One section's rows with each run of the same key's entries folded into one row, at the
  /// position of its first entry. Generic over the row and the key so every renderer, whatever
  /// value it draws, shares the rule.
  public static func fold<Row, Key: Equatable>(
    _ rows: [Row], key: (Row) -> Key?, make: (Key, [Row]) -> Row
  ) -> [Row] {
    var folded: [Row] = []
    var index = rows.startIndex
    while index < rows.endIndex {
      guard let kind = key(rows[index]) else {
        folded.append(rows[index])
        index += 1
        continue
      }
      var end = index + 1
      while end < rows.endIndex, key(rows[end]) == kind { end += 1 }
      let members = Array(rows[index..<end])
      if members.count >= minimumFoldEntries {
        folded.append(make(kind, members))
      } else {
        folded += members
      }
      index = end
    }
    return folded
  }

  /// `fold` for rows that still carry the `MediaItemAction` they draw.
  public static func fold<Row>(
    _ rows: [(action: MediaItemAction, row: Row)], make: (Fold, [Row]) -> Row
  ) -> [Row] {
    fold(
      rows, key: { Self.fold(for: $0.action) },
      make: { kind, members in
        (action: members[0].action, row: make(kind, members.map(\.row)))
      }
    ).map(\.row)
  }
}
