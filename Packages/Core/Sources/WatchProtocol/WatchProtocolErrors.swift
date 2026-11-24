public enum WatchProtocolCodingError: Error, Equatable, Sendable {
  case cryptographyUnavailable
  case unsupportedVersion(Int)
  case invalidValue
  case invalidFormat
  case invalidSelection
  case oversizedMetadata
  case tooManyRows
  case tooLarge
  case forbiddenMetadata
}

/// Stable, user-actionable error values. Raw values are part of the wire contract.
public enum WatchProtocolErrorCode: String, Codable, Sendable, Equatable {
  case accountUnavailable = "account_unavailable"
  case invalidCommand = "invalid_command"
  case invalidSelection = "invalid_selection"
  case commandConflict = "command_conflict"
  case deduplicationSaturated = "deduplication_saturated"
  case phoneUnreachable = "phone_unreachable"
  case ambiguousTransport = "ambiguous_transport"
  case malformedReply = "malformed_reply"
  case nativeWatchPlaybackUnavailable = "native_watch_playback_unavailable"
  case audioActivationFailed = "audio_activation_failed"
  case rejected = "rejected"
}
