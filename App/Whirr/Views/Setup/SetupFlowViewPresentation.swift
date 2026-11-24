import AppModel
import DesignSystem
import SwiftUI

struct SetupHeaderActionPresentation: Equatable {
  let title: String
  let systemImage: String
  let role: MediaActionRole

  var buttonRole: ButtonRole? {
    role == .destructive ? .destructive : nil
  }
}

extension SetupFlowLayout {
  static let deleteHeaderAction = SetupHeaderActionPresentation(
    title: "Delete", systemImage: "trash", role: .destructive)
}

enum SetupFlowMotion {
  nonisolated static func focusScrollAnimation(reduceMotion: Bool) -> Animation? {
    reduceMotion ? nil : .smooth(duration: 0.3)
  }
}

enum SetupFlowLayout {
  nonisolated enum Region: Hashable {
    case brandHeader
    case form
  }

  nonisolated enum ContentPresentation: Hashable {
    case groupedForm
  }

  nonisolated enum CredentialPresentation {
    case compactForm
  }

  nonisolated enum HeaderValueFieldPresentation {
    case secure
  }

  static let contentTopPadding: CGFloat = WhirrSpacing.small
  static let fixedRegions: Set<Region> = [.brandHeader]
  static let scrollableRegions: Set<Region> = [.form]
  static let contentPresentation = ContentPresentation.groupedForm
  static let credentialPresentation = CredentialPresentation.compactForm
  static let headerValueFieldPresentation = HeaderValueFieldPresentation.secure

  static func scrollAnchor(for field: SetupFlowField) -> UnitPoint {
    switch field {
    case .server, .username:
      return .center
    case .password, .apiToken:
      return UnitPoint(x: 0.5, y: 0.72)
    }
  }
}
