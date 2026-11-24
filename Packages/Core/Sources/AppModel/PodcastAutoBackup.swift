import Foundation
import Observation

/// When an automatic backup is due, what its file is called, and which older files it replaces.
public enum PodcastAutoBackupPolicy {
  public static let generationsKept = 3
  static let successInterval: TimeInterval = 24 * 3_600
  static let failureInterval: TimeInterval = 3_600

  private static let prefix = "Whirr Podcasts "
  private static let suffix = ".whirrpodcasts.json"

  /// A negative interval means the clock was set back; that never postpones a backup.
  public static func isDue(now: Date, lastSuccess: Date?, lastFailure: Date?) -> Bool {
    if let lastSuccess, case let since = now.timeIntervalSince(lastSuccess), since >= 0, since < successInterval {
      return false
    }
    if let lastFailure, case let since = now.timeIntervalSince(lastFailure), since >= 0, since < failureInterval {
      return false
    }
    return true
  }

  /// "Whirr Podcasts 2026-09-25.whirrpodcasts.json", dated in the user's own calendar day. The
  /// manual export uses the same name, so either kind of file restores the same way.
  public static func filename(for date: Date, calendar: Calendar) -> String {
    let parts = calendar.dateComponents([.year, .month, .day], from: date)
    let day = String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    return "\(prefix)\(day)\(suffix)"
  }

  /// Only an exact default name counts, so a renamed copy or any other file in the folder is
  /// never a candidate for deletion.
  public static func isBackupFilename(_ name: String) -> Bool {
    guard name.hasPrefix(prefix), name.hasSuffix(suffix) else { return false }
    let day = Array(name.dropFirst(prefix.count).dropLast(suffix.count).unicodeScalars)
    guard day.count == 10 else { return false }
    return day.enumerated().allSatisfy { index, scalar in
      index == 4 || index == 7 ? scalar == "-" : ("0"..."9").contains(scalar)
    }
  }

  /// Backups beyond the newest `generationsKept`, by the date in their names. The file just
  /// written is always kept, even when a clock set back gave it an older date.
  public static func filesToDelete(among names: [String], justWritten: String) -> [String] {
    let others = names.filter { isBackupFilename($0) && $0 != justWritten }.sorted(by: >)
    return Array(others.dropFirst(generationsKept - 1))
  }
}

/// Why the last automatic backup did not finish. Only `folderUnavailable` asks the user to act.
public enum PodcastAutoBackupFailure: String, Codable, Sendable, Equatable {
  case folderUnavailable
  case writeFailed
  /// There was nothing to back up, and the folder's existing backups were left as they were.
  case nothingToBackUp
}

/// The device-local automatic backup setting. It is never synced, exported or restored, so a
/// folder chosen on one device can never be picked up by another.
public struct PodcastAutoBackupState: Codable, Sendable, Equatable {
  /// `nil` means automatic backup is off.
  public var folderBookmark: Data?
  public var folderName: String?
  public var lastSuccess: Date?
  public var lastFailure: Date?
  public var failure: PodcastAutoBackupFailure?

  public init(
    folderBookmark: Data? = nil, folderName: String? = nil, lastSuccess: Date? = nil, lastFailure: Date? = nil,
    failure: PodcastAutoBackupFailure? = nil
  ) {
    self.folderBookmark = folderBookmark
    self.folderName = folderName
    self.lastSuccess = lastSuccess
    self.lastFailure = lastFailure
    self.failure = failure
  }
}

public protocol PodcastAutoBackupStoring: Sendable {
  func load() -> PodcastAutoBackupState
  func save(_ state: PodcastAutoBackupState)
}

public enum PodcastBackupFolderError: Error, Sendable, Equatable {
  /// The bookmark no longer resolves, or access to the folder was refused.
  case folderUnavailable
  case writeFailed
  /// The write was withheld because the folder already holds backups; see `write`.
  case existingBackupsKept
}

public struct PodcastBackupFolderChoice: Sendable, Equatable {
  public let bookmark: Data
  public let name: String

  public init(bookmark: Data, name: String) {
    self.bookmark = bookmark
    self.name = name
  }
}

