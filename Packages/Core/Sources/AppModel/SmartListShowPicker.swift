import Foundation
import Persistence

/// One row of the editor's show picker.
public struct SmartListPickerShow: Sendable, Equatable, Identifiable {
  public enum Availability: Sendable, Equatable {
    case available
    /// Named by the list, but no longer followed.
    case notFollowed
    /// Named by the list, but not on the signed-in server.
    case notOnServer
  }

  public let ref: SmartListShowRef
  public let title: String
  public let availability: Availability
  public let role: SmartListShowRole?

  public var id: String { "\(ref.source.rawValue)/\(ref.showKey)" }
  public var source: SmartListShowSource { ref.source }
}

/// The editor's show choices as a value: both sources, a show that exists in both once,
/// and the shows a list names that are no longer on the device. Roles are kept
/// for a source that is switched off or signed out, so toggling it back restores them.
struct SmartListShowPicker: Sendable, Equatable {
  var sources = SmartListSourceState(nativeEnabled: true, accountID: nil)
  var catalog: [SmartListCatalogShow] = []
  /// Server show keys whose copy is hidden behind a followed native twin.
  var twinKeys: Set<String> = []
  /// Titles the list was saved with, by show.
  private(set) var storedTitles: [SmartListShowRef: String] = [:]
  private(set) var roles: [SmartListShowRef: SmartListShowRole] = [:]
  private var order: [SmartListShowRef] = []

  mutating func load(stored: [SmartListShowRecord]) {
    storedTitles = [:]
    roles = [:]
    order = []
    for record in stored {
      let ref = SmartListShowRef(source: record.source, showKey: record.showKey)
      storedTitles[ref] = record.titleSnapshot
      assign(record.role, to: ref)
    }
  }

  private mutating func assign(_ role: SmartListShowRole?, to ref: SmartListShowRef) {
    if let role {
      if roles.updateValue(role, forKey: ref) == nil { order.append(ref) }
    } else if roles.removeValue(forKey: ref) != nil {
      order.removeAll { $0 == ref }
    }
  }

  /// The Audiobookshelf copies hidden behind this native show.
  private func twins(of ref: SmartListShowRef) -> [SmartListCatalogShow] {
    guard ref.source == .native,
      let fingerprint = catalog.first(where: { $0.ref == ref })?.fingerprint
    else { return [] }
    return catalog.filter {
      $0.ref.source == .server && $0.fingerprint == fingerprint && twinKeys.contains($0.ref.showKey)
    }
  }

  func role(for ref: SmartListShowRef) -> SmartListShowRole? {
    roles[ref] ?? twins(of: ref).lazy.compactMap { roles[$0.ref] }.first
  }

  /// Sets or clears a show's role. Choosing a native show chooses its hidden twin too.
  mutating func setRole(_ role: SmartListShowRole?, for ref: SmartListShowRef) {
    for twin in twins(of: ref) { assign(nil, to: twin.ref) }
    assign(role, to: ref)
  }

  var items: [SmartListPickerShow] {
    var result: [SmartListPickerShow] = []
    var seen = Set<SmartListShowRef>()
    for show in catalog where isVisible(show.ref.source) {
      if show.ref.source == .server, twinKeys.contains(show.ref.showKey) { continue }
      seen.insert(show.ref)
      result.append(
        SmartListPickerShow(
          ref: show.ref, title: show.title, availability: .available, role: role(for: show.ref)))
    }
    for ref in order where seen.contains(ref) == false {
      guard isVisible(ref.source) else { continue }
      if ref.source == .server, twinKeys.contains(ref.showKey) { continue }
      let title = storedTitles[ref] ?? ref.showKey
      result.append(
        SmartListPickerShow(
          ref: ref, title: title,
          availability: ref.source == .native ? .notFollowed : .notOnServer, role: roles[ref]))
    }
    return result
  }

  /// What a save writes for `scope`. `included` means nothing unless the scope is `only`, and
  /// `excluded` nothing unless it is `allExcept`; priority is kept in every scope. A twin copy
  /// follows its native show's role and title.
  func selections(for scope: SmartListShowScope) -> [SmartListShowSelection] {
    var result: [SmartListShowSelection] = []
    var written = Set<SmartListShowRef>()
    func append(_ ref: SmartListShowRef, _ role: SmartListShowRole, _ title: String) {
      guard written.insert(ref).inserted else { return }
      result.append(SmartListShowSelection(ref: ref, role: role, titleSnapshot: title))
    }
    func keeps(_ role: SmartListShowRole) -> Bool {
      switch (scope, role) {
      case (_, .priority): true
      case (.only, .included), (.allExcept, .excluded): true
      default: false
      }
    }
    for ref in order {
      if ref.source == .server, twinKeys.contains(ref.showKey) { continue }
      guard let role = roles[ref], keeps(role) else { continue }
      append(ref, role, title(of: ref))
      for twin in twins(of: ref) { append(twin.ref, role, twin.title) }
    }
    // A twin chosen only through its hidden server copy: surface it under the native show.
    for show in catalog where show.ref.source == .native {
      guard roles[show.ref] == nil, let role = role(for: show.ref), keeps(role) else { continue }
      append(show.ref, role, show.title)
      for twin in twins(of: show.ref) { append(twin.ref, role, twin.title) }
    }
    return result
  }

  private func title(of ref: SmartListShowRef) -> String {
    catalog.first { $0.ref == ref }?.title ?? storedTitles[ref] ?? ref.showKey
  }

  private func isVisible(_ source: SmartListShowSource) -> Bool {
    switch source {
    case .native: sources.nativeEnabled
    case .server: sources.accountID != nil
    }
  }
}
