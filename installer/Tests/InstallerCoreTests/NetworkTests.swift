import Foundation
import InstallerCore

func testNetworkBoundaries() throws {
    let server = Process(); server.executableURL = URL(fileURLWithPath:"/usr/bin/python3")
    server.arguments = [URL(fileURLWithPath:#filePath).deletingLastPathComponent().appendingPathComponent("transport_fixture.py").path]
    let output = Pipe(); server.standardOutput = output
    try server.run(); defer { server.terminate(); server.waitUntilExit() }
    guard String(data:output.fileHandleForReading.availableData,encoding:.utf8)?.contains("ready") == true else { throw InstallerError("Transport fixture could not bind IPv6 loopback port 8000.") }
    let done = DispatchSemaphore(value:0)
    Task {
        defer { done.signal() }
        @Sendable func network(_ token: String) throws -> InstallerNetwork {
            InstallerNetwork(activation:try Activation(URL(string:"cheatcode://install?intent=\(token)&api=http%3A%2F%2F%5B%3A%3A1%5D%3A8000")!,allowLocal:true))
        }
        do {
            let manifest = try await network("valid").manifest()
            XCTAssertEqual(manifest.slug,"personalens")
            for (token,expected) in [("redirect","HTTP 302"),("expired","expired"),("oversize","size limit"),("stream","size limit")] {
                do { _ = try await network(token).manifest(); XCTAssertTrue(false,"Expected network rejection: "+token) }
                catch { XCTAssertTrue(error.localizedDescription.contains(expected),"\(token): \(error)") }
            }
            let pending = Task { try await network("slow").manifest() }
            try await Task.sleep(nanoseconds:100_000_000); pending.cancel()
            do { _ = try await pending.value; XCTAssertTrue(false,"Expected cancelled download") } catch {}
        } catch { XCTAssertTrue(false,"Unexpected network error: \(error)") }
    }
    XCTAssertEqual(done.wait(timeout:.now()+45),.success,"Transport suite timed out")
    print("Verified bounded HTTP, rejected redirects, expiry and cancellation against isolated local fixture")
}
