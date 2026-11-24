import SwiftUI

/// One removal staged for confirmation on the Downloads screen by a row `StorageModel` does not
/// manage: a server episode, a device feed, or a device episode. It carries its own copy and its
/// own action so the screen never reaches into the row's model, and a confirmed removal still
/// completes if the row's folder collapses while the alert is up.
struct PendingDownloadDeletion: Identifiable {
  let id: String
  let alertTitle: String
  let message: String
  let perform: @MainActor () async -> Void

  init(
    id: String, alertTitle: String, message: String,
    perform: @escaping @MainActor () async -> Void
  ) {
    self.id = id
    self.alertTitle = alertTitle
    self.message = message
    self.perform = perform
  }
}
