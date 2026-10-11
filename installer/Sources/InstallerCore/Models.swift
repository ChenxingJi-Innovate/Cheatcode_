import Foundation
import CryptoKit

public let maximumArchiveBytes = 32 * 1024 * 1024
public let maximumExpandedBytes = 128 * 1024 * 1024
public func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
public func identifier(_ value: String) -> Bool { value.range(of: "^[a-z0-9][a-z0-9_-]{0,127}$", options: .regularExpression) != nil }
public func safeRelativePath(_ path: String) -> Bool {
    !path.isEmpty && path.utf8.count <= 1024 && !path.hasPrefix("/") && !path.contains("\\") && !path.contains(":") &&
    !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) &&
    path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." && $0.utf8.count <= 255 }
}
public func jsonDecoder() -> JSONDecoder { let d = JSONDecoder(); d.keyDecodingStrategy = .convertFromSnakeCase; return d }
public func jsonEncoder() -> JSONEncoder { let e = JSONEncoder(); e.keyEncodingStrategy = .convertToSnakeCase; e.outputFormatting = [.sortedKeys]; return e }

public struct NativeTarget: Codable, Equatable, Sendable {
    public let id: String
    public let label: String
    public let userPath: String
    public let alternateUserPath: String?
    public let projectPath: String?
    public let statePath: String?
    public let environmentVariable: String?
    public let environmentSuffix: String?
    public let layout: String
    public let bundleLicense: Bool
    public let accountSync: Bool
    public let restart: String
    public static func bundled() throws -> [NativeTarget] {
        #if SWIFT_PACKAGE
        let url = Bundle.module.url(forResource: "targets", withExtension: "json")
        #else
        let url = Bundle.main.url(forResource: "targets", withExtension: "json") ?? Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("targets.json")
        #endif
        guard let url else { throw InstallerError("The installer target catalog is missing. Download a new installer.") }
        return try jsonDecoder().decode([NativeTarget].self, from: Data(contentsOf: url))
    }
}
public struct ManifestFile: Codable, Sendable { public let path: String; public let sha256: String; public let bytes: Int }
public struct Manifest: Codable, Sendable {
    public let schema: String
    public let slug: String
    public let name: String
    public let version: String
    public let publisher: String
    public let license: String
    public let contentHash: String
    public let archiveSha256: String
    public let archiveBytes: Int
    public let files: [ManifestFile]
    public let skills: [String]
    public let target: NativeTarget
    public let scope: String
    public let expiresAt: String
    public func validate(targets: [NativeTarget], now: Date = Date()) throws {
        func isHash(_ value: String) -> Bool { value.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil }
        guard schema == "cheatcode-desktop/v1", identifier(slug),
              !name.isEmpty, !version.isEmpty, name.utf8.count < 1024, version.utf8.count < 256,
              [name,version,publisher,license].allSatisfy({ !$0.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) }),
              publisher.utf8.count < 1024, license.utf8.count < 1024,
              ["user", "project"].contains(scope), let expiry, expiry > now,
              targets.contains(target), ["plugin", "flat"].contains(target.layout),
              scope != "project" || target.projectPath != nil,
              isHash(contentHash), isHash(archiveSha256), archiveBytes > 0, archiveBytes <= maximumArchiveBytes,
              !files.isEmpty, files.count <= 10_000, !skills.isEmpty, skills.allSatisfy(identifier),
              Set(skills).count == skills.count else { throw InstallerError("The install details are expired or unsupported. Return to Cheatcode for a fresh link and installer.") }
        var seen = Set<String>(); var total = 0
        for file in files {
            guard safeRelativePath(file.path), isHash(file.sha256), file.bytes >= 0,
                  file.bytes <= maximumExpandedBytes, seen.insert(file.path.precomposedStringWithCanonicalMapping.lowercased()).inserted
            else { throw InstallerError("The package contains an unsafe or repeated file path.") }
            total += file.bytes
            guard total <= maximumExpandedBytes else { throw InstallerError("The package is too large.") }
        }
        let paths = Set(files.map(\.path))
        for path in paths {
            let parts = path.split(separator: "/")
            for count in 1..<parts.count {
                guard !seen.contains(parts.prefix(count).joined(separator: "/").precomposedStringWithCanonicalMapping.lowercased()) else { throw InstallerError("A file conflicts with a directory in this package.") }
            }
        }
        guard skills.allSatisfy({ paths.contains("skills/\($0)/SKILL.md") }) else { throw InstallerError("A skill entry file is missing.") }
        let summary = files.map { "\($0.path)\0\($0.sha256)\n" }.joined()
        guard digest(Data(summary.utf8)) == contentHash else { throw InstallerError("The package file list does not match the pinned content.") }
    }
    public var expiry: Date? {
        let format = ISO8601DateFormatter(); format.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = format.date(from: expiresAt) { return date }
        format.formatOptions = [.withInternetDateTime]; return format.date(from: expiresAt)
    }
}
