import Foundation
import InstallerCore
final class FailingMoves: FileManager {
    var moves = 0
    override func moveItem(at srcURL: URL, to dstURL: URL) throws {
        moves += 1
        if moves == 2 { throw NSError(domain:"fixture disk failure",code:1) }
        try super.moveItem(at:srcURL,to:dstURL)
    }
}
func temporaryHome() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("cheatcode-test-"+UUID().uuidString).resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at:url,withIntermediateDirectories:true); return url.resolvingSymlinksInPath()
}
final class InstallerTests: XCTestCase {
    func testCancelMakesNoWritesAndConflictsPreserveExistingFiles() throws {
        let home = try temporaryHome(); defer { try? FileManager.default.removeItem(at:home) }
        let m = try fixtureManifest(); let d = try Destination(manifest:m,home:home)
        let files = ["skills/demo/SKILL.md":Data("hello".utf8)]
        XCTAssertThrowsError(try Installer().install(manifest:m,files:files,destination:d,confirmed:false))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath:home.path),[])
        try FileManager.default.createDirectory(at:d.skills.appendingPathComponent("demo"),withIntermediateDirectories:true)
        let existing = d.skills.appendingPathComponent("demo/mine.txt"); try Data("keep".utf8).write(to:existing)
        XCTAssertThrowsError(try Installer().install(manifest:m,files:files,destination:d,confirmed:true))
        XCTAssertEqual(try Data(contentsOf:existing),Data("keep".utf8))
    }
    func testExistingInstallSaysWhoPutItThere() throws {
        let fm = FileManager.default
        let home = try temporaryHome(); defer { try? fm.removeItem(at:home) }
        let m = try fixtureManifest(); let d = try Destination(manifest:m,home:home)
        XCTAssertEqual(Installer().existing(manifest:m,destination:d), .none)
        let folder = d.skills.appendingPathComponent(d.layout == "plugin" ? m.slug : m.skills[0])
        try fm.createDirectory(at:folder,withIntermediateDirectories:true)
        XCTAssertEqual(Installer().existing(manifest:m,destination:d), .unmanaged)  // a kit leaves it alone
        try fm.removeItem(at:folder)
        _ = try Installer().install(manifest:m,files:["skills/demo/SKILL.md":Data("hello".utf8)],destination:d,confirmed:true)
        XCTAssertEqual(Installer().existing(manifest:m,destination:d), .native)
        let other = try temporaryHome(); defer { try? fm.removeItem(at:other) }
        let d2 = try Destination(manifest:m,home:other)
        try fm.createDirectory(at:d2.state,withIntermediateDirectories:true)
        try Data("slug=demo\n".utf8).write(to:d2.state.appendingPathComponent(m.slug+".receipt"))
        XCTAssertEqual(Installer().existing(manifest:m,destination:d2), .commandLine)
    }
    func testInstallRepeatsIdentityAndRejectsModifiedOwnedContent() throws {
        let home = try temporaryHome(); defer { try? FileManager.default.removeItem(at:home) }
        let m = try fixtureManifest(); let d = try Destination(manifest:m,home:home)
        let files = ["skills/demo/SKILL.md":Data("hello".utf8)]
        let first = try Installer().install(manifest:m,files:files,destination:d,confirmed:true)
        let second = try Installer().install(manifest:m,files:files,destination:d,confirmed:true)
        XCTAssertEqual(first.installID,second.installID)
        XCTAssertEqual(try Data(contentsOf:d.skills.appendingPathComponent("demo/SKILL.md")),Data("hello".utf8))
        try Data("local edit".utf8).write(to:d.skills.appendingPathComponent("demo/SKILL.md"))
        XCTAssertThrowsError(try Installer().install(manifest:m,files:files,destination:d,confirmed:true))
        XCTAssertEqual(try Data(contentsOf:d.skills.appendingPathComponent("demo/SKILL.md")),Data("local edit".utf8))
    }
    func testRollbackAndSymlinkEscape() throws {
        let home = try temporaryHome(); defer { try? FileManager.default.removeItem(at:home) }
        let m = try fixtureManifest(); let d = try Destination(manifest:m,home:home)
        let files = ["skills/demo/SKILL.md":Data("hello".utf8)]
        XCTAssertThrowsError(try Installer(fileManager:FailingMoves()).install(manifest:m,files:files,destination:d,confirmed:true))
        XCTAssertTrue(!FileManager.default.fileExists(atPath:d.skills.appendingPathComponent("demo").path))
        let out = try temporaryHome(); defer { try? FileManager.default.removeItem(at:out) }
        if FileManager.default.fileExists(atPath:d.skills.path) { try FileManager.default.removeItem(at:d.skills) }
        try FileManager.default.createDirectory(at:d.skills.deletingLastPathComponent(),withIntermediateDirectories:true)
        try FileManager.default.createSymbolicLink(at:d.skills,withDestinationURL:out)
        XCTAssertThrowsError(try Installer().install(manifest:m,files:files,destination:d,confirmed:true))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath:out.path),[])
    }
}
final class InterruptedMoves: FileManager {
    var moves = 0
    override func moveItem(at srcURL: URL, to dstURL: URL) throws {
        moves += 1
        if moves >= 3 { throw NSError(domain:"fixture interrupted disk",code:1) }
        try super.moveItem(at:srcURL,to:dstURL)
    }
}
extension InstallerTests {
    func testInterruptedUpdateRecoversAndKeepsIdentity() throws {
        let home = try temporaryHome(); defer { try? FileManager.default.removeItem(at:home) }
        let m = try fixtureManifest(); let d = try Destination(manifest:m,home:home)
        let files = ["skills/demo/SKILL.md":Data("hello".utf8)]
        let first = try Installer().install(manifest:m,files:files,destination:d,confirmed:true)
        XCTAssertThrowsError(try Installer(fileManager:InterruptedMoves()).install(manifest:m,files:files,destination:d,confirmed:true))
        XCTAssertTrue(FileManager.default.fileExists(atPath:d.state.appendingPathComponent(".native-transaction-demo/journal.json").path))
        let recovered = try Installer().install(manifest:m,files:files,destination:d,confirmed:true)
        XCTAssertEqual(recovered.installID,first.installID)
        XCTAssertTrue(!FileManager.default.fileExists(atPath:d.state.appendingPathComponent(".native-transaction-demo").path))
    }
    func testRealAPIPackageAcrossAllTargetsAndScopes() throws {
        let folder = URL(fileURLWithPath:#filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")
        let archive = try Data(contentsOf:folder.appendingPathComponent("personalens.tar.gz"))
        let urls = try FileManager.default.contentsOfDirectory(at:folder,includingPropertiesForKeys:nil).filter { $0.pathExtension == "json" }
        XCTAssertEqual(urls.count,21)
        for url in urls {
            let m = try jsonDecoder().decode(Manifest.self,from:Data(contentsOf:url))
            try m.validate(targets:NativeTarget.bundled())
            let files = try Archive.extract(archive,manifest:m)
            let home = try temporaryHome(); defer { try? FileManager.default.removeItem(at:home) }
            let d = try Destination(manifest:m,home:home,project:home)
            let first = try Installer().install(manifest:m,files:files,destination:d,confirmed:true)
            let repeatInstall = try Installer().install(manifest:m,files:files,destination:d,confirmed:true)
            XCTAssertEqual(first.installID,repeatInstall.installID,url.lastPathComponent)
            let skillPath = d.layout == "plugin" ? "personalens/skills/personalens/SKILL.md" : "personalens/SKILL.md"
            XCTAssertEqual(try Data(contentsOf:d.skills.appendingPathComponent(skillPath)),files["skills/personalens/SKILL.md"],url.lastPathComponent)
            if m.target.bundleLicense { XCTAssertTrue(FileManager.default.fileExists(atPath:d.skills.appendingPathComponent("personalens/LICENSE").path)) }
            let receipt = try String(contentsOf:d.state.appendingPathComponent("personalens.receipt"))
            XCTAssertTrue(receipt.contains("path="+d.state.appendingPathComponent("personalens.native.json").path))
        }
        print("Verified real PersonaLens archive in all 21 target and scope combinations")
    }
}
extension InstallerTests {
    func testRejectsDestinationThatCouldInjectLegacyReceipt() throws {
        let home = try temporaryHome(); defer { try? FileManager.default.removeItem(at:home) }
        let project = home.appendingPathComponent("project\npath=other")
        try FileManager.default.createDirectory(at:project,withIntermediateDirectories:true)
        let m = try fixtureManifest(["scope":"project"])
        let d = try Destination(manifest:m,home:home,project:project)
        XCTAssertThrowsError(try Installer().install(manifest:m,files:["skills/demo/SKILL.md":Data("hello".utf8)],destination:d,confirmed:true))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath:project.path),[])
    }
}
