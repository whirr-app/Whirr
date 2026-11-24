import Foundation
import WatchPlayback
import WatchProtocol

@main
struct HomeProjectionRegression {
  static func main() throws {
    let stamp = try WatchAccountStamp(accountIdentityHash: "watch-account", serverIdentityHash: "server")
    let catalogueStamp = try WatchAccountStamp(accountIdentityHash: "phone-catalogue", serverIdentityHash: "server")
    let other = try WatchAccountStamp(accountIdentityHash: "other-account", serverIdentityHash: "server")
    func selection(_ id: String) -> WatchSelection { .audiobookshelf(itemID: id, episodeID: nil) }
    func phone(_ id: String, selection sel: WatchSelection? = nil, current: Bool = false) throws
      -> WatchCatalogueItem
    {
      try WatchCatalogueItem(
        id: id, selection: sel ?? selection(id), title: id, isCurrentPlayback: current,
        capabilities: WatchSelectionCapabilities(phonePlayable: true, watchPlayable: true))
    }
    func watch(_ id: String, duration: Double? = 100, episode: String? = nil) -> WatchContinueItem {
      WatchContinueItem(
        id: id, selection: .audiobookshelf(itemID: id, episodeID: episode), progressSeconds: 10,
        durationSeconds: duration, isFinished: false, lastUpdate: nil)
    }
    let rows = try [phone("current", current: true), phone("shared"), phone("phone")]
    func snapshot(_ authenticated: WatchAccountStamp?, items: [WatchCatalogueItem] = rows) throws
      -> WatchCatalogueSnapshot
    {
      try WatchCatalogueSnapshot(
        accountStamp: catalogueStamp, items: items, authenticatedAccountStamp: authenticated)
    }
    let continued = [watch("current"), watch("shared"), watch("local"), watch("extra")]
    func projection(
      _ scope: WatchHomeProjection.Scope, authenticated: WatchAccountStamp? = nil,
      localStamp: WatchAccountStamp? = nil, current: WatchSelection? = nil,
      items: [WatchCatalogueItem] = rows
    ) throws -> WatchHomeProjection {
      WatchHomeProjection(
        snapshot: try snapshot(authenticated, items: items), continued: continued,
        watchAccountStamp: localStamp, currentSelection: current, scope: scope)
    }
    let home = try projection(.home, authenticated: stamp, localStamp: stamp)
    precondition(home.phone.map(\.id) == ["shared", "phone"])
    precondition(home.watch.map(\.id) == ["local"] && home.watchAccountStamp == stamp)
    let localCurrent = try projection(.home, authenticated: stamp, localStamp: stamp, current: selection("shared"))
    precondition(localCurrent.phone.map(\.id) == ["phone"])
    precondition(localCurrent.watch.map(\.id) == ["current", "local"])
    let full = try projection(.continueListening(audiobooksOnly: false), authenticated: stamp, localStamp: stamp)
    // The full list keeps the phone's current title, where it can be downloaded or moved to the
    // Watch, so the Watch's own row for it is deduplicated away.
    precondition(full.phone.map(\.id) == ["current", "shared", "phone"])
    precondition(full.watch.map(\.id) == ["local", "extra"])
    // Deduplication keys on selection, not row ID; the full list keeps the current selection and
    // every phone row, while Home limits the combined preview to three rows.
    let wideRows = try [
      phone("current", current: true), phone("shared"), phone("alias", selection: selection("local")),
      phone("phone"), phone("more"), phone("last"),
    ]
    let wide = try projection(
      .continueListening(audiobooksOnly: false), authenticated: stamp, localStamp: stamp,
      current: selection("phone"), items: wideRows)
    precondition(wide.phone.map(\.id) == ["current", "shared", "alias", "phone", "more", "last"])
    precondition(wide.watch.map(\.id) == ["extra"])
    let wideHome = try projection(
      .home, authenticated: stamp, localStamp: stamp, current: selection("phone"), items: wideRows)
    precondition(wideHome.phone.map(\.id) == ["shared", "alias", "more"])
    precondition(wideHome.watch.isEmpty && !wideHome.showsWatchSection)
    let wideOther = try projection(
      .continueListening(audiobooksOnly: false), authenticated: other, localStamp: stamp, items: wideRows)
    precondition(wideOther.phone.count == 6 && wideOther.watch.isEmpty && !wideOther.showsWatchSection)
    let mismatch = try projection(.home, authenticated: other, localStamp: stamp)
    precondition(mismatch.watch.isEmpty && !mismatch.showsWatchSection && !mismatch.isEmpty)
    let unauthenticated = try projection(.home)
    precondition(unauthenticated.watch.isEmpty && !unauthenticated.showsWatchSection)
    let offline = WatchHomeProjection(
      snapshot: nil, continued: continued, watchAccountStamp: stamp, currentSelection: selection("current"),
      scope: .home)
    precondition(offline.phone.isEmpty && offline.watch.map(\.id) == ["shared", "local", "extra"])
    let noPhoneContinue = WatchHomeProjection(
      snapshot: try WatchCatalogueSnapshot(accountStamp: catalogueStamp, items: [], authenticatedAccountStamp: other),
      continued: continued, watchAccountStamp: stamp, currentSelection: nil, scope: .home)
    precondition(noPhoneContinue.watch.count == 3 && noPhoneContinue.showsWatchSection)
    let books = WatchHomeProjection(
      snapshot: nil,
      continued: [
        watch("book"), watch("unknown", duration: nil), watch("zero", duration: 0),
        watch("show", episode: "episode"),
      ],
      watchAccountStamp: stamp, currentSelection: nil, scope: .continueListening(audiobooksOnly: true))
    precondition(books.watch.map(\.id) == ["book"])
    let reset = WatchContinueItem(
      id: "reset", selection: selection("reset"), progressSeconds: 0, durationSeconds: 100,
      isFinished: false, lastUpdate: nil)
    for scope in [WatchHomeProjection.Scope.home, .continueListening(audiobooksOnly: false)] {
      let filtered = WatchHomeProjection(
        snapshot: nil, continued: [reset, watch("ebook", duration: nil), watch("audio")],
        watchAccountStamp: stamp, currentSelection: nil, scope: scope)
      precondition(filtered.watch.map(\.id) == ["audio"])
      let cleared = WatchHomeProjection(
        snapshot: nil, continued: [reset, watch("ebook", duration: nil)],
        watchAccountStamp: stamp, currentSelection: nil, scope: scope)
      precondition(cleared.isEmpty && !cleared.showsWatchSection)
    }
    let empty = WatchHomeProjection(
      snapshot: nil, continued: [], watchAccountStamp: nil, currentSelection: nil, scope: .home)
    precondition(empty.isEmpty)
    nativeContinueRows()
    print("Watch Continue projection: account fences, deduplication, preview, current playback and book filters passed")
  }

