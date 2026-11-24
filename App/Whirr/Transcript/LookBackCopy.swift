import AppModel

/// Every string Look Back shows.
nonisolated enum LookBackCopy {
  static let menuTitle = "Look Back"
  static let menuSymbol = "text.quote"
  static let title = "Look Back"
  static let tipTitle = "Drifted Off?"
  static let tipMessage = "Look Back reads you the last few minutes so you can find your place."

  static let waitingTitle = "Waiting to Start"
  static let waiting = "Another analysis is using the recogniser."
  static let transcribing = "Transcribing"
  static let transcribingDetail = "The last few minutes appear here as they’re ready."
  static let transcribingEarlier = "Transcribing earlier…"
  static let noSpeech = "No Speech Here"
  static let noSpeechDetail = "Whirr didn’t hear any words in the last few minutes."
  static let goFurtherBack = "Go Further Back"
  static let showEarlier = "Show Earlier"
  static let showEarlierHint = "Transcribes the two and a half minutes before the text shown."
  static let reachesStart = "This goes back to the start of the book."
  static let reachesLimit = "Look Back goes back 30 minutes."
  /// The sheet's subtitle once a sentence is tapped, with the time counted back: "Playing from −4:10".
  static func playingFrom(_ timestamp: String) -> String { "Playing from \(timestamp)" }

  static let notDownloadedTitle = "Download This Book"
  static let notDownloadedMessage = "Download this book to use Look Back."
  static let noRecogniserTitle = "Not Available"
  static let noRecogniserMessage = "This iPhone can’t transcribe English speech."

  static let needsAssetTitle = "Speech Model Needed"
  static let needsAssetMessage =
    "Look Back transcribes on this iPhone with Apple’s English speech model, a one-time download."
  static let download = "Download"
  static let downloading = "Downloading the speech model."
  /// The consent prompt's message: Look Back's own, since the shared one speaks of Reduce Ads.
  static let downloadMessage =
    "Look Back transcribes the book on this iPhone with Apple’s speech model. Nothing else is sent or received."

  static let tryAgain = "Try Again"

  static func failureTitle(_ failure: LookBackModel.Failure) -> String {
    switch failure {
    case .unreadable: "Couldn’t Transcribe"
    case .tooHot: "Stopped"
    }
  }

  static func failureMessage(_ failure: LookBackModel.Failure) -> String {
    switch failure {
    case .unreadable: "Whirr couldn’t read this book’s audio."
    case .tooHot: "This iPhone is too warm. Try again once it has cooled down."
    }
  }
}
