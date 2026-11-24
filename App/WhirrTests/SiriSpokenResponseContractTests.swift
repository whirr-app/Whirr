import AppIntents
import AppModel
import Foundation
import Testing

@testable import Whirr

/// Nothing Siri speaks may carry an account, server, library, item or episode identity. Other
/// tests check the result-to-response mapping and three spoken strings, but none shows the spoken
/// set is closed: a later case speaks whatever its author wrote. The audit asserts equality
/// against the whole vocabulary, since a substring blocklist only catches leaks someone imagined.
@Suite("Siri spoken response contract (PRODUCT journey 10)")
struct SiriSpokenResponseContractTests {

  /// Adding a case to `SiriPlaybackIntentResponse` breaks this switch and stops the test target
  /// compiling. That is the point: the audit enumerates cases by hand, so a silent addition would
  /// slip past it. Fix the error by listing the new case in `everySpokenResponse`, which sends its
  /// spoken string through the audit.
  private func exhaustivenessGuard(_ response: SiriPlaybackIntentResponse) -> Bool {
    switch response {
    case .resuming, .paused, .skippedForward, .skippedBack, .sleepTimerSet, .sleepTimerCancelled,
      .sleepTimerExtended, .accountUnavailable, .noBookmark, .noActivePlayback, .noChapters,
      .startFailed, .itemUnavailable, .noSleepTimer:
      true
    }
  }

  /// Every response Siri can produce, including one per sleep-timer duration. `sleepTimerSet` is
  /// the only case carrying a value, and it is a finite `AppEnum`, so the vocabulary stays closed.
  private var everySpokenResponse: [SiriPlaybackIntentResponse] {
    let fixed: [SiriPlaybackIntentResponse] = [
      .resuming, .paused, .skippedForward, .skippedBack, .sleepTimerCancelled, .sleepTimerExtended,
      .accountUnavailable, .noBookmark, .noActivePlayback, .noChapters, .startFailed,
      .itemUnavailable, .noSleepTimer,
    ]
    return fixed + SiriSleepTimerDuration.allCases.map { .sleepTimerSet($0) }
  }

  @Test("the spoken vocabulary is closed, and every phrase in it is payload-free")
  func spokenVocabularyIsClosedAndReviewed() {
    for response in everySpokenResponse {
      #expect(exhaustivenessGuard(response))
    }

    let spoken = Set(everySpokenResponse.map { String(describing: $0.localizedStringResource.key) })

    // Every phrase Siri can say. Changing a phrase needs a deliberate update here, which is the
    // review. Adding one that names an item, show, server, account or position fails here, not in
    // a tester's living room.
    let reviewed: Set<String> = [
      "Resuming playback.",
      "Playback paused.",
      "Skipped forward.",
      "Skipped back.",
      "Sleep timer cancelled.",
      "Sleep timer set for 15 minutes.",
      "Sleep timer set for 30 minutes.",
      "Sleep timer set for 45 minutes.",
      "Sleep timer set for 60 minutes.",
      "Playback will stop at the end of the chapter.",
      "Sleep timer extended by 15 minutes.",
      "Sign in to Whirr, then try again.",
      "There’s no recent playback yet.",
      "Nothing is playing.",
      "The current item has no chapters.",
      "Playback couldn’t start. Check your connection and try again.",
      "That title isn’t available.",
      "No sleep timer is running.",
    ]

    #expect(
      spoken == reviewed,
      """
      Siri's spoken vocabulary changed. Every phrase here is spoken aloud, possibly on a lock \
      screen in earshot of other people, so it must name no item, show, author, account, server, \
      library, or position. Review the change, then update the reviewed set.
      Added: \(spoken.subtracting(reviewed).sorted())
      Removed: \(reviewed.subtracting(spoken).sorted())
      """)
  }

  @Test("no spoken phrase interpolates a runtime value")
  func spokenPhrasesCarryNoInterpolation() {
    // The vocabulary is closed only if each phrase is a literal. A format specifier in a key
    // means the phrase is assembled at runtime, which is how an item title would reach Siri.
    // `sleepTimerSet` varies by case, not by interpolation, so it stays finite.
    for response in everySpokenResponse {
      let key = String(describing: response.localizedStringResource.key)
      #expect(key.contains("%") == false, "\(key) interpolates a runtime value")
      #expect(key.contains("://") == false, "\(key) contains a URL")
      #expect(key.contains("@") == false, "\(key) contains an address or format specifier")
    }
  }

  @Test("only Whirr is named, and only as the application")
  func theOnlyProperNounIsTheApplication() {
    // "Sign in to Whirr" is the one proper noun in the vocabulary. Nothing else spoken may name a
    // host.
    let mentioningWhirr = everySpokenResponse.filter {
      String(describing: $0.localizedStringResource.key).contains("Whirr")
    }
    #expect(mentioningWhirr == [.accountUnavailable])
  }
}

