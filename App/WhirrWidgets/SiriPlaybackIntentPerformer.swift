/// The widget extension's performer for the intents it shares with the app
/// (`App/Whirr/Playback/SiriPlaybackIntents.swift`). The system runs these intents in the app
/// process, which has the account graph; the extension has no account and no player, so if it is
/// ever asked to perform one it refuses rather than guessing.
enum SiriPlaybackIntentPerformer {
  static func perform(_ action: SiriPlaybackIntentAction) async -> SiriPlaybackIntentResponse {
    .accountUnavailable
  }
}
