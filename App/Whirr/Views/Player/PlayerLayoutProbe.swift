import SwiftUI

/// The regions the expanded player's chrome invariant is stated over, plus the metadata band whose
/// height is the variance that invariant has to absorb. Always defined, so the composition reads
/// the same in every build configuration; only the recording below is debug-only.
enum PlayerLayoutProbeRegion: String, CaseIterable {
  case metadata
  case cover
  case scrubber
  case transport
  case quickActions
  case chrome
}

#if DEBUG
  /// Debug-only layout instrument for the expanded player. A hosted `UIHostingController` in a
  /// unit test publishes no accessibility tree (identifiers nil, frames zero until an
  /// accessibility client asks), so this records the regions' resolved frames for tests proving
  /// the chrome holds one position across items. Read-only (`onGeometryChange`), compiled out of
  /// release.
  @MainActor
  enum PlayerLayoutProbe {
    private(set) static var frames: [PlayerLayoutProbeRegion: CGRect] = [:]

    /// Cleared by the test between fixtures, so a stale frame can never be read as a new one.
    static func reset() {
      frames = [:]
    }

    static func record(_ region: PlayerLayoutProbeRegion, frame: CGRect) {
      frames[region] = frame
    }

    static func frame(_ region: PlayerLayoutProbeRegion) -> CGRect? {
      frames[region]
    }
  }
#endif

extension View {
  /// Publishes this view's resolved global-space frame under `region` in debug builds; a no-op
  /// elsewhere.
  @ViewBuilder
  func playerLayoutProbed(_ region: PlayerLayoutProbeRegion) -> some View {
    #if DEBUG
      onGeometryChange(for: CGRect.self) {
        $0.frame(in: .global)
      } action: {
        PlayerLayoutProbe.record(region, frame: $0)
      }
    #else
      self
    #endif
  }
}
