import SwiftUI
import AppKit
import Foundation

enum Renderer: String, CaseIterable, Codable, Identifiable {
    case dxmt = "DXMT"
    case wineD3D = "WineD3D"

    var id: String { rawValue }
    var detail: String {
        switch self {
        case .dxmt: return "Direct3D 10/11 → Metal"
        case .wineD3D: return "Compatibilidade padrão do Wine"
        }
    }
}

struct Bottle: Codable, Identifiable, Hashable {
    var id: UUID
    var name: String
    var renderer: Renderer
    var msync: Bool
    var createdAt: Date
}

struct InstalledApp: Identifiable, Hashable {
    var id: String
    var name: String
    var detail: String
    var icon: String
    var executable: URL
    var arguments: [String]
}

private enum InstalledAppScanner {
    static func scan(prefix: URL) -> [InstalledApp] {
        let fm = FileManager.default
        let driveC = prefix.appendingPathComponent("drive_c")
        guard fm.fileExists(atPath: driveC.path) else { return [] }

        var apps: [InstalledApp] = []
        var seen = Set<String>()

        func add(_ app: InstalledApp) {
            let key = app.id.lowercased()
            guard seen.insert(key).inserted else { return }
            apps.append(app)
        }

        let steamCandidates = [
            driveC.appendingPathComponent("Program Files (x86)/Steam/Steam.exe"),
            driveC.appendingPathComponent("Program Files/Steam/Steam.exe")
        ]

        if let steam = steamCandidates.first(where: { fm.fileExists(atPath: $0.path) }) {
            add(InstalledApp(
                id: "steam",
                name: "Steam",
                detail: "Launcher",
                icon: "gamecontroller.fill",
                executable: steam,
                arguments: []
            ))
            scanSteamGames(steam: steam, add: add)
        }

        scanProgramFiles(driveC: driveC, excludingSteam: seen.contains("steam"), add: add)

        return apps.sorted {
            if $0.detail == $1.detail { return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            if $0.detail == "Launcher" { return true }
            if $1.detail == "Launcher" { return false }
            if $0.detail.hasPrefix("Steam") != $1.detail.hasPrefix("Steam") { return $0.detail.hasPrefix("Steam") }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    private static func scanSteamGames(steam: URL, add: (InstalledApp) -> Void) {
        let fm = FileManager.default
        let steamRoot = steam.deletingLastPathComponent()
        let steamApps = steamRoot.appendingPathComponent("steamapps")
        guard let manifests = try? fm.contentsOfDirectory(
            at: steamApps,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return }

        for manifest in manifests where manifest.lastPathComponent.hasPrefix("appmanifest_") && manifest.pathExtension == "acf" {
            guard
                let text = try? String(contentsOf: manifest, encoding: .utf8),
                let appID = acfValue("appid", in: text),
                let name = acfValue("name", in: text),
                let installDir = acfValue("installdir", in: text)
            else { continue }

            let gameDir = steamApps.appendingPathComponent("common").appendingPathComponent(installDir)
            guard fm.fileExists(atPath: gameDir.path) else { continue }

            add(InstalledApp(
                id: "steam:\(appID)",
                name: name,
                detail: "Steam · Jogo",
                icon: "play.rectangle.fill",
                executable: steam,
                arguments: ["-applaunch", appID]
            ))
        }
    }

    private static func acfValue(_ key: String, in text: String) -> String? {
        let escaped = NSRegularExpression.escapedPattern(for: key)
        let pattern = #""\#(escaped)"\s+"([^"]*)""#
        guard
            let regex = try? NSRegularExpression(pattern: pattern),
            let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
            match.numberOfRanges > 1,
            let range = Range(match.range(at: 1), in: text)
        else { return nil }
        return String(text[range])
    }

    private static func scanProgramFiles(
        driveC: URL,
        excludingSteam: Bool,
        add: (InstalledApp) -> Void
    ) {
        let fm = FileManager.default
        let roots = [
            driveC.appendingPathComponent("Program Files"),
            driveC.appendingPathComponent("Program Files (x86)")
        ]
        let ignoredFolders = Set([
            "common files", "internet explorer", "windows media player", "windows nt",
            "microsoft", "microsoft update health tools", "reference assemblies", "modifiablewindowsapps"
        ])

        for root in roots {
            guard let folders = try? fm.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            for folder in folders {
                let folderName = folder.lastPathComponent
                let lowerFolder = folderName.lowercased()
                guard !ignoredFolders.contains(lowerFolder) else { continue }
                if excludingSteam && lowerFolder == "steam" { continue }
                guard let executable = bestExecutable(in: folder, appName: folderName) else { continue }

                add(InstalledApp(
                    id: "exe:\(executable.path)",
                    name: folderName,
                    detail: "Aplicativo Windows",
                    icon: "app.fill",
                    executable: executable,
                    arguments: []
                ))
            }
        }
    }

    private static func bestExecutable(in folder: URL, appName: String) -> URL? {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return nil }

        let ignoredNames = [
            "unins", "uninstall", "setup", "installer", "update", "updater",
            "crash", "report", "helper", "service", "redist", "dxsetup",
            "unitycrashhandler", "elevate", "bootstrap", "steamservice"
        ]
        let normalizedApp = normalized(appName)
        var best: (url: URL, score: Int)?

        for case let url as URL in enumerator {
            if enumerator.level > 4 {
                enumerator.skipDescendants()
                continue
            }
            guard url.pathExtension.lowercased() == "exe" else { continue }

            let base = url.deletingPathExtension().lastPathComponent.lowercased()
            guard !ignoredNames.contains(where: { base.contains($0) }) else { continue }

            let normalizedExe = normalized(base)
            var score = max(0, 20 - enumerator.level * 3)
            if normalizedExe == normalizedApp { score += 80 }
            else if normalizedExe.contains(normalizedApp) || normalizedApp.contains(normalizedExe) { score += 35 }

            if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                score += min(20, size / 5_000_000)
            }

            if best == nil || score > best!.score {
                best = (url, score)
            }
        }
        return best?.url
    }

    private static func normalized(_ text: String) -> String {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .joined()
    }
}

@MainActor
final class BottleStore: ObservableObject {
    @Published var bottles: [Bottle] = []
    @Published var status = "Pronto"
    @Published var busy = false
    private let fm = FileManager.default
    private var supportRoot: URL {
        fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/BottleForge")
    }
    private var bottlesRoot: URL { supportRoot.appendingPathComponent("Bottles") }
    private var projectRoot: URL {
        fm.homeDirectoryForCurrentUser.appendingPathComponent("Developer/BottleForge")
    }
    private var engineBaseRoot: URL {
        if let resources = Bundle.main.resourceURL {
            let bundled = resources.appendingPathComponent("Engines")
            if fm.fileExists(atPath: bundled.path) { return bundled }
        }
        return projectRoot.appendingPathComponent("Engine")
    }
    private var dxmtEngineRoot: URL { engineBaseRoot.appendingPathComponent("wine-11.17") }
    private var wineD3DEngineRoot: URL { engineBaseRoot.appendingPathComponent("wine-11.17-wined3d") }
    private var dxmtRoot: URL { engineBaseRoot.appendingPathComponent("dxmt-0.80") }

