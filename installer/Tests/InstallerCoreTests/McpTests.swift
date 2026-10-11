import Foundation
import InstallerCore

func bundledClientObjects() throws -> [[String: Any]] {
    let url = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("mcp_clients.json")
    return try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [[String: Any]]
}

/// An MCP request as the API serves it (snake_case JSON), so decoding is covered too.
func mcpManifest(client: String, _ changes: [String: Any] = [:]) throws -> McpManifest {
    var o: [String: Any] = [
        "schema": "cheatcode-mcp/v1", "slug": "demo-mcp", "name": "Demo MCP", "publisher": "someone", "repo": "someone/demo-mcp",
        "license": "MIT", "server_id": "demo-mcp", "status": "one_click", "transport": "stdio", "runtime": "node", "command": "npx",
        "args": ["-y", "demo-mcp@1.2.3"], "url": NSNull(), "headers": [String: String](), "inputs": [[String: Any]](),
        "package": "demo-mcp@1.2.3", "tools": 3, "verified_at": "2026-10-07T00:00:00Z",
        "client": try bundledClientObjects().first(where: { $0["id"] as? String == client })!, "expires_at": "2099-01-01T00:00:00Z",
    ]
    for (k, v) in changes { o[k] = v }
    return try jsonDecoder().decode(McpManifest.self, from: JSONSerialization.data(withJSONObject: o))
}
let remoteChanges: [String: Any] = ["transport": "streamable-http", "runtime": NSNull(), "command": NSNull(), "args": [String](),
                                    "url": "https://mcp.example.org/mcp", "package": NSNull(), "status": "needs_key",
                                    "inputs": [["name": "API_KEY", "kind": "header", "label": "Your key", "secret": true, "header": "Authorization", "template": "Bearer {value}"]]]

final class McpTests: XCTestCase {
    func testValidationRefusesRunnerOptionsAndDrift() throws {
        let clients = try McpClient.bundled()
        XCTAssertNoThrow(try mcpManifest(client: "cursor").validate(clients: clients))
        XCTAssertNoThrow(try mcpManifest(client: "cursor", remoteChanges).validate(clients: clients))
        XCTAssertNoThrow(try mcpManifest(client: "claude", ["runtime": "uv", "command": "uvx", "args": ["--from", "headroom-ai[mcp]==0.39.1", "headroom", "mcp", "serve"]]).validate(clients: clients))
        let bad: [(String, [String: Any])] = [
            ("npx -c", ["args": ["-y", "-c", "rm -rf ~"]]),
            ("npx unpinned", ["args": ["-y", "demo-mcp"]]),
            ("npx node options", ["args": ["--node-options=--require=/tmp/x", "-y", "demo-mcp@1.2.3"]]),
            ("uv index", ["runtime": "uv", "command": "uvx", "args": ["--index-url", "https://evil.example", "--from", "a==1", "a"]]),
            ("runner mismatch", ["runtime": "uv"]),
            ("other program", ["command": "bash", "args": ["-c", "x"]]),
            ("expired", ["expires_at": "2001-01-01T00:00:00Z"]),
            ("needs key without inputs", ["status": "needs_key"]),
            ("bad server id", ["server_id": "../x"]),
            ("control char", ["args": ["-y", "demo-mcp@1.2.3", "a\nb"]]),
        ]
        for (note, change) in bad { XCTAssertThrowsError(try mcpManifest(client: "cursor", change).validate(clients: clients), note) }
        var http = remoteChanges; http["url"] = "http://mcp.example.org/mcp"
        XCTAssertThrowsError(try mcpManifest(client: "cursor", http).validate(clients: clients), "plain http")
        var drift = try bundledClientObjects()
        drift[0]["path"] = "Library/LaunchAgents/evil.plist"
        XCTAssertThrowsError(try mcpManifest(client: "cursor", ["client": drift[0]]).validate(clients: clients), "client drift")
    }

