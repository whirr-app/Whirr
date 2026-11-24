import ABSApi
import AppModel
import DesignSystem
import SwiftUI

/// Paste a public podcast URL, inspect the bounded preview, then commit a device-owned follow, or
/// follow any number of directory results in place. Tapping a directory result zooms it into
/// `DirectoryPodcastDetailView`; its trailing control still follows without opening it.
/// Feed previews stay icon-only until followed. Directory thumbnails use the bounded RSS artwork
/// provider and never carry feed credentials.
struct AddFeedSheetView: View {
  @Bindable var model: AddFeedModel
  @Bindable var opmlModel: PodcastSubscriptionOPMLModel
  let artworkClient: any ArtworkServing
  /// Only the directory page uses it, for an unsaved preview wash.
  let paletteService: CoverPaletteService
  @Environment(\.dismiss) private var dismiss
  @State private var address = ""
  @FocusState private var addressIsFocused: Bool
  @State private var isImporterPresented = false
  @State private var isImportPreviewPresented = false
  @State private var presentedDetail: DirectoryPodcastDisplay?
  @Namespace private var detailZoom
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  /// The window's, not the sheet's: see `EnvironmentValues.windowHorizontalSizeClass`.
  @Environment(\.windowHorizontalSizeClass) private var windowHorizontalSizeClass

  private var usesDetailZoom: Bool {
    DirectoryPodcastDetailTransitionPolicy.usesZoom(reduceMotion: reduceMotion)
  }

