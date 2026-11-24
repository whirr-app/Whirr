import AppModel
import DesignSystem
import SwiftUI

/// Where Whirr's downloaded bytes go, as one segmented capsule: a segment per kind of download,
/// drawn against the storage limit when there is one.
///
/// The bar is decoration for VoiceOver. Every figure it draws is also in text beside it, in the
/// legend on the Storage Limit screen and in the card's spoken value on Downloads.
struct StorageBarView: View {
  let bar: StorageBarPresentation
  let height: CGFloat

  var body: some View {
    GeometryReader { proxy in
      ZStack(alignment: .leading) {
        Capsule().fill(.quaternary)
        HStack(spacing: 0) {
          ForEach(bar.segments) { segment in
            Rectangle()
              .fill(Self.color(for: segment.category))
              .frame(width: proxy.size.width * CGFloat(segment.fraction))
          }
        }
      }
      .clipShape(Capsule())
    }
    .frame(height: height)
    .accessibilityHidden(true)
  }

  /// System colours, so each segment keeps its contrast in light, dark and increased-contrast
  /// appearances without an asset of its own.
  static func color(for category: StorageCategory) -> Color {
    switch category {
    case .audiobooks: .indigo
    case .podcasts: .teal
    case .documents: .orange
    }
  }
}

/// The bar's key: one row per segment, naming the kind and its size.
struct StorageBarLegend: View {
  let bar: StorageBarPresentation

  var body: some View {
    VStack(alignment: .leading, spacing: WhirrSpacing.xSmall) {
      ForEach(bar.segments) { segment in
        LabeledContent {
          Text(SettingsCopy.storageBytes(segment.bytes))
            .monospacedDigit()
            .fixedSize(horizontal: false, vertical: true)
        } label: {
          HStack(spacing: WhirrSpacing.xSmall) {
            Circle()
              .fill(StorageBarView.color(for: segment.category))
              .frame(width: WhirrSpacing.xSmall, height: WhirrSpacing.xSmall)
              .accessibilityHidden(true)
            Text(SettingsCopy.storageCategoryTitle(segment.category))
              .fixedSize(horizontal: false, vertical: true)
          }
        }
        .font(.subheadline)
        .accessibilityElement(children: .combine)
      }
    }
  }
}