    private func engineRoot(for renderer: Renderer) -> URL {
        renderer == .dxmt ? dxmtEngineRoot : wineD3DEngineRoot
    }

    init() {
        try? fm.createDirectory(at: bottlesRoot, withIntermediateDirectories: true)
        load()
    }

    func load() {
        let dirs = (try? fm.contentsOfDirectory(
            at: bottlesRoot,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        bottles = dirs.compactMap { dir in
            let meta = dir.appendingPathComponent("bottle.json")
            guard let data = try? Data(contentsOf: meta) else { return nil }
            return try? JSONDecoder().decode(Bottle.self, from: data)
        }.sorted { $0.createdAt < $1.createdAt }
    }

    func create(name: String, renderer: Renderer, msync: Bool) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let wineboot = winebootURL(for: renderer) else {
            status = "wineboot não encontrado"
            return
        }

        let bottle = Bottle(
            id: UUID(),
            name: trimmed,
            renderer: renderer,
            msync: msync,
            createdAt: Date()
        )
        let dir = bottleDirectory(bottle)
        let prefix = prefixURL(bottle)
        try? fm.createDirectory(at: prefix, withIntermediateDirectories: true)
        save(bottle, at: dir)
        bottles.append(bottle)
        status = "Criando \(trimmed)…"
        busy = true

        runProcess(wineboot, args: ["--init"], bottle: bottle) { code in
            self.busy = false
            self.status = code == 0 ? "\(trimmed) criado" : "Wineboot falhou (\(code))"
            if code == 0 { self.installDXMTIntoPrefixIfNeeded(bottle) }
        }
    }
    func runExecutable(_ url: URL, in bottle: Bottle) {
        launch(url, arguments: [], displayName: url.lastPathComponent, in: bottle)
    }

    func installedApps(in bottle: Bottle) -> [InstalledApp] {
        InstalledAppScanner.scan(prefix: prefixURL(bottle))
    }

    func runInstalledApp(_ app: InstalledApp, in bottle: Bottle) {
        launch(app.executable, arguments: app.arguments, displayName: app.name, in: bottle)
    }

    private func launch(_ executable: URL, arguments: [String], displayName: String, in bottle: Bottle) {
        guard let wine = wineURL(for: bottle.renderer) else {
            status = "Engine Wine não encontrada"
            return
        }
        installDXMTIntoPrefixIfNeeded(bottle)
        status = "Abrindo \(displayName)…"
        runProcess(wine, args: [executable.path] + arguments, bottle: bottle) { code in
            self.status = code == 0 ? "\(displayName) finalizado" : "\(displayName) saiu com código \(code)"
        }
    }

    func wineConfig(_ bottle: Bottle) {
        guard let winecfg = winecfgURL(for: bottle.renderer) else { status = "winecfg não encontrado"; return }
        runProcess(winecfg, args: [], bottle: bottle) { _ in }
    }

    func kill(_ bottle: Bottle) {
        guard let server = wineserverURL(for: bottle.renderer) else { status = "wineserver não encontrado"; return }
        runProcess(server, args: ["-k"], bottle: bottle) { _ in
            self.status = "Processos encerrados"
        }
    }

    func revealDriveC(_ bottle: Bottle) {
        let drive = prefixURL(bottle).appendingPathComponent("drive_c")
        NSWorkspace.shared.activateFileViewerSelecting([drive])
    }

    func delete(_ bottle: Bottle) {
        try? fm.removeItem(at: bottleDirectory(bottle))
        bottles.removeAll { $0.id == bottle.id }
        status = "\(bottle.name) removido"
    }
    var engineDescription: String {
        "Wine 11.17 · DXMT 0.80 / WineD3D"
    }

    private func wineURL(for renderer: Renderer) -> URL? {
        let root = engineRoot(for: renderer)
        return firstExisting([
            root.appendingPathComponent("Contents/Resources/wine/bin/wine"),
            root.appendingPathComponent("Contents/MacOS/wine"),
            root.appendingPathComponent("bin/wine"),
            root.appendingPathComponent("bin/wine64")
        ])
    }

    private func winebootURL(for renderer: Renderer) -> URL? {
        let root = engineRoot(for: renderer)
        return firstExisting([
            root.appendingPathComponent("Contents/Resources/wine/bin/wineboot"),
            root.appendingPathComponent("bin/wineboot")
        ])
    }

    private func winecfgURL(for renderer: Renderer) -> URL? {
        let root = engineRoot(for: renderer)
        return firstExisting([
            root.appendingPathComponent("Contents/Resources/wine/bin/winecfg"),
            root.appendingPathComponent("bin/winecfg")
        ])
    }

    private func wineserverURL(for renderer: Renderer) -> URL? {
        let root = engineRoot(for: renderer)
        return firstExisting([
            root.appendingPathComponent("Contents/Resources/wine/bin/wineserver"),
            root.appendingPathComponent("bin/wineserver")
        ])
    }

    private func firstExisting(_ urls: [URL]) -> URL? {
        urls.first { fm.isExecutableFile(atPath: $0.path) }
    }

    private func bottleDirectory(_ bottle: Bottle) -> URL {
        bottlesRoot.appendingPathComponent(bottle.id.uuidString)
    }

    private func prefixURL(_ bottle: Bottle) -> URL {
        bottleDirectory(bottle).appendingPathComponent("prefix")
    }

    private func save(_ bottle: Bottle, at dir: URL) {
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(bottle) else { return }
        try? data.write(to: dir.appendingPathComponent("bottle.json"), options: .atomic)
    }

    private func environment(for bottle: Bottle) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["WINEPREFIX"] = prefixURL(bottle).path
        env["WINEDEBUG"] = "-all"
        env["WINEESYNC"] = "0"
        env["WINEMSYNC"] = bottle.msync ? "1" : "0"
        env["MVK_CONFIG_RESUME_LOST_DEVICE"] = "1"
        let engineBin = engineRoot(for: bottle.renderer)
            .appendingPathComponent("Contents/Resources/wine/bin").path
        env["PATH"] = engineBin + ":" + (env["PATH"] ?? "")

        if bottle.renderer == .dxmt {
            env["WINEDLLOVERRIDES"] = "dxgi,d3d11,d3d10core,winemetal=builtin"
        } else {
            env["WINEDLLOVERRIDES"] = ""
        }

        let bundledFrameworks = Bundle.main.resourceURL?.appendingPathComponent("Frameworks")
        let fallbackFrameworks = projectRoot.appendingPathComponent("Frameworks")
        if let bundledFrameworks, fm.fileExists(atPath: bundledFrameworks.path) {
            env["DYLD_FRAMEWORK_PATH"] = bundledFrameworks.path
        } else if fm.fileExists(atPath: fallbackFrameworks.path) {
            env["DYLD_FRAMEWORK_PATH"] = fallbackFrameworks.path
        }
        return env
    }