    func testEveryClientKeepsTheRestOfItsFileAndRemovesOnlyItsEntry() throws {
        let fm = FileManager.default
        for client in try McpClient.bundled() {
            let home = try temporaryHome(); defer { try? fm.removeItem(at: home) }
            let w = McpWriter(home: home)
            let config = try w.configURL(client)
            try fm.createDirectory(at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
            let original: String
            if client.format == "toml" {
                original = "model = \"o3\"\n\n[\(client.rootKey).mine]\ncommand = \"mine\"\n\n[profiles.fast]\nmodel = \"o4-mini\"\n"
            } else if client.format == "jsonc" {
                original = "{\n  // mine\n  \"\(client.rootKey)\": { \"mine\": { \"command\": \"mine\", }, },\n  \"other\": [1, 2,],\n}\n"
            } else {
                original = "{\"\(client.rootKey)\": {\"mine\": {\"command\": \"mine\"}}, \"other\": [1, 2], \"flag\": true}"
            }
            try Data(original.utf8).write(to: config)
            let bin = home.appendingPathComponent(".cheatcode/runtime/node/bin")
            let m = try mcpManifest(client: client.id)
            XCTAssertEqual(try w.existing(m), .none, client.id)
            let r = try w.install(m, answers: [:], bin: bin, api: "https://api.cheatcodehq.com")
            XCTAssertEqual(try w.existing(m), .ours, client.id)
            XCTAssertEqual(w.receipts().map(\.serverId), ["demo-mcp"], client.id)
            let text = try String(contentsOf: config, encoding: .utf8)
            XCTAssertTrue(text.contains(bin.appendingPathComponent("npx").path), "\(client.id) absolute runner")
            XCTAssertTrue(text.contains("demo-mcp@1.2.3") && text.contains("mine"), "\(client.id) entry and the user's own entry")
            if client.format == "toml" {
                XCTAssertTrue(text.hasPrefix(original), "codex text before the block unchanged")
                XCTAssertTrue(text.contains("[mcp_servers.demo-mcp]\ncommand = "), "codex table")
            } else {
                let root = try JSONSerialization.jsonObject(with: Data(text.utf8)) as! [String: Any]
                let entry = (root[client.rootKey] as! [String: Any])["demo-mcp"] as! [String: Any]
                XCTAssertEqual(entry["args"] as? [String], ["-y", "demo-mcp@1.2.3"], client.id)
                XCTAssertTrue(((entry["env"] as? [String: String])?["PATH"] ?? "").hasPrefix(bin.path + ":"), "\(client.id) PATH")
                XCTAssertEqual(entry["type"] as? String, client.style == "typed" ? "stdio" : nil, client.id)
                XCTAssertEqual((root["other"] as? [Int]) ?? [], [1, 2], "\(client.id) other keys kept")
                XCTAssertTrue((root[client.rootKey] as! [String: Any])["mine"] != nil, "\(client.id) user's server kept")
            }
            // A second add updates in place, keeping the same identity.
            let r2 = try w.install(m, answers: [:], bin: bin, api: "https://api.cheatcodehq.com")
            XCTAssertEqual(r2.installId, r.installId, client.id)
            try w.remove(r2, clients: McpClient.bundled())
            let after = try String(contentsOf: config, encoding: .utf8)
            XCTAssertTrue(!after.contains("demo-mcp") && after.contains("mine"), "\(client.id) removed only its entry")
            if client.format == "toml" { XCTAssertEqual(after, original, "codex file back to the original") }
            XCTAssertTrue(w.receipts().isEmpty, client.id)
            let backups = (try? fm.contentsOfDirectory(atPath: home.appendingPathComponent(".cheatcode/mcp/backups").path)) ?? []
            XCTAssertTrue(!backups.isEmpty, "\(client.id) keeps a copy of the previous file")
        }
    }

    func testRemovingTheLastServerLeavesFilesAsFound() throws {
        let fm = FileManager.default
        for client in try McpClient.bundled() {
            let home = try temporaryHome(); defer { try? fm.removeItem(at: home) }
            let w = McpWriter(home: home)
            let config = try w.configURL(client)
            let a = try mcpManifest(client: client.id)
            let b = try mcpManifest(client: client.id, ["slug": "other-mcp", "server_id": "other-mcp"])
            let ra = try w.install(a, answers: [:], bin: home, api: "https://api.cheatcodehq.com")
            let rb = try w.install(b, answers: [:], bin: home, api: "https://api.cheatcodehq.com")
            try w.remove(ra, clients: McpClient.bundled())
            XCTAssertTrue(fm.fileExists(atPath: config.path), "\(client.id) kept while another server is in it")
            try w.remove(rb, clients: McpClient.bundled())
            XCTAssertTrue(!fm.fileExists(atPath: config.path), "\(client.id) file Cheatcode created is gone again")
            if client.format != "toml" {  // a file that was there keeps everything but the section Cheatcode added
                try fm.createDirectory(at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data("{\"theme\": \"dark\"}".utf8).write(to: config)
                try w.remove(w.install(a, answers: [:], bin: home, api: "https://api.cheatcodehq.com"), clients: McpClient.bundled())
                XCTAssertEqual(try JSONSerialization.jsonObject(with: Data(contentsOf: config)) as? [String: String], ["theme": "dark"], client.id)
            }
        }
    }

    func testHostedServersPerClientAndKeys() throws {
        let home = try temporaryHome(); defer { try? FileManager.default.removeItem(at: home) }
        let w = McpWriter(home: home)
        let bin = home.appendingPathComponent("rt/bin")
        let answers = ["API_KEY": "sk-123"]
        func e(_ id: String) throws -> [String: Any] { try w.entry(mcpManifest(client: id, remoteChanges), answers: answers, bin: bin) }
        XCTAssertEqual(try e("claude")["type"] as? String, "http")
        XCTAssertEqual((try e("claude")["headers"] as? [String: String])?["Authorization"], "Bearer sk-123")
        XCTAssertEqual(try e("cursor")["url"] as? String, "https://mcp.example.org/mcp")
        XCTAssertEqual(try e("gemini")["httpUrl"] as? String, "https://mcp.example.org/mcp")
        XCTAssertEqual(try e("windsurf")["serverUrl"] as? String, "https://mcp.example.org/mcp")
        XCTAssertEqual((try e("chatgpt")["http_headers"] as? [String: String])?["Authorization"], "Bearer sk-123")
        let bridge = try e("claude-desktop")
        XCTAssertEqual(bridge["command"] as? String, bin.appendingPathComponent("npx").path)
        XCTAssertEqual(bridge["args"] as? [String], ["-y", RuntimePin.mcpRemote, "https://mcp.example.org/mcp", "--transport", "http-only", "--header", "Authorization: Bearer sk-123"])
        XCTAssertEqual(try mcpManifest(client: "claude-desktop", remoteChanges).neededRuntime, "node")
        XCTAssertEqual(try mcpManifest(client: "cursor", remoteChanges).neededRuntime, nil)
        XCTAssertThrowsError(try w.entry(mcpManifest(client: "cursor", remoteChanges), answers: [:], bin: nil), "missing key")
        XCTAssertThrowsError(try w.entry(mcpManifest(client: "cursor", remoteChanges), answers: ["API_KEY": "a\nb"], bin: nil), "newline in key")
        var sse = remoteChanges; sse["transport"] = "sse"
        XCTAssertEqual(try mcpManifest(client: "chatgpt", sse).neededRuntime, "node")  // Codex has no SSE: bridged
    }

    func testSomeoneElsesServerIsLeftAlone() throws {
        let home = try temporaryHome(); defer { try? FileManager.default.removeItem(at: home) }
        let w = McpWriter(home: home)
        let m = try mcpManifest(client: "cursor")
        let config = try w.configURL(m.client)
        try FileManager.default.createDirectory(at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
        let theirs = "{\"mcpServers\": {\"demo-mcp\": {\"command\": \"their-own\"}}}"
        try Data(theirs.utf8).write(to: config)
        XCTAssertEqual(try w.existing(m), .other)
        XCTAssertThrowsError(try w.install(m, answers: [:], bin: home, api: "https://api.cheatcodehq.com"))
        XCTAssertEqual(try String(contentsOf: config, encoding: .utf8), theirs)
        try Data("{ not json".utf8).write(to: config)
        XCTAssertThrowsError(try w.install(m, answers: [:], bin: home, api: "https://api.cheatcodehq.com"), "invalid JSON is not overwritten")
        XCTAssertEqual(try String(contentsOf: config, encoding: .utf8), "{ not json")
        XCTAssertEqual(McpWriter.stripJSONC("{\"a\": \"// not a comment\", /* x */ \"b\": [1,],}"), "{\"a\": \"// not a comment\",  \"b\": [1]}")
    }

    func testMcpLink() throws {
        let a = try Activation(URL(string: "cheatcode://mcp?intent=abc_DEF-1&api=https%3A%2F%2Fapi.cheatcodehq.com")!)
        XCTAssertTrue(a.kind == .mcp)
        XCTAssertEqual(a.endpoint().absoluteString, "https://api.cheatcodehq.com/api/v1/desktop/mcp-intents/abc_DEF-1")
        XCTAssertTrue(try Activation(URL(string: "cheatcode://install?intent=abc&api=https%3A%2F%2Fapi.cheatcodehq.com")!).kind == .skills)
        for raw in ["cheatcode://mcp?intents=a%2Cb&api=https://api.cheatcodehq.com",
                    "cheatcode://mcp?intent=abc&api=https://evil.example",
                    "cheatcode://mcp/x?intent=abc&api=https://api.cheatcodehq.com"] {
            XCTAssertThrowsError(try Activation(URL(string: raw)!), raw)
        }
    }
}
