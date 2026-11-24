import ABSApi
import Foundation
import Persistence

extension NativeEpisodeServerSaveSupport {
  static func outcome(
    from record: NativeEpisodeServerSaveAttemptRecord,
    fallback: NativeEpisodeServerSaveOutcome
  ) -> NativeEpisodeServerSaveOutcome {
    guard let id = record.id else { return fallback }
    switch record.state {
    case .accepted:
      guard let itemID = record.serverItemId else { return fallback }
      return .accepted(attemptID: id, serverItemID: itemID)
    case .createUncertain, .uncertain:
      return .uncertain(attemptID: id, state: record.state, category: record.errorCategory ?? .unknown)
    case .failed:
      return .failed(attemptID: id, state: record.state, category: record.errorCategory ?? .unknown)
    case .preparing:
      return fallback
    default:
      return .inProgress(attemptID: id, state: record.state, serverItemID: record.serverItemId)
    }
  }

  static func apiCategory(_ error: APIError) -> NativeEpisodeServerSaveErrorCategory {
    switch error {
    case .badRequest: return .invalidDestination
    case .forbidden, .unauthorized: return .permissionChanged
    case .notFound: return .staleIdentity
    case .transport: return .transport
    case .serverFailure: return .serverFailure
    case .decoding: return .malformedResponse
    case .cancelled: return .cancelled
    case .unexpectedStatus(let statusCode):
      switch statusCode {
      case 400: return .invalidDestination
      case 403: return .permissionChanged
      case 404: return .staleIdentity
      case 500...599: return .serverFailure
      default: return .serverFailure
      }
    case .payloadTooLarge, .rateLimited, .ambiguousLocalSessionResponse, .incompatibleServer,
      .invalidServerConfiguration:
      return .serverFailure
    }
  }

  static func readerCategory(
    _ error: NativeEpisodeServerSaveCommandReaderError
  ) -> NativeEpisodeServerSaveErrorCategory {
    switch error {
    case .nativeSubscriptionsDisabled: return .unsubscribed
    case .credentialedFeed: return .credentialedFeed
    case .feedNotFound, .episodeNotFound, .episodeNotInFeed: return .missingEpisode
    case .invalidFeedURL, .invalidEnclosureURL, .missingFeedTitle, .fieldTooLong:
      return .invalidDestination
    case .invalidIdentity: return .invalidDestination
    case .credentialStoreUnavailable: return .unknown
    }
  }

  static func resolverCategory(
    _ error: ServerPodcastDestinationResolverError
  ) -> NativeEpisodeServerSaveErrorCategory {
    switch error {
    case .invalidFeedURL, .invalidPagination, .pageCeilingReached, .invalidChoice:
      return .invalidDestination
    }
  }

  static func accountCategory(
    _ error: NativeEpisodeServerSaveAccountReadingError
  ) -> NativeEpisodeServerSaveErrorCategory {
    switch error {
    case .notAuthenticated, .malformedAccount: return .permissionChanged
    case .unavailable: return .unknown
    }
  }
}
