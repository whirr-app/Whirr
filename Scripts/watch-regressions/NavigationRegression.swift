import Foundation
import WatchPlayback
import WatchProtocol

@main
struct NavigationRegression {
  static func main() {
    let libraries = [
      WatchLibrary(id: "books", name: "Books", mediaType: "book"),
      WatchLibrary(id: "shows", name: "Shows", mediaType: "podcast"),
      WatchLibrary(id: "second", name: "More Books", mediaType: "book"),
    ]
    precondition(WatchNavigationPolicy.selectedLibrary(libraries, preferred: "books", mediaType: .podcast) == "shows")
    precondition(WatchNavigationPolicy.selectedLibrary(libraries, preferred: "shows", mediaType: .book) == "books")
    precondition(WatchNavigationPolicy.selectedLibrary(libraries, preferred: "second", mediaType: .book) == "second")
    precondition(WatchNavigationPolicy.selectedLibrary([], preferred: "books", mediaType: .book) == nil)
    precondition(WatchNavigationPolicy.libraries(libraries, mediaType: .podcast).map(\.id) == ["shows"])
    precondition(WatchNavigationPolicy.isBook(.audiobookshelf(itemID: "book", episodeID: nil)))
    precondition(!WatchNavigationPolicy.isBook(.audiobookshelf(itemID: "show", episodeID: "episode")))
    precondition(!WatchNavigationPolicy.isBook(.nativeFeed(feedID: "feed", episodeID: "episode")))
    itemActionsRespectAvailableDevices()
    onlyConfirmedSelectedPlaybackOpensPlayer()
    loadedTitleReadsAsPlaying()
    downloadedTitleOffersRemoval()
    followedOnIPhoneNeedsAPhoneThatOffersIt()
    print("Watch navigation: media scope, item actions and confirmed player presentation passed")
  }

  /// Followed shows play only on the iPhone, so the entry needs a reachable, signed-in phone that
  /// says its followed podcasts are on. An older phone says nothing and gets no entry.
  private static func followedOnIPhoneNeedsAPhoneThatOffersIt() {
    func offers(_ reachable: Bool, _ signedIn: Bool, _ enabled: Bool?) -> Bool {
      WatchNavigationPolicy.offersFollowedOnIPhone(
        phoneReachable: reachable, phoneSignedIn: signedIn, followedPodcastsEnabled: enabled)
    }
    precondition(offers(true, true, true))
    for (reachable, signedIn, enabled) in [
      (false, true, true), (true, false, true), (true, true, false), (true, true, nil),
    ] as [(Bool, Bool, Bool?)] {
      precondition(!offers(reachable, signedIn, enabled))
    }

    // Followed lists keep their own stored filter; ABS lists keep the key they had before sources.
    precondition(WatchNavigationPolicy.podcastListPreferenceKey(base: "k", source: .audiobookshelf) == "k")
    precondition(WatchNavigationPolicy.podcastListPreferenceKey(base: "k", source: nil) == "k")
    precondition(WatchNavigationPolicy.podcastListPreferenceKey(base: "k", source: .nativeFeed) == "k.followed")
  }

  private static func itemActionsRespectAvailableDevices() {
    let book = WatchSelection.audiobookshelf(itemID: "book", episodeID: nil)
    let both = WatchSelectionCapabilities(phonePlayable: true, watchPlayable: true)
    func destination(
      _ selection: WatchSelection, _ preferred: WatchPlaybackDestination, phone: Bool, watch: Bool,
      copy: Bool
    ) -> WatchPlaybackDestination? {
      WatchNavigationPolicy.itemDestination(
        selection: selection, capabilities: both, preferred: preferred, phoneAvailable: phone,
        watchAvailable: watch, hasLocalCopy: copy)
    }
    precondition(destination(book, .watch, phone: true, watch: false, copy: false) == .phone)
    precondition(destination(book, .watch, phone: true, watch: true, copy: false) == .watch)
    precondition(destination(book, .phone, phone: false, watch: true, copy: false) == .watch)
    // A Watch-playable title still names the Watch when nothing can play it now; the capability
    // decides, as before.
    precondition(
      WatchNavigationPolicy.itemDestination(
        selection: book, capabilities: .init(phonePlayable: false, watchPlayable: true), preferred: .phone,
        phoneAvailable: false, watchAvailable: false, hasLocalCopy: false) == .watch)
    precondition(
      WatchNavigationPolicy.itemDestination(
        selection: book, capabilities: .init(phonePlayable: false, watchPlayable: false), preferred: .phone,
        phoneAvailable: true, watchAvailable: true, hasLocalCopy: false) == nil)

    // A native feed is Watch-playable only through a copy the phone sent: the wire never claims it.
    let feed = WatchSelection.nativeFeed(feedID: "feed", episodeID: "episode")
    precondition(destination(feed, .watch, phone: true, watch: true, copy: true) == .watch)
    precondition(destination(feed, .watch, phone: true, watch: true, copy: false) == .phone)
    precondition(destination(feed, .watch, phone: false, watch: true, copy: true) == .watch)
    // Without a copy the phone is the only capable destination, so it is named even when away.
    precondition(destination(feed, .watch, phone: false, watch: true, copy: false) == .phone)
    precondition(
      WatchNavigationPolicy.itemDestination(
        selection: feed, capabilities: .init(phonePlayable: false, watchPlayable: true), preferred: .watch,
        phoneAvailable: false, watchAvailable: true, hasLocalCopy: false) == nil)
    precondition(destination(feed, .phone, phone: true, watch: true, copy: true) == .phone)
    // The copy changes nothing for an Audiobookshelf title, whose capability already said it.
    precondition(destination(book, .watch, phone: true, watch: true, copy: true) == .watch)
    precondition(destination(book, .watch, phone: true, watch: false, copy: true) == .phone)
  }

