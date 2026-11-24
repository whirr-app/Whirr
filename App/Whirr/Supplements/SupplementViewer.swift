import AppModel
import DesignSystem
import Persistence
import SwiftUI

/// An audiobook's companion PDFs, as one sheet. Item detail and the expanded player both present
/// it. One PDF opens straight into the viewer; several open onto a short list first.
struct SupplementsSheet: View {
  let model: ItemSupplementsModel
  let connectivityModel: ConnectivityModel?

  var body: some View {
    NavigationStack {
      if model.supplements.count == 1, let only = model.supplements.first {
        SupplementViewer(model: model, ino: only.id, connectivityModel: connectivityModel)
      } else {
        SupplementList(model: model, connectivityModel: connectivityModel)
          .navigationDestination(for: String.self) { ino in
            SupplementViewer(model: model, ino: ino, connectivityModel: connectivityModel)
          }
      }
    }
  }
}

private struct SupplementList: View {
  let model: ItemSupplementsModel
  let connectivityModel: ConnectivityModel?
  @Environment(\.dismiss) private var dismiss

  private var isOffline: Bool {
    ItemSupplementPresentation.isOffline(connectivityModel?.reachability)
  }

  var body: some View {
    List(model.supplements) { supplement in
      NavigationLink(value: supplement.id) {
        HStack {
          Label(ItemSupplementPresentation.title(for: supplement), systemImage: "doc.richtext")
          Spacer(minLength: WhirrSpacing.small)
          SupplementTrailingView(
            trailing: ItemSupplementPresentation.trailing(for: supplement, isOffline: isOffline))
        }
      }
    }
    .navigationTitle(ItemSupplementPresentation.rowTitle(for: model.supplements))
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .confirmationAction) {
        Button("Done") { dismiss() }
      }
    }
  }
}

/// One PDF: the document once it is on this device, otherwise the state of getting it there.
/// Done never cancels a download in flight; the file keeps coming and opens next time.
struct SupplementViewer: View {
  let model: ItemSupplementsModel
  let ino: String
  let connectivityModel: ConnectivityModel?

  @Environment(\.dismiss) private var dismiss
  @Environment(\.openURL) private var openURL
  @State private var pageCount = 0
  @State private var pageIndex = 0
  @State private var showsThumbnails = false
  @State private var couldNotOpen = false
  @State private var pendingLink: PendingLink?
  @State private var pageWriter: SupplementPageWriter?

  private struct PendingLink: Identifiable {
    let url: URL
    let displayedTarget: String
    var id: URL { url }
  }

  private var supplement: ItemSupplement? { model.supplement(ino: ino) }

  private var viewerState: ItemSupplementPresentation.ViewerState? {
    supplement.map {
      ItemSupplementPresentation.viewerState(
        for: $0, isOffline: ItemSupplementPresentation.isOffline(connectivityModel?.reachability))
    }
  }

  private var readyURL: URL? {
    if case .ready(let url) = viewerState, couldNotOpen == false { return url }
    return nil
  }