  var body: some View {
    NavigationStack {
      Form {
        if model.isIdle {
          Section {
            ContentUnavailableView {
              Label(
                AddFeedSheetPresentation.idleTitle,
                systemImage: "antenna.radiowaves.left.and.right")
            } description: {
              Text(AddFeedSheetPresentation.idleMessage)
            }
          }
          .listRowBackground(Color.clear)
        }

        if model.offersOPMLImport {
          Section {
            Button {
              isImporterPresented = true
            } label: {
              Label(PodcastSubscriptionOPMLPresentation.importLabel, systemImage: "square.and.arrow.down")
            }
          } footer: {
            Text("Import subscriptions from another podcast app using an OPML file.")
          }
        }

        if model.isLoadingPreview {
          Section { statusRow(AddFeedSheetPresentation.previewingLabel) }
        } else if let preview = model.previewDisplay {
          Section {
            previewRows(preview)
          } footer: {
            if model.didExtractCredentials {
              Text(AddFeedSheetPresentation.extractedCredentialNotice)
            }
          }
        } else if let failure = model.failure {
          Section {
            Text(AddFeedSheetPresentation.message(for: failure))
              .foregroundStyle(.red)
          }
        }

        if model.isSearchingDirectory {
          Section { statusRow(AddFeedSheetPresentation.directorySearchingLabel) }
        } else if case .results([]) = model.directoryPhase {
          Section {
            ContentUnavailableView(
              AddFeedSheetPresentation.directoryEmptyTitle, systemImage: "magnifyingglass")
          }
        } else if model.directoryResults.isEmpty == false {
          Section {
            ForEach(model.directoryResults) { result in
              directoryRow(result)
            }
          }
        } else if let failure = model.directoryFailure {
          Section {
            Text(AddFeedSheetPresentation.directorySearchMessage(for: failure))
              .foregroundStyle(.red)
          }
        }
      }
      .formStyle(.grouped)
      // A URL-shaped value is previewed as a feed, anything else searched in the directory. Not
      // `.searchable`: it moves into the navigation bar on focus (shifting the layout as the sheet
      // opens focused) and its Search key stays disabled while empty. Links are pasted, so the
      // default keyboard stays; `.webSearch` would replace Search with Go.
      .safeAreaInset(edge: .top, spacing: 0) { addressField }
      .onSubmit { submitAddress() }
      // The clear button empties the text without submitting.
      .onChange(of: address) { _, newValue in
        if newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
          model.clearQuery()
        }
      }
      // The commit is pinned outside the scroll, matching the import preview: a directory search
      // below the preview can otherwise push it past the bottom of the sheet.
      .safeAreaInset(edge: .bottom, spacing: 0) { commitBar }
      .navigationTitle(AddFeedSheetPresentation.navigationTitle)
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button(role: .close) { dismiss() }
        }
      }
    }
    .task { await model.loadFollowedFeeds() }
    .onAppear { addressIsFocused = true }
    .onChange(of: model.isFollowed) { _, followed in
      if followed { dismiss() }
    }
    .fileImporter(
      isPresented: $isImporterPresented,
      allowedContentTypes: OPMLFileSupport.allowedContentTypes
    ) { result in
      guard case .success(let url) = result else { return }
      Task {
        let data = (try? OPMLFileSupport.read(url)) ?? Data()
        await opmlModel.loadImport(data: data)
        isImportPreviewPresented = true
      }
    }
    .fullScreenCover(item: detailBinding(for: .fullScreen), onDismiss: closeDetail) {
      detailPage(for: $0)
    }
    .sheet(item: detailBinding(for: .pageSheet), onDismiss: closeDetail) {
      detailPage(for: $0)
        .adaptiveSheetPresentation(role: .page)
    }
    .sheet(isPresented: $isImportPreviewPresented) {
      OPMLImportPreviewView(model: opmlModel)
        .adaptiveSheetPresentation(role: .large)
    }
  }

  /// One presented result drives whichever container suits the window, so a size-class change
  /// can't leave two presentations competing for it.
  private func detailBinding(
    for container: DirectoryPodcastDetailTransitionPolicy.Container
  ) -> Binding<DirectoryPodcastDisplay?> {
    Binding(
      get: {
        DirectoryPodcastDetailTransitionPolicy.container(for: windowHorizontalSizeClass)
          == container ? presentedDetail : nil
      },
      set: { presentedDetail = $0 }
    )
  }

  private func detailPage(for result: DirectoryPodcastDisplay) -> some View {
    DirectoryPodcastDetailView(
      model: model, feedURL: result.feedURL, artworkClient: artworkClient,
      paletteService: paletteService
    )
    .directoryDetailZoomDestination(id: result.feedURL, in: detailZoom, isEnabled: usesDetailZoom)
  }

  /// Runs when either container dismisses. A size-class change also dismisses one container while
  /// the other takes over the same result, so only a real dismissal (the result cleared) may
  /// cancel the load; otherwise the new container would be left waiting on a cancelled preview.
  private func closeDetail() {
    guard presentedDetail == nil else { return }
    model.closeDirectoryDetail()
  }

  /// An empty Search press returns to the idle state rather than reporting a bad link.
  private func submitAddress() {
    guard address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
      model.clearQuery()
      return
    }
    Task { await model.submit(address) }
  }

  private func statusRow(_ label: String) -> some View {
    HStack(spacing: WhirrSpacing.small) {
      ProgressView()
      Text(label).foregroundStyle(WhirrColorToken.textSecondary.color)
    }
    .frame(minHeight: WhirrMetric.minimumTouchTarget)
  }

  private func previewRows(_ preview: AddFeedPreviewDisplay) -> some View {
    HStack(spacing: WhirrSpacing.small) {
      RoundedRectangle(cornerRadius: WhirrSpacing.xSmall, style: .continuous)
        .fill(WhirrColorToken.groupedSurface.color)
        .overlay { Image(systemName: "antenna.radiowaves.left.and.right") }
        .frame(width: 56, height: 56)
      VStack(alignment: .leading, spacing: WhirrSpacing.xxSmall) {
        Text(preview.title).font(.headline)
        if let author = preview.author, author.isEmpty == false {
          Text(author).font(.subheadline)
            .foregroundStyle(WhirrColorToken.textSecondary.color)
        }
        Text(AddFeedSheetPresentation.episodeCountText(preview.episodeCount))
          .font(.caption)
          .foregroundStyle(WhirrColorToken.textSecondary.color)
      }
      Spacer(minLength: 0)
    }
  }

  private var addressField: some View {
    HStack(spacing: WhirrSpacing.small) {
      Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
      TextField(AddFeedSheetPresentation.addressFieldPrompt, text: $address)
        .focused($addressIsFocused)
        .submitLabel(.search)
        .autocorrectionDisabled()
        .textInputAutocapitalization(.never)
      if address.isEmpty == false {
        Button {
          address = ""
        } label: {
          Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Clear")
      }
    }
    .padding(.horizontal, WhirrSpacing.medium)
    .frame(minHeight: WhirrMetric.minimumTouchTarget)
    .glassEffect(.regular, in: .capsule)
    .padding(.horizontal, WhirrSpacing.medium)
    .padding(.bottom, WhirrSpacing.small)
  }

  @ViewBuilder
  private var commitBar: some View {
    if model.isPreviewFollowed {
      Label(AddFeedSheetPresentation.followedLabel, systemImage: "checkmark.circle.fill")
        .font(.headline)
        .foregroundStyle(WhirrColorToken.accent.color)
        .frame(maxWidth: .infinity, minHeight: WhirrMetric.minimumTouchTarget)
        .padding(.horizontal, WhirrSpacing.medium)
        .padding(.vertical, WhirrSpacing.small)
        .background(.bar)
    } else if model.previewDisplay != nil {
      Button {
        Task { await model.follow() }
      } label: {
        HStack(spacing: WhirrSpacing.small) {
          if model.isFollowing { ProgressView() }
          Text(
            model.isFollowing
              ? AddFeedSheetPresentation.followingLabel
              : AddFeedSheetPresentation.followButtonLabel)
        }
        .frame(maxWidth: .infinity, minHeight: WhirrMetric.minimumTouchTarget)
      }
      .buttonStyle(.glassProminent)
      .buttonBorderShape(.capsule)
      // Not disabled while following, for the reason `OPMLImportPreviewView.commitBar` states:
      // `.glassProminent` drops its fill when disabled, so the in-flight follow would empty the
      // capsule reporting it.
      .disabled(model.canFollow == false && model.isFollowing == false)
      .padding(.horizontal, WhirrSpacing.medium)
      .padding(.vertical, WhirrSpacing.small)
      .background(.bar)
    }
  }

  private func directoryRow(_ result: DirectoryPodcastDisplay) -> some View {
    VStack(alignment: .leading, spacing: WhirrSpacing.xSmall) {
      HStack(spacing: WhirrSpacing.small) {
        // Plain style keeps this and the follow control as two independent hit areas in the row.
        Button {
          presentedDetail = result
        } label: {
          HStack(spacing: WhirrSpacing.small) {
            directoryArtwork(result)
            VStack(alignment: .leading, spacing: WhirrSpacing.xxSmall) {
              Text(result.title).font(.headline)
              if let author = result.author {
                Text(author).font(.subheadline)
                  .foregroundStyle(WhirrColorToken.textSecondary.color)
              }
              if let count = result.episodeCount {
                Text(AddFeedSheetPresentation.episodeCountText(count))
                  .font(.caption)
                  .foregroundStyle(WhirrColorToken.textSecondary.color)
              }
            }
            .multilineTextAlignment(.leading)
            Spacer(minLength: 0)
          }
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint(AddFeedSheetPresentation.detailRowAccessibilityHint)
        .directoryDetailZoomSource(id: result.feedURL, in: detailZoom, isEnabled: usesDetailZoom)
        directoryFollowControl(result)
      }
      if let error = model.directoryFollowErrors[result.feedURL] {
        Label(
          AddFeedSheetPresentation.directoryFollowMessage(for: error),
          systemImage: "exclamationmark.triangle.fill"
        )
        .font(.caption)
        .foregroundStyle(.red)
      }
    }
  }

  /// Follow, in-flight and followed share one fixed square, so the row's text never reflows as a
  /// follow progresses.
  @ViewBuilder
  private func directoryFollowControl(_ result: DirectoryPodcastDisplay) -> some View {
    let side = WhirrMetric.minimumTouchTarget
    if model.isDirectoryResultFollowed(result.feedURL) {
      Image(systemName: "checkmark.circle.fill")
        .font(.title2)
        .foregroundStyle(WhirrColorToken.accent.color)
        .frame(width: side, height: side)
        .accessibilityLabel(
          AddFeedSheetPresentation.followingAccessibilityLabel(title: result.title))
    } else if model.directoryFollowingURL == result.feedURL {
      ProgressView()
        .frame(width: side, height: side)
        .accessibilityLabel(AddFeedSheetPresentation.followingLabel)
    } else {
      Button {
        Task { await model.followDirectoryResult(feedURL: result.feedURL) }
      } label: {
        Image(systemName: "plus.circle")
          .font(.title2)
          .frame(width: side, height: side)
          .contentShape(Rectangle())
      }
      .buttonStyle(.borderless)
      .disabled(model.directoryFollowingURL != nil)
      .accessibilityLabel(AddFeedSheetPresentation.followAccessibilityLabel(title: result.title))
    }
  }

  @ViewBuilder
  private func directoryArtwork(_ result: DirectoryPodcastDisplay) -> some View {
    if let artworkURL = result.artworkURL,
      let source = RSSArtworkSource(
        feedIdentity: "directory:\(result.feedURL.absoluteString)", artworkURL: artworkURL)
    {
      CoverImageView(
        itemID: result.feedURL.absoluteString,
        title: result.title,
        displaySize: 48,
        client: artworkClient,
        source: .rss(source),
        revision: .unversioned
      )
      .frame(width: 48, height: 48)
    } else {
      RoundedRectangle(cornerRadius: WhirrSpacing.xSmall, style: .continuous)
        .fill(WhirrColorToken.groupedSurface.color)
        .overlay { Image(systemName: "antenna.radiowaves.left.and.right") }
        .frame(width: 48, height: 48)
    }
  }
}
