import SwiftUI
import AppKit
import InstallerCore

@MainActor final class InstallerDelegate: NSObject, NSApplicationDelegate {
    weak var model: InstallModel?
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if model?.isWriting == true { NSSound.beep(); return .terminateCancel }
        return .terminateNow
    }
}
@main struct CheatcodeInstallerApp: App {
    @NSApplicationDelegateAdaptor(InstallerDelegate.self) var delegate
    @StateObject private var model = InstallModel()
    var body: some Scene {
        WindowGroup("Cheatcode Installer") {
            InstallerView(model:model)
                .handlesExternalEvents(preferring:["*"], allowing:["*"])
                .onAppear { delegate.model = model; model.refreshAdded(); NSApplication.shared.activate(ignoringOtherApps:true) }
                .onOpenURL { model.activate($0); NSApplication.shared.activate(ignoringOtherApps:true) }
        }
        .handlesExternalEvents(matching:["*"])
        .windowResizability(.contentSize)
        .commands { CommandGroup(replacing:.newItem) {} }
    }
}
struct InstallerView: View {
    @ObservedObject var model: InstallModel
    var body: some View {
        VStack(alignment:.leading,spacing:18) {
            HStack {
                Text("cheatcode_").font(.system(.title2,design:.monospaced)).bold()
                Spacer()
                #if DEBUG
                Text("Development build").font(.caption).foregroundColor(.secondary)
                #endif
            }
            Divider()
            ScrollView {
                VStack(alignment:.leading,spacing:18) {
            Text(model.title).font(.title2).bold().accessibilityAddTraits(.isHeader)
            Text(model.message).fixedSize(horizontal:false,vertical:true).textSelection(.enabled)
            if model.busy { HStack(spacing:8) { ProgressView().controlSize(.small); if !model.progress.isEmpty { Text(model.progress).font(.callout).foregroundColor(.secondary) } } }
            if let m = model.mcp {
                McpReview(model:model, m:m)
            } else if model.phase == .welcome || (model.phase == .complete && model.mcp == nil && model.manifest == nil) {
                AddedServers(model:model)
            }
            if let manifest = model.manifest {
                if model.isKit {
                    // A role kit: one review for every package, all going to the same client and scope.
                    Grid(alignment:.leading,horizontalSpacing:18,verticalSpacing:8) {
                        row("Packages","\(model.manifests.count), \(model.manifests.reduce(0) { $0 + $1.skills.count }) skills")
                        row("Client",manifest.target.label)
                        row("Scope",manifest.scope == "project" ? "This project" : "This macOS account")
                    }
                    .font(.callout)
                    VStack(alignment:.leading,spacing:6) {
                        ForEach(Array(model.manifests.enumerated()),id:\.offset) { i, m in
                            VStack(alignment:.leading,spacing:1) {
                                HStack(spacing:6) {
                                    Text(m.name).font(.callout).bold()
                                    if model.existing.indices.contains(i) {
                                        if model.existing[i] == .commandLine { Text("installed with the terminal installer, skipped").font(.caption).foregroundColor(.secondary) }
                                        else if model.existing[i] == .unmanaged { Text("a folder with this name is already there, skipped").font(.caption).foregroundColor(.secondary) }
                                        else if model.existing[i] == .native { Text("already installed, will update").font(.caption).foregroundColor(.secondary) }
                                    }
                                }
                                Text("\(m.publisher) · v\(m.version) · \(m.license) · \(m.skills.count == 1 ? "1 skill" : "\(m.skills.count) skills")").font(.caption).foregroundColor(.secondary)
                            }
                        }
                    }
                    .textSelection(.enabled)
                } else {
                    Grid(alignment:.leading,horizontalSpacing:18,verticalSpacing:8) {
                        row("Package",manifest.name)
                        row("Publisher",manifest.publisher)
                        row("Version",manifest.version)
                        row("License",manifest.license)
                        row("Client",manifest.target.label)
                        row("Scope",manifest.scope == "project" ? "This project" : "This macOS account")
                        row("Skills",manifest.skills.joined(separator:", "))
                    }
                    .font(.callout)
                }
                if manifest.scope == "project" && model.phase == .review {
                    Button(model.project == nil ? "Choose project folder…" : "Change project folder…") { model.selectProject() }
                }
                if let destination = model.destination {
                    Text("Destination").font(.caption).foregroundColor(.secondary)
                    Text(destination.skills.path).font(.system(.caption,design:.monospaced)).textSelection(.enabled).fixedSize(horizontal:false,vertical:true)
                    if model.phase == .review && !FileManager.default.fileExists(atPath:destination.skills.deletingLastPathComponent().path) {
                        Text("The client folder was not found. Installing files does not install the client. To choose another client, cancel and change the target on Cheatcode.").font(.callout)
                    }
                }
            }
            if !model.notice.isEmpty { Text(model.notice).font(.callout).foregroundColor(.orange) }
            if !model.telemetryNotice.isEmpty { Text(model.telemetryNotice).font(.callout) }
                }.frame(maxWidth:.infinity,alignment:.leading)
            }
            Divider()
            HStack {
                if model.canCancel { Button("Cancel") { model.cancel() }.keyboardShortcut(.cancelAction) }
                Spacer()
                if model.canRetry { Button("Retry") { model.retry() } }
                if model.phase == .review && model.mcp != nil { Button("Add to \(model.mcp!.client.label)") { model.install() }.buttonStyle(.borderedProminent).disabled(!model.canInstall) }
                if model.phase == .review && model.mcp == nil { Button(!model.isKit ? "Install" : model.installable == model.manifests.count ? "Install all \(model.manifests.count)" : "Install \(model.installable), skip \(model.manifests.count - model.installable)") { model.install() }.buttonStyle(.borderedProminent).disabled(!model.canInstall) }
                if [.complete,.cancelled,.welcome].contains(model.phase) { Button("Close") { NSApplication.shared.keyWindow?.close() } }
            }
        }
        .padding(28).frame(width:600,height:620)
    }
    private func row(_ label: String, _ value: String) -> some View {
        GridRow { Text(label).foregroundColor(.secondary); Text(value).textSelection(.enabled) }
    }
}