  var body: some View {
    content
      .navigationTitle(supplement.map(ItemSupplementPresentation.title(for:)) ?? "")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { dismiss() }
        }
        // The reader's own file, exported only by their own action (SECURITY.md).
        if let readyURL {
          ToolbarItem(placement: .topBarLeading) {
            ShareLink(item: readyURL) {
              Image(systemName: "square.and.arrow.up")
            }
            .accessibilityLabel("Share PDF")
          }
        }
      }
      // Once, when the stored set first answers for this file: a later failure waits for Retry
      // rather than re-requesting on every state change.
      .task(id: supplement != nil) {
        guard let supplement else { return }
        if pageWriter == nil {
          pageWriter = SupplementPageWriter(initialPage: supplement.lastViewedPage) { [model] page in
            guard let current = model.supplement(ino: supplement.id) else { return }
            await model.setLastViewedPage(page, for: current)
          }
        }
        await model.prepare(supplement)
      }
      .onDisappear {
        let writer = pageWriter
        Task { await writer?.flush() }
      }
      .alert(
        "Leave Whirr?",
        isPresented: Binding(
          get: { pendingLink != nil }, set: { if $0 == false { pendingLink = nil } }),
        presenting: pendingLink
      ) { link in
        Button("Cancel", role: .cancel) {}
        Button("Open") { openURL(link.url) }
      } message: { link in
        Text("This link opens \(link.displayedTarget) outside the app.")
      }
  }

  @ViewBuilder
  private var content: some View {
    switch viewerState {
    case nil:
      LoadingStateView(message: "Loading…")
    case .ready(let url):
      if couldNotOpen {
        EmptyStateView(
          title: "Couldn't Open This PDF",
          message: "The file may be damaged or password-protected.",
          systemImage: "doc.badge.ellipsis")
      } else {
        document(url)
      }
    case .downloading(let progress):
      VStack(spacing: WhirrSpacing.medium) {
        ProgressView(value: progress)
          .frame(maxWidth: 240)
        Text("Downloading…")
          .font(WhirrTypeToken.headline.font)
        Text("You can close this. The download continues.")
          .font(WhirrTypeToken.caption.font)
          .foregroundStyle(.secondary)
      }
      .padding()
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    case .waitingForWiFi:
      // One download policy, no special case for a PDF.
      EmptyStateView(
        title: "Waiting for Wi-Fi",
        message: "Cellular downloads are off. Connect to Wi-Fi, or allow cellular downloads in Settings › Downloads.",
        systemImage: "wifi")
    case .failed:
      EmptyStateView(
        title: ItemSupplementPresentation.downloadFailedMessage,
        message: model.actionErrorMessage ?? "Check your connection and try again.",
        systemImage: "exclamationmark.triangle",
        actionLabel: "Try Again",
        action: {
          guard let supplement else { return }
          Task { await model.prepare(supplement) }
        })
    case .unavailableOffline:
      EmptyStateView(
        title: "Available When Online",
        message: "This PDF isn't on this device yet.",
        systemImage: "icloud.slash")
    }
  }

  private func document(_ url: URL) -> some View {
    SupplementPDFView(
      fileURL: url,
      initialPageIndex: { count in
        SupplementPageMemory.initialPageIndex(
          lastViewedPage: supplement?.lastViewedPage, pageCount: count)
      },
      showsThumbnails: showsThumbnails,
      onLoad: { count in
        pageCount = count
        pageIndex = SupplementPageMemory.initialPageIndex(
          lastViewedPage: supplement?.lastViewedPage, pageCount: count)
      },
      onLoadFailure: { couldNotOpen = true },
      onPageChange: { index in
        pageIndex = index
        pageWriter?.noteVisible(pageIndex: index)
      },
      onExternalLink: { url in
        switch SupplementLinkAction.action(for: url) {
        case .refuse:
          break
        case .confirm(let url, let displayedTarget):
          pendingLink = PendingLink(url: url, displayedTarget: displayedTarget)
        }
      }
    )
    .ignoresSafeArea(edges: .bottom)
    .overlay(alignment: .bottom) {
      if pageCount > 0 {
        Button {
          showsThumbnails.toggle()
        } label: {
          Text(SupplementPageMemory.indicator(pageIndex: pageIndex, pageCount: pageCount))
            .font(WhirrTypeToken.caption.font.monospacedDigit())
            .padding(.horizontal, WhirrSpacing.medium)
            .padding(.vertical, WhirrSpacing.xSmall)
            .background(.regularMaterial, in: Capsule())
        }
        .buttonStyle(.plain)
        .padding(.bottom, showsThumbnails ? 88 : WhirrSpacing.medium)
        .accessibilityLabel("Page \(SupplementPageMemory.indicator(pageIndex: pageIndex, pageCount: pageCount))")
        .accessibilityHint(showsThumbnails ? "Hides page thumbnails." : "Shows page thumbnails.")
      }
    }
  }
}

/// The trailing edge of a supplement row, shared by the detail row and the list. On the ladder
/// because the detail row sits on the ambient page, where only the ladder's rungs have a contrast
/// guarantee.
struct SupplementTrailingView: View {
  let trailing: ItemSupplementPresentation.Trailing

  var body: some View {
    switch trailing {
    case .size(let text):
      Text(text)
        .font(WhirrTypeToken.caption.font)
        .foregroundStyle(WhirrMetadataProminence.secondary.adaptiveStyle)
    case .progress(let progress):
      ProgressView(value: progress)
        .progressViewStyle(.circular)
        .controlSize(.small)
        .accessibilityLabel("Downloading")
    case .waitingForWiFi:
      Text("Waiting for Wi-Fi")
        .font(WhirrTypeToken.caption.font)
        .foregroundStyle(WhirrMetadataProminence.secondary.adaptiveStyle)
    case .unavailableOffline:
      Text("Available when online")
        .font(WhirrTypeToken.caption.font)
        .foregroundStyle(WhirrMetadataProminence.secondary.adaptiveStyle)
    case .failed:
      Image(systemName: "exclamationmark.circle")
        .foregroundStyle(.orange)
        .accessibilityLabel("Download failed")
    case .none:
      EmptyView()
    }
  }
}
