import SwiftUI
import Testing
import UIKit

@testable import Whirr

/// A collection header's Play and Add to Up Next share the episode card's Play label, so the
/// header row's two capsules are the card's height and level with each other.
@MainActor
@Suite struct LibraryCollectionHeaderButtonTests {
  @Test func headerCapsulesAreTheEpisodeCardPlayHeight() {
    let prominent = height(of: capsule("Play").buttonStyle(.borderedProminent))
    let bordered = height(of: capsule("Add to Up Next").buttonStyle(.bordered))

    #expect(abs(prominent - bordered) < 1)
    #expect(prominent >= PodcastEpisodeCardViewPresentation.Metric.playButtonMinHeight)
  }

  private func capsule(_ title: String) -> some View {
    Button {
    } label: {
      Label(title, systemImage: "play.fill").playCapsuleLabel()
    }
    .buttonBorderShape(.capsule)
  }

  private func height(of view: some View) -> CGFloat {
    UIHostingController(rootView: view).sizeThatFits(in: CGSize(width: 400, height: 1000)).height
  }
}
