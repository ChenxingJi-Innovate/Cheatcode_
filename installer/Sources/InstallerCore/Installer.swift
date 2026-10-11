import Foundation
import Darwin

private func canonicalDirectory(_ url: URL) throws -> URL {
    guard let pointer = realpath(url.path,nil) else { throw InstallerError("The selected base folder no longer exists.") }
    defer { free(pointer) }
    return URL(fileURLWithPath:String(cString:pointer))
}
public struct Destination: Sendable {
    public let skills: URL
    public let state: URL
    public let layout: String
    public init(manifest: Manifest, home: URL, project: URL? = nil, environment: [String:String] = [:]) throws {
        let target = manifest.target
        if manifest.scope == "project" {
            guard let project, let path = target.projectPath, safeRelativePath(path) else { throw InstallerError("Choose a project folder before installing.") }
            skills = try canonicalDirectory(project).appendingPathComponent(path); layout = "flat"
            state = skills.appendingPathComponent(".cheatcode")
        } else {
            let base = try canonicalDirectory(home)
            guard safeRelativePath(target.userPath) else { throw InstallerError("Invalid client destination.") }
            var chosen = base.appendingPathComponent(target.userPath)
            if let key = target.environmentVariable, let value = environment[key], !value.isEmpty {
                guard value.hasPrefix("/"), let suffix = target.environmentSuffix, safeRelativePath(suffix) else { throw InstallerError("The client environment path must be absolute.") }
                chosen = URL(fileURLWithPath:value).appendingPathComponent(suffix)
            } else if let alternate = target.alternateUserPath, safeRelativePath(alternate),
                      !FileManager.default.fileExists(atPath:chosen.deletingLastPathComponent().path),
                      FileManager.default.fileExists(atPath:base.appendingPathComponent(alternate).deletingLastPathComponent().path) {
                chosen = base.appendingPathComponent(alternate)
            }
            skills = chosen; layout = target.layout
            if let path = target.statePath {
                guard safeRelativePath(path) else { throw InstallerError("Invalid receipt destination.") }
                state = base.appendingPathComponent(path)
            } else { state = skills.appendingPathComponent(".cheatcode") }
        }
    }
}
public struct InstallResult: Sendable {
    public let installID: String
    public let receipt: URL
    public let destination: URL
}
private struct Receipt: Codable {
    let slug: String; let target: String; let scope: String; let installId: String
    let skillsRoot: String; let stateRoot: String; let owned: [String:[String:String]]
}
private struct Journal: Codable {
    struct Item: Codable { let key: String; let old: [String:String]?; let new: [String:String]? }
    let slug: String; let skillsRoot: String; let stateRoot: String
    var committed: Bool; let items: [Item]
}
/// none: nothing there. native: this app installed it (reinstall updates it). commandLine: the terminal
/// installer owns it. unmanaged: a folder with that name exists that neither installer put there.
public enum ExistingInstall: Sendable, Equatable { case none, native, commandLine, unmanaged }
public final class Installer {
    private let fm: FileManager
    public init(fileManager: FileManager = .default) { fm = fileManager }
    private func exists(_ url: URL) -> Bool { (try? fm.attributesOfItem(atPath:url.path)) != nil }
    /// Read only: whether this package is already in the destination, and which installer owns it.
    /// A kit skips packages the command line installer owns instead of failing on them.
    public func existing(manifest: Manifest, destination: Destination) -> ExistingInstall {
        if exists(destination.state.appendingPathComponent(manifest.slug+".native.json")) { return .native }
        if exists(destination.state.appendingPathComponent(manifest.slug+".receipt")) { return .commandLine }
        let folders = destination.layout == "plugin" ? [manifest.slug] : manifest.skills
        if folders.contains(where: { identifier($0) && exists(destination.skills.appendingPathComponent($0)) }) { return .unmanaged }
        return .none
    }
    private func safeAncestors(_ url: URL) throws {
        guard !url.path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw InstallerError("The destination path contains unsupported control characters.") }
        var cursor = url
        while cursor.path != "/" {
            if let attributes = try? fm.attributesOfItem(atPath:cursor.path) {
                guard attributes[.type] as? FileAttributeType != .typeSymbolicLink else { throw InstallerError("A destination contains a symbolic link: \(cursor.path). Choose a regular folder.") }
            }
            cursor.deleteLastPathComponent()
        }
    }
    private func snapshot(_ url: URL) throws -> [String:String] {
        try safeAncestors(url)
        let attributes = try fm.attributesOfItem(atPath:url.path)
        if attributes[.type] as? FileAttributeType == .typeRegular {
            guard (attributes[.size] as? NSNumber)?.intValue ?? Int.max <= maximumExpandedBytes else { throw InstallerError("An existing file is too large to verify.") }
            return ["":digest(try Data(contentsOf:url))]
        }
        guard attributes[.type] as? FileAttributeType == .typeDirectory else { throw InstallerError("An existing path is not a regular file or folder.") }
        var result: [String:String] = [:]; var total = 0
        func visit(_ folder: URL, _ prefix: String) throws {
            for child in try fm.contentsOfDirectory(at:folder,includingPropertiesForKeys:nil) {
                let path = prefix + child.lastPathComponent
                guard safeRelativePath(path), result.count < 20_000 else { throw InstallerError("An existing folder cannot be verified safely.") }
                let attrs = try fm.attributesOfItem(atPath:child.path)
                switch attrs[.type] as? FileAttributeType {
                case .typeDirectory: result[path + "/"] = "directory"; try visit(child,path+"/")
                case .typeRegular:
                    let size = (attrs[.size] as? NSNumber)?.intValue ?? Int.max
                    guard size <= maximumExpandedBytes-total else { throw InstallerError("Existing files are too large to verify.") }
                    total += size; result[path] = digest(try Data(contentsOf:child))
                default: throw InstallerError("An installed folder contains a link or special file. No files were replaced.")
                }
            }
        }
        try visit(url,""); return result
    }
    private func location(_ key: String, slug: String, destination: Destination) throws -> URL {
        let parts = key.split(separator:"/")
        guard parts.count == 2, safeRelativePath(key) else { throw InstallerError("The installation receipt is unsafe.") }
        let name = String(parts[1])
        if parts[0] == "skills", identifier(name) { return destination.skills.appendingPathComponent(name) }
        if parts[0] == "state", [slug,slug+".receipt",slug+".native.json"].contains(name) { return destination.state.appendingPathComponent(name) }
        throw InstallerError("The installation receipt names an unmanaged path.")
    }
    private func transactionURL(_ m: Manifest, _ d: Destination) -> URL { d.state.appendingPathComponent(".native-transaction-"+m.slug) }
    private func restore(_ transaction: URL, manifest: Manifest, destination: Destination) throws {
        try safeAncestors(transaction)
        let journalURL = transaction.appendingPathComponent("journal.json")
        guard exists(journalURL) else {
            // A crash before the journal was written cannot have changed any live destination.
            try fm.removeItem(at:transaction); return
        }
        let journal = try jsonDecoder().decode(Journal.self,from:Data(contentsOf:journalURL))
        guard journal.slug == manifest.slug, journal.skillsRoot == destination.skills.path, journal.stateRoot == destination.state.path,
              journal.items.count <= 10_004, Set(journal.items.map(\.key)).count == journal.items.count else { throw InstallerError("An interrupted transaction needs manual recovery. Its journal did not match this destination.") }
        for item in journal.items { _ = try location(item.key,slug:manifest.slug,destination:destination) }
        if journal.committed { try fm.removeItem(at:transaction); return }
        for (index,item) in journal.items.enumerated().reversed() {
            let live = try location(item.key,slug:manifest.slug,destination:destination)
            let backup = transaction.appendingPathComponent("backup/\(index)")
            try safeAncestors(live)
            if exists(backup) {
                guard try snapshot(backup) == item.old else { throw InstallerError("Recovery backup changed. No further files were replaced.") }
                if exists(live) {
                    guard try snapshot(live) == item.new else { throw InstallerError("A file changed after interruption. Preserve it before retrying recovery.") }
                    try fm.removeItem(at:live)
                }
                try fm.moveItem(at:backup,to:live)
            } else if item.old == nil, exists(live) {
                guard try snapshot(live) == item.new else { throw InstallerError("An interrupted installation conflicts with a local file.") }
                try fm.removeItem(at:live)
            } else if let old = item.old {
                guard exists(live), try snapshot(live) == old else { throw InstallerError("An interrupted installation is missing its original backup.") }
            }
        }
        try fm.removeItem(at:transaction)
    }
    public func install(manifest: Manifest, files: [String:Data], destination: Destination, confirmed: Bool) throws -> InstallResult {
        guard confirmed else { throw InstallerError("Installation cancelled. No files were changed.") }
        try manifest.validate(targets:NativeTarget.bundled())
        guard Set(files.keys) == Set(manifest.files.map(\.path)), manifest.files.allSatisfy({ files[$0.path]?.count == $0.bytes && files[$0.path].map(digest) == $0.sha256 }) else { throw InstallerError("The verified package files have changed.") }
        try safeAncestors(destination.skills); try safeAncestors(destination.state)
        try fm.createDirectory(at:destination.skills,withIntermediateDirectories:true)
        try fm.createDirectory(at:destination.state,withIntermediateDirectories:true)
        let lockURL = destination.state.appendingPathComponent(".native-install.lock")
        let descriptor = open(lockURL.path,O_CREAT | O_RDWR | O_NOFOLLOW,0o600)
        guard descriptor >= 0 else { throw InstallerError("Could not lock the installation folder.") }
        defer { flock(descriptor,LOCK_UN); close(descriptor) }
        guard flock(descriptor,LOCK_EX | LOCK_NB) == 0 else { throw InstallerError("Another installation is writing to this client. Wait for it to finish.") }
        let transaction = transactionURL(manifest,destination)
        if exists(transaction) { try restore(transaction,manifest:manifest,destination:destination) }
        let native = destination.state.appendingPathComponent(manifest.slug+".native.json")
        let legacy = destination.state.appendingPathComponent(manifest.slug+".receipt")
        try safeAncestors(native); try safeAncestors(legacy)
        var previous: Receipt?
        if exists(native) {
            let bytes = try Data(contentsOf:native)
            guard bytes.count < 8*1024*1024 else { throw InstallerError("The installation receipt is too large.") }
            previous = try jsonDecoder().decode(Receipt.self,from:bytes)
            guard let p = previous, p.slug == manifest.slug, p.target == manifest.target.id, p.scope == manifest.scope,
                  p.skillsRoot == destination.skills.path, p.stateRoot == destination.state.path, UUID(uuidString:p.installId) != nil else { throw InstallerError("The existing receipt belongs to another installation.") }
            for (key,hashes) in p.owned {
                let url = try location(key,slug:manifest.slug,destination:destination)
                guard exists(url), try snapshot(url) == hashes else { throw InstallerError("Installed files have local changes or are missing. Preserve them before reinstalling.") }
            }
        } else if exists(legacy) { throw InstallerError("This package was installed by the command line installer. Remove it with that installer before using the native installer.") }
        var trees: [String:[String:Data]] = [:]
        if destination.layout == "plugin" { trees["skills/"+manifest.slug] = files }
        else {
            for skill in manifest.skills {
                let prefix = "skills/"+skill+"/"
                var content: [String:Data] = [:]
                for (path,data) in files where path.hasPrefix(prefix) { content[String(path.dropFirst(prefix.count))] = data }
                if manifest.target.bundleLicense && content["LICENSE"] == nil {
                    for name in ["LICENSE","LICENSE.md","LICENSE.txt"] { if let license = files[name] { content["LICENSE"] = license; break } }
                }
                trees["skills/"+skill] = content
            }
            trees["state/"+manifest.slug] = files.filter { !$0.key.hasPrefix("skills/") }
        }
        for key in trees.keys {
            let url = try location(key,slug:manifest.slug,destination:destination)
            try safeAncestors(url)
            guard !exists(url) || previous?.owned[key] != nil else { throw InstallerError("A folder already exists and belongs to another installation: \(url.path). No skills were replaced.") }
        }
        let installID = previous?.installId ?? UUID().uuidString.lowercased()
        try fm.createDirectory(at:transaction.appendingPathComponent("stage"),withIntermediateDirectories:true)
        try fm.createDirectory(at:transaction.appendingPathComponent("backup"),withIntermediateDirectories:true)
        var journalWritten = false
        do {
            let treeKeys = Set(trees.keys).union(previous?.owned.keys.map { $0 } ?? []).sorted()
            var items: [Journal.Item] = []; var owned: [String:[String:String]] = [:]
            for key in treeKeys {
                let stage = transaction.appendingPathComponent("stage/\(items.count)")
                if let content = trees[key] {
                    try fm.createDirectory(at:stage,withIntermediateDirectories:true)
                    for (path,data) in content {
                        guard safeRelativePath(path) else { throw InstallerError("Unsafe staged path.") }
                        let url = stage.appendingPathComponent(path)
                        try fm.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true)
                        try data.write(to:url,options:.atomic)
                        try fm.setAttributes([.posixPermissions:0o644],ofItemAtPath:url.path)
                    }
                    owned[key] = try snapshot(stage)
                }
                items.append(Journal.Item(key:key,old:previous?.owned[key],new:owned[key]))
            }
            let receipt = Receipt(slug:manifest.slug,target:manifest.target.id,scope:manifest.scope,installId:installID,skillsRoot:destination.skills.path,stateRoot:destination.state.path,owned:owned)
            let paths = try (owned.keys.sorted() + ["state/"+manifest.slug+".native.json"]).map { "path=" + (try location($0,slug:manifest.slug,destination:destination)).path }.joined(separator:"\n")
            let legacyText = "slug=\(manifest.slug)\nversion=\(manifest.version)\ntarget=\(manifest.target.id)\nscope=\(manifest.scope)\nlayout=\(destination.layout)\ninstall_id=\(installID)\n\(paths)\n"
            for (key,bytes) in [("state/"+manifest.slug+".receipt",Data(legacyText.utf8)),("state/"+manifest.slug+".native.json",try jsonEncoder().encode(receipt))] {
                let live = try location(key,slug:manifest.slug,destination:destination)
                let stage = transaction.appendingPathComponent("stage/\(items.count)"); try bytes.write(to:stage,options:.atomic)
                items.append(Journal.Item(key:key,old:exists(live) ? try snapshot(live) : nil,new:try snapshot(stage)))
            }
            var journal = Journal(slug:manifest.slug,skillsRoot:destination.skills.path,stateRoot:destination.state.path,committed:false,items:items)
            let journalURL = transaction.appendingPathComponent("journal.json")
            try jsonEncoder().encode(journal).write(to:journalURL,options:.atomic); journalWritten = true
            for (index,item) in items.enumerated() {
                let live = try location(item.key,slug:manifest.slug,destination:destination)
                try safeAncestors(live)
                if item.old != nil {
                    guard exists(live), try snapshot(live) == item.old else { throw InstallerError("A destination changed while installing.") }
                    try fm.moveItem(at:live,to:transaction.appendingPathComponent("backup/\(index)"))
                } else if exists(live) { throw InstallerError("Another process created a conflicting folder.") }
                if item.new != nil { try fm.moveItem(at:transaction.appendingPathComponent("stage/\(index)"),to:live) }
            }
            for item in items where item.new != nil {
                guard try snapshot(location(item.key,slug:manifest.slug,destination:destination)) == item.new else { throw InstallerError("Installed files could not be verified.") }
            }
            journal.committed = true
            try jsonEncoder().encode(journal).write(to:journalURL,options:.atomic)
            // Cleanup after the commit point is optional and retried on the next install.
            try? fm.removeItem(at:transaction)
            return InstallResult(installID:installID,receipt:native,destination:destination.skills)
        } catch {
            if journalWritten {
                do { try restore(transaction,manifest:manifest,destination:destination) }
                catch { throw InstallerError("Installation was interrupted. Your recovery backup remains at \(transaction.path). Retry the same package to recover. \(error.localizedDescription)") }
            } else { try? fm.removeItem(at:transaction) }
            throw error
        }
    }
}
