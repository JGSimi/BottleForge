import Foundation

func expect(_ value: @autoclosure () -> Bool, _ message: String) {
    if !value() { fputs("FAIL: \(message)\n", stderr); exit(1) }
}

@main
struct CompatibilityTests {
    static func main() throws {
        let d12 = GameEvidence(apis: [.d3d12], machine: .x64, isUnity: false)
        expect(GameCompatibility.candidates(evidence: d12, renderer: .dxmt, msync: false, d3d12Available: true) == [.vkd3dStandard, .vkd3dMSync], "Any D3D12 game must use VKD3D, without forcing D3D11")
        expect(GameCompatibility.candidates(evidence: d12, renderer: .dxmt, msync: false, d3d12Available: false).isEmpty, "D3D12 cannot silently launch through DXMT")
        let old = GameEvidence(apis: [.d3d9], machine: .x86, isUnity: false)
        expect(GameCompatibility.candidates(evidence: old, renderer: .dxmt, msync: false, d3d12Available: true).first == .wineD3DStandard, "D3D9 needs WineD3D")
        let mixed = GameEvidence(apis: [.d3d11, .d3d12], machine: .x64, isUnity: false)
        expect(GameCompatibility.candidates(evidence: mixed, renderer: .dxmt, msync: false, d3d12Available: true).first == .dxmtStandard, "Importing multiple APIs does not prove the game selects D3D12; preserve the requested baseline")
        expect(!GameCompatibility.candidates(evidence: mixed, renderer: .dxmt, msync: false, d3d12Available: true).contains(.dxmtForceD3D11), "Unity arguments must not be sent to arbitrary engines")
        expect(GameCompatibility.candidates(evidence: mixed, renderer: .dxmt, msync: false, d3d12Available: true, steamAppID: "1245620") == [.vkd3dStandard, .vkd3dMSync], "Elden Ring requires D3D12 even when its imports include D3D11")
        expect(GameCompatibility.candidates(evidence: GameEvidence(machine: .x64), renderer: .wineD3D, msync: true, d3d12Available: true, steamAppID: "1245620") == [.vkd3dMSync, .vkd3dStandard], "Known D3D12 games cannot fall back to an incompatible renderer when imports are absent")
        expect(GameCompatibility.candidates(evidence: mixed, renderer: .dxmt, msync: false, d3d12Available: false, steamAppID: "1245620").isEmpty, "Elden Ring must report missing D3D12 instead of launching DXMT")
        expect(GameCompatibility.candidates(evidence: GameEvidence(machine: .x86), renderer: .dxmt, msync: false, d3d12Available: true, steamAppID: "1245620").isEmpty, "Known AppID cannot override executable architecture")
        expect(GameCompatibility.candidates(evidence: mixed, renderer: .dxmt, msync: false, d3d12Available: true, steamAppID: "42").first == .dxmtStandard, "Other games preserve their mixed-API baseline")
        expect(DirectGameExit.classify(code: 0, elapsed: 1) == .unconfirmed, "A direct game closing immediately with exit zero must not be recorded as a working profile")
        expect(DirectGameExit.classify(code: 5, elapsed: 1) == .failed, "An early nonzero exit remains a confirmed process failure")
        expect(DirectGameExit.classify(code: 0, elapsed: 120) == .completed, "A longer clean session can preserve the profile")
        let args = GameCompatibility.steamArguments(["-applaunch", "42", "-windowed"], profile: .dxmtForceD3D11)
        expect(args == ["-no-cef-sandbox", "-noverifyfiles", "-applaunch", "42", "-windowed", "-force-d3d11"], "Game arguments must follow AppID")
        expect(!GameCompatibility.steamArguments([], profile: .dxmtForceD3D11).contains("-force-d3d11"), "Steam itself must not receive game arguments")
        let unknown = GameEvidence(machine: .x64)
        expect(GameCompatibility.candidates(evidence: unknown, renderer: .dxmt, msync: false, d3d12Available: true).contains(.vkd3dStandard), "An x64 game with dynamically loaded graphics DLLs can try D3D12 as a fallback")
        expect(!GameCompatibility.candidates(evidence: GameEvidence(machine: .x86), renderer: .dxmt, msync: false, d3d12Available: true).contains(.vkd3dStandard), "Unknown x86 games cannot use an x64 runtime")

        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let primary = root.appendingPathComponent("drive_c/Steam")
        let libraries = SteamLibraries.roots(primary: primary, prefix: root, vdf: #""libraryfolders" { "0" { "path" "C:\\Steam" } "1" { "path" "C:\\Games Library" } }"#)
        expect(libraries.count == 2 && libraries[1].path == root.appendingPathComponent("drive_c/Games Library").path, "Resolve escaped Windows paths in additional Steam libraries")
        let legacy = SteamLibraries.roots(primary: primary, prefix: root, vdf: #""libraryfolders" { "1" "C:\\Games Library" }"#)
        expect(legacy.count == 2, "Support legacy Steam library configuration")
        let prefix = root.appendingPathComponent("prefix")
        let runtime = root.appendingPathComponent("runtime")
        let system32 = prefix.appendingPathComponent("drive_c/windows/system32")
        try FileManager.default.createDirectory(at: runtime, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: system32, withIntermediateDirectories: true)
        for name in ["dxgi.dll", "d3d12.dll", "d3d12core.dll"] {
            try Data("original".utf8).write(to: system32.appendingPathComponent(name))
            try Data("runtime".utf8).write(to: runtime.appendingPathComponent(name))
        }
        try D3D12RuntimeInstaller.install(runtime: runtime, prefix: prefix)
        expect(try! Data(contentsOf: system32.appendingPathComponent("dxgi.dll")) == Data("runtime".utf8), "Install the selected native D3D12 runtime")
        expect(try! Data(contentsOf: prefix.appendingPathComponent("BottleForgeRuntime/original-system32/dxgi.dll")) == Data("original".utf8), "Preserve original prefix DLLs")
        try FileManager.default.removeItem(at: runtime.appendingPathComponent("d3d12core.dll"))
        do {
            try D3D12RuntimeInstaller.install(runtime: runtime, prefix: prefix)
            fatalError("Incomplete runtime must fail")
        } catch {}
        expect(try! Data(contentsOf: system32.appendingPathComponent("dxgi.dll")) == Data("runtime".utf8), "Failed staging cannot remove installed DLLs")
        let game = root.appendingPathComponent("Game.exe")
        try pe(imports: ["D3D12.dll"], delayImports: ["dxgi.dll"]).write(to: game)
        expect(PEGameInspector.inspect(executable: game).apis == [.d3d12], "Detect D3D12 from PE imports")
        try pe(imports: [], delayImports: ["D3D11.dll"]).write(to: game)
        expect(PEGameInspector.inspect(executable: game).apis == [.d3d11], "Detect delay-loaded graphics APIs")
        try pe(imports: ["UnityPlayer.dll"]).write(to: game)
        try pe(imports: ["d3d11.dll"]).write(to: root.appendingPathComponent("UnityPlayer.dll"))
        let unity = PEGameInspector.inspect(executable: game)
        expect(unity.isUnity && unity.apis.contains(.d3d11), "Follow local engine DLLs")
        expect(GameCompatibility.candidates(evidence: unity, renderer: .dxmt, msync: false, d3d12Available: true).contains(.dxmtForceD3D11), "Only detected Unity games may receive Unity flags")
        for length in 0..<256 {
            try Data(repeating: 0xff, count: length).write(to: game)
            expect(PEGameInspector.inspect(executable: game).apis.isEmpty, "Malformed files must be safe")
        }
        let valid = pe(imports: ["d3d11.dll"])
        for length in stride(from: 0, to: valid.count, by: 7) {
            try valid.prefix(length).write(to: game)
            _ = PEGameInspector.inspect(executable: game)
        }
        try pe(imports: ["d3d12.dll"], machine: 0x14c).write(to: game)
        expect(GameCompatibility.candidates(evidence: PEGameInspector.inspect(executable: game), renderer: .dxmt, msync: false, d3d12Available: true).isEmpty, "Do not install x64 VKD3D for x86 games")

        let cache = CompatibilityHistory(root: root)
        let key = "bottle/game"
        let choices: [LayaGameProfile.Kind] = [.dxmtStandard, .dxmtMSync, .wineD3DStandard]
        expect(cache.next(key: key, fingerprint: "v1", candidates: choices) == .dxmtStandard, "Baseline first")
        cache.record(key: key, fingerprint: "v1", profile: .dxmtStandard, succeeded: false)
        let reopened = CompatibilityHistory(root: root)
        expect(reopened.next(key: key, fingerprint: "v1", candidates: choices) == .dxmtMSync, "Failures persist and are not repeated")
        reopened.record(key: key, fingerprint: "v1", profile: .dxmtMSync, succeeded: true)
        expect(reopened.next(key: key, fingerprint: "v1", candidates: choices) == .dxmtMSync, "Reuse a successful profile")
        expect(reopened.next(key: "other-bottle/game", fingerprint: "v1", candidates: choices) == .dxmtStandard, "Bottles must not share failures")
        expect(reopened.next(key: key, fingerprint: "v2", candidates: choices) == .dxmtStandard, "Changed runtime/game invalidates history")
        reopened.record(key: key, fingerprint: "v1", profile: .dxmtMSync, succeeded: false)
        reopened.record(key: key, fingerprint: "v1", profile: .wineD3DStandard, succeeded: false)
        expect(reopened.next(key: key, fingerprint: "v1", candidates: choices) == nil, "Exhausted profiles must stop instead of looping")

        var monitor = SteamGameSession(appID: "42")
        expect(monitor.consume("AppID 42 adding PID 10\nAppID 42 adding PID 11\nAppID 42 no longer tracking PID 10, exit code 0\n") == nil, "Launcher exit cannot end the game session")
        expect(monitor.consume("AppID 42 no longer tracking PID 11, exit code 5\n") == 5, "Child game failure must advance fallback")
        var clean = SteamGameSession(appID: "42")
        expect(clean.consume("AppID 999 adding PID 9\nAppID 42 adding PID 20\nAppID 42 no longer tracking PID 20, exit code 0\n") == 0, "Ignore other AppIDs and record clean exit")
        print("Compatibility tests passed")
    }

    // Real PE32/PE32+ import and delay-import tables, not string matching fixtures.
    static func pe(imports: [String], delayImports: [String] = [], machine: UInt16 = 0x8664) -> Data {
        var data = Data(repeating: 0, count: 4096)
        func put(_ offset: Int, _ value: UInt32, bytes: Int = 4) {
            for i in 0..<bytes { data[offset + i] = UInt8(truncatingIfNeeded: value >> (i * 8)) }
        }
        data[0] = 0x4d; data[1] = 0x5a
        put(0x3c, 0x80); data[0x80] = 0x50; data[0x81] = 0x45
        put(0x84, UInt32(machine), bytes: 2); put(0x86, 1, bytes: 2)
        let x86 = machine == 0x14c
        let optionalSize = x86 ? 224 : 240
        put(0x94, UInt32(optionalSize), bytes: 2)
        put(0x98, x86 ? 0x10b : 0x20b, bytes: 2)
        let directory = 0x98 + (x86 ? 96 : 112)
        put(directory - 4, 16)
        put(directory + 8, 0x1000); put(directory + 12, UInt32((imports.count + 1) * 20))
        put(directory + 13 * 8, 0x1200); put(directory + 13 * 8 + 4, UInt32((delayImports.count + 1) * 32))
        let section = 0x98 + optionalSize
        put(section + 8, 0xe00); put(section + 12, 0x1000)
        put(section + 16, 0xe00); put(section + 20, 0x200)
        var nameOffset = 0x800
        for (index, name) in imports.enumerated() {
            put(0x200 + index * 20 + 12, UInt32(nameOffset - 0x200 + 0x1000))
            for (i, byte) in name.utf8.enumerated() { data[nameOffset + i] = byte }
            nameOffset += name.utf8.count + 1
        }
        for (index, name) in delayImports.enumerated() {
            put(0x400 + index * 32, 1)
            put(0x400 + index * 32 + 4, UInt32(nameOffset - 0x200 + 0x1000))
            for (i, byte) in name.utf8.enumerated() { data[nameOffset + i] = byte }
            nameOffset += name.utf8.count + 1
        }
        return data
    }
}
