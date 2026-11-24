import SwiftUI
import WatchPlayback
import WatchProtocol

struct WatchAccountView: View {
  @Environment(WatchLibraryModel.self) private var model
  @State private var confirmingDisconnect = false
  var body: some View {
    List {
      if let account = model.account {
        Label("Connected", systemImage: "checkmark.circle.fill")
        Text(account.username ?? "Audiobookshelf")
        Button("Disconnect Watch", role: .destructive) { confirmingDisconnect = true }
          .frame(minHeight: 44).disabled(model.busy)
          .confirmationDialog(
            "Disconnect this Watch? Downloads on the Watch will be removed.",
            isPresented: $confirmingDisconnect, titleVisibility: .visible
          ) {
            Button("Disconnect", role: .destructive) { Task { await model.logout() } }
            Button("Cancel", role: .cancel) {}
          }
      } else {
        Text("On your iPhone, open Whirr → Settings → Apple Watch.").font(.caption).foregroundStyle(.secondary)
        if model.busy { ProgressView("Connecting") }
      }
      WatchActionStatusView(observesPhoneCommands: false)
    }.navigationTitle("Settings")
  }
}
