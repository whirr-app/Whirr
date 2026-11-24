import Foundation

public struct EndpointDecodeLimits: Sendable, Equatable {
  public static let standard = EndpointDecodeLimits()

  public let maximumBodyBytes: Int
  public let maximumListStringBytes: Int
  public let maximumArrayElements: Int

  public init(
    maximumBodyBytes: Int = 25 * 1024 * 1024,
    maximumListStringBytes: Int = 16 * 1024,
    maximumArrayElements: Int = 20_000
  ) {
    self.maximumBodyBytes = maximumBodyBytes
    self.maximumListStringBytes = maximumListStringBytes
    self.maximumArrayElements = maximumArrayElements
  }
}

public struct DecodeDiagnostic: Sendable, Equatable, CustomStringConvertible {
  public let endpoint: String
  public let elementIndex: Int?
  public let codingPath: [String]

  public init(endpoint: String, elementIndex: Int? = nil, codingPath: [String] = []) {
    self.endpoint = endpoint
    self.elementIndex = elementIndex
    self.codingPath = codingPath
  }

  public var description: String {
    let index = elementIndex.map(String.init) ?? "-"
    let path = codingPath.isEmpty ? "$" : "$." + codingPath.joined(separator: ".")
    return "endpoint=\(endpoint) index=\(index) path=\(path)"
  }
}

public final class DecodeDiagnostics: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: [DecodeDiagnostic] = []

  public init() {}

  public var entries: [DecodeDiagnostic] {
    lock.lock()
    defer { lock.unlock() }
    return storage
  }

  fileprivate func record(
    endpoint: String,
    elementIndex: Int? = nil,
    codingPath: [String] = []
  ) {
    lock.lock()
    storage.append(
      DecodeDiagnostic(endpoint: endpoint, elementIndex: elementIndex, codingPath: codingPath)
    )
    lock.unlock()
  }
}

@propertyWrapper
public struct LossyOptional<Value: Decodable>: Decodable {
  public var wrappedValue: Value?

  public init(wrappedValue: Value? = nil) {
    self.wrappedValue = wrappedValue
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    guard container.decodeNil() == false else {
      wrappedValue = nil
      return
    }
    wrappedValue = try? container.decode(Value.self)
  }
}

public enum BoundedStringPolicy: Sendable {
  case truncate
  case reject
}

extension KeyedDecodingContainer {
  public func decode<Value>(
    _ type: LossyOptional<Value>.Type,
    forKey key: Key
  ) throws -> LossyOptional<Value> where Value: Decodable {
    try decodeIfPresent(type, forKey: key) ?? LossyOptional(wrappedValue: nil)
  }

  public func decodeBoundedString(
    forKey key: Key,
    policy: BoundedStringPolicy = .truncate,
    maximumBytes: Int? = nil
  ) throws -> String? {
    guard let value = try decode(LossyOptional<String>.self, forKey: key).wrappedValue else {
      return nil
    }

    let configuredLimit =
      try? superDecoder(forKey: key).userInfo[BoundedDecoderContext.maximumStringBytesKey] as? Int
    let limit =
      maximumBytes
      ?? configuredLimit.flatMap { $0 }
      ?? EndpointDecodeLimits.standard.maximumListStringBytes
    guard value.utf8.count > limit else { return value }

    switch policy {
    case .reject:
      throw BoundedDecodingFailure.stringTooLong
    case .truncate:
      let prefix = Data(value.utf8.prefix(limit))
      return String(data: prefix, encoding: .utf8) ?? ""
    }
  }

  /// Optional-identity counterpart to `decodeBoundedString(forKey:policy: .reject)`.
  ///
  /// Absent and JSON-null decode to `nil`, as an ordinary optional would. A present value that is
  /// wrong-typed or exceeds the configured bound throws instead of decoding to `nil`: for an
  /// optional identity, `nil` can mean a different row (item-level rather than episode progress),
  /// so a rejection must drop the whole element through the caller's lossy-array handling.
  func decodeOptionalIdentity(forKey key: Key) throws -> String? {
    guard contains(key), try decodeNil(forKey: key) == false else { return nil }
    let value = try decode(String.self, forKey: key)
    let limit = BoundedDecoderContext.maximumListStringBytes(from: try superDecoder(forKey: key))
    guard value.utf8.count <= limit else { throw BoundedDecodingFailure.stringTooLong }
    return value
  }

