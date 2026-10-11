import Foundation
import CryptoKit

/// One click MCP servers (R-INSTALL-1). The website hands over a signed request; the app shows what will run and
/// where it will be written, asks for the user's own key when the server needs one, makes sure the pinned runtime
/// is on this Mac, and writes one entry into the AI app's MCP config. It never runs the server itself: the AI app
/// starts it. Everything the app wrote is recorded in a receipt so Remove can take exactly that entry out again.

public struct McpClient: Codable, Equatable, Sendable {
    public let id: String
    public let label: String
    public let path: String
    public let format: String
    public let rootKey: String
    public let style: String
    public let restart: String
    public static func bundled() throws -> [McpClient] {
        #if SWIFT_PACKAGE
        let url = Bundle.module.url(forResource: "mcp_clients", withExtension: "json")
        #else
        let url = Bundle.main.url(forResource: "mcp_clients", withExtension: "json") ?? Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("mcp_clients.json")
        #endif
        guard let url else { throw InstallerError("The installer's list of AI apps is missing. Download a new installer.") }
        return try jsonDecoder().decode([McpClient].self, from: Data(contentsOf: url))
    }
}

public struct McpInput: Codable, Equatable, Sendable {
    public let name: String
    public let kind: String
    public let label: String
    public let secret: Bool
    public let header: String?
    public let template: String?
}

public struct McpManifest: Codable, Sendable {
    public let schema: String
    public let slug: String
    public let name: String
    public let publisher: String
    public let repo: String
    public let license: String
    public let serverId: String
    public let status: String
    public let transport: String
    public let runtime: String?
    public let command: String?
    public let args: [String]
    public let url: String?
    public let headers: [String: String]
    public let inputs: [McpInput]
    public let package: String?
    public let tools: Int
    public let verifiedAt: String
    public let client: McpClient
    public let expiresAt: String

    public var isRemote: Bool { transport != "stdio" }
    /// The runtime this entry needs on this Mac: the server's own, or Node for the bridge a client without
    /// hosted-server support uses (Claude Desktop always, Codex for the older SSE transport).
    public var neededRuntime: String? {
        if let runtime { return runtime }
        return McpWriter.usesBridge(self) ? "node" : nil
    }
    public var expiry: Date? {
        let format = ISO8601DateFormatter(); format.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = format.date(from: expiresAt) { return date }
        format.formatOptions = [.withInternetDateTime]; return format.date(from: expiresAt)
    }

