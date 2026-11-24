import SyncEngine

/// Copy for the book menu's Send to E-reader entry. Device names are the server administrator's
/// own labels, so nothing here says "Kindle".
public enum EbookDeliveryCopy {
  public static let submenuTitle = "Send to E-reader"
  public static let systemImage = "paperplane"
  public static let sentSystemImage = "paperplane.fill"

  public static func sendTo(_ deviceName: String) -> String {
    "Send to \(deviceName)"
  }

  public static func sent(deviceName: String) -> String {
    sentPrefix + deviceName
  }

  /// Lets the banner recognise its own confirmation without a second channel for the symbol.
  public static func isSentConfirmation(_ message: String) -> Bool {
    message.hasPrefix(sentPrefix)
  }

  public static func uncertain(deviceName: String) -> String {
    "The server didn't confirm the send. It may still arrive on \(deviceName), so check before "
      + "trying again."
  }

  public static func notSent(
    _ reason: EbookDeliveryOutcome.NotSentReason, deviceName: String
  ) -> String {
    switch reason {
    case .serverEmailUnavailable:
      "Audiobookshelf couldn't send email. Check the server's email settings."
    case .rejectedByMailServer:
      "The mail server wouldn't accept it. The file may be too large."
    case .notPermitted:
      "You don't have access to \(deviceName)."
    case .deviceNotFound:
      "\(deviceName) is no longer set up on the server."
    case .noEbookFile:
      "The server has no ebook file for this book."
    case .unreachable:
      "Couldn't reach the server. Nothing was sent."
    case .signInRequired:
      "Sign in again to send ebooks."
    case .refused:
      "The server couldn't send it to \(deviceName)."
    }
  }

  private static let sentPrefix = "Sent to "
}

/// What a book menu draws for Send to E-reader, if anything. The server sends the item's
/// primary ebook file whatever its format, so a document Whirr cannot open still qualifies;
/// whether the device accepts that format is the device vendor's rule, not Whirr's.
public enum EbookDeliveryMenuEntry: Sendable, Equatable {
  case single(EbookDeliveryDevice)
  case submenu([EbookDeliveryDevice])

  public static func resolve(
    capability: ItemMediaCapability, devices: [EbookDeliveryDevice]
  ) -> EbookDeliveryMenuEntry? {
    switch capability {
    case .ebook, .audioAndEbook, .unsupportedDocument: break
    case .audio, .podcast: return nil
    }
    switch devices.count {
    case 0: return nil
    case 1: return .single(devices[0])
    default: return .submenu(devices)
    }
  }
}
