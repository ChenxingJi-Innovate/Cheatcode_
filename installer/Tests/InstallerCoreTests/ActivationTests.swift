import Foundation
import InstallerCore
final class ActivationTests: XCTestCase {
    func testRejectsUnsafeActivation() {
        let bad = [
            "https://install?intent=abc&api=https://api.cheatcodehq.com",
            "cheatcode://install/path?intent=abc&api=https://api.cheatcodehq.com",
            "cheatcode://install?intent=abc&intent=def&api=https://api.cheatcodehq.com",
            "cheatcode://install?intent=abc&api=https://evil.example",
            "cheatcode://install?intent=abc&api=https://api.cheatcodehq.com.evil.example",
            "cheatcode://install?intent=abc&api=https://user@api.cheatcodehq.com",
            "cheatcode://install?intent=abc&api=https://api.cheatcodehq.com/path",
            "cheatcode://install?intent=abc&api=https://api.cheatcodehq.com&command=rm",
            "cheatcode://install?intent=../abc&api=https://api.cheatcodehq.com",
            "cheatcode://install?intent=abc&api=http://127.0.0.1:8000",
            "cheatcode://install?intent=abc&api=https://api.cheatcodehq.com#fragment"
        ]
        for raw in bad { XCTAssertThrowsError(try Activation(URL(string: raw)!), raw) }
    }
    func testValidLinkAndExplicitDevelopmentOrigin() throws {
        let valid = try Activation(URL(string: "cheatcode://install?intent=abc_DEF.ghi-123&api=https%3A%2F%2Fapi.cheatcodehq.com")!)
        XCTAssertEqual(valid.origin.absoluteString, "https://api.cheatcodehq.com")
        XCTAssertEqual(valid.token, "abc_DEF.ghi-123")
        XCTAssertNoThrow(try Activation(URL(string: "cheatcode://install?intent=abc&api=http%3A%2F%2F127.0.0.1%3A8000")!, allowLocal: true))
        // A role kit: several signed requests in one link, each checked like a single one.
        let kit = try Activation(URL(string: "cheatcode://install?intents=aa_1%2Cbb-2%2Ccc.3&api=https%3A%2F%2Fapi.cheatcodehq.com")!)
        XCTAssertEqual(kit.tokens, ["aa_1", "bb-2", "cc.3"])
        XCTAssertTrue(kit.isKit)
        XCTAssertEqual(kit.endpoint("/archive", token: "bb-2").absoluteString, "https://api.cheatcodehq.com/api/v1/desktop/intents/bb-2/archive")
        XCTAssertTrue(!valid.isKit)
        let tooMany = (0...Activation.maximumPackages).map { "t\($0)" }.joined(separator: "%2C")
        for raw in [
            "cheatcode://install?intents=aa%2Caa&api=https://api.cheatcodehq.com",
            "cheatcode://install?intents=aa%2C&api=https://api.cheatcodehq.com",
            "cheatcode://install?intents=aa%2C..%2Fbb&api=https://api.cheatcodehq.com",
            "cheatcode://install?intent=aa&intents=bb&api=https://api.cheatcodehq.com",
            "cheatcode://install?intents=aa%2Cbb&api=https://evil.example",
            "cheatcode://install?intents=\(tooMany)&api=https://api.cheatcodehq.com",
        ] { XCTAssertThrowsError(try Activation(URL(string: raw)!), raw) }
        XCTAssertThrowsError(try Activation(URL(string: "cheatcode://install?intent=abc&api=http://127.0.0.1:8001")!, allowLocal: true))
    }
}
