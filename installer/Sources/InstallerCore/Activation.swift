import Foundation

public struct InstallerError: LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

public struct Activation: Sendable {
    public static let maximumPackages = 30
    /// skills: cheatcode://install (a listing or a kit). mcp: cheatcode://mcp, one MCP server into one AI app.
    public enum Kind: Sendable { case skills, mcp }
    public let kind: Kind
    public let origin: URL
    /// One signed request per package: a single listing (`intent=`) or a whole role kit (`intents=a,b,c`).
    public let tokens: [String]
    public var token: String { tokens[0] }
    public var isKit: Bool { tokens.count > 1 }
    public init(_ url: URL, allowLocal: Bool = false) throws {
        let invalid = InstallerError("This installation link is invalid. Return to Cheatcode and create a new link.")
        guard url.absoluteString.utf8.count <= 16_384,
              let c = URLComponents(url: url, resolvingAgainstBaseURL: false),
              c.scheme == "cheatcode", c.host == "install" || c.host == "mcp", c.path.isEmpty,
              c.user == nil, c.password == nil, c.port == nil, c.fragment == nil,
              let query = c.queryItems, query.count == 2,
              let raw = query.first(where: { $0.name == "api" })?.value,
              let origin = URL(string: raw), Self.allowedOrigin(origin, allowLocal: allowLocal)
        else { throw invalid }
        let names = Set(query.map(\.name))
        let tokens: [String]
        if c.host == "mcp" {
            guard names == Set(["intent", "api"]), let one = query.first(where: { $0.name == "intent" })?.value else { throw invalid }
            tokens = [one]
        } else if names == Set(["intent", "api"]), let one = query.first(where: { $0.name == "intent" })?.value {
            tokens = [one]
        } else if names == Set(["intents", "api"]), let many = query.first(where: { $0.name == "intents" })?.value {
            tokens = many.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        } else { throw invalid }
        guard !tokens.isEmpty, tokens.count <= Self.maximumPackages, Set(tokens).count == tokens.count,
              tokens.allSatisfy({ $0.range(of: "^[A-Za-z0-9_-]+(?:\\.[A-Za-z0-9_-]+)?$", options: .regularExpression) != nil })
        else { throw invalid }
        self.origin = origin; self.tokens = tokens; self.kind = c.host == "mcp" ? .mcp : .skills
    }
    public static func allowedOrigin(_ url: URL, allowLocal: Bool = false) -> Bool {
        if url.absoluteString == "https://api.cheatcodehq.com" { return true }
        #if DEBUG
        if allowLocal && ["http://127.0.0.1:8000", "http://localhost:8000", "http://[::1]:8000"].contains(url.absoluteString) { return true }
        #endif
        return false
    }
    public func endpoint(_ suffix: String = "", token: String? = nil) -> URL {
        origin.appendingPathComponent("api/v1/desktop/\(kind == .mcp ? "mcp-intents" : "intents")/\(token ?? self.token)\(suffix)")
    }
}
