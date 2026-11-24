#if DEBUG || PERF_INVESTIGATION
  import ABSApi
  import AppModel
  import DesignSystem
  import Foundation
  import MediaPlayer
  import Persistence
  import PlayerCore
  import ReaderCore
  import SwiftUI
  import SyncEngine
  import UIKit
  import os

  private struct UIHarnessMiniPlayerModifier: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
      if UIHarness.includesMiniPlayer {
        content.safeAreaInset(edge: .bottom, spacing: 0) {
          MiniPlayerView(
            title: UIHarnessFixtures.title,
            subtitle: UIHarnessFixtures.mixedAuthor,
            isPlaying: false,
            playPauseAccessibilityLabel: "Play",
            skipBackAccessibilityLabel: "Skip back",
            skipBackAccessibilityHint: "Skips backward.",
            skipBackSystemImage: "gobackward.15",
            skipForwardAccessibilityLabel: "Skip forward",
            skipForwardAccessibilityHint: "Skips forward.",
            skipForwardSystemImage: "goforward.30",
            progressAccessibilityValue: { "" },
            expandAccessibilityHint: "Opens the full player.",
            coverAccessibilityLabel: nil,
            isTitleMarqueeActive: !UIHarness.usesStaticMiniPlayerTitle,
            contentColorScheme: .dark,
            cover: { Color.gray },
            onPlayPauseTap: {},
            onSkipBackTap: {},
            onSkipForwardTap: {},
            onExpandTap: {}
          )
          .padding(.horizontal, WhirrSpacing.medium)
          .background(.ultraThinMaterial)
        }
      } else {
        content
      }
    }
  }

  extension View {
    func uiHarnessMiniPlayer() -> some View {
      modifier(UIHarnessMiniPlayerModifier())
    }
  }
#endif
