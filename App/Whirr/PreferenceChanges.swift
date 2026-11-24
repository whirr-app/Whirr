import Foundation

/// "Observe defaults, forward only real changes": the one last-value box and the one observer
/// wiring behind every preference observation in the app.
///
/// `UserDefaults.didChangeNotification` names no key, so every write in the process posts it.
/// Forwarding each one wakes a coordinator pass, a catalogue rebuild or a view invalidation for a
/// value that did not move. This compares the freshly read value with the last one forwarded and
/// forwards only a real change, unless the caller asks for an activation re-emit (a deferred
/// analysis retries when the app returns to the foreground).
///
/// Two shapes, one rule: `stream` for AsyncStream consumers, `observe` for a synchronous callback
/// that must run on the notifying queue. Reads happen under one lock, so a caller that owns
/// several observers shares the same last value.
nonisolated final class PreferenceChanges<Value: Equatable & Sendable>: @unchecked Sendable {
  private struct Registration {
    let center: NotificationCenter
    let token: NSObjectProtocol
  }

  private let lock = NSLock()
  private let read: @Sendable () -> Value
  private let reemitsOnActivation: Bool
  private let activationName: Notification.Name?
  private var last: Value
  private var registrations: [Registration] = []

  init(
    read: @escaping @Sendable () -> Value,
    reemitsOnActivation: Bool = false,
    activationName: Notification.Name? = nil
  ) {
    self.read = read
    self.reemitsOnActivation = reemitsOnActivation
    self.activationName = activationName
    self.last = read()
  }

  deinit { cancel() }

  /// The value as last forwarded.
  var current: Value { lock.withLock { last } }

  /// Re-read after every notification in `names`, calling `onChange` only for a real change (or on
  /// the activation notification, when the caller asked for that). `onChange` runs on `queue`, the
  /// notification's own queue.
  func observe(
    names: [Notification.Name],
    in center: NotificationCenter = .default,
    object: Any? = nil,
    queue: OperationQueue? = nil,
    onChange: @escaping @Sendable (Value) -> Void
  ) {
    let activationName = self.activationName
    for name in names {
      let token = center.addObserver(forName: name, object: object, queue: queue) {
        [weak self] notification in
        self?.forward(isActivation: notification.name == activationName, onChange: onChange)
      }
      lock.withLock { registrations.append(Registration(center: center, token: token)) }
    }
  }

  /// The value now, then each real change. Closing the stream removes every observer.
  func stream(
    names: [Notification.Name],
    in center: NotificationCenter = .default,
    object: Any? = nil,
    queue: OperationQueue? = nil,
    bufferingPolicy: AsyncStream<Value>.Continuation.BufferingPolicy = .bufferingNewest(1)
  ) -> AsyncStream<Value> {
    let (stream, continuation) = AsyncStream<Value>.makeStream(bufferingPolicy: bufferingPolicy)
    continuation.yield(current)
    observe(names: names, in: center, object: object, queue: queue) { value in
      continuation.yield(value)
    }
    // The stream owns the observers when the caller does not; this keeps the object alive until
    // the consumer's task ends.
    continuation.onTermination = { [self] _ in cancel() }
    return stream
  }

  /// A stream whose observers belong to the stream alone.
  static func stream(
    read: @escaping @Sendable () -> Value,
    reemitOnActivate: Bool = false,
    notificationNames: [Notification.Name],
    activationName: Notification.Name? = nil,
    in center: NotificationCenter = .default,
    object: Any? = nil,
    queue: OperationQueue? = nil,
    bufferingPolicy: AsyncStream<Value>.Continuation.BufferingPolicy = .bufferingNewest(1)
  ) -> AsyncStream<Value> {
    PreferenceChanges(
      read: read, reemitsOnActivation: reemitOnActivate, activationName: activationName
    ).stream(
      names: notificationNames, in: center, object: object, queue: queue,
      bufferingPolicy: bufferingPolicy)
  }

  /// Stops every observer. Idempotent; also runs when the object is released.
  func cancel() {
    let stopped: [Registration] = lock.withLock {
      defer { registrations.removeAll() }
      return registrations
    }
    for registration in stopped {
      registration.center.removeObserver(registration.token)
    }
  }

  private func forward(isActivation: Bool, onChange: @Sendable (Value) -> Void) {
    let next = read()
    let forwards: Bool = lock.withLock {
      if next != last {
        last = next
        return true
      }
      guard reemitsOnActivation && isActivation else { return false }
      last = next
      return true
    }
    guard forwards else { return }
    onChange(next)
  }
}
