import AppModel
import DesignSystem
import ReaderCore
import SwiftUI

@MainActor
struct ReaderSearchPanel: View {
  @State private var model: ReaderSearchModel

  let theme: DesignSystem.ReaderTheme
  let onSelect: (String) -> Void

  init(
    renderer: any EPUBRendering,
    toc: [TOCEntry],
    theme: DesignSystem.ReaderTheme,
    onSelect: @escaping (String) -> Void
  ) {
    self.theme = theme
    self.onSelect = onSelect
    _model = State(initialValue: ReaderSearchModel(renderer: renderer, toc: toc))
  }

  var body: some View {
    VStack(spacing: 0) {
      TextField(ReaderCopy.searchPrompt, text: $model.query)
        .textFieldStyle(.roundedBorder)
        .submitLabel(.search)
        .accessibilityLabel(ReaderCopy.searchPrompt)
        .padding(.horizontal, WhirrSpacing.medium)
        .padding(.vertical, WhirrSpacing.small)

      content
    }
    .background(theme.palette.backgroundColor.ignoresSafeArea())
  }

  @ViewBuilder private var content: some View {
    if model.hits.isEmpty {
      emptyState
    } else {
      results
    }
  }

  private var emptyState: some View {
    VStack {
      Spacer(minLength: 0)
      Text(emptyStateCopy)
        .multilineTextAlignment(.center)
        .foregroundStyle(theme.palette.secondaryForegroundColor)
        .padding(.horizontal, WhirrSpacing.large)
      Spacer(minLength: 0)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private var emptyStateCopy: String {
    if model.failure != nil { return ReaderCopy.searchFailed }
    if model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      return ReaderCopy.searchNothingTyped
    }
    if model.isSearching { return ReaderCopy.searchSearching }
    return ReaderCopy.searchNoMatches
  }

  private var results: some View {
    ScrollView {
      LazyVStack(spacing: 0) {
        ForEach(Array(model.hits.enumerated()), id: \.element.id) { index, hit in
          ReaderSearchResultRow(
            chapterTitle: hit.chapterTitle,
            before: hit.before,
            highlight: hit.highlight,
            after: hit.after,
            theme: theme,
            onSelect: { onSelect(hit.id) }
          )
          .accessibilityIdentifier(ReaderAccessibilityID.searchRow(index))
        }

        if model.isSearching {
          ProgressView(ReaderCopy.searchSearching)
            .tint(theme.palette.accentColor)
            .padding(WhirrSpacing.medium)
        }

        if model.didReachHitLimit {
          Text(ReaderCopy.searchResultLimit)
            .font(WhirrTypeToken.caption.font)
            .foregroundStyle(theme.palette.secondaryForegroundColor)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(WhirrSpacing.medium)
        }

        if model.failure != nil {
          Text(ReaderCopy.searchFailed)
            .font(WhirrTypeToken.caption.font)
            .foregroundStyle(theme.palette.secondaryForegroundColor)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(WhirrSpacing.medium)
        }
      }
    }
    .scrollContentBackground(.hidden)
  }
}
