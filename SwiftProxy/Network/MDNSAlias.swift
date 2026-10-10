import Foundation
import Darwin
import dnssd

/// 고정 이름(swiftproxy.local)을 mDNS(Bonjour)로 알려 클라이언트가 바뀌는 IPv6 주소 대신 이름으로 접속하게 한다.
///
/// 핫스팟 클라이언트는 IPv6로만 이 앱에 닿는데(IPv4 172.20.10.1은 전달되지 않음), IPv6 주소는 통신사 대역이라
/// 셀룰러 재연결 때마다 바뀐다. 그래서 핫스팟·Wi-Fi 인터페이스의 IPv6 주소(공인 + link-local)를
/// AAAA 레코드로 등록하고, 주소가 바뀌면 다시 등록한다. IPv4(A) 레코드는 일부러 등록하지 않는다
/// (클라이언트가 닿지 않는 IPv4를 먼저 시도하다 시간 초과가 나는 것을 막기 위해).
///
/// 클라이언트(iPadOS 등)는 시스템 리졸버로 .local 이름을 mDNS로 조회한다.
final class MDNSAlias {
    static let name = "swiftproxy.local."
    static let displayName = "swiftproxy.local"

    struct Entry: Hashable {
        let address: String
        let interface: String
    }

    var onError: ((String) -> Void)?

    private let queue = DispatchQueue(label: "com.taegun.swiftproxy.mdns")
    private var connection: DNSServiceRef?
    private var registered: [Entry] = []

    /// 등록할 주소 목록을 갱신한다. 같으면 아무것도 하지 않는다.
    func update(_ entries: [Entry]) {
        queue.async { self.apply(entries) }
    }

    func stop() {
        queue.async { self.teardown() }
    }

    deinit {
        if let connection { DNSServiceRefDeallocate(connection) }
    }

    private func apply(_ entries: [Entry]) {
        let wanted = Array(Set(entries)).sorted { $0.address < $1.address }
        guard wanted != registered else { return }
        teardown()
        guard !wanted.isEmpty else { return }

        var ref: DNSServiceRef?
        var error = DNSServiceCreateConnection(&ref)
        guard error == DNSServiceErrorType(kDNSServiceErr_NoError), let ref else {
            report("mDNS 연결 생성 실패 (\(error))")
            return
        }
        error = DNSServiceSetDispatchQueue(ref, queue)
        guard error == DNSServiceErrorType(kDNSServiceErr_NoError) else {
            DNSServiceRefDeallocate(ref)
            report("mDNS 큐 설정 실패 (\(error))")
            return
        }
        connection = ref

        let context = Unmanaged.passUnretained(self).toOpaque()
        for entry in wanted {
            guard let bytes = IPParser.bytes(entry.address), bytes.count == 16 else { continue }
            let interfaceIndex = if_nametoindex(entry.interface)
            var record: DNSRecordRef?
            let status = bytes.withUnsafeBytes { raw in
                DNSServiceRegisterRecord(
                    ref, &record,
                    DNSServiceFlags(kDNSServiceFlagsShared),
                    interfaceIndex,
                    Self.name,
                    UInt16(kDNSServiceType_AAAA),
                    UInt16(kDNSServiceClass_IN),
                    UInt16(16),
                    raw.baseAddress,
                    120,
                    MDNSAlias.callback,
                    context)
            }
            if status != DNSServiceErrorType(kDNSServiceErr_NoError) {
                report("mDNS 이름 등록 실패 \(entry.address) (\(status))")
            }
        }
        registered = wanted
    }

    private func teardown() {
        if let connection {
            DNSServiceRefDeallocate(connection)   // 등록한 레코드도 함께 해제된다
        }
        connection = nil
        registered = []
    }

    fileprivate func report(_ message: String) {
        let handler = onError
        DispatchQueue.main.async { handler?(message) }
    }

    private static let callback: DNSServiceRegisterRecordReply = { _, _, _, errorCode, context in
        guard errorCode != DNSServiceErrorType(kDNSServiceErr_NoError), let context else { return }
        let alias = Unmanaged<MDNSAlias>.fromOpaque(context).takeUnretainedValue()
        alias.report("mDNS 이름 등록 오류 (\(errorCode))")
    }

    /// iPhone의 핫스팟·Wi-Fi 인터페이스 IPv6 주소 (공인·ULA·link-local 모두).
    static func currentEntries() -> [Entry] {
        InterfaceAddresses.all()
            .filter { $0.isLANCandidate && $0.isIPv6 }
            .map { Entry(address: $0.address, interface: $0.name) }
    }
}
