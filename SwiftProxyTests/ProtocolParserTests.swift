import XCTest
@testable import SwiftProxy

final class SOCKS5ParserTests: XCTestCase {
    func testGreeting() {
        guard case .done(let g, let n) = SOCKS5.parseGreeting([5, 2, 0, 2]) else { return XCTFail() }
        XCTAssertEqual(g.methods, [0, 2])
        XCTAssertEqual(n, 4)
    }

    func testGreetingIncompleteAndInvalid() {
        guard case .incomplete = SOCKS5.parseGreeting([5]) else { return XCTFail() }
        guard case .incomplete = SOCKS5.parseGreeting([5, 2, 0]) else { return XCTFail() }
        guard case .invalid = SOCKS5.parseGreeting([4, 1, 0]) else { return XCTFail() }
        guard case .invalid = SOCKS5.parseGreeting([5, 0]) else { return XCTFail() }
    }

    func testCredentials() {
        let bytes: [UInt8] = [1, 4] + Array("user".utf8) + [6] + Array("secret".utf8)
        guard case .done(let c, let n) = SOCKS5.parseCredentials(bytes) else { return XCTFail() }
        XCTAssertEqual(c, SOCKS5.Credentials(username: "user", password: "secret"))
        XCTAssertEqual(n, bytes.count)
        guard case .incomplete = SOCKS5.parseCredentials(Array(bytes.dropLast())) else { return XCTFail() }
        guard case .invalid = SOCKS5.parseCredentials([2, 1, 65, 1, 66]) else { return XCTFail() }
    }

    func testIPv4Request() {
        let bytes: [UInt8] = [5, 1, 0, 1, 93, 184, 216, 34, 0x01, 0xBB]
        guard case .done(.success(let r), let n) = SOCKS5.parseRequest(bytes) else { return XCTFail() }
        XCTAssertEqual(r.command, 1)
        XCTAssertEqual(r.host, .ipv4([93, 184, 216, 34]))
        XCTAssertEqual(r.port, 443)
        XCTAssertEqual(n, 10)
        XCTAssertEqual(r.host.display(port: r.port), "93.184.216.34:443")
    }

    func testDomainRequest() {
        let name = Array("example.com".utf8)
        let bytes: [UInt8] = [5, 1, 0, 3, UInt8(name.count)] + name + [0, 80]
        guard case .done(.success(let r), _) = SOCKS5.parseRequest(bytes) else { return XCTFail() }
        XCTAssertEqual(r.host, .domain("example.com"))
        XCTAssertEqual(r.port, 80)
    }

    func testIPv6Request() {
        var addr = [UInt8](repeating: 0, count: 16)
        addr[0] = 0x20; addr[1] = 0x01; addr[15] = 1
        let bytes: [UInt8] = [5, 1, 0, 4] + addr + [0x1F, 0x90]
        guard case .done(.success(let r), let n) = SOCKS5.parseRequest(bytes) else { return XCTFail() }
        XCTAssertEqual(r.host, .ipv6(addr))
        XCTAssertEqual(r.port, 8080)
        XCTAssertEqual(n, 22)
        XCTAssertTrue(r.host.display(port: r.port).hasPrefix("["))
    }

    func testRequestErrors() {
        guard case .incomplete = SOCKS5.parseRequest([5, 1, 0, 1, 1, 2]) else { return XCTFail() }
        guard case .done(.failure(.unsupportedAddressType(9)), _) = SOCKS5.parseRequest([5, 1, 0, 9, 0, 0]) else {
            return XCTFail()
        }
        guard case .done(.failure(.malformed), _) = SOCKS5.parseRequest([5, 1, 0, 1, 1, 2, 3, 4, 0, 0]) else {
            return XCTFail("port 0 must be rejected")
        }
        guard case .done(.failure(.malformed), _) = SOCKS5.parseRequest([5, 1, 0, 3, 0, 0, 80]) else {
            return XCTFail("empty domain must be rejected")
        }
        let bad = Array("a b".utf8)
        guard case .done(.failure(.malformed), _) = SOCKS5.parseRequest([5, 1, 0, 3, 3] + bad + [0, 80]) else {
            return XCTFail("domain with space must be rejected")
        }
        guard case .invalid = SOCKS5.parseRequest([4, 1, 0, 1, 1, 2, 3, 4, 0, 80]) else { return XCTFail() }
    }

    func testBindCommandParsesButIsDistinguishable() {
        guard case .done(.success(let r), _) = SOCKS5.parseRequest([5, 2, 0, 1, 1, 2, 3, 4, 0, 80]) else {
            return XCTFail()
        }
        XCTAssertEqual(r.command, SOCKS5.Command.bind)
    }

    func testReplies() {
        XCTAssertEqual(SOCKS5.reply(.succeeded), Data([5, 0, 0, 1, 0, 0, 0, 0, 0, 0]))
        XCTAssertEqual(SOCKS5.methodSelection(0xFF), Data([5, 0xFF]))
        XCTAssertEqual(SOCKS5.authResult(success: false), Data([1, 1]))
    }

