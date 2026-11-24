import Foundation
import ReaderCore

/// Turns a contents entry into the place the reader should open at.
///
/// The href is preferred: Readium resolves it to the fragment, which a whole-book fraction can
/// only approximate. The fraction is the fallback; an entry with neither is not a destination, so
/// the caller opens the book where the reader left off.
public enum ItemContentsNavigation {
  /// The entry being read is the exception: tapping it means "back to my place", not "restart this
  /// chapter". No target hands the reader its saved position, which is inside the entry.
  public static func target(for row: ItemContentsRow) -> ReaderRestoreTarget? {
    row.isCurrent ? nil : target(for: row.entry)
  }

  public static func target(for entry: TOCEntry) -> ReaderRestoreTarget? {
    if let href = entry.href, href.isEmpty == false {
      return .position(
        ReadingPosition(
          href: href,
          progression: 0,
          totalProgression: entry.startProgression ?? 0))
    }
    return entry.startProgression.map(ReaderRestoreTarget.totalProgression)
  }
}
