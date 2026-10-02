import SwiftUI
import AppKit
import Foundation

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
    var gameExecutable: URL? = nil
    var gameDirectory: URL? = nil
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
            scanSteamGames(steam: steam, prefix: prefix, add: add)
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

    private static func scanSteamGames(steam: URL, prefix: URL, add: (InstalledApp) -> Void) {
        let fm = FileManager.default
        for library in SteamLibraries.roots(steam: steam, prefix: prefix) {
            let steamApps = library.appendingPathComponent("steamapps")
            guard let manifests = try? fm.contentsOfDirectory(
                at: steamApps,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else { continue }

            for manifest in manifests where manifest.lastPathComponent.hasPrefix("appmanifest_") && manifest.pathExtension == "acf" {
                guard
                    let text = try? String(contentsOf: manifest, encoding: .utf8),
                    let appID = acfValue("appid", in: text),
                    let name = acfValue("name", in: text),
                    let installDir = acfValue("installdir", in: text)
                else { continue }

                guard !appID.isEmpty, appID.allSatisfy(\.isNumber),
                      !installDir.isEmpty, !installDir.contains("/"), !installDir.contains("\\"),
                      installDir != ".", installDir != ".." else { continue }

                let gameDir = steamApps.appendingPathComponent("common").appendingPathComponent(installDir)
                guard fm.fileExists(atPath: gameDir.path) else { continue }

                let detail = appID == "1245620"
                    ? "Steam · Jogo · Offline · D3D12 (EAC)"
                    : "Steam · Jogo"

                add(InstalledApp(
                    id: "steam:\(appID)",
                    name: name,
                    detail: detail,
                    icon: "play.rectangle.fill",
                    executable: steam,
                    arguments: ["-applaunch", appID],
                    gameExecutable: bestExecutable(in: gameDir, appName: name),
                    gameDirectory: gameDir
                ))
            }
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
    private var history: CompatibilityHistory {
        CompatibilityHistory(root: supportRoot.appendingPathComponent("Compatibility"))
    }
    private var gameMonitors: [UUID: GameMonitorToken] = [:]
    private var sessionProfiles: [UUID: LayaGameProfile.Kind] = [:]

    func runExecutable(_ url: URL, in bottle: Bottle) {
        if isSteamExecutable(url) {
            launch(url, arguments: [], displayName: url.lastPathComponent, in: bottle)
        } else {
            launchGame(url, arguments: [], displayName: url.lastPathComponent,
                       gameExecutable: url, in: bottle)
        }
    }

    func installedApps(in bottle: Bottle) -> [InstalledApp] {
        InstalledAppScanner.scan(prefix: prefixURL(bottle))
    }

    func resetCompatibility(in bottle: Bottle) {
        guard gameMonitors[bottle.id] == nil else {
            status = "Encerre o jogo antes de redefinir os perfis"
            return
        }
        try? fm.removeItem(at: history.root.appendingPathComponent(bottle.id.uuidString))
        status = "Perfis de compatibilidade redefinidos"
    }

    func runInstalledApp(_ app: InstalledApp, in bottle: Bottle) {
        guard ensureRosettaAvailable() else { return }
        if app.id == "steam" {
            launch(app.executable, arguments: app.arguments, displayName: app.name, in: bottle)
        } else if app.id == "steam:1245620" {
            launchEldenRingOffline(app, bottle: bottle)
        } else {
            let appID = app.id.hasPrefix("steam:") ? String(app.id.dropFirst(6)) : nil
            launchGame(app.executable, arguments: app.arguments, displayName: app.name,
                       gameExecutable: app.gameExecutable ?? (appID == nil ? app.executable : nil),
                       steamAppID: appID, in: bottle)
        }
    }

    private func launchEldenRingOffline(_ app: InstalledApp, bottle: Bottle) {
        let gameDir = (app.gameDirectory ?? app.executable.deletingLastPathComponent()
            .appendingPathComponent("steamapps/common/ELDEN RING"))
            .appendingPathComponent("Game")
        let game = gameDir.appendingPathComponent("eldenring.exe")
        guard fm.fileExists(atPath: game.path) else {
            status = "Executável do Elden Ring não encontrado"
            return
        }
        do {
            try "1245620\n".write(to: gameDir.appendingPathComponent("steam_appid.txt"),
                                   atomically: true, encoding: .utf8)
        } catch {
            status = "Não foi possível preparar o modo offline do Elden Ring"
            return
        }
        launchGame(game, arguments: [], displayName: app.name + " · Offline",
                   gameExecutable: game, steamAppID: "1245620", offline: true, in: bottle)
    }

    private func launchGame(
        _ executable: URL, arguments: [String], displayName: String,
        gameExecutable: URL?, steamAppID: String? = nil, offline: Bool = false, in bottle: Bottle
    ) {
        guard ensureRosettaAvailable(), !busy else { return }
        guard gameMonitors[bottle.id] == nil else {
            status = "Já existe um jogo em execução nesta bottle"
            return
        }
        busy = true
        status = "Detectando compatibilidade de \(displayName)…"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let evidence = gameExecutable.map { PEGameInspector.inspect(executable: $0) } ?? GameEvidence()
            DispatchQueue.main.async {
                guard let self else { return }
                self.busy = false
                guard self.bottles.contains(where: { $0.id == bottle.id }) else { return }
                self.launchDetectedGame(executable, arguments: arguments, displayName: displayName,
                                        evidence: evidence, steamAppID: steamAppID, offline: offline, in: bottle)
            }
        }
    }

    private func launchDetectedGame(
        _ executable: URL, arguments: [String], displayName: String, evidence: GameEvidence,
        steamAppID: String?, offline: Bool, in bottle: Bottle
    ) {
        var candidates = GameCompatibility.candidates(evidence: evidence, renderer: bottle.renderer,
                                                      msync: bottle.msync, d3d12Available: d3d12RuntimeAvailable)
        candidates.removeAll { wineURL(for: $0.renderer) == nil }
        guard !candidates.isEmpty else {
            status = evidence.machine == .arm64
                ? "Executável Windows ARM64 incompatível com esta engine x86_64"
                : "Nenhum runtime compatível disponível para as APIs detectadas (\(evidence.apis.map(\.rawValue).sorted().joined(separator: ", ")))"
            return
        }
        // Old AI suggestions may rank supported profiles, but cannot invent an API or retry a failed profile.
        if let appID = steamAppID,
           let cached = LayaProfileEngine.cachedProfile(appID: appID, supportRoot: supportRoot),
           let index = candidates.firstIndex(of: cached.kind) {
            candidates.remove(at: index); candidates.insert(cached.kind, at: 0)
        }
        let gameKey = steamAppID.map { "steam:" + $0 + (offline ? ":offline" : "") } ?? "exe:" + executable.standardizedFileURL.path
        let key = bottle.id.uuidString + "/" + gameKey
        let fingerprint = compatibilityFingerprint(evidence: evidence, bottle: bottle)
        guard let kind = history.next(key: key, fingerprint: fingerprint, candidates: candidates) else {
            status = "Perfis disponíveis esgotados para \(displayName). Consulte os logs ou redefina os perfis nesta bottle."
            return
        }
        var effectiveBottle = bottle
        effectiveBottle.renderer = kind.renderer
        let running = wineSessionIsRunning(in: bottle)
        if running && sessionProfiles[bottle.id] != kind {
            status = "Encerre os processos Wine desta bottle antes de aplicar o novo perfil de \(displayName)"
            return
        }
        if !running { sessionProfiles[bottle.id] = nil }
        let profile = LayaGameProfile(appID: steamAppID ?? gameKey, gameName: displayName, kind: kind,
                                      probabilities: [:], confidence: nil, createdAt: Date())
        if profile.usesD3D12 && !running && !prepareD3D12Runtime(in: effectiveBottle) {
            status = "Não foi possível preparar o runtime DirectX 12"
            return
        }
        let token = GameMonitorToken()
        gameMonitors[bottle.id] = token
        sessionProfiles[bottle.id] = kind
        let attempt = CompatibilityAttempt(key: key, fingerprint: fingerprint, profile: profile)
        launch(executable, arguments: arguments, displayName: displayName, in: effectiveBottle,
               profile: profile, attempt: attempt, monitorToken: token,
               steamAppID: steamAppID, offline: offline)
    }

    private var d3d12RuntimeAvailable: Bool {
        ["dxgi.dll", "d3d12.dll", "d3d12core.dll", "libMoltenVK.dylib", "MoltenVK_icd.json"]
            .allSatisfy { fm.fileExists(atPath: d3d12RuntimeRoot.appendingPathComponent($0).path) }
    }

    private func compatibilityFingerprint(evidence: GameEvidence, bottle: Bottle) -> String {
        let runtimes = [wineURL(for: .dxmt), wineURL(for: .wineD3D),
                        dxmtEngineRoot.appendingPathComponent("Contents/Resources/wine/lib/wine/x86_64-windows/d3d11.dll"),
                        d3d12RuntimeRoot.appendingPathComponent("d3d12.dll"),
                        d3d12RuntimeRoot.appendingPathComponent("libMoltenVK.dylib")]
        let stamps = runtimes.compactMap { $0 }.map { url -> String in
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            return "\(url.path):\(values?.fileSize ?? 0):\(values?.contentModificationDate?.timeIntervalSince1970 ?? 0)"
        }
        let release = Bundle.main.object(forInfoDictionaryKey: "BottleForgeReleaseTag") as? String ?? "development"
        return (["policy-1", release, bottle.renderer.rawValue, String(bottle.msync), evidence.fingerprint] + stamps).joined(separator: "|")
    }

    // `wineserver -w` only waits for the prefix server; cancelling this probe does not kill games.
    private func wineSessionIsRunning(in bottle: Bottle) -> Bool {
        guard let server = wineserverURL(for: bottle.renderer) else { return false }
        let probe = Process()
        probe.executableURL = server
        probe.arguments = ["-w"]
        probe.environment = environment(for: bottle)
        probe.standardOutput = FileHandle.nullDevice
        probe.standardError = FileHandle.nullDevice
        do {
            try probe.run()
            Thread.sleep(forTimeInterval: 0.2)
            if probe.isRunning { probe.terminate(); return true }
            return probe.terminationStatus != 0
        } catch { return true }
    }

    private func prepareD3D12Runtime(in bottle: Bottle) -> Bool {
        guard d3d12RuntimeAvailable else { return false }
        do {
            try D3D12RuntimeInstaller.install(runtime: d3d12RuntimeRoot, prefix: prefixURL(bottle))
            return true
        } catch {
            return false
        }
    }

    private func monitorSteamGame(
        appID: String, name: String, bottle: Bottle, processLog: URL,
        baselineSize: Int, attempt: CompatibilityAttempt, token: GameMonitorToken
    ) {
        let diagnosticsRoot = logsRoot
        let history = history
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let launchDeadline = Date().addingTimeInterval(180)
            let monitorDeadline = Date().addingTimeInterval(6 * 60 * 60)
            var session = SteamGameSession(appID: appID)
            var offset = baselineSize
            var remainder = ""
            var diagnostic = ""
            var pendingExit: (code: Int, since: Date)?
            while Date() < monitorDeadline && !token.isCancelled {
                Thread.sleep(forTimeInterval: 2)
                if token.isCancelled { return }
                if let handle = try? FileHandle(forReadingFrom: processLog) {
                    let size = (try? handle.seekToEnd()) ?? UInt64(offset)
                    if size < UInt64(offset) { offset = 0; remainder = "" }
                    try? handle.seek(toOffset: UInt64(offset))
                    // Read incrementally, never repeatedly load an entire six-hour process log.
                    let data = (try? handle.read(upToCount: 256 * 1024)) ?? Data()
                    try? handle.close()
                    offset += data.count
                    remainder += String(decoding: data, as: UTF8.self)
                    if let boundary = remainder.lastIndex(of: "\n") {
                        let chunk = String(remainder[...boundary])
                        remainder = String(remainder[remainder.index(after: boundary)...])
                        diagnostic = String((diagnostic + chunk).suffix(64 * 1024))
                        if let code = session.consume(chunk) {
                            if pendingExit == nil { pendingExit = (code, Date()) }
                            else { pendingExit?.code = code }
                        } else { pendingExit = nil }
                    }
                    remainder = String(remainder.suffix(64 * 1024))
                }
                if let exit = pendingExit, Date().timeIntervalSince(exit.since) >= 4 {
                    guard !token.isCancelled else { return }
                    history.record(key: attempt.key, fingerprint: attempt.fingerprint,
                                   profile: attempt.profile.kind, succeeded: exit.code == 0)
                    _ = Self.writeSteamDiagnostic(appID: appID, name: name, bottleName: bottle.name,
                                                 exitCode: exit.code, details: "Profile: \(attempt.profile.displayName)\n" + diagnostic,
                                                 directory: diagnosticsRoot)
                    DispatchQueue.main.async {
                        guard !token.isCancelled else { return }
                        self?.gameMonitors[bottle.id] = nil
                        self?.status = exit.code == 0 ? "\(name) finalizado"
                            : "\(name) saiu com código \(exit.code) · outro perfil será tentado na próxima abertura"
                    }
                    return
                }
                if !session.started && Date() > launchDeadline { break }
            }
            guard !token.isCancelled else { return }
            // Missing Steam telemetry is inconclusive, not proof that a renderer failed.
            _ = Self.writeSteamDiagnostic(appID: appID, name: name, bottleName: bottle.name,
                                         exitCode: nil, details: diagnostic, directory: diagnosticsRoot)
            DispatchQueue.main.async {
                guard !token.isCancelled else { return }
                self?.gameMonitors[bottle.id] = nil
                self?.status = "Sem confirmação de execução de \(name) · consulte os logs"
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
        _ executable: URL, arguments: [String], displayName: String, in bottle: Bottle,
        profile: LayaGameProfile? = nil, attempt: CompatibilityAttempt? = nil,
        monitorToken: GameMonitorToken? = nil, steamAppID: String? = nil, offline: Bool = false
    ) {
        guard ensureRosettaAvailable(), let wine = wineURL(for: bottle.renderer) else {
            gameMonitors[bottle.id] = nil
            status = "Engine Wine ou Rosetta não encontrada"
            return
        }
        if isSteamExecutable(executable) {
            launchSteam(executable, arguments: arguments, displayName: displayName, wine: wine,
                        bottle: bottle, profile: profile, attempt: attempt, monitorToken: monitorToken)
            return
        }
        var overrides = profileEnvironment(profile)
        if offline, let appID = steamAppID {
            overrides["SteamAppId"] = appID
            overrides["SteamGameId"] = appID
        }
        let log = processDiagnosticURL(in: bottle)
        status = "Abrindo \(displayName) · \(profile?.displayName ?? bottle.renderer.rawValue)…"
        runProcess(wine, args: [executable.path] + arguments + (profile?.launchArguments ?? []), bottle: bottle,
                   environmentOverrides: overrides, workingDirectory: executable.deletingLastPathComponent(), logURL: log) { code in
            guard monitorToken?.isCancelled != true else { return }
            self.gameMonitors[bottle.id] = nil
            if let attempt {
                self.history.record(key: attempt.key, fingerprint: attempt.fingerprint,
                                    profile: attempt.profile.kind, succeeded: code == 0)
            }
            self.status = code == 0 ? "\(displayName) finalizado"
                : "\(displayName) saiu com código \(code) · consulte \(log.lastPathComponent); outro perfil na próxima abertura"
        }
    }

    private func profileEnvironment(_ profile: LayaGameProfile?) -> [String: String] {
        guard let profile else { return [:] }
        var overrides = ["WINEMSYNC": profile.msync ? "1" : "0"]
        if profile.usesD3D12 {
            let key = profile.appID.filter { $0.isNumber }
            let shaderCache = supportRoot.appendingPathComponent("ShaderCache/" + (key.isEmpty ? "local" : key))
            try? fm.createDirectory(at: shaderCache, withIntermediateDirectories: true)
            overrides.merge([
                "WINEDLLOVERRIDES": "d3d12,d3d12core,dxgi=n,b;d3d11,d3d10core,winemetal=builtin",
                "VK_ICD_FILENAMES": d3d12RuntimeRoot.appendingPathComponent("MoltenVK_icd.json").path,
                "DYLD_LIBRARY_PATH": d3d12RuntimeRoot.path,
                "DYLD_FALLBACK_LIBRARY_PATH": d3d12RuntimeRoot.path,
                "MVK_PRESENT_MODE": "1",
                "VKMT_ALLOW_NON_SINGLE_TEXEL_ALIGNMENT": "1",
                "VKD3D_SHADER_CACHE_PATH": shaderCache.path,
                "WINE_DO_NOT_CREATE_DXGI_DEVICE_MANAGER": "0"
            ], uniquingKeysWith: { _, new in new })
        }
        return overrides
    }

    private func processDiagnosticURL(in bottle: Bottle) -> URL {
        logsRoot.appendingPathComponent("wine-\(bottle.id.uuidString)-\(UUID().uuidString).log")
    }

    private func isSteamExecutable(_ executable: URL) -> Bool {
        executable.lastPathComponent.caseInsensitiveCompare("Steam.exe") == .orderedSame
    }

    private func launchSteam(
        _ executable: URL, arguments: [String], displayName: String, wine: URL,
        bottle: Bottle, profile: LayaGameProfile?, attempt: CompatibilityAttempt?, monitorToken: GameMonitorToken?
    ) {
        let isGame = arguments.contains("-applaunch")
        if !isGame {
            guard gameMonitors[bottle.id] == nil else {
                status = "Encerre o jogo antes de reiniciar a Steam"
                return
            }
            // Never kill every process in the prefix just to bring Steam to the foreground.
            if !wineSessionIsRunning(in: bottle) {
                sessionProfiles[bottle.id] = bottle.renderer == .dxmt
                    ? (bottle.msync ? .dxmtMSync : .dxmtStandard)
                    : (bottle.msync ? .wineD3DMSync : .wineD3DStandard)
            }
        }
        guard prepareSteamCEFCompatibility(in: bottle) else {
            gameMonitors[bottle.id] = nil
            status = "Não foi possível preparar a interface da Steam"
            return
        }
        let processLog = executable.deletingLastPathComponent().appendingPathComponent("logs/gameprocess_log.txt")
        let baseline = (try? processLog.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let log = processDiagnosticURL(in: bottle)
        status = "Abrindo \(displayName) · \(profile?.displayName ?? bottle.renderer.rawValue)…"
        runProcess(wine, args: [executable.path] + GameCompatibility.steamArguments(arguments, profile: profile?.kind),
                   bottle: bottle, environmentOverrides: profileEnvironment(profile),
                   workingDirectory: executable.deletingLastPathComponent(), logURL: log,
                   didStart: {
            if let attempt, let token = monitorToken, let index = arguments.firstIndex(of: "-applaunch"), index + 1 < arguments.count {
                self.monitorSteamGame(appID: arguments[index + 1], name: displayName, bottle: bottle,
                                      processLog: processLog, baselineSize: baseline, attempt: attempt, token: token)
            }
        }) { code in
            if isGame {
                // Steam's exit status is not the child game's exit status.
                if code != 0 && monitorToken?.isCancelled != true {
                    monitorToken?.cancel()
                    self.gameMonitors[bottle.id] = nil
                    self.status = "Steam saiu com código \(code) · consulte \(log.lastPathComponent)"
                }
            } else {
                self.status = code == 0 ? "Steam finalizado" : "Steam saiu com código \(code)"
            }
        }
        scheduleSteamBootstrapGuardRemoval(in: bottle)
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
        gameMonitors.removeValue(forKey: bottle.id)?.cancel()
        sessionProfiles[bottle.id] = nil
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
        gameMonitors.removeValue(forKey: bottle.id)?.cancel()
        sessionProfiles[bottle.id] = nil
        try? fm.removeItem(at: bottleDirectory(bottle))
        bottles.removeAll { $0.id == bottle.id }
        status = "\(bottle.name) removido"
    }
    var engineDescription: String {
        "Wine 11.8 Staging · DXMT 0.80 · D3D12 · Auto por API"
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
        env["WINEDEBUG"] = "-all,+seh,+timestamp"
        env["WINEESYNC"] = "0"
        env["WINEMSYNC"] = bottle.msync ? "1" : "0"
        env["MVK_CONFIG_RESUME_LOST_DEVICE"] = "1"
        let engineBin = engineRoot(for: bottle.renderer)
            .appendingPathComponent("Contents/Resources/wine/bin").path
        env["PATH"] = engineBin + ":" + (env["PATH"] ?? "")

        if bottle.renderer == .dxmt {
            env["WINEDLLOVERRIDES"] = "dxgi,d3d11,d3d10core,winemetal=builtin;d3d12,d3d12core="
            env["WINE_DO_NOT_CREATE_DXGI_DEVICE_MANAGER"] = "1"
        } else {
            env["WINEDLLOVERRIDES"] = "dxgi,d3d11,d3d10core,d3d9=builtin;d3d12,d3d12core="
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
        logURL: URL? = nil,
        didStart: (() -> Void)? = nil,
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
            var logHandle: FileHandle?
            if let logURL, FileManager.default.createFile(atPath: logURL.path, contents: nil) {
                logHandle = try? FileHandle(forWritingTo: logURL)
            }
            process.standardOutput = logHandle ?? FileHandle.nullDevice
            process.standardError = logHandle ?? FileHandle.nullDevice
            defer { try? logHandle?.close() }
            do {
                try process.run()
                DispatchQueue.main.async { didStart?() }
                process.waitUntilExit()
                let code = process.terminationStatus
                DispatchQueue.main.async { completion(code) }
            } catch {
                DispatchQueue.main.async {
                    self.gameMonitors.removeValue(forKey: bottle.id)?.cancel()
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
                    Label("Compatibilidade automática por jogo", systemImage: "sparkles")
                        .font(.caption)
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
                    LabeledContent(
                        "Perfil de jogo",
                        value: "Auto por API · histórico de falhas"
                    )
                    LabeledContent("Prefixo", value: bottle.id.uuidString)
                    Button("Redefinir perfis de compatibilidade") {
                        store.resetCompatibility(in: bottle)
                    }
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
                                            ? "\(app.detail) · Auto por API"
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
