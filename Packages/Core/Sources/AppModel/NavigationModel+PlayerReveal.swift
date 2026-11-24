extension NavigationModel {
  /// Reveals a route behind the collapsing player, for its View Details and Up Next's Open.
  ///
  /// The Podcasts tab is episode-led and never holds a book, so a book's page revealed from there
  /// lands on Library's stack and Library becomes the tab. Pushed onto Podcasts, it sat under the
  /// Podcasts tab and outlived every switch away and back. Every other section is mixed, so the
  /// route pushes where the listener is, as `navigate(to:)` does. A book already on top of
  /// Library is shown rather than stacked on itself.
  public func revealFromPlayer(_ route: Route) {
    guard section == .podcasts, case .itemDetail(let itemID, _) = route else {
      navigate(to: route)
      return
    }
    var path = self[pathFor: .library]
    if let top = path.last, case .itemDetail(let topItemID, _) = top, topItemID == itemID {
      path.removeLast()
    }
    navigate(to: Destination(section: .library, path: path + [route]))
  }
}
