import XCTest
@testable import SwiftProxy

final class SessionJournalTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suite = "SessionJournalTests"

    override func setUp() {
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
    }

    func testCleanStopIsNotReported() {
        var journal = SessionJournal(defaults: defaults)
        journal.markStarted()
        journal.markEnded(reason: "사용자가 중지")
        XCTAssertNil(journal.consumeUncleanShutdown())
        XCTAssertEqual(journal.lastEnd?.reason, "사용자가 중지")
    }

    func testUncleanShutdownIsReportedOnce() {
        SessionJournal(defaults: defaults).markStarted()
        // 다음 실행을 흉내낸다.
        var next = SessionJournal(defaults: defaults)
        XCTAssertNotNil(next.consumeUncleanShutdown())
        XCTAssertNil(next.consumeUncleanShutdown(), "must be reported only once")
    }

    func testNoSessionNoReport() {
        var journal = SessionJournal(defaults: defaults)
        XCTAssertNil(journal.consumeUncleanShutdown())
    }
}

final class SettingsMigrationTests: XCTestCase {
    func testNewFieldsDefaultWhenMissing() throws {
        let json = #"{"socksPort": 1081, "httpPort": 8081}"#.data(using: .utf8)!
        let s = try JSONDecoder().decode(ProxySettings.self, from: json)
        XCTAssertEqual(s.outboundRoute, .system)
        XCTAssertTrue(s.useContinuedProcessing)
        XCTAssertTrue(s.showLiveActivity)
    }

    func testRoundTrip() throws {
        var s = ProxySettings()
        s.outboundRoute = .cellularOnly
        s.showLiveActivity = false
        let decoded = try JSONDecoder().decode(ProxySettings.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(decoded, s)
    }
}

final class UDPClientMatchTests: XCTestCase {
    func testIPv6SamePrefixMatches() {
        let a = IPParser.bytes("2001:2d8:8214:7a20:1111:2222:3333:4444")!
        let b = IPParser.bytes("2001:2d8:8214:7a20:aaaa:bbbb:cccc:dddd")!
        let c = IPParser.bytes("2001:2d8:9999:7a20:1111:2222:3333:4444")!
        XCTAssertTrue(UDPAssociation.isSameClient(a, b))
        XCTAssertFalse(UDPAssociation.isSameClient(a, c))
    }

    func testIPv4MustMatchExactly() {
        XCTAssertTrue(UDPAssociation.isSameClient([172, 20, 10, 2], [172, 20, 10, 2]))
        XCTAssertFalse(UDPAssociation.isSameClient([172, 20, 10, 2], [172, 20, 10, 3]))
        XCTAssertFalse(UDPAssociation.isSameClient([172, 20, 10, 2], IPParser.bytes("::1")!))
    }
}
