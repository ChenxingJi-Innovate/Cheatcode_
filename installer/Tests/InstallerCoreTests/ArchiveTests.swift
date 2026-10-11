import Foundation
import InstallerCore
func tarEntry(_ name: String, data: Data = Data("hello".utf8), type: UInt8 = 48) -> Data {
    var h = [UInt8](repeating:0, count:512)
    func field(_ s: String, _ start: Int, _ count: Int) { for (i,c) in s.utf8.prefix(count).enumerated() { h[start+i] = c } }
    field(name,0,100); field("0000644",100,8); field(String(format:"%011o",data.count),124,12)
    field("ustar",257,6); h[156] = type
    for i in 148..<156 { h[i] = 32 }
    field(String(format:"%06o",h.reduce(0) { $0 + Int($1) }),148,7); h[155] = 32
    var result = Data(h); result.append(data); result.append(Data(repeating:0,count:(512-data.count%512)%512)); return result
}
func tar(_ entries: Data...) -> Data { entries.reduce(Data(),+) + Data(repeating:0,count:1024) }
final class ArchiveTests: XCTestCase {
    func testTarRejectsUnsafeEntriesAndCorruption() throws {
        let m = try fixtureManifest()
        XCTAssertEqual(try Archive.parseTar(tar(tarEntry("demo/skills/demo/SKILL.md")),manifest:m)["skills/demo/SKILL.md"],Data("hello".utf8))
        for path in ["../outside", "demo/../outside", "/demo/skills/demo/SKILL.md", "other/skills/demo/SKILL.md", "demo/unexpected"] {
            XCTAssertThrowsError(try Archive.parseTar(tar(tarEntry(path)),manifest:m),path)
        }
        for type: UInt8 in [49,50,51,52,53,54,55,103,76] { XCTAssertThrowsError(try Archive.parseTar(tar(tarEntry("demo/skills/demo/SKILL.md",type:type)),manifest:m)) }
        XCTAssertThrowsError(try Archive.parseTar(tar(tarEntry("demo/skills/demo/SKILL.md"),tarEntry("demo/skills/demo/SKILL.md")),manifest:m))
        XCTAssertThrowsError(try Archive.parseTar(tar(tarEntry("demo/skills/demo/SKILL.md",data:Data("wrong".utf8))),manifest:m))
        var corrupt = tar(tarEntry("demo/skills/demo/SKILL.md")); corrupt[10] ^= 1
        XCTAssertThrowsError(try Archive.parseTar(corrupt,manifest:m))
        XCTAssertThrowsError(try Archive.parseTar(Data(repeating:0,count:1024),manifest:m))
        XCTAssertThrowsError(try Archive.extract(Data("not gzip".utf8),manifest:m))
    }
}
extension ArchiveTests {
    func testAcceptsPinnedPAXPathAndRejectsPAXOverrides() throws {
        let path = "skills/demo/" + String(repeating:"a",count:120) + ".md"
        let hashes: [[String:Any]] = [
            ["path":"skills/demo/SKILL.md","sha256":digest(Data("hello".utf8)),"bytes":5],
            ["path":path,"sha256":digest(Data("hello".utf8)),"bytes":5]
        ]
        let m = try fixtureManifest(["files":hashes])
        func pax(_ key: String, _ value: String) -> Data {
            let record = key+"="+value+"\n"
            var length = record.utf8.count+2
            while String(length).count + 1 + record.utf8.count != length { length = String(length).count+1+record.utf8.count }
            return Data("\(length) \(record)".utf8)
        }
        let entry = tarEntry("demo/skills/demo/SKILL.md")
        let extended = tar(entry,tarEntry("././@PaxHeader",data:pax("path","demo/"+path),type:120),tarEntry("placeholder"))
        XCTAssertEqual(try Archive.parseTar(extended,manifest:m)[path],Data("hello".utf8))
        for (key,value) in [("path","demo/../outside"),("linkpath","/tmp/outside"),("GNU.sparse.name","demo/file")] {
            XCTAssertThrowsError(try Archive.parseTar(tar(entry,tarEntry("././@PaxHeader",data:pax(key,value),type:120),tarEntry("placeholder")),manifest:m))
        }
    }
}
