import Foundation
import CryptoKit

enum Renderer: String, CaseIterable, Codable, Identifiable {
    case dxmt = "DXMT"
    case wineD3D = "WineD3D"
    var id: String { rawValue }
    var detail: String {
        self == .dxmt ? "Direct3D 10/11 → Metal · Auto D3D12" : "Compatibilidade padrão do Wine"
    }
}

enum GraphicsAPI: String, Codable, Hashable {
    case d3d9, d3d10, d3d11, d3d12, openGL, vulkan
}

struct GameEvidence {
    enum Machine: String { case x86, x64, arm64, unknown }
    var apis: Set<GraphicsAPI> = []
    var machine: Machine = .unknown
    var isUnity = false
    var fingerprint = "unknown"
}

enum PEGameInspector {
    static func inspect(executable: URL) -> GameEvidence {
        var evidence = GameEvidence()
        var pending = [executable]
        var seen = Set<String>()
        var stamps: [String] = []
        let root = executable.deletingLastPathComponent()
        let siblings = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        let localFiles = Dictionary(siblings.map { ($0.lastPathComponent.lowercased(), $0) }, uniquingKeysWith: { first, _ in first })
        while !pending.isEmpty && seen.count < 64 {
            let file = pending.removeFirst()
            guard seen.insert(file.standardizedFileURL.path).inserted,
                  let data = try? Data(contentsOf: file, options: .mappedIfSafe),
                  let pe = PEImage(data: data) else { continue }
            if file == executable { evidence.machine = pe.machine }
            let values = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            stamps.append("\(file.path):\(values?.fileSize ?? 0):\(values?.contentModificationDate?.timeIntervalSince1970 ?? 0)")
            for name in pe.imports {
                switch name {
                case "d3d8.dll", "d3d9.dll": evidence.apis.insert(.d3d9)
                case "d3d10.dll", "d3d10_1.dll", "d3d10core.dll": evidence.apis.insert(.d3d10)
                case "d3d11.dll": evidence.apis.insert(.d3d11)
                case "d3d12.dll", "d3d12core.dll": evidence.apis.insert(.d3d12)
                case "opengl32.dll": evidence.apis.insert(.openGL)
                case "vulkan-1.dll": evidence.apis.insert(.vulkan)
                default: break
                }
                if name == "unityplayer.dll" { evidence.isUnity = true }
                // Follow engine DLLs without scanning game assets or trusting arbitrary paths.
                if !name.contains("/"), !name.contains("\\"), let dependency = localFiles[name],
                   !seen.contains(dependency.standardizedFileURL.path), !pending.contains(dependency) {
                    pending.append(dependency)
                }
            }
        }
        evidence.fingerprint = stamps.sorted().joined(separator: "|")
        return evidence
    }

    private struct PEImage {
        let data: Data
        let header: Int
        let optional: Int
        let optionalSize: Int
        let is64: Bool
        let sectionCount: Int
        var machine: GameEvidence.Machine {
            switch word(header + 4, 2) {
            case 0x14c: return .x86
            case 0x8664: return .x64
            case 0xaa64: return .arm64
            default: return .unknown
            }
        }

        init?(data: Data) {
            guard data.count >= 64, data[0] == 0x4d, data[1] == 0x5a else { return nil }
            let header = (0..<4).reduce(0) { $0 | (Int(data[0x3c + $1]) << ($1 * 8)) }
            guard header <= data.count - 24,
                  Array(data[header..<header + 4]) == [0x50, 0x45, 0, 0] else { return nil }
            self.data = data
            self.header = header
            optional = header + 24
            optionalSize = Int(data[header + 20]) | Int(data[header + 21]) << 8
            guard optionalSize >= 96, optionalSize <= data.count - optional else { return nil }
            let magic = Int(data[optional]) | Int(data[optional + 1]) << 8
            guard magic == 0x10b || magic == 0x20b else { return nil }
            is64 = magic == 0x20b
            sectionCount = Int(data[header + 6]) | Int(data[header + 7]) << 8
            guard sectionCount <= 96,
                  sectionCount * 40 <= data.count - optional - optionalSize else { return nil }
        }

        func word(_ offset: Int, _ count: Int = 4) -> UInt64 {
            guard offset >= 0, count <= data.count, offset <= data.count - count else { return 0 }
            return (0..<count).reduce(UInt64(0)) { $0 | UInt64(data[offset + $1]) << ($1 * 8) }
        }

        func offset(rva: UInt64) -> Int? {
            guard rva > 0 else { return nil }
            for index in 0..<sectionCount {
                let section = optional + optionalSize + index * 40
                let start = word(section + 12)
                let rawSize = word(section + 16)
                if rva >= start && rva - start < rawSize {
                    let location = word(section + 20) + rva - start
                    return location < UInt64(data.count) ? Int(location) : nil
                }
            }
            let headersSize = word(optional + 60)
            return rva < headersSize && rva < UInt64(data.count) ? Int(rva) : nil
        }