    func testUDPHeaderRoundTrip() throws {
        let header = SOCKS5.udpHeader(host: .ipv4([8, 8, 8, 8]), port: 53)
        XCTAssertEqual(header, Data([0, 0, 0, 1, 8, 8, 8, 8, 0, 53]))
        let parsed = try XCTUnwrap(SOCKS5.parseUDPHeader(Array(header) + [0xAB, 0xCD]))
        XCTAssertEqual(parsed, SOCKS5.UDPHeader(fragment: 0, host: .ipv4([8, 8, 8, 8]), port: 53, length: 10))

        let name = Array("dns.google".utf8)
        let domain = try XCTUnwrap(SOCKS5.parseUDPHeader([0, 0, 0, 3, UInt8(name.count)] + name + [0x01, 0xBB, 0xFF]))
        XCTAssertEqual(domain.host, .domain("dns.google"))
        XCTAssertEqual(domain.port, 443)
        XCTAssertEqual(domain.length, 5 + name.count + 2)
    }

    func testUDPHeaderRejectsInvalid() {
        XCTAssertNil(SOCKS5.parseUDPHeader([0, 1, 0, 1, 1, 2, 3, 4, 0, 53]), "RSV must be zero")
        XCTAssertNil(SOCKS5.parseUDPHeader([0, 0, 0, 1, 1, 2, 3]), "truncated")
        XCTAssertNil(SOCKS5.parseUDPHeader([0, 0, 0, 9, 1, 2, 3, 4, 0, 53]), "bad atyp")
        XCTAssertNil(SOCKS5.parseUDPHeader([0, 0, 0, 1, 1, 2, 3, 4, 0, 0]), "port 0")
        XCTAssertEqual(SOCKS5.parseUDPHeader([0, 0, 1, 1, 1, 2, 3, 4, 0, 53])?.fragment, 1)
    }

    func testReplyWithBindAddress() {
        XCTAssertEqual(SOCKS5.reply(.succeeded, bind: .ipv4([172, 20, 10, 1]), port: 0x1234),
                       Data([5, 0, 0, 1, 172, 20, 10, 1, 0x12, 0x34]))
    }

    func testLoopbackDetection() {
        XCTAssertTrue(TargetHost.ipv4([127, 0, 0, 1]).isLoopback)
        XCTAssertTrue(TargetHost.ipv6([UInt8](repeating: 0, count: 15) + [1]).isLoopback)
        XCTAssertTrue(TargetHost.domain("LocalHost").isLoopback)
        XCTAssertTrue(TargetHost.domain("foo.localhost.").isLoopback)
        XCTAssertFalse(TargetHost.domain("example.com").isLoopback)
        XCTAssertFalse(TargetHost.ipv4([192, 168, 0, 1]).isLoopback)
    }
}

final class HTTPParserTests: XCTestCase {
    private func head(_ s: String) -> HTTPProxy.RequestHead? {
        guard case .done(.success(let h), _) = HTTPProxy.parseHead(Array(s.utf8)) else { return nil }
        return h
    }

    func testConnectRequest() throws {
        let h = try XCTUnwrap(head("CONNECT example.com:443 HTTP/1.1\r\nHost: example.com:443\r\n\r\n"))
        XCTAssertEqual(h.method, "CONNECT")
        XCTAssertEqual(h.target, "example.com:443")
        XCTAssertEqual(h.header("host"), "example.com:443")
        let a = try XCTUnwrap(HTTPProxy.parseAuthority(h.target, defaultPort: nil))
        XCTAssertEqual(a.host, .domain("example.com"))
        XCTAssertEqual(a.port, 443)
    }

    func testConsumedLeavesBody() {
        let raw = Array("POST http://a/ HTTP/1.1\r\nContent-Length: 3\r\n\r\nabc".utf8)
        guard case .done(.success, let n) = HTTPProxy.parseHead(raw) else { return XCTFail() }
        XCTAssertEqual(Array(raw[n...]), Array("abc".utf8))
    }

    func testIncompleteAndTooLarge() {
        guard case .incomplete = HTTPProxy.parseHead(Array("GET http://a/ HTTP/1.1\r\nHost: a\r\n".utf8)) else {
            return XCTFail()
        }
        let big = Array(("GET http://a/ HTTP/1.1\r\nX: " + String(repeating: "a", count: 40_000)).utf8)
        guard case .done(.failure(.tooLarge), _) = HTTPProxy.parseHead(big) else { return XCTFail() }
    }

    func testMalformed() {
        for raw in ["GET\r\n\r\n", "GET / HTTP/2.0\r\n\r\n", "GET / HTTP/1.1\r\nNoColon\r\n\r\n",
                    "GET / HTTP/1.1\r\nA: b\r\n folded\r\n\r\n", "G3T / HTTP/1.1\r\n\r\n"] {
            guard case .done(.failure(.malformed), _) = HTTPProxy.parseHead(Array(raw.utf8)) else {
                return XCTFail(raw)
            }
        }
    }

