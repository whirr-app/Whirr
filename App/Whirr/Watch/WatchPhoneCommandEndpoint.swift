import AppModel
import Foundation
import Persistence
import WatchProtocol

/// Deduplication, account-scoped command execution, and a reply that carries the command's real outcome.
@MainActor
final class WatchPhoneCommandEndpoint {
  typealias ReplyHandler = WatchPhoneBridge.ReplyHandler
  typealias CurrentSelection = WatchPhoneBridge.CurrentSelection
  typealias Completion = WatchPhoneBridge.Completion

  private weak var handler: (any CompanionPlaybackActionHandling)?
  private var accountStamp: WatchAccountStamp?
  private var currentSelection: CurrentSelection?
  private let deduplicator: WatchCommandDeduplicator
  private let onCommandCompletion: Completion
  /// Playback run for a Watch command is the Watch's own doing; see `WatchCommandScope`.
  let commandScope: WatchCommandScope
  private var bindingEpoch = 0
  private var inFlightCommandID: UUID?
  private var inFlightTask: Task<Void, Never>?
  private var inFlightGate: WatchReplyGate<CompanionPlaybackActionResult>?
  private var inFlightSelection: CompanionSelection?
  private let startReplyBound: Duration

  init(
    deduplicator: WatchCommandDeduplicator, onCommandCompletion: @escaping Completion,
    commandScope: WatchCommandScope? = nil,
    startReplyBound: Duration = .seconds(6)
  ) {
    self.startReplyBound = startReplyBound
    self.deduplicator = deduplicator
    self.onCommandCompletion = onCommandCompletion
    // A default argument is evaluated outside the main actor, so the default is built here.
    self.commandScope = commandScope ?? WatchCommandScope()
  }

  var isBound: Bool { handler != nil && accountStamp != nil }
  var isBusy: Bool { inFlightCommandID != nil }

  /// Binds the current account graph. The bridge never retains the graph: RootComposition owns the
  /// handler and this weak reference is cleared as soon as logout replaces it.
  func bind(
    _ handler: any CompanionPlaybackActionHandling,
    accountStamp: WatchAccountStamp,
    currentSelection: @escaping CurrentSelection
  ) {
    if let existing = self.handler,
      self.accountStamp == accountStamp,
      (existing as AnyObject) === (handler as AnyObject)
    {
      // Snapshot publication may rediscover the same account repeatedly. Keep an in-flight
      // admission alive while refreshing the weak handler/selection closure.
      self.handler = handler
      self.currentSelection = currentSelection
      return
    }
    cancelInFlightForAccountChange()
    self.handler = handler
    self.accountStamp = accountStamp
    self.currentSelection = currentSelection
  }

  func unbind() {
    cancelInFlightForAccountChange()
    handler = nil
    accountStamp = nil
    currentSelection = nil
  }

  // MARK: Admission

  func admit(
    data: Data, replyHandler: @escaping ReplyHandler
  ) async {
    guard let command = try? WatchWireCodec.decode(WatchCommand.self, from: data) else {
      replyHandler([:])
      return
    }
    guard authorise(command, replyHandler: replyHandler) else { return }
    guard let selection = admittedSelection(command, replyHandler: replyHandler) else { return }
    let admissionEpoch = bindingEpoch
    guard await admitsExecution(command, admissionEpoch: admissionEpoch, replyHandler: replyHandler)
    else { return }
    if Self.isControl(command.action) {
      await admitControl(
        command, selection: selection, admissionEpoch: admissionEpoch, replyHandler: replyHandler)
    } else {
      await admitStart(
        command, selection: selection, admissionEpoch: admissionEpoch, replyHandler: replyHandler)
    }
  }

  /// A command is admitted only for the bound account, and only while a handler is bound to run it.
  private func authorise(_ command: WatchCommand, replyHandler: @escaping ReplyHandler) -> Bool {
    guard let accountStamp, command.accountStamp == accountStamp, handler != nil else {
      send(
        .rejected(commandID: command.id, errorCode: .accountUnavailable),
        to: replyHandler)
      return false
    }
    return true
  }

  /// The command's selection as the player names it. A selection that cannot be mapped is refused
  /// here, before the deduplicator reserves anything.
  private func admittedSelection(
    _ command: WatchCommand, replyHandler: @escaping ReplyHandler
  ) -> CompanionSelection? {
    guard let selection = Self.map(command.selection) else {
      send(
        .rejected(commandID: command.id, errorCode: .invalidSelection),
        to: replyHandler)
      return nil
    }
    return selection
  }

