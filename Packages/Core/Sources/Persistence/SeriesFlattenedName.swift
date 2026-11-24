import Foundation

/// Parses Audiobookshelf's flattened series display value. It cannot resolve, and never will,
/// a series name containing `", "`, a series name containing `" #"`, or a sequence containing
/// `", "`; Stage 2 of the parity plan is what removes those ambiguities.
enum SeriesFlattenedName {
  struct Entry: Equatable {
    let name: String
    let sequence: String?
  }

  static func entries(from value: String?) -> [Entry] {
    guard let value else { return [] }

    return value.components(separatedBy: ", ").compactMap { component in
      let component = component.trimmingCharacters(in: .whitespacesAndNewlines)
      guard component.isEmpty == false else { return nil }

      guard let marker = component.range(of: " #", options: .backwards) else {
        return Entry(name: component, sequence: nil)
      }

      let sequence = component[marker.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
      guard sequence.isEmpty == false else {
        return Entry(name: component, sequence: nil)
      }

      let name = component[..<marker.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
      guard name.isEmpty == false else { return nil }
      return Entry(name: name, sequence: sequence)
    }
  }

  static func sequenceValue(_ sequence: String?) -> Double? {
    guard let sequence else { return nil }

    let scalars = Array(sequence.unicodeScalars)
    var index = 0
    while index < scalars.count && scalars[index].properties.isWhitespace {
      index += 1
    }

    let numberStart = index
    if index < scalars.count && (scalars[index].value == 0x2B || scalars[index].value == 0x2D) {
      index += 1
    }

    var digitCount = 0
    while index < scalars.count && isASCIIDigit(scalars[index]) {
      index += 1
      digitCount += 1
    }

    if index < scalars.count && scalars[index].value == 0x2E {
      index += 1
      while index < scalars.count && isASCIIDigit(scalars[index]) {
        index += 1
        digitCount += 1
      }
    }

    guard digitCount > 0 else { return 0.0 }

    let mantissaEnd = index
    if index < scalars.count && (scalars[index].value == 0x45 || scalars[index].value == 0x65) {
      var exponentIndex = index + 1
      if exponentIndex < scalars.count
        && (scalars[exponentIndex].value == 0x2B || scalars[exponentIndex].value == 0x2D)
      {
        exponentIndex += 1
      }

      let exponentStart = exponentIndex
      while exponentIndex < scalars.count && isASCIIDigit(scalars[exponentIndex]) {
        exponentIndex += 1
      }
      if exponentIndex > exponentStart {
        index = exponentIndex
      } else {
        index = mantissaEnd
      }
    }

    let numericPrefix = String(
      decoding: scalars[numberStart..<index].map { UInt8($0.value) }, as: UTF8.self)
    guard let value = Double(numericPrefix), value.isFinite else { return 0.0 }
    return value
  }

  private static func isASCIIDigit(_ scalar: Unicode.Scalar) -> Bool {
    (0x30...0x39).contains(scalar.value)
  }
}
