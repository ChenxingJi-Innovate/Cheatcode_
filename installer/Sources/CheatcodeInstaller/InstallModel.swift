import SwiftUI
import AppKit
import InstallerCore

@MainActor final class InstallModel: ObservableObject {
    enum Phase { case welcome, loading, review, downloading, verifying, writing, complete, cancelled, failed }
    @Published var phase: Phase = .welcome
    /// One manifest per package: a single listing, or every package of a role kit in install order.
    @Published var manifests: [Manifest] = []
    @Published var destinations: [Destination] = []
    @Published var project: URL?
    @Published var message = "Choose Add on a Cheatcode listing to begin."
    @Published var notice = ""
    @Published var telemetryNotice = ""
    @Published var progress = ""
    /// Per package, what is already in the destination (index-aligned with manifests).
    @Published var existing: [ExistingInstall] = []
    /// An MCP server request (cheatcode://mcp): one server into one AI app.
    @Published var mcp: McpManifest?
    @Published var mcpExisting: McpExisting = .none
    @Published var answers: [String: String] = [:]
    /// MCP servers this app added on this Mac, from its receipts, with a Remove button each.
    @Published var added: [McpReceipt] = []
    private let home = FileManager.default.homeDirectoryForCurrentUser
    private var task: Task<Void,Never>?
    private var activation: Activation?
    private var network: InstallerNetwork?
    var manifest: Manifest? { manifests.first }
    var destination: Destination? { destinations.first }
    var isKit: Bool { manifests.count > 1 }
    /// Packages a kit will actually write: the command line installer's own are left alone.
    var installable: Int { isKit ? manifests.count - existing.filter(InstallModel.leftAlone).count : manifests.count }
    /// In a kit, packages already put here by something else are left exactly as they are.
    nonisolated static func leftAlone(_ e: ExistingInstall) -> Bool { e == .commandLine || e == .unmanaged }
    var isWriting: Bool { phase == .writing }
    var busy: Bool { [.loading,.downloading,.verifying,.writing].contains(phase) }
    var canCancel: Bool { [.loading,.review,.downloading,.verifying].contains(phase) }
    var canRetry: Bool { phase == .failed && network != nil }
    var canInstall: Bool {
        if let mcp { return phase == .review && mcpExisting != .other && mcp.inputs.allSatisfy { !(answers[$0.name] ?? "").trimmingCharacters(in: .whitespaces).isEmpty } }
        return phase == .review && !manifests.isEmpty && destinations.count == manifests.count
    }
    var title: String {
        switch phase {
        case .welcome: return "Cheatcode Installer"
        case .loading: return "Checking installation details"
        case .review: return mcp != nil ? "Review MCP server" : isKit ? "Review \(manifests.count) packages" : "Review installation"
        case .downloading where mcp != nil: return "Getting the runtime ready"
        case .downloading: return isKit ? "Downloading packages" : "Downloading package"
        case .verifying: return "Verifying package files"
        case .writing: return "Installing files"
        case .complete where mcp != nil: return "Added to \(mcp!.client.label)"
        case .complete: return manifest?.target.accountSync == true ? "Files installed. Waiting for client sync." : "Files installed. Ready for a new session."
        case .cancelled: return "Installation cancelled"
        case .failed: return "Installation could not finish"
        }
    }
    func activate(_ url: URL) {
        if busy || phase == .review { notice = "An installation is already open. Finish or cancel it, then open your other link again."; return }
        task?.cancel(); activation = nil; network = nil; project = nil; destinations = []; manifests = []; existing = []; notice = ""; telemetryNotice = ""; progress = ""
        mcp = nil; mcpExisting = .none; answers = [:]
        do {
            #if DEBUG
            let allowLocal = ProcessInfo.processInfo.environment["CHEATCODE_ALLOW_LOCAL_API"] == "1"
            #else
            let allowLocal = false
            #endif
            activation = try Activation(url,allowLocal:allowLocal)
            network = InstallerNetwork(activation:activation!)
            if activation!.kind == .mcp { loadMcp() } else { load() }
        } catch { phase = .failed; message = error.localizedDescription }
    }
    func load() {
        guard let network, let activation else { return }
        phase = .loading; manifests = []; destinations = []; existing = []; progress = ""
        message = "Checking the \(activation.isKit ? "packages" : "package") and the destination. No client files have been changed."
        task = Task {
            do {
                var loaded: [Manifest] = []
                for (i,token) in activation.tokens.enumerated() {
                    if activation.isKit { progress = "Checking \(i+1) of \(activation.tokens.count)" }
                    let m = try await network.manifest(token:token); try Task.checkCancellation()
                    // A kit is one review for one client: every package must go to the same place.
                    if let first = loaded.first, first.target.id != m.target.id || first.scope != m.scope {
                        throw InstallerError("This kit link mixes destinations. Return to Cheatcode and create a new link.")
                    }
                    loaded.append(m)
                }
                manifests = loaded; progress = ""; phase = .review
                message = activation.isKit
                    ? "Review the packages and destination, then choose Install. Each package is checked against its pinned source before anything is written. Package content can contain instructions for your AI client."
                    : "Review the publisher and destination, then choose Install. Package content can contain instructions for your AI client."
                try updateDestination()
            } catch is CancellationError {} catch {
                if !Task.isCancelled { phase = .failed; progress = ""; message = error.localizedDescription }
            }
        }
    }
    func loadMcp() {
        guard let network else { return }
        phase = .loading; mcp = nil; progress = ""
        message = "Checking the server and your AI app. Nothing has been changed."
        task = Task {
            do {
                let m = try await network.mcpManifest(); try Task.checkCancellation()
                mcpExisting = try McpWriter(home:home).existing(m)
                answers = Dictionary(uniqueKeysWithValues: m.inputs.map { ($0.name, answers[$0.name] ?? "") })
                mcp = m; phase = .review
                if mcpExisting == .other {
                    message = "\(m.client.label) already has a server named \(m.serverId) that Cheatcode did not add. It is left exactly as it is, so there is nothing to add here."
                } else {
                    message = (mcpExisting == .ours ? "Cheatcode added this server before. Adding it again updates the entry. " : "")
                        + "\(m.client.label) will start this server itself whenever you use it. It can do whatever the server's own code does, so add only servers you want to use."
                }
            } catch is CancellationError {} catch {
                if !Task.isCancelled { phase = .failed; message = error.localizedDescription }
            }
        }
    }
    func installMcp(_ m: McpManifest) {
        guard let network, let activation else { return }
        let given = answers.mapValues { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        task = Task {
            do {
                var bin: URL? = nil
                if let name = m.neededRuntime, let pin = RuntimePin.pin(name) {
                    if !pin.isInstalled(home:home) { phase = .downloading }
                    bin = try await Runtimes.ensure(pin, home:home) { text in Task { @MainActor in self.message = text } }
                }
                try Task.checkCancellation()
                phase = .writing; message = "Adding the server to \(m.client.label)'s settings and keeping a copy of the previous file."
                let home = self.home, runtimeBin = bin, api = activation.origin.absoluteString
                let receipt = try await Task.detached(priority:.userInitiated) {
                    try McpWriter(home:home).install(m, answers:given, bin:runtimeBin, api:api)
                }.value
                refreshAdded()
                phase = .complete
                var next = m.client.restart
                if m.status == "sign_in" { next += " The first time you use it, \(m.client.label) opens the provider's page so you can sign in." }
                if !m.isRemote { next += " The first start can take a minute while the server downloads." }
                message = next + " To take it out again, open this app and choose Remove."
                do { try await network.record(mcp:m, receipt:receipt) }
                catch { if self.network === network { telemetryNotice = "The server is added. The install could not be counted on Cheatcode." } }
            } catch is CancellationError {
                phase = .cancelled; message = "Nothing was added."
            } catch {
                if !Task.isCancelled { phase = .failed; message = error.localizedDescription }
            }
        }
    }
    func refreshAdded() { added = McpWriter(home:home).receipts() }
    func remove(_ r: McpReceipt) {
        do {
            try McpWriter(home:home).remove(r, clients:McpClient.bundled())
            notice = "\(r.name) was taken out of \(r.clientLabel). Restart \(r.clientLabel) to finish."
            Task.detached { await recordUninstall(api:r.api, installId:r.installId) }
        } catch { notice = error.localizedDescription }
        refreshAdded()
    }
    func updateDestination() throws {
        guard let first = manifests.first else { return }
        if first.scope == "project" && project == nil { destinations = []; return }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let environment = ProcessInfo.processInfo.environment
        destinations = try manifests.map { try Destination(manifest:$0,home:home,project:project,environment:environment) }
        existing = zip(manifests,destinations).map { Installer().existing(manifest:$0.0,destination:$0.1) }
    }
    func selectProject() {
        guard phase == .review else { return }
        let picker = NSOpenPanel(); picker.title = "Choose the project to install into"; picker.canChooseDirectories = true; picker.canChooseFiles = false; picker.allowsMultipleSelection = false; picker.canCreateDirectories = false
        if picker.runModal() == .OK {
            project = picker.url
            do { try updateDestination() } catch { message = error.localizedDescription; destinations = [] }
        }
    }
    func cancel() {
        guard canCancel else { return }
        task?.cancel(); phase = .cancelled; progress = ""; message = "No installation was recorded and no client files were changed."; manifests = []; destinations = []; network = nil; activation = nil; mcp = nil
    }
    func install() {
        if let mcp { if canInstall { installMcp(mcp) }; return }
        guard canInstall, let network, let activation, activation.tokens.count == manifests.count else { return }
        let all = Array(zip(zip(activation.tokens,manifests),destinations)).map { ($0.0.0,$0.0.1,$0.1) }
        let kit = all.count > 1
        // In a kit, a package the command line installer already put here is left as it is, never a failure.
        let skip = { (i: Int) in kit && self.existing.indices.contains(i) && InstallModel.leftAlone(self.existing[i]) }
        let terminalOwned = all.indices.filter(skip).map { all[$0].1.name }
        let jobs = all.enumerated().filter { !skip($0.offset) }.map(\.element)
        task = Task {
            var installed: [String] = []
            var failed: [(String,String)] = []
            for (i,(token,manifest,destination)) in jobs.enumerated() {
                let step = jobs.count > 1 ? "\(i+1) of \(jobs.count): \(manifest.name). " : ""
                progress = jobs.count > 1 ? "Package \(i+1) of \(jobs.count)" : ""
                do {
                    phase = .downloading; message = step + "Downloading the exact package you reviewed."
                    let archive = try await network.archive(manifest:manifest,token:token); try Task.checkCancellation()
                    phase = .verifying; message = step + "Checking archive paths, file sizes and integrity."
                    let files = try await Task.detached(priority:.userInitiated) { try Archive.extract(archive,manifest:manifest) }.value
                    try Task.checkCancellation()
                    // This phase begins only from the explicit native Install button.
                    phase = .writing; message = step + "Writing verified files and a recovery receipt. Please keep the installer open until this finishes. Cancellation is unavailable during this step."
                    let result = try await Task.detached(priority:.userInitiated) { try Installer().install(manifest:manifest,files:files,destination:destination,confirmed:true) }.value
                    installed.append(manifest.name)
                    do { try await network.record(manifest:manifest,result:result) }
                    catch { if self.network === network { telemetryNotice = "Files and receipts are in place. An installation event could not be recorded. Reinstalling will reuse the same identity." } }
                } catch is CancellationError {
                    if installed.isEmpty { return }
                    phase = .cancelled; progress = ""
                    message = "Stopped after \(installed.count) of \(jobs.count) packages. The installed ones stay in place; open the link again from Cheatcode to add the rest."
                    return
                } catch {
                    if Task.isCancelled { return }
                    if !kit { phase = .failed; progress = ""; message = error.localizedDescription; return }
                    failed.append((manifest.name,error.localizedDescription))  // a kit carries on with the rest
                }
            }
            progress = ""
            let first = all[0].1
            let kept = terminalOwned.isEmpty ? "" : " Already in place from another install, left exactly as it is: \(terminalOwned.joined(separator:", "))."
            if !failed.isEmpty {
                phase = .failed
                message = "\(installed.count) of \(jobs.count) packages installed.\(kept) Not installed: " + failed.map { "\($0.0) (\($0.1))" }.joined(separator:"; ") + ". The installed ones stay in place. Retry checks everything again, then installs what is missing and updates the rest."
                return
            }
            phase = .complete
            let restart = first.target.accountSync ? "Doubao must be running and signed in to sync these files. This installer cannot verify account sync. Remove account skills inside Doubao." : first.target.restart + " The installer has verified the files, but cannot confirm the client has loaded them."
            message = (kit ? "\(installed.count) \(installed.count == 1 ? "package is" : "packages are") in \(first.target.label).\(kept) " : "") + restart
        }
    }
    func retry() { guard !busy else { return }; if activation?.kind == .mcp { loadMcp() } else { load() } }
}
