import Foundation

/// User-facing copy for Settings › About › Report a Problem, owned and tested in AppModel the
/// way `SettingsCopy` is. The footer is a promise the diagnostics bundle has to keep:
/// `ProblemReportRedaction` and `ProblemReportComposerTests` are what make it true.
public enum ProblemReportCopy {
  public static let rowTitle = "Report a Problem"
  public static let rowDetail = "Bugs, feedback and diagnostics"

  public static let issueTitle = "Report on GitHub"
  public static let issueDetail = "Opens a bug report with your app and device details filled in."

  public static let shareTitle = "Share Diagnostics"
  public static let shareDetail =
    "A short text file about this device and recent activity. Nothing is sent until you choose where it goes."
  public static let preparingShare = "Preparing diagnostics…"
  public static let shareFailed = "Couldn't build the diagnostics file. Try again."

  public static let previewTitle = "What's Included"
  public static let previewDetail = "Read the file before you share it."

  public static let footer =
    "Diagnostics never include your server address, account name, passwords, tokens, or the titles of anything in your library. Read what is included before you share it."
}