/// The App's Files access for a user-chosen backup folder.
public protocol PodcastBackupFolderWriting: Sendable {
  /// Retains access to a folder the user has just picked.
  func choose(pickedFolder url: URL) async throws -> PodcastBackupFolderChoice
  /// Writes `data` as `filename`, confirms it reads back unchanged, then deletes the backups
  /// `PodcastAutoBackupPolicy.filesToDelete` names. A failure deletes nothing. Returns a
  /// replacement bookmark when the stored one had gone stale.
  ///
  /// With `keepingExistingBackups`, a folder already holding any backup (today's included) throws
  /// `existingBackupsKept` and nothing is written, replaced or deleted. A folder that cannot be
  /// listed counts as holding backups.
  func write(
    _ data: Data, named filename: String, toFolder bookmark: Data, keepingExistingBackups: Bool
  ) async throws -> Data?
}

/// Settings > Podcasts > Backups > Automatic Backups, and the once-a-day run when Whirr opens.
@MainActor @Observable
public final class PodcastAutoBackupModel {
  public private(set) var state: PodcastAutoBackupState
  public private(set) var isRunning = false
  /// The last folder choice could not be backed up to, so nothing changed.
  public private(set) var choiceFailed = false
  /// The last folder choice already held backups and this device had nothing to back up, so
  /// nothing changed.
  public private(set) var choiceKeptExistingBackups = false

  public var isOn: Bool { state.folderBookmark != nil }

  private let exporter: any PodcastBackupExporting
  private let folder: any PodcastBackupFolderWriting
  private let store: any PodcastAutoBackupStoring
  private let now: @Sendable () -> Date
  private let calendar: Calendar

  public init(
    exporter: any PodcastBackupExporting, folder: any PodcastBackupFolderWriting, store: any PodcastAutoBackupStoring,
    now: @escaping @Sendable () -> Date = Date.init, calendar: Calendar = .current
  ) {
    self.exporter = exporter
    self.folder = folder
    self.store = store
    self.now = now
    self.calendar = calendar
    self.state = store.load()
  }

  /// Turns automatic backup on, or moves it to a new folder, only if a backup written there now
  /// succeeds. Otherwise the current setting is kept.
  public func choose(folder url: URL) async {
    guard isRunning == false else { return }
    isRunning = true
    defer { isRunning = false }
    choiceFailed = false
    choiceKeptExistingBackups = false
    do {
      let choice = try await folder.choose(pickedFolder: url)
      let date = now()
      let refreshed = try await backUp(at: date, to: choice.bookmark)
      commit(
        PodcastAutoBackupState(
          folderBookmark: refreshed ?? choice.bookmark, folderName: choice.name, lastSuccess: date))
    } catch PodcastBackupFolderError.existingBackupsKept {
      choiceKeptExistingBackups = true
    } catch {
      choiceFailed = true
    }
  }

  /// Called each time Whirr becomes active.
  public func runIfDue() async {
    guard isRunning == false, let bookmark = state.folderBookmark,
      PodcastAutoBackupPolicy.isDue(now: now(), lastSuccess: state.lastSuccess, lastFailure: state.lastFailure)
    else { return }
    isRunning = true
    defer { isRunning = false }
    let date = now()
    var next = state
    do {
      let refreshed = try await backUp(at: date, to: bookmark)
      next.lastSuccess = date
      next.lastFailure = nil
      next.failure = nil
      if let refreshed { next.folderBookmark = refreshed }
    } catch {
      next.lastFailure = date
      next.failure =
        switch error as? PodcastBackupFolderError {
        case .folderUnavailable: .folderUnavailable
        case .existingBackupsKept: .nothingToBackUp
        case .writeFailed, nil: .writeFailed
        }
    }
    // Turned off or moved while this ran: the result belongs to a setting that no longer exists.
    guard state.folderBookmark == bookmark else { return }
    commit(next)
  }

  /// Forgets the folder. Backup files already written stay where they are.
  public func turnOff() {
    choiceFailed = false
    choiceKeptExistingBackups = false
    commit(PodcastAutoBackupState())
  }

  /// An empty snapshot is what a reinstall or a lost database exports, so it is only ever written
  /// to a folder that holds no backup it could replace or push out of the newest three.
  private func backUp(at date: Date, to bookmark: Data) async throws -> Data? {
    let export = try await exporter.exportBackup(at: date)
    return try await folder.write(
      export.data, named: PodcastAutoBackupPolicy.filename(for: date, calendar: calendar), toFolder: bookmark,
      keepingExistingBackups: export.isEmpty)
  }

  private func commit(_ next: PodcastAutoBackupState) {
    state = next
    store.save(next)
  }
}