  /// A ready copy with a listen in progress joins the Watch rows, under the same account rule as an
  /// ABS row. A copy never played and a finished one stay out; the phone's own rows are unchanged.
  private static func nativeContinueRows() {
    let stamp = try! WatchAccountStamp(accountIdentityHash: "watch-account", serverIdentityHash: "server")
    let catalogueStamp = try! WatchAccountStamp(accountIdentityHash: "phone-catalogue", serverIdentityHash: "server")
    let other = try! WatchAccountStamp(accountIdentityHash: "other-account", serverIdentityHash: "server")
    func native(
      _ id: String, position: Double = 50, duration: Double = 100, finished: Bool = false
    ) -> WatchNativeContinueItem {
      WatchNativeContinueItem(
        selection: .nativeFeed(feedID: "feed", episodeID: id), title: "Episode " + id, showTitle: "Show",
        progressSeconds: position, durationSeconds: duration, isFinished: finished)
    }
    func book(_ id: String) -> WatchContinueItem {
      WatchContinueItem(
        id: id, selection: .audiobookshelf(itemID: id, episodeID: nil), progressSeconds: 10,
        durationSeconds: 100, isFinished: false, lastUpdate: nil)
    }
    func phoneRow(_ id: String, current: Bool = false) throws -> WatchCatalogueItem {
      try WatchCatalogueItem(
        id: id, selection: .audiobookshelf(itemID: id, episodeID: nil), title: id, isCurrentPlayback: current,
        capabilities: WatchSelectionCapabilities(phonePlayable: true, watchPlayable: true))
    }

    // The phone is away: the copy the listener started resumes beside the Watch's own rows.
    let away = WatchHomeProjection(
      snapshot: nil, continued: [], nativeContinued: [native("inProgress")], watchAccountStamp: stamp,
      currentSelection: nil, scope: .home)
    precondition(away.native.map(\.title) == ["Episode inProgress"])
    precondition(away.showsWatchSection && !away.isEmpty)

    // Never played, or finished, is not a resume point.
    for row in [native("unplayed", position: 0), native("finished", finished: true)] {
      let filtered = WatchHomeProjection(
        snapshot: nil, continued: [], nativeContinued: [row], watchAccountStamp: stamp,
        currentSelection: nil, scope: .home)
      precondition(filtered.native.isEmpty && !filtered.showsWatchSection && filtered.isEmpty)
    }

    // A phone showing another account's rows keeps its list, and the Watch section stays hidden.
    let otherPhone = try! WatchCatalogueSnapshot(
      accountStamp: catalogueStamp, items: [phoneRow("phone", current: true)], authenticatedAccountStamp: other)
    let hidden = WatchHomeProjection(
      snapshot: otherPhone, continued: [], nativeContinued: [native("inProgress")], watchAccountStamp: stamp,
      currentSelection: nil, scope: .continueListening(audiobooksOnly: false))
    precondition(hidden.phone.map(\.id) == ["phone"] && hidden.native.isEmpty && !hidden.showsWatchSection)

    // Home's three-row preview counts the native rows with the phone's and the Watch's.
    let mixed = WatchHomeProjection(
      snapshot: nil, continued: [book("local")],
      nativeContinued: [native("a"), native("b"), native("c")], watchAccountStamp: stamp,
      currentSelection: nil, scope: .home)
    precondition(mixed.watch.map(\.id) == ["local"])
    precondition(mixed.native.map(\.title) == ["Episode a", "Episode b"])

    // The full list has no preview limit, and the current title is left out of both.
    let full = WatchHomeProjection(
      snapshot: nil, continued: [book("local")], nativeContinued: [native("a"), native("b")],
      watchAccountStamp: stamp, currentSelection: nil,
      scope: .continueListening(audiobooksOnly: false))
    precondition(full.watch.map(\.id) == ["local"] && full.native.count == 2)
    let current = WatchHomeProjection(
      snapshot: nil, continued: [book("local")], nativeContinued: [native("a")], watchAccountStamp: stamp,
      currentSelection: native("a").selection, scope: .home)
    precondition(current.native.isEmpty && current.watch.map(\.id) == ["local"])

    // The Audiobooks-only list keeps its book scope.
    let books = WatchHomeProjection(
      snapshot: nil, continued: [], nativeContinued: [native("a")], watchAccountStamp: stamp,
      currentSelection: nil, scope: .continueListening(audiobooksOnly: true))
    precondition(books.native.isEmpty && books.isEmpty)
  }
}