  /// A server-side file identity (`ino`). Audiobookshelf sends a JSON string
  /// (`"ino": "649641337522215266"`); a number is tolerated for servers or fixtures that emit one.
  /// Kept as a string because values exceed `Int32` and nothing downstream needs the numeric
  /// value. Null, missing, empty, non-scalar or implausibly long values decode as `nil`. Never
  /// truncated, since a truncated identity would address a different file.
  public func decodeFileIdentifier(forKey key: Key, maximumBytes: Int = 64) throws -> String? {
    let raw =
      try decode(LossyOptional<String>.self, forKey: key).wrappedValue
      ?? decode(LossyOptional<Int64>.self, forKey: key).wrappedValue.map(String.init)
    guard let raw, raw.isEmpty == false, raw.utf8.count <= maximumBytes else { return nil }
    return raw
  }

  /// Converts a millisecond-epoch numeric field (as Audiobookshelf sends `lastUpdate`,
  /// `startedAt`, `finishedAt` and similar) to `Date`. Null, missing, wrong-type, negative, NaN or
  /// infinite values decode as `nil` rather than throwing (API-CONVENTIONS rule 21).
  public func decodeEpochMillisDate(forKey key: Key) throws -> Date? {
    guard let millis = try decode(LossyOptional<Double>.self, forKey: key).wrappedValue else {
      return nil
    }
    guard millis.isFinite, millis >= 0 else { return nil }
    return Date(timeIntervalSince1970: millis / 1000)
  }
}

public struct LossyArray<Element: Decodable>: Decodable {
  struct IndexedElement {
    let index: Int
    let value: Element
  }

  let indexedElements: [IndexedElement]
  /// Every element the container held, including ones dropped because they failed to decode.
  /// `decodeLossyArrayCountingDropped` needs it to combine these with elements that later fail
  /// its `validating` filter into one dropped count.
  let totalElementCount: Int
  public var elements: [Element] { indexedElements.map(\.value) }

  public init(from decoder: Decoder) throws {
    var container = try decoder.unkeyedContainer()
    var values: [IndexedElement] = []
    values.reserveCapacity(min(container.count ?? 0, BoundedDecoderContext.maximumArrayElements(from: decoder)))
    var total = 0

    while container.isAtEnd == false {
      let index = container.currentIndex
      guard index < BoundedDecoderContext.maximumArrayElements(from: decoder) else {
        throw BoundedDecodingFailure.arrayTooLarge
      }

      let elementDecoder = try container.superDecoder()
      total += 1
      do {
        values.append(IndexedElement(index: index, value: try Element(from: elementDecoder)))
      } catch {
        let codingPath: [String]
        if let decodingError = error as? DecodingError {
          codingPath = safeCodingPath(from: decodingError)
        } else {
          codingPath = elementDecoder.codingPath.compactMap { key in
            key.intValue == nil ? key.stringValue : nil
          }
        }
        BoundedDecoderContext.record(
          from: elementDecoder,
          elementIndex: index,
          codingPath: codingPath
        )
      }
    }
    indexedElements = values
    totalElementCount = total
  }
}

extension KeyedDecodingContainer {
  /// Nested-field counterpart to `BoundedDecoder.decodeLossyArray(_:from:...)`, for paginated
  /// responses that wrap the item array in an object. `LossyArray.init` skips malformed elements
  /// with diagnostics (`superDecoder` carries the decoder's `userInfo` through at any depth).
  /// This adds the required-key/validating post-filter, with matching diagnostics, for elements
  /// that decode but fail the endpoint's required-field contract.
  public func decodeLossyArray<Element: Decodable>(
    forKey key: Key,
    validating: (Element) -> Bool = { _ in true },
    requiredKey: String? = nil
  ) throws -> [Element] {
    let elementDecoder = try superDecoder(forKey: key)
    let array = try LossyArray<Element>(from: elementDecoder)
    return array.indexedElements.compactMap { indexedElement in
      guard validating(indexedElement.value) else {
        BoundedDecoderContext.record(
          from: elementDecoder,
          elementIndex: indexedElement.index,
          codingPath: requiredKey.map { [$0] } ?? []
        )
        return nil
      }
      return indexedElement.value
    }
  }

  /// Same decode as `decodeLossyArray(forKey:validating:requiredKey:)`, plus the total count of
  /// elements dropped, whether they failed to decode or failed `validating`. For callers that must
  /// know the list is the server's complete list (e.g. `UserProgressSnapshot.isComplete`, which
  /// the cross-device reset needs before inferring anything from a row's absence).
  public func decodeLossyArrayCountingDropped<Element: Decodable>(
    forKey key: Key,
    validating: (Element) -> Bool = { _ in true },
    requiredKey: String? = nil
  ) throws -> (elements: [Element], droppedCount: Int) {
    let elementDecoder = try superDecoder(forKey: key)
    let array = try LossyArray<Element>(from: elementDecoder)
    var kept: [Element] = []
    kept.reserveCapacity(array.indexedElements.count)
    for indexedElement in array.indexedElements {
      guard validating(indexedElement.value) else {
        BoundedDecoderContext.record(
          from: elementDecoder,
          elementIndex: indexedElement.index,
          codingPath: requiredKey.map { [$0] } ?? []
        )
        continue
      }
      kept.append(indexedElement.value)
    }
    return (kept, array.totalElementCount - kept.count)
  }
}