        var imports: [String] {
            var result: [String] = []
            let directories = optional + (is64 ? 112 : 96)
            let numberOfDirectories = word(directories - 4)
            for (index, stride, namePosition) in [(1, 20, 12), (13, 32, 4)] {
                guard UInt64(index) < numberOfDirectories,
                      directories + index * 8 + 8 <= optional + optionalSize,
                      let table = offset(rva: word(directories + index * 8)) else { continue }
                let size = Int(word(directories + index * 8 + 4))
                for entry in 0..<min(1024, size / stride) {
                    let descriptor = table + entry * stride
                    guard descriptor <= data.count - stride else { break }
                    var nameRVA = word(descriptor + namePosition)
                    if nameRVA == 0 { break }
                    if index == 13 && word(descriptor) & 1 == 0 {
                        let base = word(optional + (is64 ? 24 : 28), is64 ? 8 : 4)
                        guard nameRVA >= base else { continue }
                        nameRVA -= base
                    }
                    guard let location = offset(rva: nameRVA) else { continue }
                    let end = min(data.count, location + 260)
                    let bytes = data[location..<end].prefix(while: { $0 != 0 })
                    guard bytes.count < end - location, let name = String(data: bytes, encoding: .ascii) else { continue }
                    result.append(name.lowercased())
                }
            }
            return result
        }
    }
}

enum GameCompatibility {
    static func candidates(evidence: GameEvidence, renderer: Renderer, msync: Bool, d3d12Available: Bool) -> [LayaGameProfile.Kind] {
        guard evidence.machine != .arm64 else { return [] }
        let modern = evidence.apis.contains(.d3d10) || evidence.apis.contains(.d3d11)
        let d12 = evidence.apis.contains(.d3d12)
        if d12 && !modern {
            guard d3d12Available && evidence.machine == .x64 else { return [] }
            return msync ? [.vkd3dMSync, .vkd3dStandard] : [.vkd3dStandard, .vkd3dMSync]
        }
        let metal: [LayaGameProfile.Kind] = msync ? [.dxmtMSync, .dxmtStandard] : [.dxmtStandard, .dxmtMSync]
        let wine: [LayaGameProfile.Kind] = msync ? [.wineD3DMSync, .wineD3DStandard] : [.wineD3DStandard, .wineD3DMSync]
        // DXMT implements D3D10/11, not D3D9/OpenGL/Vulkan.
        if !modern && !evidence.apis.isEmpty { return wine }
        var profiles = renderer == .wineD3D ? wine + metal : metal + wine
        if evidence.isUnity && evidence.apis.contains(.d3d11) {
            profiles.insert(contentsOf: [.dxmtForceD3D11, .dxmtMSyncForceD3D11], at: 2)
        }
        if d12 && d3d12Available && evidence.machine == .x64 {
            profiles.insert(contentsOf: [.vkd3dStandard, .vkd3dMSync], at: 0)
        } else if evidence.apis.isEmpty && d3d12Available && evidence.machine == .x64 {
            // Some games resolve graphics DLLs dynamically instead of listing PE imports.
            profiles.append(contentsOf: [.vkd3dStandard, .vkd3dMSync])
        }
        return profiles
    }

    static func steamArguments(_ arguments: [String], profile: LayaGameProfile.Kind?) -> [String] {
        let client = ["-no-cef-sandbox", "-noverifyfiles"]
        guard let index = arguments.firstIndex(of: "-applaunch"), index + 1 < arguments.count else {
            return client + arguments
        }
        let extra = profile?.gameArguments.filter { !arguments.dropFirst(index + 2).contains($0) } ?? []
        return client + arguments + extra
    }
}

extension LayaGameProfile.Kind {
    var renderer: Renderer {
        self == .wineD3DStandard || self == .wineD3DMSync ? .wineD3D : .dxmt
    }
    var gameArguments: [String] {
        self == .dxmtForceD3D11 || self == .dxmtMSyncForceD3D11 ? ["-force-d3d11"] : []
    }
}

