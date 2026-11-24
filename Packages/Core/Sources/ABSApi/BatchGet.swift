import Foundation

/// The server documents no maximum for `POST /api/items/batch/get`, so this reuses the
/// paginated-list bound from API-CONVENTIONS rule 15 as a conservative ceiling, consistent with
/// `LibraryItemsBounds`. Internal so tests can assert against it.
enum BatchGetBounds {
  static let maximum = 100
}

/// Input over the bound is rejected rather than truncated, since truncation would silently drop
/// ids the caller expects results for.
public enum BatchGetError: Error, Sendable, Equatable {
  case tooManyIDs(requested: Int, maximum: Int)
}

extension ABSClient {
  /// `POST /api/items/batch/get`. Use instead of N sequential `GET /api/items/{id}` calls
  /// (API-CONVENTIONS rule 15). Empty `ids` returns `[]` without a network round-trip.
  public func batchGetItems(
    account: TokenAccount,
    ids: [String],
    diagnostics: DecodeDiagnostics? = nil
  ) async throws -> [ItemDetail] {
    guard ids.isEmpty == false else { return [] }
    guard ids.count <= BatchGetBounds.maximum else {
      throw BatchGetError.tooManyIDs(requested: ids.count, maximum: BatchGetBounds.maximum)
    }

    let tokens = try loadTokens(for: account)
    let request = try requestBuilder.makeJSONRequest(
      method: .post,
      path: "/api/items/batch/get",
      body: BatchGetRequestDTO(libraryItemIds: ids),
      routeTemplate: "/api/items/batch/get"
    )
    let response = try await authenticatedSend(request, account: account, initialTokens: tokens)
    try validateSuccess(response)

    let wire = try decoder.decode(
      BatchGetResponseDTO.self,
      from: response.body,
      endpoint: "/api/items/batch/get",
      diagnostics: diagnostics
    )
    // Safety net: `wire.libraryItems` already excludes required-id failures via `requiredKey`.
    return wire.libraryItems.compactMap { dto -> ItemDetail? in
      guard let id = dto.id else { return nil }
      return ItemDetail(dto: dto, id: id)
    }
  }

}

private struct BatchGetRequestDTO: Encodable, Sendable {
  let libraryItemIds: [String]
}

private struct BatchGetResponseDTO: Decodable {
  let libraryItems: [ItemDetailDTO]

  private enum CodingKeys: String, CodingKey { case libraryItems }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    libraryItems = try container.decodeLossyArray(
      forKey: .libraryItems,
      validating: { $0.id != nil },
      requiredKey: "id"
    )
  }
}