    public func validate(clients: [McpClient], now: Date = Date()) throws {
        let bad = InstallerError("The server details are expired or unsupported. Return to Cheatcode for a fresh link and installer.")
        func plain(_ s: String, _ limit: Int) -> Bool { s.utf8.count <= limit && !s.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) }
        func matches(_ s: String, _ pattern: String) -> Bool { s.range(of: pattern, options: .regularExpression) != nil }
        guard schema == "cheatcode-mcp/v1", identifier(slug), matches(serverId, "^[a-z0-9][a-z0-9-]{0,39}$"),
              !name.isEmpty, plain(name, 200), plain(publisher, 200), plain(repo, 200), plain(license, 100),
              ["one_click", "needs_key", "sign_in"].contains(status), clients.contains(client),
              let expiry, expiry > now, (status == "needs_key") == !inputs.isEmpty,
              inputs.count <= 12, Set(inputs.map(\.name)).count == inputs.count,
              inputs.allSatisfy({ matches($0.name, "^[A-Za-z_][A-Za-z0-9_]{0,63}$") && plain($0.label, 300) })
        else { throw bad }
        if transport == "stdio" {
            guard let command, ["npx": "node", "uvx": "uv"][command] == runtime, url == nil, headers.isEmpty,
                  !args.isEmpty, args.count <= 40, args.allSatisfy({ !$0.isEmpty && plain($0, 512) }),
                  Self.argsShapeOK(command, args), inputs.allSatisfy({ $0.kind == "env" && $0.header == nil })
            else { throw bad }
        } else {
            guard ["streamable-http", "sse"].contains(transport), runtime == nil, command == nil, args.isEmpty,
                  let url, plain(url, 2048), let parsed = URLComponents(string: url), parsed.scheme == "https",
                  !(parsed.host ?? "").isEmpty, parsed.user == nil, parsed.password == nil,
                  headers.count <= 12, headers.allSatisfy({ matches($0.key, "^[A-Za-z0-9-]{1,64}$") && plain($0.value, 2048) }),
                  inputs.allSatisfy({ $0.kind == "header" && matches($0.header ?? "", "^[A-Za-z0-9-]{1,64}$") && ($0.template ?? "").contains("{value}") && plain($0.template ?? "", 256) })
            else { throw bad }
        }
    }

    /// The only argument shapes the app passes on, mirrored from the API (`mcp_install.args_shape_ok`): npx gets
    /// -y and a pinned package, uvx gets an optional --python and a pinned --from package. Anything that could
    /// reach the runner's own options (npx -c runs a shell line, a uv index URL changes where code comes from)
    /// is refused. Arguments after the package go to the server itself.
    public static func argsShapeOK(_ command: String, _ args: [String]) -> Bool {
        func m(_ s: String, _ p: String) -> Bool { s.range(of: p, options: .regularExpression) != nil }
        let npmSpec = "^(@[a-z0-9][a-z0-9._-]*/)?[a-z0-9][a-z0-9._-]*@[0-9]+\\.[0-9]+\\.[0-9]+[A-Za-z0-9.+-]*$"
        let bin = "^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$"
        if command == "npx" {
            if args.count >= 3, args[0] == "-y", args[1].hasPrefix("--package=") { return m(String(args[1].dropFirst(10)), npmSpec) && m(args[2], bin) }
            return args.count >= 2 && args[0] == "-y" && m(args[1], npmSpec)
        }
        if command == "uvx" {
            var i = 0
            if args.first == "--python" { guard args.count > 1, m(args[1], "^[0-9]+\\.[0-9]+(\\.[0-9]+)?$") else { return false }; i = 2 }
            return args.count >= i + 3 && args[i] == "--from" && m(args[i+1], "^[A-Za-z0-9][A-Za-z0-9._-]*(\\[[A-Za-z0-9._,-]+\\])?==[A-Za-z0-9.+!_-]{1,64}$") && m(args[i+2], bin)
        }
        return false
    }
}

// MARK: runtimes

/// A pinned runtime the app downloads once into ~/.cheatcode/runtime and points the AI app at by absolute path.
/// The AI apps start servers with a short PATH, so a server is never left to whatever Node or uv happens to be
/// installed (most of Cheatcode's users have neither).
public struct RuntimePin: Sendable {
    public let name: String
    public let version: String
    public let url: URL
    public let sha256: String
    public let bytes: Int
    public let root: String  // top folder inside the archive, kept as the install folder name
    public let binDir: String  // relative to root
    public let command: String  // the program clients start: npx or uvx

    public static let mcpRemote = "mcp-remote@0.14.3"  // Node bridge for hosted servers in clients without native support

