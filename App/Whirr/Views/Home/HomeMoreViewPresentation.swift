import AppModel

/// The pushed Home section list keeps its scroll host alive while its projection is loading or
/// empty. The placeholder is an overlay so its intrinsic height never becomes container-relative
/// scroll content under a large navigation title.
enum HomeMoreViewPresentation {
  nonisolated enum Placeholder: Equatable {
    case loading
    case empty

    var allowsHitTesting: Bool { false }
  }

  static func placeholder(for state: HomeMoreModel.State) -> Placeholder? {
    switch state {
    case .loading: .loading
    case .empty: .empty
    case .loaded: nil
    }
  }
}
