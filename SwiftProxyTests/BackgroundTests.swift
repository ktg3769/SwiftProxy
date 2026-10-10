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
