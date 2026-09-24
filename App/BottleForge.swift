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

            let detail = appID == "1245620"
                ? "Steam · Jogo · Offline (EAC)"
                : "Steam · Jogo"

            add(InstalledApp(
                id: "steam:\(appID)",
                name: name,
                detail: detail,
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
    @Published var rosettaRequired = false
    @Published var rosettaInstalling = false
    private let fm = FileManager.default
    private var supportRoot: URL {
        fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/BottleForge")
    }
    private var bottlesRoot: URL { supportRoot.appendingPathComponent("Bottles") }
    private var logsRoot: URL { supportRoot.appendingPathComponent("Logs") }
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
    private var dxmtEngineRoot: URL { engineBaseRoot.appendingPathComponent("wine-11.8-dxmt") }
    private var wineD3DEngineRoot: URL { engineBaseRoot.appendingPathComponent("wine-11.8-wined3d") }
    private var d3d12RuntimeRoot: URL {
        if let resources = Bundle.main.resourceURL {
            let bundled = resources.appendingPathComponent("D3D12Runtime")
            if fm.fileExists(atPath: bundled.path) { return bundled }
        }
        return projectRoot.appendingPathComponent("Runtime/D3D12")
    }

    private func engineRoot(for renderer: Renderer) -> URL {
        renderer == .dxmt ? dxmtEngineRoot : wineD3DEngineRoot
    }

    init() {
        try? fm.createDirectory(at: bottlesRoot, withIntermediateDirectories: true)
        try? fm.createDirectory(at: logsRoot, withIntermediateDirectories: true)
        clearStaleSteamBootstrapGuards()
        load()
        refreshRosettaStatus()
    }

    func refreshRosettaStatus() {
#if arch(arm64)
        DispatchQueue.global(qos: .utility).async {
            let available = Self.rosettaIsAvailable()
            DispatchQueue.main.async {
                self.rosettaRequired = !available
                if !available {
                    self.status = "Rosetta 2 é necessária para executar apps Windows"
                }
            }
        }
#else
        rosettaRequired = false
#endif
    }

    func installRosetta() {
#if arch(arm64)
        guard !rosettaInstalling else { return }

        rosettaInstalling = true
        busy = true
        status = "Instalando Rosetta 2…"

        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = [
                "-e",
                #"do shell script "/usr/sbin/softwareupdate --install-rosetta --agree-to-license" with administrator privileges"#
            ]
            process.standardOutput = FileHandle.nullDevice
            let errorPipe = Pipe()
            process.standardError = errorPipe

            var launchError: Error?
            var exitCode: Int32?

            do {
                try process.run()
                process.waitUntilExit()
                exitCode = process.terminationStatus
            } catch {
                launchError = error
            }

            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let errorText = String(data: errorData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let available = Self.rosettaIsAvailable()

            DispatchQueue.main.async {
                self.rosettaInstalling = false
                self.busy = false
                self.rosettaRequired = !available

                if available {
                    self.status = "Rosetta 2 instalada — BottleForge pronto"
                } else if let launchError {
                    self.status = "Não foi possível instalar Rosetta 2: \(launchError.localizedDescription)"
                } else if !errorText.isEmpty {
                    self.status = "Rosetta 2 não foi instalada: \(errorText)"
                } else {
                    self.status = "Rosetta 2 não foi instalada (código \(exitCode ?? -1))"
                }
            }
        }
#else
        rosettaRequired = false
#endif
    }

    private func ensureRosettaAvailable() -> Bool {
#if arch(arm64)
        if Self.rosettaIsAvailable() {
            rosettaRequired = false
            return true
        }

        rosettaRequired = true
        status = "Rosetta 2 é necessária para executar apps Windows"
        return false
#else
        return true
#endif
    }

    nonisolated private static func rosettaIsAvailable() -> Bool {
#if arch(arm64)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/arch")
        process.arguments = ["-x86_64", "/usr/bin/true"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
#else
        return true
#endif
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
        guard ensureRosettaAvailable() else { return }

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
        }
    }
    func runExecutable(_ url: URL, in bottle: Bottle) {
        launch(url, arguments: [], displayName: url.lastPathComponent, in: bottle)
    }

    func installedApps(in bottle: Bottle) -> [InstalledApp] {
        InstalledAppScanner.scan(prefix: prefixURL(bottle))
    }

    func runInstalledApp(_ app: InstalledApp, in bottle: Bottle) {
        guard ensureRosettaAvailable() else { return }

        guard app.id.hasPrefix("steam:") else {
            launch(app.executable, arguments: app.arguments, displayName: app.name, in: bottle)
            return
        }

        let appID = String(app.id.dropFirst("steam:".count))

        if appID == "1245620" {
            launchEldenRingOffline(app, bottle: bottle)
            return
        }

        monitorSteamGame(appID: appID, name: app.name, bottle: bottle)

        guard bottle.renderer == .dxmt else {
            launch(app.executable, arguments: app.arguments, displayName: app.name, in: bottle)
            return
        }

        optimizeAndLaunchSteamGame(app, appID: appID, bottle: bottle)
    }

    private func launchEldenRingOffline(_ app: InstalledApp, bottle: Bottle) {
        let appID = "1245620"
        let steamRoot = app.executable.deletingLastPathComponent()
        let gameDir = steamRoot
            .appendingPathComponent("steamapps/common/ELDEN RING/Game")
        let game = gameDir.appendingPathComponent("eldenring.exe")

        guard fm.fileExists(atPath: game.path) else {
            status = "Elden Ring não encontrado na biblioteca padrão da Steam"
            return
        }

        guard prepareD3D12Runtime(in: bottle) else {
            status = "Runtime DirectX 12 não encontrado no BottleForge"
            return
        }

        do {
            try "1245620\n".write(
                to: gameDir.appendingPathComponent("steam_appid.txt"),
                atomically: true,
                encoding: .utf8
            )
        } catch {
            status = "Não foi possível preparar o modo offline do Elden Ring"
            return
        }

        let launchWithProfile: (LayaGameProfile?) -> Void = { [weak self] profile in
            guard let self else { return }
            guard let wine = self.wineURL(for: .dxmt) else {
                self.status = "Engine Wine não encontrada"
                return
            }

            let shaderCache = self.supportRoot.appendingPathComponent("ShaderCache/\(appID)")
            try? self.fm.createDirectory(at: shaderCache, withIntermediateDirectories: true)

            var overrides: [String: String] = [
                "SteamAppId": appID,
                "SteamGameId": appID,
                "WINEDLLOVERRIDES": "d3d12,d3d12core,dxgi=n,b",
                "VK_ICD_FILENAMES": self.d3d12RuntimeRoot.appendingPathComponent("MoltenVK_icd.json").path,
                "DYLD_LIBRARY_PATH": self.d3d12RuntimeRoot.path,
                "DYLD_FALLBACK_LIBRARY_PATH": self.d3d12RuntimeRoot.path,
                "MVK_PRESENT_MODE": "1",
                "VKMT_ALLOW_NON_SINGLE_TEXEL_ALIGNMENT": "1",
                "VKD3D_SHADER_CACHE_PATH": shaderCache.path
            ]
            if let profile {
                overrides["WINEMSYNC"] = profile.msync ? "1" : "0"
            }

            self.status = profile == nil
                ? "Abrindo Elden Ring · Offline · D3D12"
                : "Abrindo Elden Ring · Offline · \(profile!.displayName)"

            self.runProcess(
                wine,
                args: [game.path],
                bottle: bottle,
                environmentOverrides: overrides,
                workingDirectory: gameDir
            ) { code in
                if code == 0 {
                    self.status = "Elden Ring finalizado · Offline"
                } else {
                    LayaProfileEngine.invalidate(appID: appID, supportRoot: self.supportRoot)
                    self.status = "Elden Ring saiu com código \(code) · perfil D3D12 será recalculado"
                }
            }
        }

        if let profile = LayaProfileEngine.cachedProfile(appID: appID, supportRoot: supportRoot) {
            if profile.usesD3D12 {
                launchWithProfile(profile)
                return
            }
            LayaProfileEngine.invalidate(appID: appID, supportRoot: supportRoot)
        }

        let firstRun = !LayaProfileEngine.modelIsCached(supportRoot: supportRoot)
        status = firstRun
            ? "Preparando Elden Ring D3D12 + otimização automática…"
            : "Otimizando Elden Ring D3D12 com Laya…"
        busy = true

        let supportRoot = supportRoot
        let projectRoot = projectRoot
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let profile = try LayaProfileEngine.chooseProfile(
                    appID: appID,
                    gameName: app.name + " (offline, sem EAC)",
                    renderer: .dxmt,
                    supportRoot: supportRoot,
                    projectRoot: projectRoot,
                    graphicsAPI: "D3D12"
                )

                DispatchQueue.main.async {
                    self?.busy = false
                    launchWithProfile(profile)
                }
            } catch {
                DispatchQueue.main.async {
                    self?.busy = false
                    self?.status = "Laya indisponível; abrindo Elden Ring D3D12 com perfil padrão"
                    launchWithProfile(nil)
                }
            }
        }
    }

    private func prepareD3D12Runtime(in bottle: Bottle) -> Bool {
        let required = ["dxgi.dll", "d3d12.dll", "d3d12core.dll", "libMoltenVK.dylib", "MoltenVK_icd.json"]
        guard required.allSatisfy({ fm.fileExists(atPath: d3d12RuntimeRoot.appendingPathComponent($0).path) }) else {
            return false
        }

        let system32 = prefixURL(bottle).appendingPathComponent("drive_c/windows/system32")
        do {
            try fm.createDirectory(at: system32, withIntermediateDirectories: true)
            for name in ["dxgi.dll", "d3d12.dll", "d3d12core.dll"] {
                let source = d3d12RuntimeRoot.appendingPathComponent(name)
                let target = system32.appendingPathComponent(name)
                try? fm.removeItem(at: target)
                try fm.copyItem(at: source, to: target)
            }
            return true
        } catch {
            return false
        }
    }

    private func optimizeAndLaunchSteamGame(_ app: InstalledApp, appID: String, bottle: Bottle) {
        if let profile = LayaProfileEngine.cachedProfile(appID: appID, supportRoot: supportRoot) {
            status = "Abrindo \(app.name) · Auto: \(profile.displayName)"
            launch(
                app.executable,
                arguments: app.arguments,
                displayName: app.name,
                in: bottle,
                profile: profile
            )
            return
        }

        let firstRun = !LayaProfileEngine.modelIsCached(supportRoot: supportRoot)
        status = firstRun
            ? "Preparando otimização automática (~1,7 GB na primeira vez)…"
            : "Otimizando \(app.name) com Laya…"
        busy = true

        let supportRoot = supportRoot
        let projectRoot = projectRoot
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let profile = try LayaProfileEngine.chooseProfile(
                    appID: appID,
                    gameName: app.name,
                    renderer: bottle.renderer,
                    supportRoot: supportRoot,
                    projectRoot: projectRoot
                )

                DispatchQueue.main.async {
                    guard let self else { return }
                    self.busy = false
                    self.status = "Laya escolheu \(profile.displayName) · abrindo \(app.name)…"
                    self.launch(
                        app.executable,
                        arguments: app.arguments,
                        displayName: app.name,
                        in: bottle,
                        profile: profile
                    )
                }
            } catch {
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.busy = false
                    self.status = "Laya indisponível; usando perfil padrão"
                    self.launch(app.executable, arguments: app.arguments, displayName: app.name, in: bottle)
                }
            }
        }
    }

    private func monitorSteamGame(appID: String, name: String, bottle: Bottle) {
        let steamRoots = [
            prefixURL(bottle).appendingPathComponent("drive_c/Program Files (x86)/Steam"),
            prefixURL(bottle).appendingPathComponent("drive_c/Program Files/Steam")
        ]
        guard let steamRoot = steamRoots.first(where: { fm.fileExists(atPath: $0.path) }) else { return }

        let processLog = steamRoot.appendingPathComponent("logs/gameprocess_log.txt")
        let baselineSize = (try? Data(contentsOf: processLog).count) ?? 0
        let diagnosticsRoot = logsRoot
        let profileSupportRoot = supportRoot
        let bottleName = bottle.name

        DispatchQueue.global(qos: .utility).async { [weak self] in
            let launchDeadline = Date().addingTimeInterval(180)
            let monitorDeadline = Date().addingTimeInterval(6 * 60 * 60)
            var mainPID: String?
            var latestChunk = ""

            while Date() < monitorDeadline {
                Thread.sleep(forTimeInterval: 2)

                guard let data = try? Data(contentsOf: processLog) else { continue }
                let offset = data.count >= baselineSize ? baselineSize : 0
                latestChunk = String(data: data.suffix(from: offset), encoding: .utf8) ?? ""

                let lines = latestChunk.components(separatedBy: .newlines)
                let addMarker = "AppID \(appID) adding PID "

                if mainPID == nil {
                    for line in lines where line.contains(addMarker) {
                        let lower = line.lowercased()
                        if lower.contains("crashhandler") || lower.contains("steamerrorreporter") {
                            continue
                        }

                        if let range = line.range(of: addMarker) {
                            let tail = line[range.upperBound...]
                            mainPID = tail.split(separator: " ").first.map(String.init)
                            break
                        }
                    }
                }

                if let mainPID {
                    let exitMarker = "AppID \(appID) no longer tracking PID \(mainPID), exit code "
                    if let exitLine = lines.last(where: { $0.contains(exitMarker) }),
                       let range = exitLine.range(of: exitMarker) {
                        let rawCode = exitLine[range.upperBound...]
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        let code = Int(rawCode) ?? -1

                        if code == 0 {
                            DispatchQueue.main.async {
                                self?.status = "\(name) finalizado"
                            }
                        } else {
                            LayaProfileEngine.invalidate(appID: appID, supportRoot: profileSupportRoot)
                            _ = Self.writeSteamDiagnostic(
                                appID: appID,
                                name: name,
                                bottleName: bottleName,
                                exitCode: code,
                                details: latestChunk,
                                directory: diagnosticsRoot
                            )
                            DispatchQueue.main.async {
                                self?.status = "\(name) encerrou com código \(code) · perfil Auto será recalculado"
                            }
                        }
                        return
                    }
                } else if Date() > launchDeadline {
                    LayaProfileEngine.invalidate(appID: appID, supportRoot: profileSupportRoot)
                    _ = Self.writeSteamDiagnostic(
                        appID: appID,
                        name: name,
                        bottleName: bottleName,
                        exitCode: nil,
                        details: latestChunk,
                        directory: diagnosticsRoot
                    )
                    DispatchQueue.main.async {
                        self?.status = "\(name) não iniciou · perfil Auto será recalculado"
                    }
                    return
                }
            }
        }
    }

    nonisolated private static func writeSteamDiagnostic(
        appID: String,
        name: String,
        bottleName: String,
        exitCode: Int?,
        details: String,
        directory: URL
    ) -> String {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let timestamp = Int(Date().timeIntervalSince1970)
        let fileName = "steam-\(appID)-\(timestamp).log"
        let destination = directory.appendingPathComponent(fileName)
        let exitDescription = exitCode.map(String.init) ?? "processo não iniciado"

        let report = """
        BottleForge Steam Diagnostic
        Date: \(ISO8601DateFormatter().string(from: Date()))
        Bottle: \(bottleName)
        App: \(name)
        AppID: \(appID)
        Exit: \(exitDescription)

        --- Steam gameprocess_log ---
        \(details)
        """

        try? report.write(to: destination, atomically: true, encoding: .utf8)
        return fileName
    }

    private func launch(
        _ executable: URL,
        arguments: [String],
        displayName: String,
        in bottle: Bottle,
        profile: LayaGameProfile? = nil
    ) {
        guard ensureRosettaAvailable() else { return }

        guard let wine = wineURL(for: bottle.renderer) else {
            status = "Engine Wine não encontrada"
            return
        }

        if isSteamExecutable(executable) {
            launchSteam(
                executable,
                arguments: arguments,
                displayName: displayName,
                wine: wine,
                bottle: bottle,
                profile: profile
            )
            return
        }

        status = "Abrindo \(displayName)…"
        runProcess(wine, args: [executable.path] + arguments, bottle: bottle) { code in
            self.status = code == 0 ? "\(displayName) finalizado" : "\(displayName) saiu com código \(code)"
        }
    }

    private func isSteamExecutable(_ executable: URL) -> Bool {
        executable.lastPathComponent.caseInsensitiveCompare("Steam.exe") == .orderedSame
            && executable.path.lowercased().contains("/steam/")
    }

    private func launchSteam(
        _ executable: URL,
        arguments: [String],
        displayName: String,
        wine: URL,
        bottle: Bottle,
        profile: LayaGameProfile?
    ) {
        if !arguments.contains("-applaunch") {
            terminateRunningSteam(in: bottle)
        }

        guard prepareSteamCEFCompatibility(in: bottle) else {
            status = "Não foi possível preparar a interface da Steam"
            return
        }

        let steamArgs = [
            "-no-cef-sandbox",
            "-noverifyfiles"
        ] + (profile?.launchArguments ?? []) + arguments

        var environmentOverrides: [String: String] = [:]
        if let profile {
            environmentOverrides["WINEMSYNC"] = profile.msync ? "1" : "0"
        }

        status = "Abrindo \(displayName)…"
        runProcess(
            wine,
            args: [executable.path] + steamArgs,
            bottle: bottle,
            environmentOverrides: environmentOverrides
        ) { code in
            self.status = code == 0 ? "\(displayName) finalizado" : "\(displayName) saiu com código \(code)"
        }

        scheduleSteamBootstrapGuardRemoval(in: bottle)
    }

    private func terminateRunningSteam(in bottle: Bottle) {
        guard let server = wineserverURL(for: bottle.renderer) else { return }

        let process = Process()
        process.executableURL = server
        process.arguments = ["-k"]
        process.environment = environment(for: bottle)
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            // Continue: Steam may not have been running.
        }
    }

    private func prepareSteamCEFCompatibility(in bottle: Bottle) -> Bool {
        guard let wrapper = steamCompatWrapperURL() else { return false }

        let steamDir = prefixURL(bottle)
            .appendingPathComponent("drive_c/Program Files (x86)/Steam")
        let cefRoot = steamDir.appendingPathComponent("bin/cef")

        guard let cefDirs = try? fm.contentsOfDirectory(
            at: cefRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return false }

        var patched = false
        var refreshedOriginal = false

        for cefDir in cefDirs where cefDir.lastPathComponent.lowercased().hasPrefix("cef.win") {
            let helper = cefDir.appendingPathComponent("steamwebhelper.exe")
            let real = cefDir.appendingPathComponent("steamwebhelper_real.exe")
            let helperSize = (try? helper.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0

            if helperSize > 1_000_000 {
                try? fm.removeItem(at: real)
                do {
                    try fm.moveItem(at: helper, to: real)
                    refreshedOriginal = true
                } catch {
                    continue
                }
            }

            guard fm.fileExists(atPath: real.path) else { continue }

            try? fm.removeItem(at: helper)
            do {
                try fm.copyItem(at: wrapper, to: helper)
                patched = true
            } catch {
                continue
            }
        }

        guard patched else { return false }

        let steamCfg = steamDir.appendingPathComponent("steam.cfg")
        try? "BootStrapperInhibitAll=enable\n".write(
            to: steamCfg,
            atomically: true,
            encoding: .utf8
        )

        if refreshedOriginal {
            clearSteamHTMLCache(in: bottle)
        } else {
            cleanSteamChromiumLocks(in: bottle)
        }

        return true
    }

    private func steamCompatWrapperURL() -> URL? {
        if let resources = Bundle.main.resourceURL {
            let bundled = resources.appendingPathComponent("SteamCompat/steamwebhelper-wrapper.exe")
            if fm.fileExists(atPath: bundled.path) { return bundled }
        }

        let development = projectRoot.appendingPathComponent("build/steamwebhelper-wrapper.exe")
        return fm.fileExists(atPath: development.path) ? development : nil
    }

    private func scheduleSteamBootstrapGuardRemoval(in bottle: Bottle) {
        let steamCfg = prefixURL(bottle)
            .appendingPathComponent("drive_c/Program Files (x86)/Steam/steam.cfg")

        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 20) {
            let fileManager = FileManager.default
            guard
                let text = try? String(contentsOf: steamCfg, encoding: .utf8),
                text.trimmingCharacters(in: .whitespacesAndNewlines) == "BootStrapperInhibitAll=enable"
            else { return }

            try? fileManager.removeItem(at: steamCfg)
        }
    }

    private func clearStaleSteamBootstrapGuards() {
        let dirs = (try? fm.contentsOfDirectory(
            at: bottlesRoot,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []

        for dir in dirs {
            let steamCfg = dir
                .appendingPathComponent("prefix/drive_c/Program Files (x86)/Steam/steam.cfg")
            guard
                let text = try? String(contentsOf: steamCfg, encoding: .utf8),
                text.trimmingCharacters(in: .whitespacesAndNewlines) == "BootStrapperInhibitAll=enable"
            else { continue }

            try? fm.removeItem(at: steamCfg)
        }
    }

    private func clearSteamHTMLCache(in bottle: Bottle) {
        let usersRoot = prefixURL(bottle).appendingPathComponent("drive_c/users")
        guard let users = try? fm.contentsOfDirectory(
            at: usersRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        for user in users {
            let htmlCache = user.appendingPathComponent("AppData/Local/Steam/htmlcache")
            try? fm.removeItem(at: htmlCache)
        }
    }

    private func cleanSteamChromiumLocks(in bottle: Bottle) {
        let usersRoot = prefixURL(bottle).appendingPathComponent("drive_c/users")
        guard let users = try? fm.contentsOfDirectory(
            at: usersRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        for user in users {
            let htmlCache = user.appendingPathComponent("AppData/Local/Steam/htmlcache")
            guard let enumerator = fm.enumerator(
                at: htmlCache,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else { continue }

            for case let url as URL in enumerator {
                if enumerator.level > 2 {
                    enumerator.skipDescendants()
                    continue
                }

                let name = url.lastPathComponent
                if name.hasPrefix("Singleton")
                    || name.hasSuffix(".lock")
                    || name.hasPrefix("CrashpadMetrics") && name.hasSuffix(".pma") {
                    try? fm.removeItem(at: url)
                }
            }
        }
    }

    func wineConfig(_ bottle: Bottle) {
        guard ensureRosettaAvailable() else { return }
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
        "Wine 11.8 Staging · DXMT 0.80 · Auto Laya"
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
            env["WINE_DO_NOT_CREATE_DXGI_DEVICE_MANAGER"] = "1"
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
        environmentOverrides: [String: String] = [:],
        workingDirectory: URL? = nil,
        completion: @escaping (Int32) -> Void
    ) {
        var env = environment(for: bottle)
        for (key, value) in environmentOverrides {
            env[key] = value
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = executable
            process.arguments = args
            process.environment = env
            process.currentDirectoryURL = workingDirectory
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

}

struct ContentView: View {
    @EnvironmentObject private var store: BottleStore
    @EnvironmentObject private var updater: UpdateManager
    @State private var showingCreate = false
    @State private var showingUpdate = false
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
                if updater.availableUpdate != nil {
                    Button(action: { showingUpdate = true }) {
                        Label("Atualização disponível", systemImage: "arrow.down.circle.fill")
                    }
                    .help("Nova versão do BottleForge disponível")
                }

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
        .sheet(isPresented: $showingUpdate) {
            UpdateView()
                .environmentObject(updater)
        }
        .alert("Componente de compatibilidade necessário", isPresented: $store.rosettaRequired) {
            Button("Instalar Rosetta 2") {
                store.installRosetta()
            }
            .disabled(store.rosettaInstalling)

            Button("Agora não", role: .cancel) {}
        } message: {
            Text(
                "O BottleForge usa um runtime Windows x86_64. Neste Mac com Apple Silicon, " +
                "é necessário instalar o Rosetta 2 da Apple para executar jogos e aplicativos Windows."
            )
        }
        .onAppear {
            if selectedBottle == nil {
                selectedBottle = store.bottles.first
            }
            updater.checkForUpdates(silent: true)
        }
        .onChange(of: store.bottles) { _, bottles in
            if let selected = selectedBottle, !bottles.contains(selected) {
                selectedBottle = bottles.first
            } else if selectedBottle == nil {
                selectedBottle = bottles.first
            }
        }
        .onChange(of: updater.availableUpdate) { _, update in
            if update != nil {
                showingUpdate = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification
        )) { _ in
            updater.checkForUpdates(silent: true)
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Circle()
                    .fill(store.busy ? Color.orange : Color.green)
                    .frame(width: 8, height: 8)
                Text(store.status).font(.caption)
                Spacer()
                if let update = updater.availableUpdate {
                    Button("\(update.tag) disponível") {
                        showingUpdate = true
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                } else {
                    Button {
                        updater.checkForUpdates()
                    } label: {
                        Image(systemName: updater.isChecking ? "clock" : "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .help("Verificar atualizações")
                }

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
                    if bottle.renderer == .dxmt {
                        Label("Modo Auto com Laya", systemImage: "sparkles")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
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
                    LabeledContent(
                        "Perfil de jogo",
                        value: bottle.renderer == .dxmt ? "Auto por jogo · Laya" : "Manual"
                    )
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
                                    Text(
                                        app.id.hasPrefix("steam:") && bottle.renderer == .dxmt
                                            ? "\(app.detail) · Auto Laya"
                                            : app.detail
                                    )
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

struct UpdateView: View {
    @EnvironmentObject private var updater: UpdateManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Atualizações")
                        .font(.title2.bold())
                    Text("Versão atual: \(updater.currentTag)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
            }

            if let release = updater.availableUpdate {
                GroupBox {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(release.title)
                                    .font(.headline)
                                Text("\(release.tag) · \(formattedSize(release.assetSize))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "arrow.down.circle.fill")
                                .font(.title)
                        }

                        if !release.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Divider()
                            ScrollView {
                                Text(release.notes)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .textSelection(.enabled)
                            }
                            .frame(maxHeight: 180)
                        }
                    }
                    .padding(.vertical, 4)
                }

                HStack {
                    if updater.isDownloading {
                        ProgressView()
                            .controlSize(.small)
                    }

                    Text(updater.statusMessage ?? "")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Spacer()

                    Button("Agora não") {
                        dismiss()
                    }

                    Button("Atualizar agora") {
                        updater.installAvailableUpdate()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(updater.isDownloading)
                }
            } else {
                VStack(spacing: 14) {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 36))
                        .foregroundStyle(.secondary)

                    Text(updater.isChecking ? "Verificando atualizações…" : "Nenhuma atualização disponível")
                        .font(.headline)

                    if let status = updater.statusMessage {
                        Text(status)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Button("Verificar novamente") {
                        updater.checkForUpdates()
                    }
                    .disabled(updater.isChecking)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 28)
            }

            if let error = updater.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(24)
        .frame(width: 520)
    }

    private func formattedSize(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
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

            Text("O Modo Auto escolhe MSync e argumentos por jogo.")
                .font(.caption)
                .foregroundStyle(.secondary)

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
    @StateObject private var updater = UpdateManager()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .environmentObject(updater)
        }
    }
}