    func testAuthority() {
        XCTAssertEqual(HTTPProxy.parseAuthority("[::1]:8443", defaultPort: nil)?.port, 8443)
        XCTAssertEqual(HTTPProxy.parseAuthority("[::1]", defaultPort: 80)?.port, 80)
        XCTAssertNil(HTTPProxy.parseAuthority("example.com", defaultPort: nil))
        XCTAssertNil(HTTPProxy.parseAuthority("example.com:0", defaultPort: nil))
        XCTAssertNil(HTTPProxy.parseAuthority("example.com:99999", defaultPort: nil))
        XCTAssertNil(HTTPProxy.parseAuthority("::1:80", defaultPort: nil))
        XCTAssertEqual(HTTPProxy.parseAuthority("1.2.3.4:5", defaultPort: nil)?.host, .ipv4([1, 2, 3, 4]))
    }

    func testAbsoluteURL() throws {
        let u = try XCTUnwrap(HTTPProxy.parseAbsoluteHTTPURL("http://example.com:8080/a/b?c=1#frag"))
        XCTAssertEqual(u.host, .domain("example.com"))
        XCTAssertEqual(u.port, 8080)
        XCTAssertEqual(u.path, "/a/b?c=1")
        XCTAssertEqual(HTTPProxy.parseAbsoluteHTTPURL("http://example.com")?.path, "/")
        XCTAssertEqual(HTTPProxy.parseAbsoluteHTTPURL("HTTP://example.com?q")?.path, "/?q")
        XCTAssertEqual(HTTPProxy.parseAbsoluteHTTPURL("http://user:pw@example.com/")?.host, .domain("example.com"))
        XCTAssertNil(HTTPProxy.parseAbsoluteHTTPURL("https://example.com/"))
        XCTAssertNil(HTTPProxy.parseAbsoluteHTTPURL("/relative"))
    }

    func testForwardHeadRewritesAndStripsHopByHop() throws {
        let h = try XCTUnwrap(head("GET http://example.com/x HTTP/1.1\r\nHost: example.com\r\nProxy-Connection: keep-alive\r\nProxy-Authorization: Basic Zm9vOmJhcg==\r\nConnection: keep-alive, X-Custom\r\nX-Custom: 1\r\nAccept: */*\r\n\r\n"))
        let out = String(decoding: HTTPProxy.forwardHead(h, path: "/x", hostHeader: "example.com"), as: UTF8.self)
        XCTAssertTrue(out.hasPrefix("GET /x HTTP/1.1\r\n"))
        XCTAssertTrue(out.contains("Host: example.com\r\n"))
        XCTAssertTrue(out.contains("Accept: */*\r\n"))
        XCTAssertTrue(out.hasSuffix("Connection: close\r\n\r\n"))
        XCTAssertFalse(out.contains("Proxy-"))
        XCTAssertFalse(out.contains("X-Custom"))
        XCTAssertFalse(out.contains("keep-alive"))
    }

    func testForwardHeadAddsMissingHost() throws {
        let h = try XCTUnwrap(head("GET http://example.com/ HTTP/1.0\r\n\r\n"))
        let out = String(decoding: HTTPProxy.forwardHead(h, path: "/", hostHeader: "example.com"), as: UTF8.self)
        XCTAssertTrue(out.contains("Host: example.com\r\n"))
    }

    func testBasicCredentials() throws {
        let token = Data("alice:p:w".utf8).base64EncodedString()
        let h = try XCTUnwrap(head("CONNECT a:1 HTTP/1.1\r\nProxy-Authorization: Basic \(token)\r\n\r\n"))
        XCTAssertEqual(HTTPProxy.basicCredentials(h), SOCKS5.Credentials(username: "alice", password: "p:w"))
        let none = try XCTUnwrap(head("CONNECT a:1 HTTP/1.1\r\n\r\n"))
        XCTAssertNil(HTTPProxy.basicCredentials(none))
        let bad = try XCTUnwrap(head("CONNECT a:1 HTTP/1.1\r\nProxy-Authorization: Bearer xyz\r\n\r\n"))
        XCTAssertNil(HTTPProxy.basicCredentials(bad))
    }

    func testPAC() {
        let pac = PACFile.make(host: "192.168.0.5", httpPort: 8080, socksPort: 1080)
        XCTAssertTrue(pac.contains("FindProxyForURL"))
        XCTAssertTrue(pac.contains("PROXY 192.168.0.5:8080"))
        XCTAssertTrue(pac.contains("SOCKS5 192.168.0.5:1080"))
        XCTAssertTrue(PACFile.make(host: "fe80::1", httpPort: 1, socksPort: nil).contains("PROXY [fe80::1]:1"))
        XCTAssertFalse(PACFile.make(host: "h", httpPort: nil, socksPort: 2).contains("PROXY"))
    }

    func testConstantTimeEquals() {
        XCTAssertTrue(constantTimeEquals("abc", "abc"))
        XCTAssertFalse(constantTimeEquals("abc", "abd"))
        XCTAssertFalse(constantTimeEquals("abc", "abcd"))
        XCTAssertFalse(constantTimeEquals("", "a"))
        XCTAssertTrue(constantTimeEquals("", ""))
    }
}
