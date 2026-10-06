import Foundation

@main
struct LauncherTests {
    @MainActor
    static func main() async throws {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["BOTTLEFORGE_SUPPORT_ROOT"]!)
        let resources = Bundle.main.resourceURL!
        let bottle = Bottle(id: UUID(), name: "Launcher fixture", renderer: .dxmt, msync: false, createdAt: Date())
        let directory = root.appendingPathComponent("Bottles/\(bottle.id)")
        let prefix = directory.appendingPathComponent("prefix")
        let steam = prefix.appendingPathComponent("drive_c/Program Files (x86)/Steam")
        let gameDir = steam.appendingPathComponent("steamapps/common/ELDEN RING/Game")
        let engine = resources.appendingPathComponent("Engines/wine-11.8-dxmt/bin")
        let runtime = resources.appendingPathComponent("D3D12Runtime")
        let wrapper = resources.appendingPathComponent("SteamCompat/steamwebhelper-wrapper.exe")
        try fm.createDirectory(at: gameDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: engine, withIntermediateDirectories: true)
        try fm.createDirectory(at: runtime, withIntermediateDirectories: true)
        try fm.createDirectory(at: wrapper.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(bottle).write(to: directory.appendingPathComponent("bottle.json"))
        try Data("client fixture".utf8).write(to: steam.appendingPathComponent("Steam.exe"))
        let cef = steam.appendingPathComponent("bin/cef/cef.win64")
        try fm.createDirectory(at: cef, withIntermediateDirectories: true)
        try Data("original helper".utf8).write(to: cef.appendingPathComponent("steamwebhelper_real.exe"))
        try Data("wrapper fixture".utf8).write(to: wrapper)
        for name in ["dxgi.dll", "d3d12.dll", "d3d12core.dll", "libMoltenVK.dylib", "MoltenVK_icd.json"] {
            try Data("runtime fixture".utf8).write(to: runtime.appendingPathComponent(name))
        }
        // A valid PE32+ x64 image with no graphics imports: known AppID must still select D3D12.
        var pe = Data(repeating: 0, count: 512)
        pe[0] = 0x4d; pe[1] = 0x5a; pe[0x3c] = 0x80
        pe[0x80] = 0x50; pe[0x81] = 0x45
        pe[0x84] = 0x64; pe[0x85] = 0x86; pe[0x94] = 240
        pe[0x98] = 0x0b; pe[0x99] = 0x02
        try pe.write(to: gameDir.appendingPathComponent("eldenring.exe"))
        // Disposable subprocesses model the Steam/Wine boundary; no actual game, user data or engine.
        try script("""
        #!/bin/zsh
        if [[ "$1" == tasklist.exe ]]; then
          if [[ -e "$WINEPREFIX/steam-running" ]]; then
            print '\"steam.exe\",\"42\",\"Console\",\"1\",\"10 K\"'
          fi
          exit 0
        fi
        if [[ "$1" == *Steam.exe ]]; then
          if [[ ! -e "$WINEPREFIX/fail-steam" ]]; then
            /usr/bin/touch "$WINEPREFIX/steam-running"
          fi
          print 'STEAM_CLIENT_FIXTURE'
          print "CLIENT_OVERRIDES=$WINEDLLOVERRIDES"
        else
          print 'GAME_EARLY_EXIT_FIXTURE'
          print "SteamAppId=$SteamAppId"
          print "Overrides=$WINEDLLOVERRIDES"
        fi
        exit 0
        """, at: engine.appendingPathComponent("wine"))
        try script("""
        #!/bin/zsh
        if [[ "$1" == '-w' && ( -e "$WINEPREFIX/steam-running" || -e "$WINEPREFIX/helper-running" ) ]]; then
          exec /bin/sleep 2
        fi
        exit 0
        """, at: engine.appendingPathComponent("wineserver"))
        let store = BottleStore(steamStartupTimeout: 1)
        let app = InstalledApp(id: "steam:1245620", name: "Elden Ring", detail: "Offline", icon: "",
                               executable: steam.appendingPathComponent("Steam.exe"), arguments: ["-applaunch", "1245620"],
                               gameDirectory: gameDir.deletingLastPathComponent())
        let steamApp = InstalledApp(id: "steam", name: "Steam", detail: "Launcher", icon: "",
                                    executable: steam.appendingPathComponent("Steam.exe"), arguments: [])
        store.runInstalledApp(steamApp, in: bottle)
        try await wait("Regular Steam launch", diagnostic: { store.status + "\n" + logs(root) }) {
            logs(root).contains("STEAM_CLIENT_FIXTURE") && store.status == "Steam finalizado"
        }
        store.runInstalledApp(app, in: bottle)
        try await wait("D3D12 game with regular Steam already open", diagnostic: { store.status + "\n" + logs(root) }) {
            store.status.contains("abertura não confirmada")
        }
        try fm.removeItem(at: prefix.appendingPathComponent("steam-running"))
        for file in try fm.contentsOfDirectory(at: root.appendingPathComponent("Logs"), includingPropertiesForKeys: nil) { try fm.removeItem(at: file) }
        store.runInstalledApp(app, in: bottle)
        try await wait("Steam preparation", diagnostic: { store.status + "\n" + logs(root) }) {
            logs(root).contains("STEAM_CLIENT_FIXTURE") && store.status.contains("Steam em execução")
        }
        check(!logs(root).contains("GAME_EARLY_EXIT_FIXTURE"), "Cold launch must prepare Steam before running the offline game")
        check(logs(root).contains("CLIENT_OVERRIDES=dxgi,d3d11,d3d10core,winemetal=builtin;d3d12,d3d12core="), "Steam must use its client renderer rather than the game's native D3D12 DXGI")
        check(try String(contentsOf: prefix.appendingPathComponent("drive_c/windows/system32/d3d12.dll"), encoding: .utf8) == "runtime fixture", "D3D12 must be installed before Steam starts")
        store.runInstalledApp(app, in: bottle)
        try await wait("Early game exit", diagnostic: { store.status + "\n" + logs(root) }) { store.status.contains("abertura não confirmada") }
        let output = logs(root)
        check(output.contains("GAME_EARLY_EXIT_FIXTURE") && output.contains("SteamAppId=1245620"), "After Steam preparation the correct offline game must start")
        check(output.contains("Overrides=d3d12,d3d12core,dxgi=n,b"), "Game must receive the D3D12 overrides")
        check(output.contains("Code: 0") && output.contains("Elapsed seconds:") && output.contains("Working directory:"), "Diagnostics must preserve command, timing and exit code")
        let historyFiles = (fm.enumerator(at: root.appendingPathComponent("Compatibility"), includingPropertiesForKeys: nil)?.allObjects as? [URL]) ?? []
        check(!historyFiles.contains { $0.pathExtension == "json" }, "An immediate zero exit must not persist a successful profile")
        let reopened = BottleStore(steamStartupTimeout: 1)
        reopened.runInstalledApp(app, in: bottle)
        try await wait("Reopened BottleForge with live Steam", diagnostic: { reopened.status }) { reopened.status.contains("abertura não confirmada") }
        try fm.removeItem(at: prefix.appendingPathComponent("steam-running"))
        try Data().write(to: prefix.appendingPathComponent("helper-running"))
        store.runInstalledApp(app, in: bottle)
        try await wait("Background Wine helper without Steam", diagnostic: { store.status }) { store.status.contains("Steam em execução") }
        try fm.removeItem(at: prefix.appendingPathComponent("steam-running"))
        try Data().write(to: prefix.appendingPathComponent("fail-steam"))
        store.runInstalledApp(app, in: bottle)
        try await wait("Steam exits zero without client", diagnostic: { store.status }) { store.status.contains("Steam não iniciou") }
        check(!store.status.contains("login"), "A clean launcher exit without Steam must never claim login is ready")
        try fm.removeItem(at: prefix.appendingPathComponent("fail-steam"))
        try fm.removeItem(at: cef.appendingPathComponent("steamwebhelper_real.exe"))
        store.runInstalledApp(app, in: bottle)
        try await wait("Missing Steam helper", diagnostic: { store.status + "\n" + logs(root) }) { store.status.contains("Não foi possível preparar a interface da Steam") }
        check(!store.status.contains("Steam iniciada"), "Steam preparation failure must not be overwritten by a success message")
        check(SteamClientProbe.containsSteam(Data("\"Steam.exe\",\"42\",\"Console\"\r\n".utf8)), "Parse actual CSV process names case-insensitively")
        check(SteamClientProbe.containsSteam("\"steam.exe\",\"42\"".data(using: .utf16LittleEndian)!), "Accept Wine's UTF-16 redirected output")
        check(!SteamClientProbe.containsSteam(Data("\"steamwebhelper.exe\",\"42\"\nerror: steam.exe not found".utf8)), "A helper or error mentioning Steam cannot establish readiness")
        let hungProbe = root.appendingPathComponent("hung-probe")
        try script("#!/bin/zsh\nexec /bin/sleep 30\n", at: hungProbe)
        let start = ProcessInfo.processInfo.systemUptime
        let timedOut = SteamClientProbe.inspect(wine: hungProbe, environment: [:], timeout: 0.1, token: GameMonitorToken())
        if case .unavailable(let reason) = timedOut { check(reason.contains("tempo limite"), "Report a stalled process probe") }
        else { fatalError("A stalled probe cannot establish Steam readiness") }
        check(ProcessInfo.processInfo.systemUptime - start < 3, "Probe timeout must terminate and reap only its own subprocess promptly")
        let cancelled = GameMonitorToken()
        cancelled.cancel()
        check(SteamClientProbe.inspect(wine: hungProbe, environment: [:], token: cancelled) == .unavailable("verificação cancelada"), "Cancelled attempts must not start another probe")
        let diagnostics = root.appendingPathComponent("Diagnostic fixtures")
        try fm.createDirectory(at: diagnostics, withIntermediateDirectories: true)
        let oldSteamLog = diagnostics.appendingPathComponent("wine-\(bottle.id)-steam.log")
        let gameLog = diagnostics.appendingPathComponent("wine-\(bottle.id)-game.log")
        try Data("Steam log".utf8).write(to: oldSteamLog)
        try fm.setAttributes([.creationDate: Date(timeIntervalSinceNow: -60)], ofItemAtPath: oldSteamLog.path)
        try Data("Unhandled exception: GAME_DIAGNOSTIC".utf8).write(to: gameLog)
        try fm.setAttributes([.modificationDate: Date(timeIntervalSinceNow: 60)], ofItemAtPath: oldSteamLog.path)
        let unrelated = diagnostics.appendingPathComponent("wine-\(UUID())-other.log")
        try Data("Other bottle".utf8).write(to: unrelated)
        let symlink = diagnostics.appendingPathComponent("wine-\(bottle.id)-symlink.log")
        try fm.createSymbolicLink(at: symlink, withDestinationURL: unrelated)
        let latestDiagnostic = ExecutionDiagnostics.latestLog(in: diagnostics, bottleID: bottle.id)
        check(latestDiagnostic?.resolvingSymlinksInPath() == gameLog.resolvingSymlinksInPath(), "Export the latest launch in the selected bottle, ignoring live writes to older Steam logs and symlinks")
        let report = try ExecutionDiagnostics.report(log: gameLog, release: "v0.1.15-alpha", bottleDescription: "Fixture")
        check(report.contains("GAME_DIAGNOSTIC") && report.contains("macOS:") && report.contains("Mac:") && report.contains("v0.1.15-alpha"), "Export actual error and system details")
        try (Data(repeating: 65, count: ExecutionDiagnostics.maximumLogBytes + 100) + Data("CRASH_AT_END".utf8)).write(to: gameLog)
        let bounded = try ExecutionDiagnostics.report(log: gameLog, release: "test", bottleDescription: "Fixture")
        check(bounded.contains("Log truncado") && bounded.hasSuffix("CRASH_AT_END"), "Bound large logs while preserving the crash at the end")
        check(try ExecutionDiagnostics.report(log: nil, release: "test", bottleDescription: "Fixture").contains("Nenhum log"), "Explain an empty log directory")
        print("Launcher subprocess tests passed")
    }

    static func script(_ text: String, at url: URL) throws {
        try text.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }
    static func logs(_ root: URL) -> String {
        let files = (try? FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("Logs"), includingPropertiesForKeys: nil)) ?? []
        return files.compactMap { try? String(contentsOf: $0, encoding: .utf8) }.joined(separator: "\n")
    }
    @MainActor
    static func wait(_ name: String, diagnostic: () -> String, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(10)
        while !condition() {
            if Date() > deadline { fatalError("\(name): launcher did not reach the expected state: \(diagnostic())") }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }
    static func check(_ condition: Bool, _ message: String) {
        if !condition { fatalError(message) }
    }
}
