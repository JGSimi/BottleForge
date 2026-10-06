import Foundation
import Darwin

enum ExecutionDiagnostics {
    static let maximumLogBytes = 2 * 1024 * 1024

    static func latestLog(in directory: URL, bottleID: UUID?) -> URL? {
        let prefix = bottleID.map { "wine-\($0.uuidString)-" } ?? "wine-"
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .creationDateKey, .contentModificationDateKey]
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys))) ?? []
        return files.compactMap { url -> (URL, Date)? in
            guard url.lastPathComponent.hasPrefix(prefix), url.pathExtension == "log",
                  let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true,
                  values.isSymbolicLink != true else { return nil }
            // An older Steam process can keep writing after the newer game has crashed.
            return (url, values.creationDate ?? values.contentModificationDate ?? .distantPast)
        }.sorted { $0.1 > $1.1 }.first?.0
    }

    static func report(log: URL?, release: String, bottleDescription: String) throws -> String {
        var modelSize = 0
        _ = sysctlbyname("hw.model", nil, &modelSize, nil, 0)
        var model = [CChar](repeating: 0, count: max(1, modelSize))
        _ = sysctlbyname("hw.model", &model, &modelSize, nil, 0)
        var output = "BottleForge: \(release)\nmacOS: \(ProcessInfo.processInfo.operatingSystemVersionString)\nMac: \(String(cString: model))\nBottle: \(bottleDescription)\nExportado em: \(ISO8601DateFormatter().string(from: Date()))\n"
        guard let log else { return output + "\nNenhum log de execução encontrado. Tente abrir o jogo e exporte novamente.\n" }
        let handle = try FileHandle(forReadingFrom: log)
        defer { try? handle.close() }
        let length = try handle.seekToEnd()
        let size = Int(min(length, UInt64(maximumLogBytes)))
        try handle.seek(toOffset: length - UInt64(size))
        let data = try handle.read(upToCount: size) ?? Data()
        output += "Log: \(log.lastPathComponent)\n"
        if length > UInt64(maximumLogBytes) { output += "Log truncado: últimas \(maximumLogBytes) bytes.\n" }
        return output + "\n--- Log de execução ---\n" + String(decoding: data, as: UTF8.self)
    }
}
