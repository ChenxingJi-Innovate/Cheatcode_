import Foundation
import InstallerCore
func fixtureManifest(_ changes: [String: Any] = [:]) throws -> Manifest {
    let targets = try NativeTarget.bundled()
    let target = try JSONSerialization.jsonObject(with: jsonEncoder().encode(targets.first(where: { $0.id == "cursor" })!))
    var object: [String: Any] = ["schema":"cheatcode-desktop/v1", "slug":"demo", "name":"Demo", "version":"1.0", "publisher":"Test fixture", "license":"MIT", "content_hash":digest(Data("skills/demo/SKILL.md\0\(digest(Data("hello".utf8)))\n".utf8)), "archive_sha256":String(repeating:"a", count:64), "archive_bytes":100, "files":[["path":"skills/demo/SKILL.md", "sha256":digest(Data("hello".utf8)), "bytes":5]], "skills":["demo"], "target":target, "scope":"user", "expires_at":"2099-01-01T00:00:00Z"]
    for (key, value) in changes { object[key] = value }
    return try jsonDecoder().decode(Manifest.self, from: JSONSerialization.data(withJSONObject: object))
}
final class ManifestTests: XCTestCase {
    func testValidAndExpiredManifest() throws {
        let targets = try NativeTarget.bundled()
        XCTAssertNoThrow(try fixtureManifest().validate(targets: targets))
        XCTAssertThrowsError(try fixtureManifest(["expires_at":"2000-01-01T00:00:00Z"]).validate(targets: targets))
        XCTAssertThrowsError(try fixtureManifest(["expires_at":"not a date"]).validate(targets: targets))
        XCTAssertNoThrow(try fixtureManifest(["expires_at":"2099-01-01T00:00:00.123Z"]).validate(targets: targets))
    }
    func testRejectsPathsBoundsTargetDriftAndHashDrift() throws {
        let targets = try NativeTarget.bundled()
        for path in ["../out", "/tmp/out", "a/../b", "a//b", "a\\b", "a:b", "a/./b"] { XCTAssertTrue(!safeRelativePath(path)) }
        XCTAssertThrowsError(try fixtureManifest(["content_hash":String(repeating:"b",count:64)]).validate(targets: targets))
        XCTAssertThrowsError(try fixtureManifest(["archive_bytes":maximumArchiveBytes + 1]).validate(targets: targets))
        XCTAssertThrowsError(try fixtureManifest().validate(targets: []))
        let t = try JSONSerialization.jsonObject(with: jsonEncoder().encode(targets[0])) as! [String: Any]
        var drift = t; drift["user_path"] = "other/skills"
        XCTAssertThrowsError(try fixtureManifest(["target":drift]).validate(targets: targets))
    }
}
extension ManifestTests {
    func testRejectsReceiptInjectionAndCaseCollision() throws {
        let targets = try NativeTarget.bundled()
        XCTAssertThrowsError(try fixtureManifest(["version":"1.0\npath=/tmp/unrelated"]).validate(targets:targets))
        let duplicate = [["path":"skills/demo/SKILL.md","bytes":5,"sha256":digest(Data("hello".utf8))],["path":"skills/demo/skill.md","bytes":5,"sha256":digest(Data("hello".utf8))]] as [[String:Any]]
        XCTAssertThrowsError(try fixtureManifest(["files":duplicate]).validate(targets:targets))
    }
}
