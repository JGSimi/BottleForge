import Foundation
import Darwin

enum SteamClientState: Equatable {
    case running, stopped, unavailable(String)
}

enum SteamClientProbe {
    static func containsSteam(_ data: Data) -> Bool {
        let text: String
        if data.starts(with: [0xff, 0xfe]) || data.prefix(128).contains(0) {
            text = String(data: data, encoding: .utf16LittleEndian) ?? ""
        } else { text = String(decoding: data, as: UTF8.self) }
        return text.components(separatedBy: .newlines).contains { line in
            let value = line.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{feff}"))).lowercased()
            return value.hasPrefix("\"steam.exe\",\"")
        }
    }

    // tasklist runs inside this WINEPREFIX. A live wineserver or helper alone is not Steam.
    static func inspect(wine: URL, environment: [String: String], timeout: TimeInterval = 8,
                        token: GameMonitorToken) -> SteamClientState {
        if token.isCancelled { return .unavailable("verificação cancelada") }
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("bottleforge-steam-\(UUID()).log")
        guard FileManager.default.createFile(atPath: output.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: output) else { return .unavailable("não foi possível criar o diagnóstico") }
        defer { try? handle.close(); try? FileManager.default.removeItem(at: output) }
        let process = Process()
        process.executableURL = wine
        process.arguments = ["tasklist.exe", "/FO", "CSV", "/NH", "/FI", "IMAGENAME eq steam.exe"]
        process.environment = environment
        process.standardOutput = handle
        process.standardError = handle
        do { try process.run() }
        catch { return .unavailable(error.localizedDescription) }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while process.isRunning && !token.isCancelled && ProcessInfo.processInfo.systemUptime < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            // Terminate only our tasklist probe, never the Steam client or the prefix server.
            process.terminate()
            let stopDeadline = ProcessInfo.processInfo.systemUptime + 1
            while process.isRunning && ProcessInfo.processInfo.systemUptime < stopDeadline { Thread.sleep(forTimeInterval: 0.05) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
            return .unavailable(token.isCancelled ? "verificação cancelada" : "tempo limite ao consultar os processos da Steam")
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return .unavailable("consulta de processos saiu com código \(process.terminationStatus)") }
        guard let reader = try? FileHandle(forReadingFrom: output) else { return .unavailable("diagnóstico de processos indisponível") }
        defer { try? reader.close() }
        let data = (try? reader.read(upToCount: 256 * 1024)) ?? Data()
        return containsSteam(data) ? .running : .stopped
    }
}