struct CompatibilityHistory {
    var root: URL
    private struct Record: Codable {
        var fingerprint: String
        var failed: Set<LayaGameProfile.Kind> = []
        var successful: LayaGameProfile.Kind?
    }
    func next(key: String, fingerprint: String, candidates: [LayaGameProfile.Kind]) -> LayaGameProfile.Kind? {
        let record = read(key: key, fingerprint: fingerprint)
        if let successful = record.successful, candidates.contains(successful), !record.failed.contains(successful) {
            return successful
        }
        return candidates.first { !record.failed.contains($0) }
    }
    func record(key: String, fingerprint: String, profile: LayaGameProfile.Kind, succeeded: Bool) {
        var record = read(key: key, fingerprint: fingerprint)
        if succeeded {
            record.successful = profile
            record.failed.remove(profile)
        } else {
            record.failed.insert(profile)
            if record.successful == profile { record.successful = nil }
        }
        do {
            try FileManager.default.createDirectory(at: url(key: key).deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(record).write(to: url(key: key), options: .atomic)
        } catch { NSLog("BottleForge: could not persist compatibility history: %@", error.localizedDescription) }
    }
    func reset(key: String) { try? FileManager.default.removeItem(at: url(key: key)) }
    private func read(key: String, fingerprint: String) -> Record {
        guard let data = try? Data(contentsOf: url(key: key)),
              let record = try? JSONDecoder().decode(Record.self, from: data), record.fingerprint == fingerprint else {
            return Record(fingerprint: fingerprint)
        }
        return record
    }
    private func url(key: String) -> URL {
        let safe = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        let bottle = key.split(separator: "/").first.map(String.init) ?? "local"
        let folder = UUID(uuidString: bottle)?.uuidString ?? "local"
        return root.appendingPathComponent(folder).appendingPathComponent(safe + ".json")
    }
}

struct SteamGameSession {
    let appID: String
    private(set) var started = false
    private var pids = Set<String>()
    private var failure: Int?
    init(appID: String) { self.appID = appID }
    mutating func consume(_ chunk: String) -> Int? {
        for line in chunk.components(separatedBy: .newlines) {
            let lower = line.lowercased()
            if lower.contains("crashhandler") || lower.contains("steamerrorreporter") { continue }
            let add = "AppID \(appID) adding PID "
            let remove = "AppID \(appID) no longer tracking PID "
            if let range = line.range(of: add), let pid = line[range.upperBound...].split(separator: " ").first {
                pids.insert(String(pid)); started = true
            } else if let range = line.range(of: remove) {
                let parts = line[range.upperBound...].components(separatedBy: ", exit code ")
                guard parts.count == 2, pids.remove(parts[0]) != nil,
                      let code = Int(parts[1].trimmingCharacters(in: .whitespacesAndNewlines)) else { continue }
                if code != 0 { failure = code }
            }
        }
        return started && pids.isEmpty ? (failure ?? 0) : nil
    }
}

final class GameMonitorToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }
    func cancel() {
        lock.lock(); defer { lock.unlock() }
        cancelled = true
    }
}

struct CompatibilityAttempt {
    var key: String
    var fingerprint: String
    var profile: LayaGameProfile
}

enum D3D12RuntimeInstaller {
    static func install(runtime: URL, prefix: URL) throws {
        let fm = FileManager.default
        let names = ["dxgi.dll", "d3d12.dll", "d3d12core.dll"]
        let system32 = prefix.appendingPathComponent("drive_c/windows/system32")
        let state = prefix.appendingPathComponent("BottleForgeRuntime")
        let backup = state.appendingPathComponent("original-system32")
        let transaction = state.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: system32, withIntermediateDirectories: true)
        try fm.createDirectory(at: backup, withIntermediateDirectories: true)
        try fm.createDirectory(at: transaction, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: transaction) }
        var replaced: [String] = []
        do {
            // Stage the complete runtime before changing a single prefix DLL.
            for name in names {
                try fm.copyItem(at: runtime.appendingPathComponent(name), to: transaction.appendingPathComponent(name))
                let target = system32.appendingPathComponent(name)
                var directory: ObjCBool = false
                if fm.fileExists(atPath: target.path, isDirectory: &directory), directory.boolValue {
                    throw CocoaError(.fileWriteInvalidFileName)
                }
            }
            for name in names {
                let target = system32.appendingPathComponent(name)
                let exists = (try? fm.attributesOfItem(atPath: target.path)) != nil
                if exists {
                    let original = backup.appendingPathComponent(name)
                    if (try? fm.attributesOfItem(atPath: original.path)) == nil {
                        try fm.copyItem(at: target, to: original)
                    }
                    try fm.moveItem(at: target, to: transaction.appendingPathComponent(name + ".previous"))
                }
                replaced.append(name)
                try fm.moveItem(at: transaction.appendingPathComponent(name), to: target)
            }
        } catch {
            for name in replaced.reversed() {
                let target = system32.appendingPathComponent(name)
                try? fm.removeItem(at: target)
                let previous = transaction.appendingPathComponent(name + ".previous")
                if (try? fm.attributesOfItem(atPath: previous.path)) != nil {
                    try? fm.moveItem(at: previous, to: target)
                }
            }
            throw error
        }
    }
}
