import Foundation
import Darwin

struct LayaGameProfile: Codable, Hashable {
    enum Kind: String, Codable {
        case dxmtStandard = "dxmt_standard"
        case dxmtMSync = "dxmt_msync"
        case dxmtForceD3D11 = "dxmt_force_d3d11"
        case dxmtMSyncForceD3D11 = "dxmt_msync_force_d3d11"
    }

    var appID: String
    var gameName: String
    var kind: Kind
    var probabilities: [String: Double]
    var confidence: Double?
    var createdAt: Date

    var msync: Bool {
        kind == .dxmtMSync || kind == .dxmtMSyncForceD3D11
    }

    var launchArguments: [String] {
        switch kind {
        case .dxmtForceD3D11, .dxmtMSyncForceD3D11:
            return ["-force-d3d11"]
        default:
            return []
        }
    }

    var displayName: String {
        switch kind {
        case .dxmtStandard: return "DXMT"
        case .dxmtMSync: return "DXMT · MSync"
        case .dxmtForceD3D11: return "DXMT · D3D11"
        case .dxmtMSyncForceD3D11: return "DXMT · MSync · D3D11"
        }
    }
}

private struct LayaDecision: Decodable {
    var profile: String
    var probabilities: [String: Double]
    var confidence: Double?
}

enum LayaProfileEngine {
    private enum ProfileError: LocalizedError {
        case runtimeMissing
        case modelNeedsSpace
        case executionFailed(Int32)
        case invalidResponse

        var errorDescription: String? {
            switch self {
            case .runtimeMissing:
                return "Runtime Laya não encontrado"
            case .modelNeedsSpace:
                return "Espaço insuficiente para baixar o modelo Laya"
            case .executionFailed(let code):
                return "Laya saiu com código \(code)"
            case .invalidResponse:
                return "Resposta inválida do Laya"
            }
        }
    }

    static func cachedProfile(appID: String, supportRoot: URL) -> LayaGameProfile? {
        let url = profileURL(appID: appID, supportRoot: supportRoot)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(LayaGameProfile.self, from: data)
    }

    static func invalidate(appID: String, supportRoot: URL) {
        try? FileManager.default.removeItem(at: profileURL(appID: appID, supportRoot: supportRoot))
    }

    static func modelIsCached(supportRoot: URL) -> Bool {
        let root = supportRoot.appendingPathComponent("AI/Laya")
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return false }

        for case let url as URL in enumerator where url.lastPathComponent == "laya.onnx.data" {
            return true
        }
        return false
    }

    static func chooseProfile(
        appID: String,
        gameName: String,
        renderer: Renderer,
        supportRoot: URL,
        projectRoot: URL
    ) throws -> LayaGameProfile {
        if !modelIsCached(supportRoot: supportRoot) {
            try ensureModelSpace(supportRoot: supportRoot)
        }

        guard let runtime = runtimeRoot(projectRoot: projectRoot) else {
            throw ProfileError.runtimeMissing
        }

        let node = runtime.appendingPathComponent("node")
        let script = runtime.appendingPathComponent("choose-profile.mjs")
        guard FileManager.default.isExecutableFile(atPath: node.path),
              FileManager.default.fileExists(atPath: script.path) else {
            throw ProfileError.runtimeMissing
        }

        let state: [String: Any] = [
            "game": gameName,
            "steamAppID": appID,
            "renderer": renderer.rawValue,
            "runtime": "Wine Staging 11.8 + DXMT 0.80",
            "macModel": hardwareModel(),
            "memoryGB": Int(ProcessInfo.processInfo.physicalMemory / 1_073_741_824),
            "architecture": "Apple Silicon",
            "goal": "maximize stable frame rate, 1% lows and frame pacing while preserving stability"
        ]
        let input = try JSONSerialization.data(withJSONObject: ["state": state])

        let process = Process()
        process.executableURL = node
        process.arguments = [script.path]
        var env = ProcessInfo.processInfo.environment
        let cache = supportRoot.appendingPathComponent("AI/Laya")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        env["LAYA_CACHE"] = cache.path
        process.environment = env

        let stdin = Pipe()
        let stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice

        try process.run()
        stdin.fileHandleForWriting.write(input)
        try? stdin.fileHandleForWriting.close()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw ProfileError.executionFailed(process.terminationStatus)
        }

        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        guard let decision = try? JSONDecoder().decode(LayaDecision.self, from: output),
              let kind = LayaGameProfile.Kind(rawValue: decision.profile) else {
            throw ProfileError.invalidResponse
        }

        let profile = LayaGameProfile(
            appID: appID,
            gameName: gameName,
            kind: kind,
            probabilities: decision.probabilities,
            confidence: decision.confidence,
            createdAt: Date()
        )
        save(profile, supportRoot: supportRoot)
        return profile
    }

    private static func save(_ profile: LayaGameProfile, supportRoot: URL) {
        let directory = supportRoot.appendingPathComponent("Profiles")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(profile) else { return }
        try? data.write(to: profileURL(appID: profile.appID, supportRoot: supportRoot), options: .atomic)
    }

    private static func profileURL(appID: String, supportRoot: URL) -> URL {
        supportRoot.appendingPathComponent("Profiles/steam-\(appID).json")
    }

    private static func runtimeRoot(projectRoot: URL) -> URL? {
        let fm = FileManager.default
        if let resources = Bundle.main.resourceURL {
            let bundled = resources.appendingPathComponent("LayaRuntime")
            if fm.fileExists(atPath: bundled.path) { return bundled }
        }

        let development = projectRoot.appendingPathComponent("Runtime/Laya")
        return fm.fileExists(atPath: development.path) ? development : nil
    }

    private static func ensureModelSpace(supportRoot: URL) throws {
        let values = try? supportRoot.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        if let bytes = values?.volumeAvailableCapacityForImportantUsage, bytes < 3_000_000_000 {
            throw ProfileError.modelNeedsSpace
        }
    }

    private static func hardwareModel() -> String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        guard size > 0 else { return "Apple Silicon Mac" }

        var buffer = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &buffer, &size, nil, 0)
        return String(cString: buffer)
    }
}
