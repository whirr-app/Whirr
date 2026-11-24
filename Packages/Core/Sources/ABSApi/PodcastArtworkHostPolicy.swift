import Foundation

/// The public-artwork-host policy for a podcast's declared cover URL.
///
/// A saved artwork URL may point anywhere the listener's device can reach, so the write boundary
/// accepts only a host that is publicly routable: no local name, and no loopback, private,
/// link-local, shared, multicast or documentation address in any IPv4 or IPv6 spelling, including
/// the shorthand and mapped forms a URL parser lets through. The checks read the literal host
/// only; name resolution is the network stack's business.
func isPublicArtworkHost(_ rawHost: String) -> Bool {
  // A trailing DNS root dot does not make localhost safe. Keep ordinary DNS names accepted while
  // treating every spelling of the local name as non-public.
  let host = rawHost.hasSuffix(".") ? String(rawHost.dropLast()) : rawHost
  guard host.isEmpty == false,
    host != "localhost",
    host.hasSuffix(".localhost") == false
  else { return false }

  let hostComponents = host.split(separator: ".", omittingEmptySubsequences: false)
  if hostComponents.allSatisfy(isIPv4ArtworkComponent) {
    guard let octets = parseIPv4ArtworkHost(host) else { return false }
    return isPublicIPv4ArtworkAddress(octets)
  }
  if host.contains(":") {
    guard let groups = parseIPv6ArtworkHost(host) else { return false }
    return isPublicIPv6ArtworkAddress(groups)
  }
  return true
}

func isIPv4ArtworkComponent(_ component: Substring) -> Bool {
  guard component.isEmpty == false else { return false }
  if component.hasPrefix("0x") {
    return component.dropFirst(2).isEmpty == false
      && component.dropFirst(2).utf8.allSatisfy {
        ($0 >= 48 && $0 <= 57) || ($0 >= 65 && $0 <= 70) || ($0 >= 97 && $0 <= 102)
      }
  }
  return component.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 })
}

func parseIPv4ArtworkHost(_ host: String, allowShorthand: Bool = true) -> [Int]? {
  let components = host.split(separator: ".", omittingEmptySubsequences: false)
  guard components.count == 4 || (allowShorthand && (1...3).contains(components.count)),
    components.allSatisfy(isIPv4ArtworkComponent)
  else { return nil }

  let values: [UInt64] = components.compactMap { component in
    let string = String(component)
    if string.hasPrefix("0x") {
      return UInt64(string.dropFirst(2), radix: 16)
    }
    // Do not accept legacy octal-looking spellings: different URL stacks disagree about whether
    // `010` means ten or eight, which could turn a public-looking host into a loopback/private one.
    guard string.count == 1 || string.first != "0" else { return nil }
    return UInt64(string, radix: 10)
  }
  guard values.count == components.count else { return nil }

  let address: UInt64
  switch values.count {
  case 1:
    guard values[0] <= UInt64(UInt32.max) else { return nil }
    address = values[0]
  case 2:
    guard values[0] <= 0xff, values[1] <= 0xffffff else { return nil }
    address = (values[0] << 24) | values[1]
  case 3:
    guard values[0] <= 0xff, values[1] <= 0xff, values[2] <= 0xffff else { return nil }
    address = (values[0] << 24) | (values[1] << 16) | values[2]
  case 4:
    guard values.allSatisfy({ $0 <= 0xff }) else { return nil }
    address = (values[0] << 24) | (values[1] << 16) | (values[2] << 8) | values[3]
  default:
    return nil
  }

  let address32 = UInt32(address)
  return [
    Int((address32 >> 24) & 0xff),
    Int((address32 >> 16) & 0xff),
    Int((address32 >> 8) & 0xff),
    Int(address32 & 0xff),
  ]
}

