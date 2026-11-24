import Foundation
import UIKit
import WidgetProtocol

/// What a widget or control draws from: the app's last snapshot, read from the App Group.
nonisolated enum WidgetSnapshotState: Sendable, Equatable {
  /// No readable snapshot: no container (an unsigned build), the device has not been unlocked
  /// since restart, the app has never published, or the file is not one this build understands.
  /// Drawn as the placeholder, never as signed out.
  case unavailable
  /// The app published the signed-out snapshot (logout, account removal, no account yet).
  case signedOut
  case signedIn(WidgetSnapshot)

  var snapshot: WidgetSnapshot? {
    if case .signedIn(let snapshot) = self { return snapshot }
    return nil
  }
}

/// The extension's read side of the files `WidgetFileStore` writes in the app. Read-only: the
/// extension never writes to the App Group, so the app remains the single writer.
nonisolated struct WidgetSnapshotReader: Sendable {
  /// `nil` when the App Group entitlement is missing.
  let containerURL: URL?

  static var production: WidgetSnapshotReader {
    WidgetSnapshotReader(
      containerURL: FileManager.default.containerURL(
        forSecurityApplicationGroupIdentifier: WidgetStorageLayout.appGroupIdentifier))
  }

  func read() -> WidgetSnapshotState {
    guard let containerURL else { return .unavailable }
    let url = WidgetStorageLayout.snapshotFile(inContainer: containerURL)
    // Bound the read before loading, so a file that is not a snapshot is never pulled into the
    // extension's small memory budget; the codec re-checks the bytes it is given.
    guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
      size <= WidgetSnapshotLimits.maxEncodedBytes,
      let data = try? Data(contentsOf: url),
      let snapshot = try? WidgetSnapshotCodec.decode(data)
    else { return .unavailable }
    return snapshot.accountStamp == nil ? .signedOut : .signedIn(snapshot)
  }

  /// The item's exported cover, or `nil` when it has none, the file is gone (pruned after this
  /// snapshot was read), or its name is not one the app could have written.
  func cover(for item: WidgetItem) -> UIImage? {
    guard let containerURL, let name = item.coverFileName,
      let url = try? WidgetStorageLayout.coverFile(named: name, inContainer: containerURL)
    else { return nil }
    return UIImage(contentsOfFile: url.path)
  }
}