  /// Reserves the command in the deduplicator and answers every outcome that does not execute.
  /// Returns whether the command should run now. An entry reserved just before logout is completed
  /// here too: leaving it in flight forever would eventually saturate the bounded cache.
  private func admitsExecution(
    _ command: WatchCommand, admissionEpoch: Int, replyHandler: @escaping ReplyHandler
  ) async -> Bool {
    let decision: WatchDeduplicationDecision
    do {
      decision = try await deduplicator.begin(command)
    } catch {
      guard isCurrent(command, admissionEpoch: admissionEpoch) else {
        send(
          .rejected(commandID: command.id, errorCode: .accountUnavailable),
          to: replyHandler)
        return false
      }
      send(
        .rejected(commandID: command.id, errorCode: .invalidCommand),
        to: replyHandler)
      return false
    }

    guard isCurrent(command, admissionEpoch: admissionEpoch) else {
      _ = try? await deduplicator.complete(
        command, with: .rejected(commandID: command.id, errorCode: .accountUnavailable))
      send(
        .rejected(commandID: command.id, errorCode: .accountUnavailable),
        to: replyHandler)
      return false
    }
    return answers(decision, for: command, replyHandler: replyHandler)
  }

  /// Sends the reply a decision implies, and reports whether the command should run. Only the
  /// first copy of a command executes.
  private func answers(
    _ decision: WatchDeduplicationDecision, for command: WatchCommand,
    replyHandler: @escaping ReplyHandler
  ) -> Bool {
    switch decision {
    case .replay(let reply):
      send(reply, to: replyHandler)
    case .inFlight:
      // The first copy has not reached its real outcome yet. A duplicate must not be told the
      // command succeeded, nor be allowed to run it again: report it as unresolved.
      send(
        .rejected(commandID: command.id, errorCode: .ambiguousTransport),
        to: replyHandler)
    case .conflict:
      send(
        .rejected(commandID: command.id, errorCode: .commandConflict),
        to: replyHandler)
    case .saturated:
      send(
        .rejected(commandID: command.id, errorCode: .deduplicationSaturated),
        to: replyHandler)
    case .expired:
      send(.rejected(commandID: command.id, errorCode: .invalidCommand), to: replyHandler)
    case .execute:
      return true
    }
    return false
  }

  /// A start is the only slow command, so it alone holds the operation slot. The reply carries the
  /// real outcome; if the start outlasts `startReplyBound` the reply is `.ambiguousTransport` (the
  /// Watch reads it as unresolved and never falls back), and the start keeps running.
  private func admitStart(
    _ command: WatchCommand, selection: CompanionSelection, admissionEpoch: Int,
    replyHandler: @escaping ReplyHandler
  ) async {
    guard inFlightCommandID == nil else {
      await finish(
        command, with: .rejected(commandID: command.id, errorCode: .rejected),
        admissionEpoch: admissionEpoch, replyHandler: replyHandler)
      return
    }
    // No suspension point between the check above and this reservation.
    inFlightCommandID = command.id
    inFlightSelection = selection
    let gate = WatchReplyGate<CompanionPlaybackActionResult>()
    inFlightGate = gate
    inFlightTask = Task { @MainActor [weak self] in
      guard let self else {
        gate.finish(.rejected(.cancelled))
        return
      }
      let result = await self.run(
        command, selection: selection, admissionEpoch: admissionEpoch)
      if self.inFlightCommandID == command.id { self.clearInFlight() }
      gate.finish(result)
    }
    let result = await settled(gate)
    await finish(
      command, with: Self.reply(for: result, commandID: command.id),
      admissionEpoch: admissionEpoch, replyHandler: replyHandler)
  }

  /// Controls never take the operation slot, so a pause during a pending start is not refused. If
  /// the control targets the item that start is preparing, it waits (bounded) for that start and
  /// is then applied; otherwise a stale source is rejected with an explicit reply.
  private func admitControl(
    _ command: WatchCommand, selection: CompanionSelection, admissionEpoch: Int,
    replyHandler: @escaping ReplyHandler
  ) async {
    var ready = currentSelection?() == selection
    if !ready, let gate = inFlightGate, inFlightSelection == selection {
      let started = await settled(gate)
      if case .accepted? = started { ready = currentSelection?() == selection }
    }
    guard ready, isCurrent(command, admissionEpoch: admissionEpoch) else {
      await finish(
        command, with: .rejected(commandID: command.id, errorCode: .rejected),
        admissionEpoch: admissionEpoch, replyHandler: replyHandler)
      return
    }
    let result = await run(command, selection: selection, admissionEpoch: admissionEpoch)
    await finish(
      command, with: Self.reply(for: result, commandID: command.id),
      admissionEpoch: admissionEpoch, replyHandler: replyHandler)
  }

  private func run(
    _ command: WatchCommand, selection: CompanionSelection, admissionEpoch: Int
  ) async -> CompanionPlaybackActionResult {
    guard admissionEpoch == bindingEpoch, let handler, accountStamp == command.accountStamp else {
      return .rejected(.accountUnavailable)
    }
    let handing = command.action == .play ? command.value.map { (selection.itemID, selection.episodeID, $0) } : nil
    let result = await commandScope.run(handing: handing) {
      await Self.perform(command, selection: selection, on: handler)
    }
    complete(command: command, result: result, admissionEpoch: admissionEpoch)
    return result
  }

