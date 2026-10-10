import XCTest
@testable import SwiftProxy

final class SettingsValidatorTests: XCTestCase {
    func testDefaultsAreValidAndSafe() {
        let s = ProxySettings()
        XCTAssertEqual(SettingsValidator.validate(s), [])
        XCTAssertEqual(s.accessPolicy, .localNetworkOnly)
        XCTAssertFalse(s.autoStart)
    }

    func testPortRange() {
        var s = ProxySettings()
        s.socksPort = 80
        XCTAssertFalse(SettingsValidator.validate(s).isEmpty)
        s.socksPort = 70000
        XCTAssertFalse(SettingsValidator.validate(s).isEmpty)
        s.socksPort = 1024
        XCTAssertTrue(SettingsValidator.validate(s).isEmpty)
    }

    func testDisabledListenerPortIsIgnored() {
        var s = ProxySettings()
        s.httpEnabled = false
        s.httpPort = 1
        XCTAssertTrue(SettingsValidator.validate(s).isEmpty)
    }

    func testPortConflict() {
        var s = ProxySettings()
        s.socksPort = 9000
        s.httpPort = 9000
        XCTAssertFalse(SettingsValidator.validate(s).isEmpty)
    }

    func testAtLeastOneListener() {
        var s = ProxySettings()
        s.socksEnabled = false
        s.httpEnabled = false
        XCTAssertFalse(SettingsValidator.validate(s).isEmpty)
    }

    func testAllowListValidation() {
        var s = ProxySettings()
        s.accessPolicy = .allowList
        XCTAssertFalse(SettingsValidator.validate(s).isEmpty, "empty allow list must be rejected")
        s.allowList = ["192.168.0.0/24"]
        XCTAssertTrue(SettingsValidator.validate(s).isEmpty)
        s.allowList.append("nope/99")
        XCTAssertFalse(SettingsValidator.validate(s).isEmpty)
    }

    func testAuthUsername() {
        var s = ProxySettings()
        s.authEnabled = true
        s.authUsername = ""
        XCTAssertFalse(SettingsValidator.validate(s).isEmpty)
        s.authUsername = "a:b"
        XCTAssertFalse(SettingsValidator.validate(s).isEmpty)
        s.authUsername = String(repeating: "a", count: 256)
        XCTAssertFalse(SettingsValidator.validate(s).isEmpty)
        s.authUsername = "user"
        XCTAssertTrue(SettingsValidator.validate(s).isEmpty)
    }

    func testStatsInterval() {
        var s = ProxySettings()
        s.statsInterval = 0.1
        XCTAssertFalse(SettingsValidator.validate(s).isEmpty)
        s.statsInterval = 2
        XCTAssertTrue(SettingsValidator.validate(s).isEmpty)
    }

    func testDecodingOldDataUsesDefaults() throws {
        let json = #"{"socksPort": 2000}"#.data(using: .utf8)!
        let s = try JSONDecoder().decode(ProxySettings.self, from: json)
        XCTAssertEqual(s.socksPort, 2000)
        XCTAssertEqual(s.httpPort, ProxySettings().httpPort)
        XCTAssertEqual(s.accessPolicy, .localNetworkOnly)
    }

    func testGeneratedPasswordsAreRandom() {
        let a = KeychainStore.generatePassword()
        let b = KeychainStore.generatePassword()
        XCTAssertEqual(a.count, 16)
        XCTAssertNotEqual(a, b)
    }
}

final class TrafficStatisticsTests: XCTestCase {
    func testCounterAccumulates() {
        let counter = TrafficCounter()
        counter.addUp(100)
        counter.addDown(250)
        counter.addUp(-5)
        XCTAssertEqual(counter.totals(), .init(up: 100, down: 250))
        counter.reset()
        XCTAssertEqual(counter.totals(), .init())
    }

    func testCounterIsThreadSafe() {
        let counter = TrafficCounter()
        DispatchQueue.concurrentPerform(iterations: 1000) { _ in
            counter.addUp(1)
            counter.addDown(2)
        }
        XCTAssertEqual(counter.totals(), .init(up: 1000, down: 2000))
    }

    func testRateCalculation() {
        var calc = RateCalculator()
        let t0 = Date(timeIntervalSince1970: 1000)
        XCTAssertEqual(calc.update(.init(up: 0, down: 0), at: t0), .zero)
        let r = calc.update(.init(up: 2048, down: 4096), at: t0.addingTimeInterval(2))
        XCTAssertEqual(r.up, 1024, accuracy: 0.001)
        XCTAssertEqual(r.down, 2048, accuracy: 0.001)
    }

    func testRateAfterCounterResetIsNotNegative() {
        var calc = RateCalculator()
        let t0 = Date(timeIntervalSince1970: 1000)
        _ = calc.update(.init(up: 5000, down: 5000), at: t0)
        let r = calc.update(.init(up: 10, down: 10), at: t0.addingTimeInterval(1))
        XCTAssertEqual(r, .zero)
    }

    func testDurationFormatting() {
        XCTAssertEqual(Formatters.duration(5), "00:05")
        XCTAssertEqual(Formatters.duration(65), "01:05")
        XCTAssertEqual(Formatters.duration(3725), "1:02:05")
    }
}
