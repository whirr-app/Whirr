import SwiftUI
import Testing

@testable import DesignSystem

@Suite("Player motion")
@MainActor
struct PlayerMotionTests {

  @Test("timeline readout transition animation is disabled under Reduce Motion")
  func timelineReadoutAnimationDisablesReduceMotion() {
    #expect(PlayerMotion.timelineReadoutAnimation(reduceMotion: true) == nil)
    #expect(PlayerMotion.timelineReadoutAnimation(reduceMotion: false) != nil)
  }

  @Test("timeline scrubbing animation is disabled under Reduce Motion")
  func timelineScrubbingAnimationDisablesReduceMotion() {
    #expect(PlayerMotion.timelineScrubbingAnimation(reduceMotion: true) == nil)
    #expect(PlayerMotion.timelineScrubbingAnimation(reduceMotion: false) != nil)
  }

  @Test("ambient adoption crossfade is disabled under Reduce Motion")
  func ambientAdoptionAnimationDisablesReduceMotion() {
    #expect(PlayerMotion.ambientAdoptionAnimation(reduceMotion: true) == nil)
    #expect(PlayerMotion.ambientAdoptionAnimation(reduceMotion: false) == .easeInOut(duration: 0.2))
  }
}