  /// Stores the exact reply for replay, then sends it unless the account changed meanwhile.
  private func finish(
    _ command: WatchCommand, with reply: WatchReply, admissionEpoch: Int,
    replyHandler: @escaping ReplyHandler
  ) async {
    _ = try? await deduplicator.complete(command, with: reply)
    guard isCurrent(command, admissionEpoch: admissionEpoch) else {
      send(
        .rejected(commandID: command.id, errorCode: .accountUnavailable),
        to: replyHandler)
      return
    }
    send(reply, to: replyHandler)
  }

  /// Waits for `gate`, giving up after `startReplyBound`. The Watch abandons a command after 8 s,
  /// so the phone must answer first. `nil` means the bound elapsed.
  private func settled(
    _ gate: WatchReplyGate<CompanionPlaybackActionResult>
  ) async -> CompanionPlaybackActionResult? {
    let race = WatchReplyGate<CompanionPlaybackActionResult>()
    let bound = startReplyBound
    Task { race.finish(await gate.wait()) }
    let timer = Task {
      try? await Task.sleep(for: bound)
      guard !Task.isCancelled else { return }
      race.finish(nil)
    }
    let result = await race.wait()
    timer.cancel()
    return result
  }

  private static func reply(
    for result: CompanionPlaybackActionResult?, commandID: UUID
  ) -> WatchReply {
    switch result {
    case nil:
      return .rejected(commandID: commandID, errorCode: .ambiguousTransport)
    case .accepted?:
      return .accepted(commandID: commandID)
    case .rejected(let reason)?:
      switch reason {
      case .accountUnavailable:
        return .rejected(commandID: commandID, errorCode: .accountUnavailable)
      case .invalidSelection:
        return .rejected(commandID: commandID, errorCode: .invalidSelection)
      case .preparationFailed, .cancelled, .noActivePlayback, .invalidPosition, .invalidRate,
        .staleRequest:
        return .rejected(commandID: commandID, errorCode: .rejected)
      }
    }
  }

  private func clearInFlight() {
    inFlightCommandID = nil
    inFlightTask = nil
    inFlightGate = nil
    inFlightSelection = nil
  }

  private static func perform(
    _ command: WatchCommand, selection: CompanionSelection, on handler: any CompanionPlaybackActionHandling
  ) async -> CompanionPlaybackActionResult {
    switch command.action {
    case .play:
      return await handler.start(source: selection.source, episodeID: selection.episodeID)
    case .pause:
      return handler.pause()
    case .resume:
      return handler.resume()
    case .seek:
      guard let value = command.value else { return .rejected(.invalidPosition) }
      return handler.seek(toGlobalOffset: value)
    case .skip:
      guard let value = command.value else { return .rejected(.invalidPosition) }
      return handler.skip(by: value)
    case .setRate:
      guard let value = command.value else { return .rejected(.invalidRate) }
      return handler.setRate(value)
    }
  }

  private func complete(
    command: WatchCommand,
    result: CompanionPlaybackActionResult,
    admissionEpoch: Int
  ) {
    guard admissionEpoch == bindingEpoch, accountStamp == command.accountStamp else { return }
    onCommandCompletion(command, result)
  }

  private func isCurrent(_ command: WatchCommand, admissionEpoch: Int) -> Bool {
    admissionEpoch == bindingEpoch
      && accountStamp == command.accountStamp
      && handler != nil
  }

  private func cancelInFlightForAccountChange() {
    bindingEpoch &+= 1
    inFlightTask?.cancel()
    // Release anyone still waiting on the cancelled start.
    inFlightGate?.finish(.rejected(.accountUnavailable))
    clearInFlight()
  }

  private func send(_ reply: WatchReply, to replyHandler: @escaping ReplyHandler) {
    guard let data = try? WatchWireCodec.encode(reply) else { return }
    replyHandler([WatchTransportKey.payload: data])
  }

  private static func map(_ selection: WatchSelection) -> CompanionSelection? {
    switch selection {
    case .audiobookshelf(let itemID, let episodeID):
      guard let source = PodcastSourceIdentity.abs(itemId: itemID) else { return nil }
      return CompanionSelection(source: source, episodeID: episodeID)
    case .nativeFeed(let feedID, let episodeID):
      guard
        let numericFeedID = Int64(feedID),
        numericFeedID > 0,
        String(numericFeedID) == feedID,
        let source = PodcastSourceIdentity.rss(feedId: numericFeedID)
      else { return nil }
      return CompanionSelection(source: source, episodeID: episodeID)
    }
  }

  private static func isControl(_ action: WatchCommandAction) -> Bool {
    switch action {
    case .play: return false
    case .pause, .resume, .seek, .skip, .setRate: return true
    }
  }
}