public struct BoundedDecoder: Sendable {
  public let limits: EndpointDecodeLimits

  public init(limits: EndpointDecodeLimits = .standard) {
    self.limits = limits
  }

  public func decode<Value: Decodable>(
    _ type: Value.Type,
    from data: Data,
    endpoint: String,
    diagnostics: DecodeDiagnostics? = nil
  ) throws -> Value {
    guard data.count <= limits.maximumBodyBytes else {
      throw APIError.payloadTooLarge
    }

    do {
      return try makeDecoder(endpoint: endpoint, diagnostics: diagnostics).decode(type, from: data)
    } catch let error as APIError {
      throw error
    } catch {
      diagnostics?.record(endpoint: endpoint)
      throw APIError.decoding
    }
  }

  public func decodeLossyArray<Element: Decodable>(
    _ type: Element.Type,
    from data: Data,
    endpoint: String,
    diagnostics: DecodeDiagnostics? = nil,
    validating: (Element) -> Bool = { _ in true },
    requiredKey: String? = nil
  ) throws -> [Element] {
    let array = try decode(
      LossyArray<Element>.self,
      from: data,
      endpoint: endpoint,
      diagnostics: diagnostics
    )
    return array.indexedElements.compactMap { indexedElement in
      let index = indexedElement.index
      let element = indexedElement.value
      guard validating(element) else {
        diagnostics?.record(
          endpoint: endpoint,
          elementIndex: index,
          codingPath: requiredKey.map { [$0] } ?? []
        )
        return nil
      }
      return element
    }
  }

  private func makeDecoder(endpoint: String, diagnostics: DecodeDiagnostics?) -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.userInfo[BoundedDecoderContext.endpointKey] = endpoint
    decoder.userInfo[BoundedDecoderContext.diagnosticsKey] = diagnostics
    decoder.userInfo[BoundedDecoderContext.maximumStringBytesKey] = limits.maximumListStringBytes
    decoder.userInfo[BoundedDecoderContext.maximumArrayElementsKey] = limits.maximumArrayElements
    return decoder
  }
}

private enum BoundedDecodingFailure: Error {
  case stringTooLong
  case arrayTooLarge
}

enum BoundedDecoderContext {
  static let endpointKey = CodingUserInfoKey(rawValue: "ABSApi.BoundedDecoder.endpoint")!
  static let diagnosticsKey = CodingUserInfoKey(rawValue: "ABSApi.BoundedDecoder.diagnostics")!
  static let maximumStringBytesKey = CodingUserInfoKey(rawValue: "ABSApi.BoundedDecoder.maximumStringBytes")!
  static let maximumArrayElementsKey = CodingUserInfoKey(rawValue: "ABSApi.BoundedDecoder.maximumArrayElements")!

  static func maximumListStringBytes(from decoder: Decoder) -> Int {
    decoder.userInfo[maximumStringBytesKey] as? Int ?? EndpointDecodeLimits.standard.maximumListStringBytes
  }
  static func maximumArrayElements(from decoder: Decoder) -> Int {
    decoder.userInfo[maximumArrayElementsKey] as? Int ?? EndpointDecodeLimits.standard.maximumArrayElements
  }

  static func record(
    from decoder: Decoder,
    elementIndex: Int? = nil,
    codingPath: [String] = []
  ) {
    guard let diagnostics = decoder.userInfo[diagnosticsKey] as? DecodeDiagnostics else { return }
    let endpoint = decoder.userInfo[endpointKey] as? String ?? "<unknown>"
    diagnostics.record(endpoint: endpoint, elementIndex: elementIndex, codingPath: codingPath)
  }
}

private func safeCodingPath(from error: DecodingError) -> [String] {
  let path: [any CodingKey]
  switch error {
  case .typeMismatch(_, let context), .valueNotFound(_, let context), .dataCorrupted(let context):
    path = context.codingPath
  case .keyNotFound(let key, let context):
    path = context.codingPath + [key]
  @unknown default:
    path = []
  }
  return path.compactMap { key in
    key.intValue == nil ? key.stringValue : nil
  }
}