func isPublicIPv4ArtworkAddress(_ octets: [Int]) -> Bool {
  guard octets.count == 4 else { return false }
  let first = octets[0]
  let second = octets[1]
  let third = octets[2]
  switch first {
  case 0, 10, 127, 224...255:
    return false
  case 100 where (64...127).contains(second):
    return false  // Shared address space (RFC 6598).
  case 169 where second == 254:
    return false  // Link-local.
  case 172 where (16...31).contains(second):
    return false  // RFC 1918 private space.
  case 192 where second == 0 || second == 168 || (second == 88 && third == 99):
    return false  // Special-use and documentation ranges.
  case 198 where (18...19).contains(second) || second == 51:
    return false  // Benchmark and documentation ranges.
  case 203 where second == 0:
    return false  // Documentation range.
  default:
    return true
  }
}

func parseIPv6ArtworkHost(_ rawHost: String) -> [UInt16]? {
  var host = rawHost
  if host.first == "[", host.last == "]" {
    host.removeFirst()
    host.removeLast()
  }
  guard host.isEmpty == false, host.contains("%") == false,
    host.contains("[") == false, host.contains("]") == false
  else { return nil }

  let compressionParts = host.components(separatedBy: "::")
  guard compressionParts.count <= 2 else { return nil }
  if compressionParts.count == 2 {
    let left = tryParseIPv6ArtworkSide(compressionParts[0], allowIPv4Tail: false)
    let right = tryParseIPv6ArtworkSide(compressionParts[1], allowIPv4Tail: true)
    guard let left, let right, left.count + right.count < 8 else { return nil }
    return left + Array(repeating: 0, count: 8 - left.count - right.count) + right
  }

  guard let groups = tryParseIPv6ArtworkSide(host, allowIPv4Tail: true), groups.count == 8 else {
    return nil
  }
  return groups
}

func tryParseIPv6ArtworkSide(_ side: String, allowIPv4Tail: Bool) -> [UInt16]? {
  guard side.isEmpty == false else { return [] }
  let components = side.split(separator: ":", omittingEmptySubsequences: false)
  guard components.isEmpty == false, components.allSatisfy({ $0.isEmpty == false }) else {
    return nil
  }

  var groups = [UInt16]()
  groups.reserveCapacity(8)
  for (index, component) in components.enumerated() {
    if component.contains(".") {
      guard allowIPv4Tail, index == components.index(before: components.endIndex),
        let octets = parseIPv4ArtworkHost(String(component), allowShorthand: false)
      else { return nil }
      groups.append(UInt16((octets[0] << 8) | octets[1]))
      groups.append(UInt16((octets[2] << 8) | octets[3]))
    } else {
      guard component.utf8.count <= 4,
        component.utf8.allSatisfy({
          ($0 >= 48 && $0 <= 57) || ($0 >= 65 && $0 <= 70) || ($0 >= 97 && $0 <= 102)
        }),
        let group = UInt16(component, radix: 16)
      else { return nil }
      groups.append(group)
    }
  }
  return groups
}

func isPublicIPv6ArtworkAddress(_ groups: [UInt16]) -> Bool {
  guard groups.count == 8 else { return false }
  let first = groups[0]
  let second = groups[1]

  // Unspecified, loopback, IPv4-compatible, and IPv4-mapped forms all begin with zero. A mapped
  // public IPv4 address remains eligible; every other zero-prefix form is local/non-routable.
  if first == 0 {
    if groups[0...4].allSatisfy({ $0 == 0 }) && groups[5] == 0xffff {
      let octets = [
        Int(groups[6] >> 8), Int(groups[6] & 0xff),
        Int(groups[7] >> 8), Int(groups[7] & 0xff),
      ]
      return isPublicIPv4ArtworkAddress(octets)
    }
    return false
  }
  if first & 0xfe00 == 0xfc00 { return false }  // Unique-local.
  if first & 0xffc0 == 0xfe80 { return false }  // Link-local.
  if first & 0xff00 == 0xff00 { return false }  // Multicast.
  if first & 0xffc0 == 0xfec0 { return false }  // Deprecated site-local.
  if first == 0x2001
    && (second == 0x0002 || (0x0010...0x002f).contains(second) || second == 0x0db8)
  {
    return false  // Benchmark, ORCHID/ORCHIDv2, and documentation ranges.
  }
  return first & 0xe000 == 0x2000  // Global unicast (2000::/3).
}
