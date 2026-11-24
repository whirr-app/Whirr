import AppModel
import Persistence
import ReaderCore

struct ReaderPresentationItem: Identifiable, Equatable {
  let itemID: String
  let title: String
  let category: ItemMediaCategory
  /// Where to land, when the reader was raised from a contents entry rather than from a Read
  /// action. `nil` opens at the saved reading position, which is every other entry point.
  var initialTarget: ReaderRestoreTarget?

  var id: String { itemID }
}

/// Holds a reader request that cannot be raised yet.
///
/// ADR 0008: at regular width item detail is a shell-level `.sheet` while the reader is a
/// `.fullScreenCover` on `RootView`, an ancestor of that sheet. Asking for the cover while the
/// card stands makes SwiftUI defer it until the card goes, so Read would do nothing until a tap
/// outside. Playing drops the card when playback starts (`LibraryShellView`'s `nowPlayingIdentity`
/// observer); reading can't raise the cover alongside the dismissal, so the request parks here and
/// the card's `onDismiss` releases it.
struct ReaderPresentationRelay: Equatable {
  private(set) var pending: ReaderPresentationItem?

  /// The reader to raise now, or `nil` when the card has to drop first. A parked request replaces
  /// any earlier one: only the last Read tapped is worth honouring.
  mutating func request(
    _ item: ReaderPresentationItem,
    itemDetailPresented: Bool
  ) -> ReaderPresentationItem? {
    guard itemDetailPresented else {
      pending = nil
      return item
    }
    pending = item
    return nil
  }

  /// The parked reader, once the card's dismissal has completed. Clearing as it is handed back is
  /// what keeps a later, unrelated card dismissal from raising a reader nobody asked for.
  mutating func itemDetailDismissed() -> ReaderPresentationItem? {
    defer { pending = nil }
    return pending
  }
}
