import Foundation

/// One generation counter and the tokens captured from it.
///
/// A model that replaces an observation or search pipeline advances the fence and captures the
/// token; every answer then checks `isCurrent` before writing state. A value yielded by the
/// retired pipeline therefore cannot publish over the newer generation. Task cancellation alone
/// is not enough: a stream suspended in `for await` can deliver one more element before the
/// cancellation lands.
///
/// A token is meaningful only against the fence that produced it.
struct GenerationFence {
  struct Token: Equatable {
    fileprivate let id: Int
  }

  private var currentID = 0

  /// Invalidates every earlier token and returns the token for this generation.
  @discardableResult
  mutating func advance() -> Token {
    currentID &+= 1
    return Token(id: currentID)
  }

  /// True only for the token returned by the latest `advance()`.
  func isCurrent(_ token: Token) -> Bool {
    token.id == currentID
  }

  /// The token for the current generation, or nil before the first advance. A reader that must
  /// not start a new generation (paging an existing result) captures this instead.
  var currentToken: Token? {
    currentID == 0 ? nil : Token(id: currentID)
  }
}