    private func runProcess(
        _ executable: URL,
        args: [String],
        bottle: Bottle,
        completion: @escaping (Int32) -> Void
    ) {
        let env = environment(for: bottle)
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = executable
            process.arguments = args
            process.environment = env
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
                process.waitUntilExit()
                let code = process.terminationStatus
                DispatchQueue.main.async { completion(code) }
            } catch {
                DispatchQueue.main.async {
                    self.status = "Erro: \(error.localizedDescription)"
                    self.busy = false
                }
            }
        }
    }

    private func installDXMTIntoPrefixIfNeeded(_ bottle: Bottle) {
        guard bottle.renderer == .dxmt else { return }
        let src = dxmtRoot.appendingPathComponent("x86_64-windows/winemetal.dll")
        let system32 = prefixURL(bottle).appendingPathComponent("drive_c/windows/system32")
        let dst = system32.appendingPathComponent("winemetal.dll")
        guard fm.fileExists(atPath: src.path), !fm.fileExists(atPath: dst.path) else { return }
        try? fm.createDirectory(at: system32, withIntermediateDirectories: true)
        try? fm.copyItem(at: src, to: dst)
    }
}

struct ContentView: View {
    @EnvironmentObject private var store: BottleStore
    @State private var showingCreate = false
    @State private var selectedBottle: Bottle?

