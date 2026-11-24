import Testing
import UIKit

@testable import Whirr

/// With the queue inline the page holds two scroll views. The pull-down must gate on the one under
/// the finger, so a drag on a scrolled queue scrolls it back instead of dismissing the player.
@MainActor
@Suite("Player dismissal scroll gate")
struct PlayerDismissalScrollGateTests {

  private struct Fixture {
    let root = UIView(frame: CGRect(x: 0, y: 0, width: 300, height: 600))
    let header = UIScrollView(frame: CGRect(x: 0, y: 0, width: 300, height: 80))
    let queue = UIScrollView(frame: CGRect(x: 0, y: 80, width: 300, height: 320))
    let row = UIView(frame: CGRect(x: 0, y: 0, width: 300, height: 60))
    let chrome = UIView(frame: CGRect(x: 0, y: 400, width: 300, height: 200))

    init() {
      queue.addSubview(row)
      root.addSubview(header)
      root.addSubview(queue)
      root.addSubview(chrome)
    }
  }

  @Test("a touch on the queue gates on the queue, not the page scroll view")
  func touchOnQueueGatesOnQueue() {
    let fixture = Fixture()
    let gate = PlayerDismissInteractor.gatingScrollView(
      at: CGPoint(x: 150, y: 100), in: fixture.root, fallback: fixture.header)
    #expect(gate === fixture.queue)
  }

  @Test("a touch on the header gates on the page scroll view")
  func touchOnHeaderGatesOnHeader() {
    let fixture = Fixture()
    let gate = PlayerDismissInteractor.gatingScrollView(
      at: CGPoint(x: 150, y: 40), in: fixture.root, fallback: fixture.header)
    #expect(gate === fixture.header)
  }

  @Test("a touch outside every scroll view falls back to the page scroll view")
  func touchOnChromeFallsBack() {
    let fixture = Fixture()
    let gate = PlayerDismissInteractor.gatingScrollView(
      at: CGPoint(x: 150, y: 500), in: fixture.root, fallback: fixture.header)
    #expect(gate === fixture.header)
    #expect(
      PlayerDismissInteractor.gatingScrollView(
        at: CGPoint(x: 150, y: 500), in: fixture.root, fallback: nil) == nil)
  }
}