/// What will run and where it goes, in plain words, plus a field for each key the server needs.
struct McpReview: View {
    @ObservedObject var model: InstallModel
    let m: McpManifest
    var body: some View {
        VStack(alignment:.leading,spacing:14) {
            Grid(alignment:.leading,horizontalSpacing:18,verticalSpacing:8) {
                row("Server",m.name)
                row("Publisher",m.repo.isEmpty ? m.publisher : "\(m.publisher) (github.com/\(m.repo))")
                if !m.license.isEmpty { row("License",m.license) }
                row("Runs",m.isRemote ? "On the publisher's server: \(m.url ?? "")" : "On this Mac: \(m.package ?? "") with \(m.runtime == "uv" ? "uv" : "Node.js")")
                row("Checked","Started and listed \(m.tools) tools on \(String(m.verifiedAt.prefix(10)))" + (m.status == "sign_in" ? ", asks you to sign in" : ""))
                row("AI app",m.client.label)
                row("Writes","~/\(m.client.path), one entry named \(m.serverId)")
            }
            .font(.callout).textSelection(.enabled)
            if !m.inputs.isEmpty && model.phase == .review {
                Text("This server needs your own details. They are written only into \(m.client.label)'s settings on this Mac, never sent to Cheatcode.").font(.callout)
                ForEach(m.inputs, id:\.name) { input in
                    VStack(alignment:.leading,spacing:4) {
                        Text(input.label.isEmpty ? input.name : input.label).font(.caption).foregroundColor(.secondary).fixedSize(horizontal:false,vertical:true)
                        if input.secret {
                            SecureField(input.name, text:binding(input.name)).textFieldStyle(.roundedBorder)
                        } else {
                            TextField(input.name, text:binding(input.name)).textFieldStyle(.roundedBorder)
                        }
                    }
                }
            }
            if let runtime = m.neededRuntime, let pin = RuntimePin.pin(runtime), !pin.isInstalled(home:FileManager.default.homeDirectoryForCurrentUser), model.phase == .review {
                Text("The first server of this kind also downloads \(runtime == "uv" ? "uv" : "Node.js") \(pin.version) from its official site into ~/.cheatcode/runtime, checked against its published checksum.").font(.callout).foregroundColor(.secondary)
            }
        }
    }
    private func binding(_ name: String) -> Binding<String> {
        Binding(get: { model.answers[name] ?? "" }, set: { model.answers[name] = $0 })
    }
    private func row(_ label: String, _ value: String) -> some View {
        GridRow { Text(label).foregroundColor(.secondary); Text(value).fixedSize(horizontal:false,vertical:true) }
    }
}

/// The MCP servers this app added, so taking one out is a button, not a config file.
struct AddedServers: View {
    @ObservedObject var model: InstallModel
    var body: some View {
        if !model.added.isEmpty {
            VStack(alignment:.leading,spacing:8) {
                Text("MCP servers added with Cheatcode").font(.headline)
                ForEach(model.added, id:\.installId) { r in
                    HStack {
                        VStack(alignment:.leading,spacing:1) {
                            Text(r.name).font(.callout).bold()
                            Text("in \(r.clientLabel)").font(.caption).foregroundColor(.secondary)
                        }
                        Spacer()
                        Button("Remove") { model.remove(r) }.disabled(model.busy)
                    }
                }
            }
        }
    }
}
