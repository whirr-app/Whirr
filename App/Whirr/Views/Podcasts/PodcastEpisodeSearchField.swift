import AppModel
import DesignSystem
import SwiftUI

/// Keeps episode search immediately above the status chips so both controls read as one filtering
/// group within the show content. The capsule is glass through `GlassContainer` so it reads as the
/// same surface as Library's system search field: an opaque fill sat on the show's colour wash as
/// the one patch that refused the tint, and this screen cannot host the system field itself
/// without either parking it above the header or doubling the tab bar's search glyph.
struct PodcastEpisodeSearchField: View {
  @Binding var query: String
  let tint: Color?
  /// Called as the field gains focus, ahead of the first keystroke.
  var onFocus: () -> Void = {}
  @FocusState private var isFocused: Bool

  private var hasQueryText: Bool {
    query.isEmpty == false
  }

  var body: some View {
    // The single container keeps this List row unary. `GlassContainer`'s body is a `Group` over an
    // `if`, which a List otherwise flattens into its own view list, so every focus change here
    // re-diffed every episode row below it.
    ZStack {
      GlassContainer(in: Capsule()) {
        field
      }
    }
    .padding(.horizontal, WhirrSpacing.medium)
    .padding(.vertical, WhirrSpacing.small)
    .tint(tint)
  }

  private var field: some View {
    HStack(spacing: WhirrSpacing.xSmall) {
      Image(systemName: "magnifyingglass")
        .foregroundStyle(WhirrColorToken.textSecondary.color)
        .accessibilityHidden(true)

      TextField(PodcastShowListCopy.searchPrompt, text: $query)
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .submitLabel(.search)
        .accessibilityIdentifier(PodcastAccessibilityID.episodeSearchField)
        .focused($isFocused)
        .onChange(of: isFocused) { _, focused in
          if focused { onFocus() }
        }

      if hasQueryText {
        Button {
          query = ""
        } label: {
          Image(systemName: "xmark.circle.fill")
            .foregroundStyle(WhirrColorToken.textSecondary.color)
        }
        .buttonStyle(.plain)
        .frame(width: WhirrMetric.minimumTouchTarget, height: WhirrMetric.minimumTouchTarget)
        .accessibilityLabel(PodcastShowListCopy.clearSearchLabel)
      }
    }
    .padding(.leading, WhirrSpacing.medium)
    .padding(.trailing, hasQueryText ? 0 : WhirrSpacing.medium)
    .frame(minHeight: WhirrMetric.minimumTouchTarget)
    .contentShape(Capsule())
  }
}
