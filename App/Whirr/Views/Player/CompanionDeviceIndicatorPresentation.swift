/// The companion-playback indicator's copy and its one rule: the phone says "Playing on Apple
/// Watch" for a title the Watch reports playing while this phone is not playing it, and play reads
/// as taking over. It shows on the item detail action row, and on the mini-player only when the
/// mini-player already shows that title.
nonisolated enum CompanionDeviceIndicatorPresentation {
  static let text = "Playing on Apple Watch"
  static let systemImage = "applewatch"
  static let takeOverLabel = "Play on iPhone"
  static let takeOverHint = "Pauses your Apple Watch and plays here."

  static func shows(watchPlaying: Bool, playingHere: Bool) -> Bool {
    watchPlaying && !playingHere
  }
}
