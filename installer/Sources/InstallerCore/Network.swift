import Foundation

private final class NoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
public final class InstallerNetwork {
    private let activation: Activation
    private let session: URLSession
    public init(activation: Activation) {
        self.activation = activation
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20; config.timeoutIntervalForResource = 90
        config.urlCache = nil; config.httpCookieStorage = nil; config.urlCredentialStorage = nil
        config.httpShouldSetCookies = false; config.httpMaximumConnectionsPerHost = 2
        session = URLSession(configuration:config,delegate:NoRedirects(),delegateQueue:nil)
    }
    deinit { session.invalidateAndCancel() }
    private func request(_ url: URL, limit: Int, body: Data? = nil) async throws -> Data {
        var request = URLRequest(url:url); request.cachePolicy = .reloadIgnoringLocalCacheData
        if let body { request.httpMethod = "POST"; request.httpBody = body; request.setValue("application/json",forHTTPHeaderField:"Content-Type") }
        let (bytes,response) = try await session.bytes(for:request)
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            switch status {
            case 409: throw InstallerError("This package changed since you opened the link. Return to Cheatcode to review the current version.")
            case 410: throw InstallerError("This link expired. Return to Cheatcode for a new installation link.")
            default: throw InstallerError("Cheatcode could not complete the request (HTTP \(status)). Check your connection and retry.")
            }
        }
        guard response.expectedContentLength <= Int64(limit) else { throw InstallerError("The response exceeds the installer size limit.") }
        var data = Data(); data.reserveCapacity(min(limit,64*1024))
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < limit else { throw InstallerError("The response exceeds the installer size limit.") }
            data.append(byte)
        }
        return data
    }
    public func manifest(token: String? = nil) async throws -> Manifest {
        let manifest = try jsonDecoder().decode(Manifest.self,from:await request(activation.endpoint(token:token),limit:4*1024*1024))
        try manifest.validate(targets:NativeTarget.bundled()); return manifest
    }
    public func archive(manifest: Manifest, token: String? = nil) async throws -> Data {
        try await request(activation.endpoint("/archive",token:token),limit:min(manifest.archiveBytes,maximumArchiveBytes))
    }
    public func mcpManifest() async throws -> McpManifest {
        let manifest = try jsonDecoder().decode(McpManifest.self,from:await request(activation.endpoint(),limit:256*1024))
        try manifest.validate(clients:McpClient.bundled()); return manifest
    }
    public func record(mcp manifest: McpManifest, receipt: McpReceipt) async throws {
        let object = ["slug":manifest.slug,"target":manifest.client.id,"scope":"user","client":"desktop","install_id":receipt.installId,"package_version":String((manifest.package ?? "hosted").prefix(40))]
        _ = try await request(activation.origin.appendingPathComponent("api/events/install"),limit:64*1024,body:JSONSerialization.data(withJSONObject:object))
    }
    public func record(manifest: Manifest, result: InstallResult) async throws {
        let object = ["slug":manifest.slug,"target":manifest.target.id,"scope":manifest.scope,"client":"desktop","install_id":result.installID,"package_version":manifest.version]
        _ = try await request(activation.origin.appendingPathComponent("api/events/install"),limit:64*1024,body:JSONSerialization.data(withJSONObject:object))
    }
}

/// Tells Cheatcode an MCP server was removed, so install counts stay honest. Best effort: removal never waits on it.
public func recordUninstall(api: String, installId: String) async {
    guard let origin = URL(string: api), Activation.allowedOrigin(origin, allowLocal: true),
          installId.range(of: "^[a-f0-9-]{36}$", options: .regularExpression) != nil else { return }
    var request = URLRequest(url: origin.appendingPathComponent("api/events/uninstall"))
    request.httpMethod = "POST"; request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try? JSONSerialization.data(withJSONObject: ["install_id": installId])
    let config = URLSessionConfiguration.ephemeral; config.timeoutIntervalForRequest = 10
    let session = URLSession(configuration: config); defer { session.finishTasksAndInvalidate() }
    _ = try? await session.data(for: request)
}
