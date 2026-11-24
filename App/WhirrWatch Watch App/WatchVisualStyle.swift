import SwiftUI

enum WatchVisualStyle {
  // WhirrColorToken.brandInk: fixed navy fill and its dark-appearance light ink.
  // Watch does not link DesignSystem; keep these RGB values aligned with its tokens.
  static let primaryFill = Color(red: 28.0 / 255, green: 42.0 / 255, blue: 58.0 / 255)
  static let accent = Color(red: 223.0 / 255, green: 229.0 / 255, blue: 238.0 / 255)
  static let audiobooks = accent
  static let podcasts = Color.purple
  static let downloads = Color.blue
  static let rowSurface = Color(white: 0.12)
}

struct WatchItemActionLayout<Primary: View>: View {
  let showsMore: Bool
  @ViewBuilder let primary: (Bool) -> Primary
  let more: () -> Void

  var body: some View {
    if showsMore {
      ViewThatFits(in: .horizontal) {
        HStack(spacing: 8) {
          primary(true)
          moreButton
        }
        VStack(alignment: .trailing, spacing: 8) {
          primary(false)
          moreButton
        }
      }
    } else {
      primary(false)
    }
  }

  private var moreButton: some View {
    Button(action: more) {
      Image(systemName: "ellipsis").foregroundStyle(.white).frame(width: 48, height: 48)
        .glassEffect(.regular.interactive(), in: .circle)
        .contentShape(Rectangle())
    }.buttonStyle(.plain).accessibilityLabel("More actions")
  }
}

struct WatchPrimaryActionLabel: View {
  let title: String
  let compactTitle: String
  let systemImage: String
  let compact: Bool

  var body: some View {
    Label(compact ? compactTitle : title, systemImage: systemImage)
      .font(.headline).foregroundStyle(.white)
      .fixedSize(horizontal: compact, vertical: true)
      .padding(.horizontal, 8).padding(.vertical, 8)
      .frame(minWidth: 48, maxWidth: .infinity, minHeight: 48)
      .glassEffect(.regular.tint(WatchVisualStyle.primaryFill).interactive(), in: .capsule)
      .contentShape(Rectangle())
      .accessibilityLabel(title)
  }
}

struct WatchCategoryLabel: View {
  let title: String
  let systemImage: String
  var color: Color = WatchVisualStyle.accent

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: systemImage)
        .font(.body.weight(.medium)).symbolRenderingMode(.hierarchical)
        .foregroundStyle(color).frame(width: 32, height: 32)
        .background(color.opacity(0.15), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityHidden(true)
      Text(title).foregroundStyle(.primary)
    }.frame(minHeight: 40)
  }
}

struct WatchEmptyState: View {
  let title: String
  let message: String
  let systemImage: String
  var color: Color = WatchVisualStyle.accent

  var body: some View {
    VStack(spacing: 8) {
      Image(systemName: systemImage).font(.largeTitle).foregroundStyle(color).accessibilityHidden(true)
      Text(title).font(.headline)
      Text(message).font(.caption).foregroundStyle(.secondary)
    }
    .multilineTextAlignment(.center)
    .frame(maxWidth: .infinity)
    .padding(.vertical, 12)
    .listRowBackground(Color.clear)
  }
}

private struct WatchPlayerToolbar: ViewModifier {
  @Environment(WatchLibraryModel.self) private var model
  @Environment(WatchCompanionStore.self) private var companion
  @Environment(WatchPlayerPresentation.self) private var presentation

  func body(content: Content) -> some View {
    content.toolbar {
      if model.currentSelection != nil || companion.currentItem != nil {
        ToolbarItem(placement: .topBarTrailing) {
          Button("Now Playing", systemImage: "waveform") { presentation.isPresented = true }
            .labelStyle(.iconOnly)
            .buttonStyle(.glassProminent).buttonBorderShape(.circle)
            .tint(WatchVisualStyle.primaryFill).foregroundStyle(.white)
        }
      }
    }
  }
}

extension View {
  func watchPlayerToolbar() -> some View { modifier(WatchPlayerToolbar()) }
}
