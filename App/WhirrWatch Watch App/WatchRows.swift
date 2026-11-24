import SwiftUI
import WatchPlayback
import WatchProtocol

struct WatchSelectionRow: View {
  let selection: WatchSelection
  let title: String
  let subtitle: String?
  var capabilities = WatchSelectionCapabilities(phonePlayable: true, watchPlayable: true)
  let accountStamp: WatchAccountStamp?
  var phoneCatalogueStamp: WatchAccountStamp? = nil

  var body: some View {
    NavigationLink {
      WatchSelectionDetailView(
        selection: selection, title: title, subtitle: subtitle, capabilities: capabilities,
        accountStamp: accountStamp, phoneCatalogueStamp: phoneCatalogueStamp)
    } label: {
      HStack(spacing: 8) {
        WatchArtworkView(selection: selection, accountStamp: accountStamp, phoneCatalogueStamp: phoneCatalogueStamp)
        VStack(alignment: .leading, spacing: 3) {
          Text(title).font(.headline).lineLimit(2)
          if let subtitle { Text(subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
        }
      }.frame(minHeight: 48)
    }
  }
}

struct WatchSetupHint: View {
  var text = "Set up on iPhone to browse your library."

  var body: some View {
    WatchEmptyState(title: "Your library awaits", message: text, systemImage: "books.vertical.fill")
  }
}

struct WatchConnectionStatusView: View {
  @Environment(WatchCompanionStore.self) private var companion
  @Environment(WatchLibraryModel.self) private var model
  var body: some View {
    if companion.snapshot == nil && model.account == nil {
      WatchSetupHint()
    }
  }
}

struct WatchPhoneShelf: View {
  @Environment(WatchCompanionStore.self) private var companion
  let section: WatchCatalogueSection
  let title: String
  var body: some View {
    let items = companion.snapshot?.items.filter { $0.section == section } ?? []
    if !items.isEmpty {
      Section(title) {
        ForEach(items) { item in WatchPhoneItemRow(item: item) }
      }
    }
  }
}

struct WatchPhoneItemRow: View {
  @Environment(WatchCompanionStore.self) private var companion
  let item: WatchCatalogueItem
  var body: some View {
    WatchSelectionRow(
      selection: item.selection, title: item.title, subtitle: item.subtitle,
      capabilities: item.capabilities,
      accountStamp: companion.snapshot?.authenticatedAccountStamp,
      phoneCatalogueStamp: companion.snapshot?.accountStamp)
  }
}

struct WatchActionStatusView: View {
  @Environment(WatchLibraryModel.self) private var model
  @Environment(WatchCompanionStore.self) private var companion
  var observesPhoneCommands = true
  @State private var message: String?

  var body: some View {
    Group {
      if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
    }
    // A result belongs to the open action screen, not every screen visited afterwards.
    .onChange(of: model.messageID) { _, _ in message = model.message }
    .onChange(of: companion.lastCommandEvent) { _, event in
      if observesPhoneCommands { message = event?.outcome.statusDescription() }
    }
    .onDisappear { message = nil }
  }
}
