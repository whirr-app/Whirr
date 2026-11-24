import SwiftUI
import WatchPlayback
import WatchProtocol

struct WatchDownloadsView: View {
  @Environment(WatchLibraryModel.self) private var model
  var body: some View {
    List {
      if model.account == nil {
        NavigationLink {
          WatchAccountView()
        } label: {
          Label("Set up Watch downloads", systemImage: "applewatch")
        }.frame(minHeight: 44)
      }
      let groups = model.downloadGroups
      // An episode the phone sent is still something to listen to, so a Watch holding only those
      // is not empty.
      let hasReceivedEpisodes = !model.receivedEpisodes.isEmpty
      if groups.isEmpty && !hasReceivedEpisodes {
        WatchEmptyState(
          title: "Listen offline", message: "Download a title to listen without your iPhone.",
          systemImage: "arrow.down.circle.fill", color: WatchVisualStyle.downloads)
      }
      WatchReceivedEpisodesSection()
      ForEach([true, false], id: \.self) { ready in
        let matching = groups.filter { $0.isReady == ready }
        if !matching.isEmpty {
          Section {
            ForEach(matching) { group in
              NavigationLink {
                WatchDownloadDetailView(groupID: group.id)
              } label: {
                let presentation = model.downloadPresentation(for: group)
                HStack(spacing: 8) {
                  WatchArtworkView(selection: group.selection, accountStamp: group.accountStamp)
                  VStack(alignment: .leading, spacing: 4) {
                    Text(presentation.title).font(.headline).lineLimit(2)
                    Text(presentation.status).font(.caption2).foregroundStyle(.secondary)
                    if let progress = group.progress, !group.isReady {
                      ProgressView(value: progress).progressViewStyle(.linear)
                        .tint(WatchVisualStyle.downloads)
                        .accessibilityLabel("Download progress")
                    }
                  }
                }.frame(minHeight: 48)
              }
            }
          } header: {
            Text(ready ? "Ready to Listen" : "Transfers")
          }
        }
      }
      WatchActionStatusView(observesPhoneCommands: false)
    }.navigationTitle("Downloads").watchPlayerToolbar()
      .task {
        await model.refreshDownloads()
        await model.refreshReceivedEpisodes()
      }
  }
}
