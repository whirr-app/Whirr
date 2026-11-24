import SwiftUI
import WatchPlayback
import WatchProtocol

struct WatchContinueView: View {
  var audiobooksOnly = false
  @Environment(WatchLibraryModel.self) private var model

  var body: some View {
    List {
      let projection = model.homeProjection(scope: .continueListening(audiobooksOnly: audiobooksOnly))
      if projection.isEmpty {
        WatchEmptyState(
          title: "Pick up a story", message: "Titles you start will appear here.", systemImage: "headphones")
      } else {
        if !projection.phone.isEmpty {
          Section("On iPhone") { ForEach(projection.phone) { WatchPhoneItemRow(item: $0) } }
        }
        if projection.showsWatchSection {
          Section("On Watch") {
            ForEach(projection.watch) { item in
              WatchSelectionRow(
                selection: item.selection, title: model.continueTitles[item.selection] ?? "Resume listening",
                subtitle: nil, accountStamp: projection.watchAccountStamp)
            }
            ForEach(projection.native) { item in
              WatchNativeContinueRow(item: item, accountStamp: projection.watchAccountStamp)
            }
          }
        }
      }
    }.navigationTitle("Continue").watchPlayerToolbar()
      .task { await model.refreshReceivedEpisodes() }
  }
}
