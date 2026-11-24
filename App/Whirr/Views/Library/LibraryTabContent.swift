import ABSApi
import AppModel
import Persistence
import SwiftUI
import SyncEngine

/// The long-lived half of the Library tab's callbacks. A closure stored directly on a view is not
/// comparable, so a view holding one reads as changed on every evaluation of the view that
/// created it. Holding the closures behind a reference lets `LibraryTabContent` compare the relay
/// by identity and stay equal while the shell rewrites what the closures capture.
@MainActor
final class LibraryTabRelay {
  var onSelectTitle: (ItemSummary) -> Void = { _ in }
  var onSelectEntity: (LibraryEntityGroup) -> Void = { _ in }
  var onPresentReader: (String, String, ItemMediaCategory) -> Void = { _, _, _ in }
  var onSearch: (String) -> Void = { _ in }
  var onSelectCollection: (LibraryCollectionKey) -> Void = { _ in }
}

/// The equality boundary around the Library tab's content.
///
/// `TabView` retains visited tabs, so every `LibraryShellView.body` evaluation re-evaluates each
/// tab's builder. `LibraryBrowseRootView`'s four closure callbacks aren't comparable, so without
/// this wrapper the whole catalogue row hierarchy rebuilds. Measured on a 1,204-item account: a
/// Podcasts arrival spent 83 ms of its 148 ms largest main-thread turn on that, a Search arrival
/// 77 ms of 241 ms.
///
/// Holds only comparable values, routes callbacks through `LibraryTabRelay`, and is applied with
/// `.equatable()`; the subtree stays, so scroll, query, selection and Authors/Series models live.
struct LibraryTabContent: View, Equatable {
  @Binding var mode: LibraryBrowsePresentation.Mode
  let selectionEntry: LibrarySelectionEntry
  let browseModel: LibraryBrowseModel
  let authorSeriesReading: any AuthorSeriesReading
  let libraryCollections: LibraryCollectionsAccess
  let coverClient: any ArtworkServing
  let downloadStatus: DownloadStatusStore
  let finishedStatus: FinishedStatusStore
  let actions: ItemActionsModel
  let playback: PlaybackModel
  let relay: LibraryTabRelay
  /// Bumped by the shell on every Library tab reselect. See `LibraryReselectRequests`.
  let scrollToTopRequest: Int

  /// Everything `==` consults, testable without a `LibraryBrowseModel` or playback stack.
  /// `coverClient`, `authorSeriesReading` and `libraryCollections` are absent: existentials, and
  /// per-account constants (an account change replaces the compared `browseModel`).
  struct Identity: Equatable {
    let mode: LibraryBrowsePresentation.Mode
    let scrollToTopRequest: Int
    let selectionEntry: ObjectIdentifier
    let browseModel: ObjectIdentifier
    let downloadStatus: ObjectIdentifier
    let finishedStatus: ObjectIdentifier
    let actions: ObjectIdentifier
    let playback: ObjectIdentifier
    let relay: ObjectIdentifier
  }

  var identity: Identity {
    Identity(
      mode: mode,
      scrollToTopRequest: scrollToTopRequest,
      selectionEntry: ObjectIdentifier(selectionEntry),
      browseModel: ObjectIdentifier(browseModel),
      downloadStatus: ObjectIdentifier(downloadStatus),
      finishedStatus: ObjectIdentifier(finishedStatus),
      actions: ObjectIdentifier(actions),
      playback: ObjectIdentifier(playback),
      relay: ObjectIdentifier(relay))
  }

  static func == (lhs: LibraryTabContent, rhs: LibraryTabContent) -> Bool {
    lhs.identity == rhs.identity
  }

  var body: some View {
    LibraryBrowseRootView(
      mode: $mode,
      selectionEntry: selectionEntry,
      browseModel: browseModel,
      authorSeriesReading: authorSeriesReading,
      libraryCollections: libraryCollections,
      coverClient: coverClient,
      downloadStatus: downloadStatus,
      finishedStatus: finishedStatus,
      actions: actions,
      playback: playback,
      onSelectTitle: { [relay] item in relay.onSelectTitle(item) },
      onSelectEntity: { [relay] group in relay.onSelectEntity(group) },
      onPresentReader: { [relay] itemID, title, category in
        relay.onPresentReader(itemID, title, category)
      },
      onSearch: { [relay] query in relay.onSearch(query) },
      onSelectCollection: { [relay] key in relay.onSelectCollection(key) },
      scrollToTopRequest: scrollToTopRequest
    )
  }
}
