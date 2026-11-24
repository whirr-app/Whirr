/// Shared top-level ordering for media-item menus. A book's primary section contains Play/Read and
/// queue actions; a podcast episode's contains Play/Pause and queue actions. Keeping this order in
/// AppModel lets both menu families evolve without independently restating their section order.
/// The saved section holds the Save for Later / Remove from Saved state toggle. Whatever destroys
/// something sits in the last section, away from the finger that opened the menu.
public enum MediaItemMenuSection: Sendable, Equatable, Hashable, CaseIterable {
  case primary
  /// Save for Later or Remove from Saved, depending on the current membership state.
  case saved
  case navigation
  case download
  case progress
  case server
  /// Remove Download and Remove from Server, always last.
  case destructive
}
