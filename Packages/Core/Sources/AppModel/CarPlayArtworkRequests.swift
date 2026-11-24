/// What one car thumbnail is: the row's artwork, in the graph it was listed under, at the size
/// and appearance the car asked for. A result for any other key is not this row's image.
public struct CarPlayArtworkKey: Sendable, Hashable {
  public let generation: Int
  public let reference: CarPlayArtworkReference
  /// The longer edge in pixels: the car's point size times its display scale.
  public let pixelSize: Int
  public let isDark: Bool

  public init(generation: Int, reference: CarPlayArtworkReference, pixelSize: Int, isDark: Bool) {
    self.generation = generation
    self.reference = reference
    self.pixelSize = pixelSize
    self.isDark = isDark
  }
}

/// The car's thumbnail working set.
///
/// Rows go on screen with placeholders; this fills them in afterwards. Only the keys last named
/// by `show` are wanted: a request for a gone page is cancelled, and a late result for one is kept
/// but not delivered. Loading is injected (the cover and feed-artwork clients), so this adds no
/// second pipeline.
@MainActor
public final class CarPlayArtworkRequests<Image: Sendable> {
  public typealias Load = @Sendable (CarPlayArtworkKey) async -> Image?
  public typealias Sleep = @Sendable (Duration) async throws -> Void

  private let capacity: Int
  private let retryDelays: [Duration]
  private let sleep: Sleep
  private let load: Load
  private var images: [CarPlayArtworkKey: Image] = [:]
  /// Least recently used first.
  private var order: [CarPlayArtworkKey] = []
  private var tasks: [CarPlayArtworkKey: Task<Void, Never>] = [:]
  private var visible: Set<CarPlayArtworkKey> = []
  private var deliver: (@MainActor (CarPlayArtworkKey, Image) -> Void)?
  private var epoch = 0

  /// A list is drawn once, so nothing asks again for a thumbnail whose load failed. A failed
  /// load is therefore retried after each of `retryDelays` in turn, for as long as its row
  /// stays on screen, and then given up until the row is next shown.
  public init(
    capacity: Int, retryDelays: [Duration] = [.seconds(2), .seconds(8), .seconds(30)],
    sleep: @escaping Sleep = { try await Task.sleep(for: $0) }, load: @escaping Load
  ) {
    self.capacity = max(0, capacity)
    self.retryDelays = retryDelays
    self.sleep = sleep
    self.load = load
  }

  public var cachedCount: Int { images.count }
  public var inFlightCount: Int { tasks.count }

  /// Declares the thumbnails now on screen. Returns the ones already held; each of the rest is
  /// handed to `deliver` when it loads, provided it is still wanted then.
  @discardableResult
  public func show(
    _ keys: [CarPlayArtworkKey], deliver: @escaping @MainActor (CarPlayArtworkKey, Image) -> Void
  ) -> [CarPlayArtworkKey: Image] {
    let wanted = keys.filter { $0.reference != .none }
    visible = Set(wanted)
    self.deliver = deliver
    for (key, task) in tasks where visible.contains(key) == false {
      task.cancel()
      tasks[key] = nil
    }
    var held: [CarPlayArtworkKey: Image] = [:]
    for key in wanted {
      if let image = images[key] {
        held[key] = image
        touch(key)
      } else if tasks[key] == nil {
        let epoch = epoch
        tasks[key] = Task { [weak self, load, retryDelays, sleep] in
          var image = await load(key)
          for delay in retryDelays {
            guard image == nil, (try? await sleep(delay)) != nil, Task.isCancelled == false else { break }
            image = await load(key)
          }
          self?.finish(key, image, epoch: epoch)
        }
      }
    }
    return held
  }

  /// Nothing is on screen: the scene disconnected, the account changed, or memory is short.
  /// Requests are cancelled and every held image released; nothing later is delivered.
  public func purge() {
    epoch += 1
    for task in tasks.values { task.cancel() }
    tasks = [:]
    images = [:]
    order = []
    visible = []
    deliver = nil
  }

  private func finish(_ key: CarPlayArtworkKey, _ image: Image?, epoch: Int) {
    guard epoch == self.epoch, tasks[key] != nil else { return }
    tasks[key] = nil
    guard let image, capacity > 0 else { return }
    images[key] = image
    touch(key)
    while order.count > capacity {
      // Never evict a thumbnail that is on screen in favour of one that is not.
      guard let victim = order.first(where: { visible.contains($0) == false }) ?? order.first else { break }
      order.removeAll { $0 == victim }
      images[victim] = nil
    }
    if visible.contains(key), images[key] != nil { deliver?(key, image) }
  }

  private func touch(_ key: CarPlayArtworkKey) {
    order.removeAll { $0 == key }
    order.append(key)
  }
}