  private static func onlyConfirmedSelectedPlaybackOpensPlayer() {
    let stamp = try! WatchAccountStamp(accountIdentityHash: "account", serverIdentityHash: "server")
    let otherStamp = try! WatchAccountStamp(accountIdentityHash: "other", serverIdentityHash: "server")
    let selection = WatchSelection.audiobookshelf(itemID: "chosen", episodeID: nil)
    let previous = Date(timeIntervalSince1970: 1_000)
    func snapshot(
      itemID: String = "chosen", account: WatchAccountStamp? = nil,
      state: WatchPlaybackState = .playing, date: Date = previous.addingTimeInterval(1)
    ) -> WatchCatalogueSnapshot {
      let item = try! WatchCatalogueItem(
        id: itemID, selection: .audiobookshelf(itemID: itemID, episodeID: nil), title: "Title",
        isCurrentPlayback: true, capabilities: .init(phonePlayable: true, watchPlayable: false))
      return try! WatchCatalogueSnapshot(
        accountStamp: account ?? stamp, generatedAt: date, items: [item], playbackState: state)
    }
    func opens(_ snapshot: WatchCatalogueSnapshot?) -> Bool {
      WatchNavigationPolicy.shouldPresentPhonePlayer(
        selection: selection, accountStamp: stamp, snapshot: snapshot, newerThan: previous)
    }
    precondition(opens(snapshot()))
    precondition(!opens(nil))
    precondition(!opens(snapshot(itemID: "previous")))
    precondition(!opens(snapshot(account: otherStamp)))
    for state in [WatchPlaybackState.paused, .preparing, .failed, .unresolved, .idle] {
      precondition(!opens(snapshot(state: state)))
    }
    precondition(!opens(snapshot(date: previous)))
    precondition(!opens(snapshot(date: previous.addingTimeInterval(-1))))
  }

  private static func loadedTitleReadsAsPlaying() {
    let book = WatchSelection.audiobookshelf(itemID: "book", episodeID: nil)
    let other = WatchSelection.audiobookshelf(itemID: "other", episodeID: nil)
    func state(_ current: WatchSelection?, wants: Bool) -> WatchLoadedItemState {
      WatchNavigationPolicy.loadedState(of: book, current: current, wantsPlayback: wants)
    }
    precondition(state(nil, wants: false) == .notLoaded)
    precondition(state(other, wants: true) == .notLoaded)
    precondition(state(book, wants: true) == .active)
    precondition(state(book, wants: false) == .paused)
  }

  private static func downloadedTitleOffersRemoval() {
    func offers(account: Bool, primary: WatchPlaybackDestination?, phone: Bool, watch: Bool = true) -> Bool {
      WatchNavigationPolicy.itemOffersMoreActions(
        watchSupported: watch, watchAccountMatches: account, primary: primary, phonePlayable: phone)
    }
    // A Watch-only title already on the Watch still has Remove from Watch to offer.
    precondition(offers(account: true, primary: .watch, phone: false))
    precondition(offers(account: false, primary: .phone, phone: true))
    precondition(offers(account: false, primary: .watch, phone: true))
    precondition(!offers(account: false, primary: .watch, phone: false))
    precondition(!offers(account: true, primary: .phone, phone: true, watch: false))
  }
}
