import Foundation
import CryptoKit

struct UpdateRelease: Identifiable, Equatable {
    let tag: String
    let title: String
    let notes: String
    let assetURL: URL
    let assetName: String
    let assetDigest: String?
    let assetSize: Int64
    let checksumURL: URL?
    var id: String { tag }
}

struct ReleaseVersion: Comparable {
    private let core: [Int]
    let prerelease: [String]

    init?(_ raw: String) {
        let tag = raw.hasPrefix("v") ? String(raw.dropFirst()) : raw
        let metadata = tag.split(separator: "+", omittingEmptySubsequences: false)
        guard metadata.count <= 2 else { return nil }
        if metadata.count == 2, !Self.validIdentifiers(String(metadata[1]), numericLeadingZeros: true) { return nil }
        let pieces = metadata[0].split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let numbers = pieces[0].split(separator: ".", omittingEmptySubsequences: false)
        guard numbers.count == 3,
              numbers.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy { 48...57 ~= $0 } && ($0.count == 1 || $0.first != "0") }),
              numbers.allSatisfy({ Int($0) != nil }) else { return nil }
        core = numbers.compactMap { Int($0) }
        if pieces.count == 2 {
            guard Self.validIdentifiers(String(pieces[1]), numericLeadingZeros: false) else { return nil }
            prerelease = pieces[1].split(separator: ".").map(String.init)
        } else { prerelease = [] }
    }

    private static func validIdentifiers(_ value: String, numericLeadingZeros: Bool) -> Bool {
        value.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { part in
            guard !part.isEmpty, part.utf8.allSatisfy({ 48...57 ~= $0 || 65...90 ~= $0 || 97...122 ~= $0 || $0 == 45 }) else { return false }
            return numericLeadingZeros || !part.utf8.allSatisfy { 48...57 ~= $0 } || part.count == 1 || part.first != "0"
        }
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.core != rhs.core { return lhs.core.lexicographicallyPrecedes(rhs.core) }
        if lhs.prerelease.isEmpty || rhs.prerelease.isEmpty { return !lhs.prerelease.isEmpty && rhs.prerelease.isEmpty }
        for (left, right) in zip(lhs.prerelease, rhs.prerelease) where left != right {
            let ln = left.utf8.allSatisfy { 48...57 ~= $0 }
            let rn = right.utf8.allSatisfy { 48...57 ~= $0 }
            if ln && rn { return left.count == right.count ? left < right : left.count < right.count }
            if ln != rn { return ln }
            return left < right
        }
        return lhs.prerelease.count < rhs.prerelease.count
    }
}

enum UpdateReleaseSelector {
    private struct Release: Decodable {
        var tag_name: String
        var name: String?
        var body: String?
        var draft: Bool
        var prerelease: Bool
        var assets: [Asset]
    }
    private struct Asset: Decodable {
        var name: String
        var state: String
        var browser_download_url: URL
        var digest: String?
        var size: Int64
    }
    static func latest(data: Data, currentTag: String) throws -> UpdateRelease? {
        guard let current = ReleaseVersion(currentTag) else { throw UpdateError.invalidCurrentVersion }
        let releases = try JSONDecoder().decode([Release].self, from: data)
        return releases.compactMap { release -> (ReleaseVersion, UpdateRelease)? in
            guard !release.draft, let version = ReleaseVersion(release.tag_name), version > current else { return nil }
            if current.prerelease.isEmpty && (release.prerelease || !version.prerelease.isEmpty) { return nil }
            let name = "BottleForge-\(release.tag_name)-macOS.dmg"
            guard let asset = release.assets.first(where: { $0.name == name && $0.state == "uploaded" && $0.size > 0 }),
                  officialAsset(asset.browser_download_url, tag: release.tag_name) else { return nil }
            let checksum = release.assets.first { $0.name == "SHA256SUMS.txt" && $0.state == "uploaded" }
            let checksumURL = checksum.flatMap { officialAsset($0.browser_download_url, tag: release.tag_name) ? $0.browser_download_url : nil }
            return (version, UpdateRelease(tag: release.tag_name, title: release.name ?? "BottleForge \(release.tag_name)",
                                          notes: release.body ?? "", assetURL: asset.browser_download_url,
                                          assetName: asset.name, assetDigest: asset.digest, assetSize: asset.size,
                                          checksumURL: checksumURL))
        }.max(by: { $0.0 < $1.0 })?.1
    }
    private static func officialAsset(_ url: URL, tag: String) -> Bool {
        url.scheme == "https" && url.host == "github.com" && url.path.hasPrefix("/JGSimi/BottleForge/releases/download/\(tag)/")
    }
}

enum UpdateIntegrity {
    static func digestHash(_ digest: String?) -> String? {
        guard let digest, digest.lowercased().hasPrefix("sha256:") else { return nil }
        return validHash(String(digest.dropFirst(7)))
    }
    static func manifestHash(_ manifest: String, assetName: String) -> String? {
        let matches = manifest.components(separatedBy: .newlines).compactMap { line -> String? in
            let fields = line.split(maxSplits: 1, whereSeparator: { $0 == " " || $0 == "\t" })
            guard fields.count == 2, let hash = validHash(String(fields[0])) else { return nil }
            let filename = fields[1].trimmingCharacters(in: .whitespaces)
            guard filename == assetName || filename == "*" + assetName else { return nil }
            return hash
        }
        return matches.count == 1 ? matches[0] : nil
    }
    private static func validHash(_ value: String) -> String? {
        let hash = value.lowercased()
        return hash.utf8.count == 64 && hash.utf8.allSatisfy { 48...57 ~= $0 || 97...102 ~= $0 } ? hash : nil
    }
    static func verify(file: URL, expectedHash: String, expectedSize: Int64) throws {
        let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize
        guard size.map(Int64.init) == expectedSize else { throw UpdateError.sizeMismatch }
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 4 * 1024 * 1024), !data.isEmpty { hasher.update(data: data) }
        let actual = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard actual == expectedHash else { throw UpdateError.hashMismatch }
    }
}

struct UpdateInstallationResult: Decodable {
    var releaseTag: String
    var code: Int
    var message: String
}

enum UpdateError: LocalizedError {
    case githubAPI(Int), invalidCurrentVersion, downloadFailed, hashMismatch, checksumUnavailable, sizeMismatch
    case applicationNotWritable, invalidApplication, installerTimedOut
    var errorDescription: String? {
        switch self {
        case .githubAPI(let code): return "o GitHub respondeu com HTTP \(code); tente novamente em alguns minutos"
        case .invalidCurrentVersion: return "esta build não contém uma versão válida; instale a distribuição oficial do BottleForge"
        case .downloadFailed: return "o download da release falhou"
        case .hashMismatch: return "o SHA-256 do arquivo não confere"
        case .checksumUnavailable: return "não foi possível obter o SHA-256 oficial desta release"
        case .sizeMismatch: return "o download está incompleto ou possui tamanho diferente do publicado"
        case .applicationNotWritable: return "mova o BottleForge para uma pasta Aplicativos com permissão de escrita antes de atualizar"
        case .invalidApplication: return "esta execução não está em um BottleForge.app instalado; copie o app do DMG para Aplicativos"
        case .installerTimedOut: return "a preparação demorou demais; consulte o log de atualização"
        }
    }
}
