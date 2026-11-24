import Persistence
import SwiftUI
import Testing

@testable import Whirr

/// Equatable-gated because the parent reads the live playhead: without the gate the menu source
/// rebuilds twice a second and an open menu closes under the listener's finger. The gate is only
/// as good as its field list. A field the menu reads but the identity omits freezes at its first
/// value for the whole session.
@Suite("Metadata overflow control identity")
struct MetadataOverflowControlIdentityTests {

  private static func identity(
    itemID: String = "item-1",
    episodeID: String? = nil,
    duration: Double? = 3600,
    playbackStatus: ItemPlaybackStatus? = .inProgress,
    includesHistory: Bool = true,
    supplementCount: Int = 0,
    includesAddBookmark: Bool = false,
    includesTranscript: Bool = false,
    includesLookBack: Bool = false
  ) -> MetadataOverflowControl.Identity {
    MetadataOverflowControl.Identity(
      itemID: itemID, episodeID: episodeID, duration: duration, playbackStatus: playbackStatus,
      includesHistory: includesHistory, supplementCount: supplementCount,
      includesAddBookmark: includesAddBookmark, includesTranscript: includesTranscript,
      includesLookBack: includesLookBack)
  }

  @Test("everything the overflow menu draws from participates in the gate")
  func theMenuInputsParticipate() {
    #expect(Self.identity() != Self.identity(itemID: "item-2"))
    #expect(Self.identity() != Self.identity(episodeID: "ep-1"))
    #expect(Self.identity() != Self.identity(duration: nil))
    #expect(Self.identity() != Self.identity(playbackStatus: .finished))
    #expect(Self.identity() != Self.identity(includesHistory: false))
    // The PDF set arrives from its own observation after the menu first draws.
    #expect(Self.identity() != Self.identity(supplementCount: 1))
    // Add Bookmark appears once the shown audiobook becomes the loaded one.
    #expect(Self.identity() != Self.identity(includesAddBookmark: true))
    // Transcript appears once the coordinator reports the loaded episode eligible.
    #expect(Self.identity() != Self.identity(includesTranscript: true))
    // Look Back appears once the shown audiobook becomes the loaded one.
    #expect(Self.identity() != Self.identity(includesLookBack: true))
  }

  /// The other half of the contract, and the reason the type exists: two controls differing only
  /// in values the menu never reads are equal, so a position tick rebuilds nothing.
  @Test("identical menu inputs compare equal, so a position tick rebuilds nothing")
  func equalInputsCompareEqual() {
    #expect(Self.identity() == Self.identity())
  }

  /// Draws no glass: glass reads as a lens over the artwork, not a control. Kept as its own view so
  /// this check runs without the player's models, using the same `dump` check as the mini player.
  @Test("the overflow trigger draws no glass of its own")
  @MainActor
  func overflowTriggerDrawsNoGlass() {
    var dumped = ""
    dump(MetadataOverflowTrigger().body, to: &dumped)
    #expect(dumped.contains("GlassContainer") == false)
  }
}