    var body: some View {
        NavigationSplitView {
            List(store.bottles, selection: $selectedBottle) { bottle in
                VStack(alignment: .leading, spacing: 3) {
                    Text(bottle.name).font(.headline)
                    Text("\(bottle.renderer.rawValue) · MSync \(bottle.msync ? "ON" : "OFF")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .tag(bottle)
            }
            .navigationTitle("BottleForge")
            .toolbar {
                Button(action: { showingCreate = true }) {
                    Label("Nova bottle", systemImage: "plus")
                }
            }
        } detail: {
            if let bottle = selectedBottle {
                BottleDetail(bottle: bottle)
                    .environmentObject(store)
            } else {
                ContentUnavailableView(
                    "Selecione uma bottle",
                    systemImage: "shippingbox",
                    description: Text("Clique em uma bottle na barra lateral para executar um .exe.")
                )
            }
        }
        .sheet(isPresented: $showingCreate) {
            CreateBottleView()
                .environmentObject(store)
        }
        .onAppear {
            if selectedBottle == nil {
                selectedBottle = store.bottles.first
            }
        }
        .onChange(of: store.bottles) { _, bottles in
            if let selected = selectedBottle, !bottles.contains(selected) {
                selectedBottle = bottles.first
            } else if selectedBottle == nil {
                selectedBottle = bottles.first
            }
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Circle()
                    .fill(store.busy ? Color.orange : Color.green)
                    .frame(width: 8, height: 8)
                Text(store.status).font(.caption)
                Spacer()
                Text(store.engineDescription)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(.bar)
        }
        .frame(minWidth: 820, minHeight: 520)
    }
}

struct BottleDetail: View {
    @EnvironmentObject private var store: BottleStore
    let bottle: Bottle
    @State private var installedApps: [InstalledApp] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(bottle.name).font(.largeTitle.bold())
                    Text("\(bottle.renderer.rawValue) — \(bottle.renderer.detail)")
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 12) {
                    Button("Executar .exe") { chooseExecutable() }
                        .buttonStyle(.borderedProminent)
                    Button("Wine Config") { store.wineConfig(bottle) }
                    Button("Abrir C:") { store.revealDriveC(bottle) }
                    Button("Encerrar") { store.kill(bottle) }
                }

                installedAppsBox

                GroupBox("Configuração") {
                    LabeledContent("Renderer", value: bottle.renderer.rawValue)
                    LabeledContent("MSync", value: bottle.msync ? "Ativo" : "Desativado")
                    LabeledContent("Prefixo", value: bottle.id.uuidString)
                }

                Button("Excluir bottle", role: .destructive) {
                    store.delete(bottle)
                }
                .padding(.top, 4)
            }
            .padding(28)
        }
        .navigationTitle(bottle.name)
        .onAppear { refreshInstalledApps() }
        .onChange(of: bottle.id) { _, _ in refreshInstalledApps() }
        .onChange(of: store.status) { _, status in
            if status.hasSuffix("finalizado") {
                refreshInstalledApps()
            }
        }
    }

    private var installedAppsBox: some View {
        GroupBox {
            if installedApps.isEmpty {
                HStack(spacing: 12) {
                    Image(systemName: "square.stack.3d.up.slash")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Nenhum aplicativo detectado")
                            .font(.headline)
                        Text("Instale um programa ou jogo nesta bottle e clique em atualizar.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(.vertical, 8)
            } else {
                VStack(spacing: 0) {
                    ForEach(installedApps) { app in
                        Button {
                            store.runInstalledApp(app, in: bottle)
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: app.icon)
                                    .font(.title3)
                                    .frame(width: 34, height: 34)
                                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(app.name)
                                        .font(.headline)
                                        .foregroundStyle(.primary)
                                    Text(app.detail)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }

                                Spacer()

                                Text("Abrir")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Image(systemName: "play.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .contentShape(Rectangle())
                            .padding(.vertical, 9)
                        }
                        .buttonStyle(.plain)

                        if app.id != installedApps.last?.id {
                            Divider()
                        }
                    }
                }
            }
        } label: {
            HStack {
                Text(installedApps.isEmpty ? "Instalados" : "Instalados (\(installedApps.count))")
                Spacer()
                Button {
                    refreshInstalledApps()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Atualizar aplicativos instalados")
            }
        }
    }

    private func refreshInstalledApps() {
        installedApps = store.installedApps(in: bottle)
    }

    private func chooseExecutable() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = []
        panel.message = "Selecione um instalador, launcher ou jogo Windows"
        if panel.runModal() == .OK, let url = panel.url {
            store.runExecutable(url, in: bottle)
        }
    }
}

struct CreateBottleView: View {
    @EnvironmentObject private var store: BottleStore
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var renderer: Renderer = .dxmt
    @State private var msync = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Nova bottle").font(.title.bold())

            TextField("Nome do jogo ou launcher", text: $name)
                .textFieldStyle(.roundedBorder)

            Picker("Renderer", selection: $renderer) {
                ForEach(Renderer.allCases) { item in
                    VStack(alignment: .leading) {
                        Text(item.rawValue)
                        Text(item.detail)
                    }
                    .tag(item)
                }
            }

            Toggle("MSync (requer engine CX custom)", isOn: $msync)
                .disabled(true)

            HStack {
                Button("Cancelar") { dismiss() }
                Spacer()
                Button("Criar") {
                    store.create(name: name, renderer: renderer, msync: msync)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 440)
    }
}

@main
struct BottleForgeApp: App {
    @StateObject private var store = BottleStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
        }
    }
}