    public static func pin(_ name: String) -> RuntimePin? {
        #if arch(arm64)
        switch name {
        case "node": return RuntimePin(name: "node", version: "22.23.3", url: URL(string: "https://nodejs.org/dist/v22.23.3/node-v22.23.3-darwin-arm64.tar.gz")!,
                                       sha256: "23b25245dcfb9af7262f8ff142e9e2e0af025368117329e7a7458a51e5922f53", bytes: 49_963_763,
                                       root: "node-v22.23.3-darwin-arm64", binDir: "bin", command: "npx")
        case "uv": return RuntimePin(name: "uv", version: "0.12.23", url: URL(string: "https://github.com/astral-sh/uv/releases/download/0.12.23/uv-aarch64-apple-darwin.tar.gz")!,
                                     sha256: "50487ae565ccd96e499056b4674d438f4c53170202617b4c759defe0c6a1b544", bytes: 17_044_217,
                                     root: "uv-aarch64-apple-darwin", binDir: ".", command: "uvx")
        default: return nil
        }
        #else
        switch name {
        case "node": return RuntimePin(name: "node", version: "22.23.3", url: URL(string: "https://nodejs.org/dist/v22.23.3/node-v22.23.3-darwin-x64.tar.gz")!,
                                       sha256: "8a677b0219178efd6eb0e475457c4afb452b521a92f6e67845a73bd85727f2a8", bytes: 0,
                                       root: "node-v22.23.3-darwin-x64", binDir: "bin", command: "npx")
        case "uv": return RuntimePin(name: "uv", version: "0.12.23", url: URL(string: "https://github.com/astral-sh/uv/releases/download/0.12.23/uv-x86_64-apple-darwin.tar.gz")!,
                                     sha256: "960da44cb4b73685206ddd250b19e0a117fa41095710c1038f081f5cb613efb4", bytes: 21_263_712,
                                     root: "uv-x86_64-apple-darwin", binDir: ".", command: "uvx")
        default: return nil
        }
        #endif
    }
    public func folder(home: URL) -> URL { home.appendingPathComponent(".cheatcode/runtime").appendingPathComponent(root) }
    public func bin(home: URL) -> URL { binDir == "." ? folder(home: home) : folder(home: home).appendingPathComponent(binDir) }
    public func isInstalled(home: URL) -> Bool {
        let marker = folder(home: home).appendingPathComponent(".cheatcode-verified")
        return (try? String(contentsOf: marker, encoding: .utf8)) == sha256 && FileManager.default.isExecutableFile(atPath: bin(home: home).appendingPathComponent(command).path)
    }
}

