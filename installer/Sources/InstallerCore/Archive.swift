import Foundation

public enum Archive {
    public static func extract(_ compressed: Data, manifest: Manifest) throws -> [String: Data] {
        guard compressed.count == manifest.archiveBytes, digest(compressed) == manifest.archiveSha256 else { throw InstallerError("The download does not match the reviewed package.") }
        return try parseTar(decompress(compressed), manifest: manifest)
    }
    public static func parseTar(_ tar: Data, manifest: Manifest) throws -> [String: Data] {
        guard tar.count <= maximumExpandedBytes + 16 * 1024 * 1024, tar.count % 512 == 0 else { throw InstallerError("The archive size is invalid.") }
        let expected = Dictionary(uniqueKeysWithValues: manifest.files.map { ($0.path, $0) })
        var output: [String: Data] = [:]; var offset = 0; var paxPath: String?
        func fail() -> InstallerError { InstallerError("The archive contains an unsafe, unexpected or corrupt entry.") }
        while offset + 512 <= tar.count {
            let h = [UInt8](tar[offset..<offset+512]); offset += 512
            if h.allSatisfy({ $0 == 0 }) {
                guard paxPath == nil, offset + 512 <= tar.count, tar[offset...].allSatisfy({ $0 == 0 }), output.count == expected.count else { throw fail() }
                return output
            }
            func text(_ start: Int, _ length: Int) throws -> String {
                let raw = h[start..<start+length].prefix(while: { $0 != 0 })
                guard let value = String(bytes: raw, encoding: .utf8) else { throw fail() }
                return value
            }
            func octal(_ start: Int, _ length: Int) throws -> Int {
                let raw = try text(start, length).trimmingCharacters(in: .whitespaces)
                guard !raw.isEmpty, raw.allSatisfy({ $0 >= "0" && $0 <= "7" }), let n = Int(raw, radix:8) else { throw fail() }
                return n
            }
            var check = h; for i in 148..<156 { check[i] = 32 }
            guard try octal(148,8) == check.reduce(0,{ $0 + Int($1) }),
                  try text(257,6) == "ustar", try text(157,100).isEmpty else { throw fail() }
            let size = try octal(124,12)
            guard size >= 0, size <= maximumExpandedBytes, size <= tar.count-offset else { throw fail() }
            let data = Data(tar[offset..<offset+size]); offset += ((size+511)/512)*512
            guard offset <= tar.count else { throw fail() }
            if h[156] == 120 {
                guard paxPath == nil, size <= 4096 else { throw fail() }
                // Python's deterministic PAX writer uses a per-file path record for long or Unicode names.
                var cursor = 0; var values: [String:String] = [:]
                let bytes = [UInt8](data)
                while cursor < bytes.count {
                    guard let space = bytes[cursor...].firstIndex(of:32), space-cursor <= 8,
                          let number = String(bytes: bytes[cursor..<space],encoding:.utf8),
                          let length = Int(number), length > space-cursor+2, length <= bytes.count-cursor,
                          bytes[cursor+length-1] == 10,
                          let record = String(bytes:bytes[space+1..<cursor+length-1],encoding:.utf8),
                          let equal = record.firstIndex(of:"=") else { throw fail() }
                    let key = String(record[..<equal]); let value = String(record[record.index(after:equal)...])
                    guard key == "path", values[key] == nil else { throw fail() }
                    values[key] = value; cursor += length
                }
                guard let path = values["path"], safeRelativePath(path) else { throw fail() }
                paxPath = path; continue
            }
            guard h[156] == 48 || h[156] == 0 else { throw fail() }
            let prefix = try text(345,155); let headerName = try text(0,100)
            let name = paxPath ?? (prefix.isEmpty ? headerName : prefix + "/" + headerName); paxPath = nil
            guard safeRelativePath(name), name.hasPrefix(manifest.slug + "/") else { throw fail() }
            let relative = String(name.dropFirst(manifest.slug.count+1))
            guard output[relative] == nil, let file = expected[relative], file.bytes == size, file.sha256 == digest(data) else { throw fail() }
            output[relative] = data
        }
        throw fail()
    }
    private static func decompress(_ input: Data) throws -> Data {
        // The only child process is Apple's fixed decoder. Archive content is never executed.
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try input.write(to: temp, options: [.atomic]); defer { try? FileManager.default.removeItem(at: temp) }
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/gzip"); process.arguments = ["-dc", temp.path]
        let pipe = Pipe(); process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
        try process.run(); defer { if process.isRunning { process.terminate() }; process.waitUntilExit() }
        var output = Data()
        while let chunk = try pipe.fileHandleForReading.read(upToCount: 64 * 1024), !chunk.isEmpty {
            guard output.count + chunk.count <= maximumExpandedBytes + 16 * 1024 * 1024 else { throw InstallerError("The expanded archive is too large.") }
            output.append(chunk)
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw InstallerError("The archive could not be decoded.") }
        return output
    }
}
