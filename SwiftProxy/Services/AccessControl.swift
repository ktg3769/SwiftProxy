import Foundation
import Darwin

enum IPParser {
    /// 숫자 IP 문자열을 네트워크 바이트 순서 바이트 배열로 변환한다.
    /// IPv4는 4바이트, IPv6는 16바이트. IPv4-mapped IPv6(::ffff:a.b.c.d)는 IPv4 4바이트로 정규화한다.
    /// 스코프 ID(예: fe80::1%en0)는 무시한다.
    static func bytes(_ raw: String) -> [UInt8]? {
        var s = raw.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("[") && s.hasSuffix("]") { s = String(s.dropFirst().dropLast()) }
        if let pct = s.firstIndex(of: "%") { s = String(s[..<pct]) }
        guard !s.isEmpty else { return nil }

        var v4 = in_addr()
        if inet_pton(AF_INET, s, &v4) == 1 {
            return withUnsafeBytes(of: &v4) { Array($0) }
        }
        var v6 = in6_addr()
        if inet_pton(AF_INET6, s, &v6) == 1 {
            let b = withUnsafeBytes(of: &v6) { Array($0) }
            let mappedPrefix: [UInt8] = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff]
            if Array(b[0..<12]) == mappedPrefix {
                return Array(b[12..<16])
            }
            return b
        }
        return nil
    }
}

/// CIDR 표기 주소 범위 (예: 192.168.0.0/16, fe80::/10).
struct IPAddressRange: Equatable, Sendable, CustomStringConvertible {
    let network: [UInt8]
    let prefixLength: Int

    init?(cidr: String) {
        let parts = cidr.trimmingCharacters(in: .whitespaces).split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 1 || parts.count == 2, let addr = IPParser.bytes(String(parts[0])) else { return nil }
        let maxBits = addr.count * 8
        let prefix: Int
        if parts.count == 2 {
            guard let p = Int(parts[1]), (0...maxBits).contains(p) else { return nil }
            prefix = p
        } else {
            prefix = maxBits
        }
        self.network = IPAddressRange.mask(addr, prefix: prefix)
        self.prefixLength = prefix
    }

    func contains(_ address: [UInt8]) -> Bool {
        guard address.count == network.count else { return false }
        return IPAddressRange.mask(address, prefix: prefixLength) == network
    }

    func contains(_ address: String) -> Bool {
        guard let b = IPParser.bytes(address) else { return false }
        return contains(b)
    }

    var description: String {
        if network.count == 4 {
            return network.map(String.init).joined(separator: ".") + "/\(prefixLength)"
        }
        var groups: [String] = []
        for i in stride(from: 0, to: 16, by: 2) {
            groups.append(String(UInt16(network[i]) << 8 | UInt16(network[i + 1]), radix: 16))
        }
        return groups.joined(separator: ":") + "/\(prefixLength)"
    }

    private static func mask(_ bytes: [UInt8], prefix: Int) -> [UInt8] {
        var out = bytes
        for i in 0..<out.count {
            let bitsInByte = max(0, min(8, prefix - i * 8))
            let m: UInt8 = bitsInByte == 0 ? 0 : UInt8(truncatingIfNeeded: 0xFF << (8 - bitsInByte))
            out[i] &= m
        }
        return out
    }
}

enum AccessControl {
    /// "로컬 네트워크만" 정책에서 허용하는 범위.
    static let localRanges: [IPAddressRange] = [
        "10.0.0.0/8",
        "172.16.0.0/12",
        "192.168.0.0/16",
        "169.254.0.0/16",   // IPv4 link-local
        "127.0.0.0/8",      // loopback
        "100.64.0.0/10",    // CGNAT / 일부 핫스팟 구성
        "fc00::/7",         // IPv6 ULA
        "fe80::/10",        // IPv6 link-local
        "::1/128",
    ].compactMap { IPAddressRange(cidr: $0) }

    /// - Parameter lanPrefixes: iPhone의 Wi-Fi·핫스팟 인터페이스에 붙은 IPv6 대역(/64).
    ///   핫스팟 클라이언트는 통신사에서 받은 공인 IPv6(예: 2001:…)를 쓰므로 사설 대역 검사만으로는 거부된다.
    static func isAllowed(address: String, policy: AccessPolicy, allowList: [IPAddressRange],
                          lanPrefixes: [IPAddressRange] = []) -> Bool {
        switch policy {
        case .anyone:
            return true
        case .localNetworkOnly:
            guard let b = IPParser.bytes(address) else { return false }
            return localRanges.contains { $0.contains(b) } || lanPrefixes.contains { $0.contains(b) }
        case .allowList:
            guard let b = IPParser.bytes(address) else { return false }
            return allowList.contains { $0.contains(b) }
        }
    }
}

enum Redactor {
    /// 로그와 UI에 쓸 수 있도록 IP 주소를 일부 가린다. reveal이 true면 그대로 반환한다.
    static func address(_ raw: String, reveal: Bool = false) -> String {
        if reveal { return raw }
        var s = raw
        if let pct = s.firstIndex(of: "%") { s = String(s[..<pct]) }
        if s.contains(":") {
            let groups = s.split(separator: ":", omittingEmptySubsequences: false)
            let head = groups.prefix(2).joined(separator: ":")
            return head + ":…"
        }
        let octets = s.split(separator: ".")
        guard octets.count == 4 else { return "…" }
        return "\(octets[0]).\(octets[1]).x.x"
    }
}
