import WatchPlayback
import WatchProtocol

/// One received native-RSS episode that has a listen in progress on the Watch. Built by the
/// library model from the copy's journal, so the projection itself needs no store or actor.
struct WatchNativeContinueItem: Equatable, Identifiable {
  let selection: WatchSelection
  let title: String
  let showTitle: String
  let progressSeconds: Double
  let durationSeconds: Double
  let isFinished: Bool

  var id: WatchSelection { selection }

  /// Played a little and not finished: the only state that resumes. A copy never played stays in
  /// On My Watch instead.
  var isResumable: Bool {
    guard !isFinished, progressSeconds.isFinite, progressSeconds > 0,
      durationSeconds.isFinite, durationSeconds > 0
    else { return false }
    return progressSeconds < durationSeconds
  }
}

/// Shared account-fenced Continue rows. Watch rows require an audio resume point; Home keeps
/// its three-row preview and current-item exclusion, and the full list keeps its book scope.
struct WatchHomeProjection {
  enum Scope {
    case home
    case continueListening(audiobooksOnly: Bool)
  }

  let phone: [WatchCatalogueItem]
  let watch: [WatchContinueItem]
  /// In-progress copies the phone sent, shown with the Watch rows under the same rule.
  let native: [WatchNativeContinueItem]
  let watchAccountStamp: WatchAccountStamp?
  let showsWatchSection: Bool
  let isEmpty: Bool

  init(
    snapshot: WatchCatalogueSnapshot?, continued: [WatchContinueItem],
    nativeContinued: [WatchNativeContinueItem] = [],
    watchAccountStamp: WatchAccountStamp?, currentSelection: WatchSelection?, scope: Scope
  ) {
    self.watchAccountStamp = watchAccountStamp
    let limit: Int?
    let audiobooksOnly: Bool
    switch scope {
    case .home:
      limit = 3
      audiobooksOnly = false
    case .continueListening(let books):
      limit = nil
      audiobooksOnly = books
    }
    let current = currentSelection ?? snapshot?.items.first(where: \.isCurrentPlayback)?.selection
    let phoneRows =
      snapshot?.items.filter {
        // Home shows the current title in its own card; the full list keeps it, because its
        // detail page is where the title can be downloaded or moved to the Watch.
        $0.section == .continueListening
          && (limit == nil || (!$0.isCurrentPlayback && $0.selection != current))
          && (!audiobooksOnly || WatchNavigationPolicy.isBook($0.selection))
      } ?? []
    let phone = Array(phoneRows.prefix(limit ?? phoneRows.count))
    self.phone = phone
    let sameAccount = watchAccountStamp != nil && watchAccountStamp == snapshot?.authenticatedAccountStamp
    let phoneSelections = Set(phone.map(\.selection))
    let watchRows = continued.filter {
      $0.isResumableAudio && (limit == nil || $0.selection != current)
        && (!sameAccount || !phoneSelections.contains($0.selection))
        && (!audiobooksOnly || WatchNavigationPolicy.isBook($0.selection))
    }
    // A native copy is only playable here, so it joins the Watch rows rather than the phone's.
    let nativeRows = nativeContinued.filter {
      $0.isResumable && (limit == nil || $0.selection != current)
        && (!sameAccount || !phoneSelections.contains($0.selection))
        && (!audiobooksOnly || WatchNavigationPolicy.isBook($0.selection))
    }
    let watchSlots = limit.map { max(0, $0 - phone.count) } ?? watchRows.count
    let limitedWatch = Array(watchRows.prefix(watchSlots))
    let nativeSlots = limit.map { max(0, $0 - phone.count - limitedWatch.count) } ?? nativeRows.count
    let limitedNative = Array(nativeRows.prefix(nativeSlots))
    showsWatchSection = (phone.isEmpty || sameAccount) && !(limitedWatch.isEmpty && limitedNative.isEmpty)
    watch = showsWatchSection ? limitedWatch : []
    native = showsWatchSection ? limitedNative : []
    isEmpty = phone.isEmpty && watch.isEmpty && native.isEmpty
  }
}
