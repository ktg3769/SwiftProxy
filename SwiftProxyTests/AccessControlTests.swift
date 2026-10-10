import XCTest
@testable import SwiftProxy

final class AccessControlTests: XCTestCase {
    func testParsesIPv4AndIPv6() {
        XCTAssertEqual(IPParser.bytes("192.168.1.10"), [192, 168, 1, 10])
        XCTAssertEqual(IPParser.bytes("::1")?.count, 16)
        XCTAssertEqual(IPParser.bytes("fe80::1%en0")?.count, 16)
        XCTAssertEqual(IPParser.bytes("[2001:db8::1]")?.count, 16)
        XCTAssertNil(IPParser.bytes("999.1.1.1"))
        XCTAssertNil(IPParser.bytes("not-an-ip"))
        XCTAssertNil(IPParser.bytes(""))
    }

    func testIPv4MappedIPv6IsNormalized() {
        XCTAssertEqual(IPParser.bytes("::ffff:192.168.0.5"), [192, 168, 0, 5])
    }

    func testCIDRParsing() {
        XCTAssertEqual(IPAddressRange(cidr: "192.168.1.77/24")?.description, "192.168.1.0/24")
        XCTAssertEqual(IPAddressRange(cidr: "10.0.0.1")?.prefixLength, 32)
        XCTAssertNil(IPAddressRange(cidr: "10.0.0.0/33"))
        XCTAssertNil(IPAddressRange(cidr: "10.0.0.0/-1"))
        XCTAssertNil(IPAddressRange(cidr: "10.0.0.0/8/1"))
        XCTAssertNil(IPAddressRange(cidr: "fe80::/129"))
        XCTAssertNotNil(IPAddressRange(cidr: "fe80::/10"))
    }

    func testRangeContains() throws {
        let range = try XCTUnwrap(IPAddressRange(cidr: "172.16.0.0/12"))
        XCTAssertTrue(range.contains("172.16.0.1"))
        XCTAssertTrue(range.contains("172.31.255.255"))
        XCTAssertFalse(range.contains("172.32.0.1"))
        XCTAssertFalse(range.contains("::1"))

        let v6 = try XCTUnwrap(IPAddressRange(cidr: "fe80::/10"))
        XCTAssertTrue(v6.contains("fe80::abcd"))
        XCTAssertTrue(v6.contains("febf::1"))
        XCTAssertFalse(v6.contains("fec0::1"))
    }

    func testLocalNetworkPolicy() {
        let allowed = ["192.168.0.2", "10.1.2.3", "172.20.10.2", "169.254.3.4", "127.0.0.1",
                       "fe80::1", "fd12::1", "::1", "::ffff:192.168.1.1"]
        for address in allowed {
            XCTAssertTrue(AccessControl.isAllowed(address: address, policy: .localNetworkOnly, allowList: []), address)
        }
        let denied = ["8.8.8.8", "1.1.1.1", "2001:4860:4860::8888", "172.32.0.1", "garbage"]
        for address in denied {
            XCTAssertFalse(AccessControl.isAllowed(address: address, policy: .localNetworkOnly, allowList: []), address)
        }
    }

    func testLocalPolicyAcceptsHotspotIPv6Prefix() throws {
        let prefix = try XCTUnwrap(IPAddressRange(cidr: "2001:2d8:8214:7a20:18c2:9828:fc6:4e66/64"))
        let client = "2001:2d8:8214:7a20:aaaa:bbbb:cccc:dddd"
        XCTAssertFalse(AccessControl.isAllowed(address: client, policy: .localNetworkOnly, allowList: []))
        XCTAssertTrue(AccessControl.isAllowed(address: client, policy: .localNetworkOnly, allowList: [], lanPrefixes: [prefix]))
        XCTAssertFalse(AccessControl.isAllowed(address: "2001:2d8:9999::1", policy: .localNetworkOnly, allowList: [], lanPrefixes: [prefix]))
    }

    func testAllowListPolicy() {
        let list = ["192.168.50.0/24"].compactMap { IPAddressRange(cidr: $0) }
        XCTAssertTrue(AccessControl.isAllowed(address: "192.168.50.9", policy: .allowList, allowList: list))
        XCTAssertFalse(AccessControl.isAllowed(address: "192.168.51.9", policy: .allowList, allowList: list))
        XCTAssertFalse(AccessControl.isAllowed(address: "192.168.50.9", policy: .allowList, allowList: []))
    }

    func testAnyonePolicy() {
        XCTAssertTrue(AccessControl.isAllowed(address: "8.8.8.8", policy: .anyone, allowList: []))
    }

    func testRedaction() {
        XCTAssertEqual(Redactor.address("192.168.1.23"), "192.168.x.x")
        XCTAssertEqual(Redactor.address("192.168.1.23", reveal: true), "192.168.1.23")
        XCTAssertEqual(Redactor.address("fe80:1:2::5%en0"), "fe80:1:…")
        XCTAssertFalse(Redactor.address("2001:db8::99").contains("99"))
    }
}
