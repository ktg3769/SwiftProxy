import Foundation
import Darwin

struct InterfaceAddress: Identifiable, Hashable, Sendable {
    let name: String
    let address: String
    let isIPv6: Bool

    var id: String { "\(name)|\(address)" }

    var isLinkLocal: Bool {
        isIPv6 ? address.lowercased().hasPrefix("fe80") : address.hasPrefix("169.254.")
    }

    /// 다른 기기가 접속할 때 쓸 수 있는 인터페이스인지 (Wi-Fi: en*, 개인용 핫스팟: bridge*).
    var isLANCandidate: Bool {
        name.hasPrefix("en") || name.hasPrefix("bridge")
    }

    var kindLabel: String {
        if name.hasPrefix("bridge") { return "핫스팟" }
        if name.hasPrefix("en") { return "Wi-Fi" }
        if name.hasPrefix("pdp_ip") { return "셀룰러" }
        if name.hasPrefix("utun") || name.hasPrefix("ipsec") { return "VPN" }
        return "기타"
    }
}

enum InterfaceAddresses {
    /// 활성화된 비-루프백 인터페이스의 모든 숫자 주소.
    static func all() -> [InterfaceAddress] {
        var result: [InterfaceAddress] = []
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }

        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = ptr.pointee
            let flags = Int32(bitPattern: entry.ifa_flags)
            let upRunning = Int32(IFF_UP | IFF_RUNNING)
            guard flags & upRunning == upRunning, flags & Int32(IFF_LOOPBACK) == 0 else { continue }
            guard let sa = entry.ifa_addr else { continue }

            let family = Int32(sa.pointee.sa_family)
            guard family == AF_INET || family == AF_INET6 else { continue }
            let length = socklen_t(family == AF_INET ? MemoryLayout<sockaddr_in>.size : MemoryLayout<sockaddr_in6>.size)

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(sa, length, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let address = host.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
            let name = String(cString: entry.ifa_name)
            result.append(InterfaceAddress(name: name, address: address, isIPv6: family == AF_INET6))
        }
        return result
    }

    /// 같은 LAN의 다른 기기가 접속할 수 있는 주소. IPv4를 먼저, link-local은 뒤로 보낸다.
    static func lanAddresses() -> [InterfaceAddress] {
        all()
            .filter(\.isLANCandidate)
            .sorted { a, b in
                if a.isLinkLocal != b.isLinkLocal { return !a.isLinkLocal }
                if a.isIPv6 != b.isIPv6 { return !a.isIPv6 }
                return a.name < b.name
            }
    }
}
