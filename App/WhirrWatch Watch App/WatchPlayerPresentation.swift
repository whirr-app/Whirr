import Observation
import SwiftUI

/// Presentation only. Playback and account ownership remain in the existing controllers.
@MainActor @Observable
final class WatchPlayerPresentation {
  var isPresented = false
}
