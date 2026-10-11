import Foundation
import XCTest

final class CoreSuiteTests: XCTestCase {
    func testNativeSecuritySuite() throws {
        // SwiftPM builds the executable dependency beside this test bundle.
        let executable = Bundle(for:Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("NativeCoreTests")
        let process = Process(); process.executableURL = executable
        let pipe = Pipe(); process.standardOutput = pipe; process.standardError = pipe
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus,0,String(decoding:output,as:UTF8.self))
    }
}
