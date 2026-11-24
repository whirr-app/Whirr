extension Array {
  /// Splits the array into consecutive chunks of at most `maximumCount` elements.
  ///
  /// Returns an empty array when `maximumCount` is non-positive, including for non-empty input.
  public func chunked(maximumCount: Int) -> [[Element]] {
    guard maximumCount > 0 else { return [] }
    var result: [[Element]] = []
    var index = startIndex
    while index < endIndex {
      let next = self.index(index, offsetBy: maximumCount, limitedBy: endIndex) ?? endIndex
      result.append(Array(self[index..<next]))
      index = next
    }
    return result
  }
}