/// What each intent does with a router result, minus the one line that resolves the router.
///
/// `perform()` resolves the process router, calls it, then maps and throws. The last two steps are
/// pure and asserted for every intent and unavailability reason. Resolution is not:
/// `SiriPlaybackIntentRuntime.router` evaluates `AppRuntime.shared.composition`, building the real
/// account graph with real hardware. Device checks cover it: cold launch, signed out, post-logout.
@Suite("Siri intent outcome contract (PRODUCT journey 10)")
struct SiriIntentOutcomeContractTests {

  private static let everyReason: [VoicePlaybackActionUnavailabilityReason] = [
    .accountUnavailable, .noBookmark, .noActivePlayback, .noChapters, .startFailed,
    .itemUnavailable, .noSleepTimer,
  ]

  /// The success response each intent asks `make(for:success:)` for, mirroring its `perform()`.
  private static let intentSuccesses: [(name: String, success: SiriPlaybackIntentResponse)] = [
    ("ResumeListeningIntent", .resuming),
    ("PausePlaybackIntent", .paused),
    ("SkipForwardIntent", .skippedForward),
    ("SkipBackIntent", .skippedBack),
    ("SetSleepTimerIntent(.off)", .sleepTimerCancelled),
    ("SetSleepTimerIntent(.thirtyMinutes)", .sleepTimerSet(.thirtyMinutes)),
    ("StartSleepTimerIntent(.fifteenMinutes)", .sleepTimerSet(.fifteenMinutes)),
    ("ExtendSleepTimerIntent", .sleepTimerExtended),
    ("CancelSleepTimerIntent", .sleepTimerCancelled),
    ("PlayWidgetItemIntent", .resuming),
    ("SetPlayingIntent(true)", .resuming),
    ("SetPlayingIntent(false)", .paused),
  ]

  @Test("a performed result returns each intent's own success response and never throws")
  func performedResultsSucceed() throws {
    for intent in Self.intentSuccesses {
      let response = SiriPlaybackIntentResponse.make(for: .performed, success: intent.success)
      #expect(response == intent.success, "\(intent.name) lost its success response")
      #expect(throws: Never.self) { try response.throwIfUnavailable() }
    }
  }

  @Test("every unavailability reason throws for every intent, and speaks that reason's phrase")
  func unavailableResultsThrowTheReasonsOwnPhrase() {
    for intent in Self.intentSuccesses {
      for reason in Self.everyReason {
        let response = SiriPlaybackIntentResponse.make(
          for: .unavailable(reason), success: intent.success)

        #expect(
          response != intent.success,
          "\(intent.name) reported success for \(reason)")

        do {
          try response.throwIfUnavailable()
          Issue.record("\(intent.name) did not throw for \(reason)")
        } catch let error as any CustomLocalizedStringResourceConvertible {
          // Siri speaks the thrown error, not the response, so the error must carry the right
          // phrase. A mismatch would be silent in every other test.
          #expect(
            String(describing: error.localizedStringResource.key)
              == String(describing: response.localizedStringResource.key),
            "\(intent.name)/\(reason) speaks something other than its own response")
        } catch {
          Issue.record("\(intent.name)/\(reason) threw an error Siri cannot speak: \(error)")
        }
      }
    }
  }

  @Test("the sleep timer speaks the duration it was actually set to")
  func sleepTimerSuccessNamesItsDuration() {
    // SetSleepTimerIntent picks its success response from the requested duration. A wrong mapping
    // here would speak a plausible but false confirmation.
    for duration in SiriSleepTimerDuration.allCases {
      let success: SiriPlaybackIntentResponse =
        duration == .off ? .sleepTimerCancelled : .sleepTimerSet(duration)
      let response = SiriPlaybackIntentResponse.make(for: .performed, success: success)
      #expect(response == success)
    }

    #expect(
      String(describing: SiriPlaybackIntentResponse.sleepTimerSet(.off).localizedStringResource.key)
        == "Sleep timer cancelled.")
  }
}