public enum Runtimes {
    /// Download, check the pinned SHA-256, unpack with the system tar and move into place. Idempotent.
    public static func ensure(_ pin: RuntimePin, home: URL, progress: @escaping @Sendable (String) -> Void = { _ in }) async throws -> URL {
        if pin.isInstalled(home: home) { return pin.bin(home: home) }
        let fm = FileManager.default
        let base = home.appendingPathComponent(".cheatcode/runtime")
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        let work = base.appendingPathComponent(".download-" + UUID().uuidString.lowercased())
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }
        progress("Downloading \(pin.name == "node" ? "Node.js" : "uv") \(pin.version), needed once for this kind of server.")
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30; config.timeoutIntervalForResource = 600; config.urlCache = nil
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let (file, response) = try await session.download(from: pin.url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw InstallerError("Could not download \(pin.name) \(pin.version). Check your connection and retry.") }
        let archive = work.appendingPathComponent("runtime.tar.gz")
        try fm.moveItem(at: file, to: archive)
        progress("Checking the \(pin.name) download against its published checksum.")
        guard try fileDigest(archive) == pin.sha256 else { throw InstallerError("The \(pin.name) download does not match its published checksum. Nothing was installed.") }
        let unpacked = work.appendingPathComponent("unpacked")
        try fm.createDirectory(at: unpacked, withIntermediateDirectories: true)
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.arguments = ["-xzf", archive.path, "-C", unpacked.path, "--no-same-owner"]
        try tar.run(); tar.waitUntilExit()
        let root = unpacked.appendingPathComponent(pin.root)
        guard tar.terminationStatus == 0, fm.fileExists(atPath: root.path) else { throw InstallerError("Could not unpack \(pin.name). Nothing was installed.") }
        try Data(pin.sha256.utf8).write(to: root.appendingPathComponent(".cheatcode-verified"))
        let final = pin.folder(home: home)
        if fm.fileExists(atPath: final.path) { try fm.removeItem(at: final) }
        try fm.moveItem(at: root, to: final)
        guard pin.isInstalled(home: home) else { throw InstallerError("\(pin.name) did not install correctly.") }
        return pin.bin(home: home)
    }
    static func fileDigest(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        var hash = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hash.update(data: chunk) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: writing the client config

public struct McpReceipt: Codable, Equatable, Sendable {
    public let slug: String
    public let name: String
    public let serverId: String
    public let client: String
    public let clientLabel: String
    public let configPath: String
    public let installId: String
    public let entryDigest: String
    public let writtenAt: String
    public let api: String
}

/// none: no server by this name. ours: Cheatcode wrote it (adding again updates it). other: something else put a
/// server with this name there; it is left exactly as it is.
public enum McpExisting: Sendable, Equatable { case none, ours, other }

public final class McpWriter {
    let home: URL
    let fm = FileManager.default
    public init(home: URL) { self.home = home }

    public static func usesBridge(_ m: McpManifest) -> Bool {
        m.isRemote && (m.client.style == "bridge" || (m.client.style == "codex" && m.transport == "sse"))
    }
    public func configURL(_ client: McpClient) throws -> URL {
        guard safeRelativePath(client.path) else { throw InstallerError("Invalid AI app config path.") }
        let url = home.appendingPathComponent(client.path)
        // A dotfiles setup may link the config elsewhere: edit the file it points to, never replace the link.
        return (try? fm.destinationOfSymbolicLink(atPath: url.path)).map { URL(fileURLWithPath: $0, relativeTo: url.deletingLastPathComponent()).standardizedFileURL } ?? url
    }
    var receiptsDir: URL { home.appendingPathComponent(".cheatcode/mcp/receipts") }
    /// What Cheatcode created in a client's config (the file, the servers section), so removing the last server it
    /// added leaves the file as it found it. Written once, when something is first created.
    struct Created: Codable { var file: Bool; var root: Bool }
    func createdURL(_ client: String) -> URL { home.appendingPathComponent(".cheatcode/mcp/created/\(client).json") }
    func noteCreated(_ client: String, file: Bool, root: Bool) throws {
        let url = createdURL(client)
        guard (file || root), !fm.fileExists(atPath: url.path) else { return }
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try jsonEncoder().encode(Created(file: file, root: root)).write(to: url, options: .atomic)
    }
    func receiptURL(client: String, serverId: String) -> URL { receiptsDir.appendingPathComponent("\(client)--\(serverId).json") }

    public func receipts() -> [McpReceipt] {
        let files = (try? fm.contentsOfDirectory(at: receiptsDir, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }.compactMap { try? jsonDecoder().decode(McpReceipt.self, from: Data(contentsOf: $0)) }
            .sorted { $0.writtenAt > $1.writtenAt }
    }
    public func receipt(_ m: McpManifest) -> McpReceipt? {
        try? jsonDecoder().decode(McpReceipt.self, from: Data(contentsOf: receiptURL(client: m.client.id, serverId: m.serverId)))
    }

    /// The entry exactly as it will be written. `bin` is the folder of the pinned runtime that runs it.
    public func entry(_ m: McpManifest, answers: [String: String], bin: URL?) throws -> [String: Any] {
        let path = (bin.map { $0.path + ":" } ?? "") + "/usr/bin:/bin:/usr/sbin:/sbin"
        func stdio(_ command: String, _ args: [String], _ env: [String: String]) throws -> [String: Any] {
            guard let bin else { throw InstallerError("The runtime for this server is missing.") }
            var e = env; e["PATH"] = path
            if command == "uvx" { e["UV_PYTHON_PREFERENCE"] = "only-managed" }  // never the macOS python3 stub
            var o: [String: Any] = ["command": bin.appendingPathComponent(command).path, "args": args, "env": e]
            if m.client.style == "typed" { o["type"] = "stdio" }
            return o
        }
        for input in m.inputs {
            guard let v = answers[input.name], !v.isEmpty, v.utf8.count <= 4096,
                  !v.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw InstallerError("Fill in \(input.label.isEmpty ? input.name : input.label).") }
        }
        if !m.isRemote {
            var env: [String: String] = [:]
            for input in m.inputs { env[input.name] = answers[input.name] }
            return try stdio(m.command!, m.args, env)
        }
        var headers = m.headers
        for input in m.inputs { headers[input.header!] = input.template!.replacingOccurrences(of: "{value}", with: answers[input.name]!) }
        let url = m.url!
        if Self.usesBridge(m) {
            var args = ["-y", RuntimePin.mcpRemote, url, "--transport", m.transport == "sse" ? "sse-only" : "http-only"]
            for (k, v) in headers.sorted(by: { $0.key < $1.key }) { args += ["--header", "\(k): \(v)"] }
            return try stdio("npx", args, [:])
        }
        var o: [String: Any]
        switch m.client.style {
        case "typed": o = ["type": m.transport == "sse" ? "sse" : "http", "url": url]
        case "gemini": o = [m.transport == "sse" ? "url" : "httpUrl": url]
        case "windsurf": o = ["serverUrl": url]
        default: o = ["url": url]
        }
        if !headers.isEmpty { o[m.client.style == "codex" ? "http_headers" : "headers"] = headers }
        return o
    }

    // TOML for Codex: one [mcp_servers.<id>] table, written and removed as a block.
    static func toml(_ s: String) -> String {
        var out = "\""
        for u in s.unicodeScalars {
            switch u {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            default:
                if CharacterSet.controlCharacters.contains(u) { out += String(format: "\\u%04X", u.value) } else { out.unicodeScalars.append(u) }
            }
        }
        return out + "\""
    }
    static func tomlValue(_ v: Any) -> String {
        if let s = v as? String { return toml(s) }
        if let a = v as? [String] { return "[" + a.map(toml).joined(separator: ", ") + "]" }
        if let d = v as? [String: String] { return "{ " + d.sorted(by: { $0.key < $1.key }).map { "\(toml($0.key)) = \(toml($0.value))" }.joined(separator: ", ") + " }" }
        return "\"\""
    }
    func tomlBlock(_ m: McpManifest, _ entry: [String: Any]) -> String {
        var lines = ["# Added by Cheatcode_ for \(m.slug). Remove it in the Cheatcode app.", "[\(m.client.rootKey).\(m.serverId)]"]
        for key in ["command", "args", "url", "env", "http_headers"] { if let v = entry[key] { lines.append("\(key) = \(Self.tomlValue(v))") } }
        return lines.joined(separator: "\n") + "\n"
    }
    func tomlHeader(_ m: McpManifest) -> String { "(?m)^[ \\t]*\\[[ \\t]*\(m.client.rootKey)[ \\t]*\\.[ \\t]*\"?\(NSRegularExpression.escapedPattern(for: m.serverId))\"?[ \\t]*\\]" }

    static func digestOf(_ entry: [String: Any]) -> String {
        digest((try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys])) ?? Data())
    }

    /// JSON with comments and trailing commas (VS Code's mcp.json) to plain JSON. Strings are kept as they are.
    public static func stripJSONC(_ text: String) -> String {
        var out = ""; let chars = Array(text.unicodeScalars); var i = 0; var inString = false
        while i < chars.count {
            let c = chars[i]
            if inString {
                out.unicodeScalars.append(c)
                if c == "\\" && i + 1 < chars.count { out.unicodeScalars.append(chars[i+1]); i += 2; continue }
                if c == "\"" { inString = false }
                i += 1; continue
            }
            if c == "\"" { inString = true; out.unicodeScalars.append(c); i += 1; continue }
            if c == "/" && i + 1 < chars.count && chars[i+1] == "/" { while i < chars.count && chars[i] != "\n" { i += 1 }; continue }
            if c == "/" && i + 1 < chars.count && chars[i+1] == "*" {
                i += 2; while i + 1 < chars.count && !(chars[i] == "*" && chars[i+1] == "/") { i += 1 }; i += 2; continue
            }
            if c == "," {
                var j = i + 1; while j < chars.count && CharacterSet.whitespacesAndNewlines.contains(chars[j]) { j += 1 }
                if j < chars.count && (chars[j] == "}" || chars[j] == "]") { i += 1; continue }
            }
            out.unicodeScalars.append(c); i += 1
        }
        return out
    }

    func readJSON(_ url: URL, jsonc: Bool) throws -> [String: Any] {
        guard fm.fileExists(atPath: url.path) else { return [:] }
        let data = try Data(contentsOf: url)
        guard data.count < 64 * 1024 * 1024 else { throw InstallerError("The AI app's config file is too large to edit safely.") }
        guard let text = String(data: data, encoding: .utf8) else { throw InstallerError("The AI app's config file is not readable text. Nothing was changed.") }
        let body = jsonc ? Self.stripJSONC(text) : text
        if body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return [:] }
        guard let object = try? JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any] else {
            throw InstallerError("\(url.path) is not valid JSON, so Cheatcode left it as it is. Fix or remove that file and try again.")
        }
        return object
    }

    func write(_ data: Data, to url: URL) throws {
        let dir = url.deletingLastPathComponent()
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let mode = (try? fm.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue ?? 0o600
        if fm.fileExists(atPath: url.path) {  // one copy of the previous file per write, the last five kept
            let backups = home.appendingPathComponent(".cheatcode/mcp/backups")
            try fm.createDirectory(at: backups, withIntermediateDirectories: true)
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            let name = url.lastPathComponent
            try? fm.copyItem(at: url, to: backups.appendingPathComponent("\(name).\(stamp)"))
            let old = ((try? fm.contentsOfDirectory(atPath: backups.path)) ?? []).filter { $0.hasPrefix(name + ".") }.sorted()
            for f in old.dropLast(5) { try? fm.removeItem(at: backups.appendingPathComponent(f)) }
        }
        let tmp = dir.appendingPathComponent(".\(url.lastPathComponent).cheatcode-\(UUID().uuidString.prefix(8))")
        try data.write(to: tmp)
        try fm.setAttributes([.posixPermissions: mode], ofItemAtPath: tmp.path)
        guard rename(tmp.path, url.path) == 0 else { try? fm.removeItem(at: tmp); throw InstallerError("Could not save \(url.path).") }
    }

    public func existing(_ m: McpManifest) throws -> McpExisting {
        let url = try configURL(m.client)
        let present: Bool
        if m.client.format == "toml" {
            let text = fm.fileExists(atPath: url.path) ? try String(contentsOf: url, encoding: .utf8) : ""
            present = text.range(of: tomlHeader(m), options: .regularExpression) != nil
        } else {
            present = ((try readJSON(url, jsonc: m.client.format == "jsonc"))[m.client.rootKey] as? [String: Any])?[m.serverId] != nil
        }
        if !present { return .none }
        return receipt(m) != nil ? .ours : .other
    }

    /// Writes the entry and its receipt. Nothing else in the file changes.
    public func install(_ m: McpManifest, answers: [String: String], bin: URL?, installId: String? = nil, api: String) throws -> McpReceipt {
        let url = try configURL(m.client)
        let state = try existing(m)
        guard state != .other else { throw InstallerError("\(m.client.label) already has a server named \(m.serverId) that Cheatcode did not add. It was left as it is.") }
        let entry = try self.entry(m, answers: answers, bin: bin)
        let fileExisted = fm.fileExists(atPath: url.path)
        if m.client.format == "toml" {
            var text = fm.fileExists(atPath: url.path) ? try String(contentsOf: url, encoding: .utf8) : ""
            guard text.range(of: "(?m)^[ \\t]*\(m.client.rootKey)[ \\t]*=", options: .regularExpression) == nil else {
                throw InstallerError("\(url.path) lists its MCP servers in one line, which Cheatcode does not edit. Nothing was changed.")
            }
            if state == .ours { text = removeTomlBlock(text, m) }
            if !text.isEmpty && !text.hasSuffix("\n") { text += "\n" }
            text += (text.isEmpty ? "" : "\n") + tomlBlock(m, entry)
            try write(Data(text.utf8), to: url)
            try noteCreated(m.client.id, file: !fileExisted, root: false)
        } else {
            var root = try readJSON(url, jsonc: m.client.format == "jsonc")
            if let existing = root[m.client.rootKey], !(existing is [String: Any]) { throw InstallerError("\(url.path) has an unexpected \(m.client.rootKey) section. Nothing was changed.") }
            let rootExisted = root[m.client.rootKey] != nil
            var servers = root[m.client.rootKey] as? [String: Any] ?? [:]
            servers[m.serverId] = entry
            root[m.client.rootKey] = servers
            try write(try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .withoutEscapingSlashes]), to: url)
            try noteCreated(m.client.id, file: !fileExisted, root: !rootExisted)
        }
        let r = McpReceipt(slug: m.slug, name: m.name, serverId: m.serverId, client: m.client.id, clientLabel: m.client.label,
                           configPath: url.path, installId: installId ?? receipt(m)?.installId ?? UUID().uuidString.lowercased(),
                           entryDigest: Self.digestOf(entry), writtenAt: ISO8601DateFormatter().string(from: Date()), api: api)
        try fm.createDirectory(at: receiptsDir, withIntermediateDirectories: true)
        try jsonEncoder().encode(r).write(to: receiptURL(client: m.client.id, serverId: m.serverId), options: .atomic)
        return r
    }

    func removeTomlBlock(_ text: String, _ m: McpManifest) -> String {
        var lines = text.components(separatedBy: "\n")
        guard let start = lines.firstIndex(where: { $0.range(of: tomlHeader(m), options: .regularExpression) != nil }) else { return text }
        var end = start + 1
        let sub = "[\(m.client.rootKey).\(m.serverId)."
        while end < lines.count {
            let t = lines[end].trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("[") && !t.hasPrefix(sub) { break }
            end += 1
        }
        if end == lines.count && lines.last == "" { end -= 1 }  // keep the file's final newline
        var from = start
        if from > 0 && lines[from - 1].hasPrefix("# Added by Cheatcode_") { from -= 1 }
        lines.removeSubrange(from..<end)
        if from > 0 && lines[from - 1].isEmpty && (from == lines.count || lines[from].isEmpty) { lines.remove(at: from - 1) }
        return lines.joined(separator: "\n")
    }

    /// Takes out the entry Cheatcode added, whatever was typed into it since, and the receipt.
    public func remove(_ r: McpReceipt, clients: [McpClient]) throws {
        guard let client = clients.first(where: { $0.id == r.client }), r.serverId.range(of: "^[a-z0-9][a-z0-9-]{0,39}$", options: .regularExpression) != nil else {
            throw InstallerError("This receipt names an AI app this installer does not know.")
        }
        let url = try configURL(client)
        let created = try? jsonDecoder().decode(Created.self, from: Data(contentsOf: createdURL(client.id)))
        let lastOne = !receipts().contains { $0.client == r.client && $0.serverId != r.serverId }
        if fm.fileExists(atPath: url.path) {
            if client.format == "toml" {
                let fake = McpManifest.placeholder(slug: r.slug, serverId: r.serverId, client: client)
                let text = try String(contentsOf: url, encoding: .utf8)
                let next = removeTomlBlock(text, fake)
                if lastOne && created?.file == true && next.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { try fm.removeItem(at: url) }
                else if next != text { try write(Data(next.utf8), to: url) }
            } else {
                var root = try readJSON(url, jsonc: client.format == "jsonc")
                if var servers = root[client.rootKey] as? [String: Any], servers[r.serverId] != nil {
                    servers.removeValue(forKey: r.serverId); root[client.rootKey] = servers
                    if lastOne && servers.isEmpty && created?.root == true { root.removeValue(forKey: client.rootKey) }
                    if lastOne && root.isEmpty && created?.file == true { try fm.removeItem(at: url) }
                    else { try write(try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .withoutEscapingSlashes]), to: url) }
                }
            }
        }
        try? fm.removeItem(at: receiptURL(client: r.client, serverId: r.serverId))
        if lastOne { try? fm.removeItem(at: createdURL(client.id)) }
    }
}

extension McpManifest {
    static func placeholder(slug: String, serverId: String, client: McpClient) -> McpManifest {
        McpManifest(schema: "cheatcode-mcp/v1", slug: slug, name: slug, publisher: "", repo: "", license: "", serverId: serverId,
                    status: "one_click", transport: "stdio", runtime: nil, command: nil, args: [], url: nil, headers: [:], inputs: [],
                    package: nil, tools: 0, verifiedAt: "", client: client, expiresAt: "")
    }
}
