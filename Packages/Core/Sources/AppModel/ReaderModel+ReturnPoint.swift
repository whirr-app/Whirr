import ReaderCore

/// Where the reader was before a jump (a rail seek, a contents entry, or a search hit), so a jump
/// taken by accident, or only to look something up, costs one tap to undo.
public struct ReaderReturnPoint: Sendable, Equatable {
  public let position: ReadingPosition
  public let label: String
  /// Distinguishes jumps that share an origin, so the offer's timeout restarts with each one.
  let jump: Int
}

@MainActor
extension ReaderModel {
  /// What the rail's readout shows while a finger is on it: the page a release at `fraction` would
  /// land on, resolved as `seek(toTotalProgression:)` resolves it, so the readout never promises a
  /// page the seek then misses.
  public func scrubPreview(forTotalProgression fraction: Double) -> ReaderProgressDisplay {
    makeProgressDisplay(for: seekTarget(forTotalProgression: fraction))
  }

  /// Seeks to a rail position and offers the way back to the page that was being read.
  public func seek(toTotalProgression fraction: Double) async {
    let target = seekTarget(forTotalProgression: fraction)
    await jump(to: target) {
      if let target, target.position != nil {
        try await $0.go(to: target)
      } else {
        try await $0.go(toTotalProgression: target?.totalProgression ?? fraction)
      }
    }
  }

  /// Search hits resolve to a locator only inside the renderer, so the landing page is not known
  /// in advance and the offer is made whatever it turns out to be.
  public func goToSearchHit(id: String) async {
    let landed = await jump(to: nil) { try await $0.go(toSearchHit: id) }
    if landed { await renderer.highlightSearchHit(id: id) }
  }

  /// Makes the offer, then moves. A jump made while an offer is still up keeps that offer's origin:
  /// the place worth returning to is where reading was, not the last stop of a scrub or a run
  /// through search results that is still hunting. A jump that throws never moved the page, so the
  /// offer goes back to what it was.
  @discardableResult
  func jump(
    to target: ReadingPosition?,
    navigate: (any EPUBRendering) async throws -> Void
  ) async -> Bool {
    let previous = returnPoint
    if let origin = returnPoint?.position ?? currentPosition,
      target.map({ isSamePage(origin, $0) }) != true
    {
      jumpCount += 1
      returnPoint = ReaderReturnPoint(
        position: origin, label: returnLabel(for: origin), jump: jumpCount)
    }
    do {
      try await navigate(renderer)
      return true
    } catch {
      returnPoint = previous
      return false
    }
  }

  public func goBack() async {
    guard let returnPoint else { return }
    self.returnPoint = nil
    try? await renderer.go(to: returnPoint.position)
  }

  public func dismissReturnPoint() {
    returnPoint = nil
  }

  /// The page containing `fraction`: the last position starting at or before it, or the first page
  /// for a fraction ahead of every position. Without a positions list there is no page to resolve,
  /// so the target carries the progression alone.
  private func seekTarget(forTotalProgression fraction: Double) -> ReadingPosition? {
    let clamped = fraction.isFinite ? min(max(fraction, 0), 1) : 0
    guard let positions = publication?.positions, let first = positions.first else {
      return ReadingPosition(
        href: currentPosition?.href ?? "", progression: clamped, totalProgression: clamped)
    }
    return positions.last(where: { $0.totalProgression <= clamped }) ?? first
  }

  private func isSamePage(_ origin: ReadingPosition, _ target: ReadingPosition) -> Bool {
    if let originPage = origin.position, let targetPage = target.position {
      return originPage == targetPage
    }
    return ReaderCopy.progressPercent(origin.totalProgression)
      == ReaderCopy.progressPercent(target.totalProgression)
  }

  private func returnLabel(for origin: ReadingPosition) -> String {
    let display = makeProgressDisplay(for: origin)
    return ReaderCopy.backToPosition(page: display.page, percentText: display.percentText)
  }
}
