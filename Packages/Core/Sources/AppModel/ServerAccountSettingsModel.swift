import Observation
import SyncEngine

/// Observable state for the read-only Server & Account Settings destination. Durable data lands
/// before the live profile so the screen remains useful when `/api/me` is unavailable.
@MainActor
@Observable
public final class ServerAccountSettingsModel {
  public enum LoadState: Sendable, Equatable {
    case loading
    case loaded
    case failed
  }

  public enum ProfileState: Sendable, Equatable {
    case loading
    case available
    case unavailable
  }

  public private(set) var loadState: LoadState = .loading
  public private(set) var profileState: ProfileState = .loading
  public private(set) var durableSettings: ServerAccountDurableSettings?
  public private(set) var profile: ServerAccountProfile?

  private let reading: any ServerAccountReading

  public init(reading: any ServerAccountReading) {
    self.reading = reading
  }

  /// Reads durable rows first and then attempts the live profile. A profile failure is not
  /// promoted to `loadState == .failed`: the durable projection is a successful screen load and
  /// the separate profile state lets the view say exactly what is unavailable.
  public func load() async {
    loadState = .loading
    profileState = .loading
    profile = nil

    do {
      let durableSettings = try await reading.readDurableSettings()
      guard Task.isCancelled == false else { return }
      self.durableSettings = durableSettings
      loadState = .loaded
    } catch {
      guard Task.isCancelled == false else { return }
      durableSettings = nil
      loadState = .failed
      profileState = .unavailable
      return
    }

    do {
      let profile = try await reading.fetchProfile()
      guard Task.isCancelled == false else { return }
      self.profile = profile
      profileState = .available
    } catch {
      guard Task.isCancelled == false else { return }
      profile = nil
      profileState = .unavailable
    }
  }
}
