import Foundation
import AppKit
import CryptoKit

struct UpdateRelease: Identifiable, Equatable {
    let tag: String
    let title: String
    let notes: String
    let assetURL: URL
    let assetName: String
    let assetDigest: String?
    let assetSize: Int64

    var id: String { tag }
}

private struct GitHubRelease: Decodable {
    let tagName: String
    let name: String?
    let body: String?
    let draft: Bool
    let prerelease: Bool
    let assets: [GitHubAsset]
    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case name, body, draft, prerelease, assets
    }
}

private struct GitHubAsset: Decodable {
    let name: String
    let state: String
    let browserDownloadURL: URL
    let digest: String?
    let size: Int64

    enum CodingKeys: String, CodingKey {
        case name, state, digest, size
        case browserDownloadURL = "browser_download_url"
    }
}

private struct ReleaseVersion: Comparable {
    let major: Int
    let minor: Int
    let patch: Int
    let stageRank: Int
    let stageNumber: Int

    init?(_ rawTag: String) {
        var tag = rawTag.lowercased()
        if tag.hasPrefix("v") { tag.removeFirst() }

        let pieces = tag.split(separator: "-", maxSplits: 1).map(String.init)
        let numbers = pieces[0].split(separator: ".").compactMap { Int($0) }
        guard numbers.count >= 2 else { return nil }

        major = numbers[0]
        minor = numbers[1]
        patch = numbers.count > 2 ? numbers[2] : 0

        guard pieces.count > 1 else {
            stageRank = 4
            stageNumber = 0
            return
        }

        let stage = pieces[1]
        if stage.hasPrefix("rc") {
            stageRank = 3
        } else if stage.hasPrefix("beta") {
            stageRank = 2
        } else if stage.hasPrefix("alpha") {
            stageRank = 1
        } else {
            stageRank = 0
        }

        stageNumber = Int(stage.filter(\.isNumber)) ?? 0
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        if lhs.patch != rhs.patch { return lhs.patch < rhs.patch }
        if lhs.stageRank != rhs.stageRank { return lhs.stageRank < rhs.stageRank }
        return lhs.stageNumber < rhs.stageNumber
    }
}

@MainActor
final class UpdateManager: ObservableObject {
    @Published var availableUpdate: UpdateRelease?
    @Published var isChecking = false
    @Published var isDownloading = false
    @Published var statusMessage: String?
    @Published var errorMessage: String?

    private let releasesURL = URL(
        string: "https://api.github.com/repos/JGSimi/BottleForge/releases?per_page=20"
    )!
    private var lastAutomaticCheck: Date?

    var currentTag: String {
        Bundle.main.object(forInfoDictionaryKey: "BottleForgeReleaseTag") as? String
            ?? "v0.1.0-alpha"
    }

    func checkForUpdates(silent: Bool = false) {
        guard !isChecking else { return }

        if silent,
           let lastAutomaticCheck,
           Date().timeIntervalSince(lastAutomaticCheck) < 15 * 60 {
            return
        }

        if silent {
            lastAutomaticCheck = Date()
        }

        isChecking = true

        if !silent {
            statusMessage = "Verificando atualizações…"
            errorMessage = nil
        }

        Task {
            defer { isChecking = false }

            do {
                let release = try await fetchLatestRelease()
                if let release {
                    availableUpdate = release
                    statusMessage = "BottleForge \(release.tag) disponível"
                } else {
                    availableUpdate = nil
                    if !silent {
                        statusMessage = "Você já está na versão mais recente."
                    }
                }
            } catch {
                if !silent {
                    errorMessage = "Não foi possível verificar atualizações: \(error.localizedDescription)"
                    statusMessage = nil
                }
            }
        }
    }

    func installAvailableUpdate() {
        guard let release = availableUpdate, !isDownloading else { return }

        isDownloading = true
        errorMessage = nil
        statusMessage = "Baixando \(release.tag)…"
        Task {
            do {
                let dmg = try await downloadAndVerify(release)
                statusMessage = "Instalando \(release.tag)…"
                try startInstaller(dmg: dmg, release: release)
                NSApplication.shared.terminate(nil)
            } catch {
                isDownloading = false
                errorMessage = "Falha na atualização: \(error.localizedDescription)"
                statusMessage = nil
            }
        }
    }

    private func fetchLatestRelease() async throws -> UpdateRelease? {
        var request = URLRequest(url: releasesURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("BottleForge/\(currentTag)", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse,
              200..<300 ~= http.statusCode else {
            throw UpdateError.githubAPI
        }
        let releases = try JSONDecoder().decode([GitHubRelease].self, from: data)
        guard let currentVersion = ReleaseVersion(currentTag) else {
            throw UpdateError.invalidCurrentVersion
        }

        let acceptsPrereleases = currentTag.contains("-")

        let candidates = releases.compactMap { release -> (ReleaseVersion, UpdateRelease)? in
            guard !release.draft else { return nil }
            if !acceptsPrereleases && release.prerelease { return nil }

            guard
                let version = ReleaseVersion(release.tagName),
                version > currentVersion,
                let asset = release.assets.first(where: {
                    $0.state == "uploaded"
                        && $0.name.hasPrefix("BottleForge-")
                        && $0.name.hasSuffix("-macOS.dmg")
                })
            else { return nil }

            let update = UpdateRelease(
                tag: release.tagName,
                title: release.name ?? "BottleForge \(release.tagName)",
                notes: release.body ?? "",
                assetURL: asset.browserDownloadURL,
                assetName: asset.name,
                assetDigest: asset.digest,
                assetSize: asset.size
            )
            return (version, update)
        }

        return candidates.max(by: { $0.0 < $1.0 })?.1
    }

    private func downloadAndVerify(_ release: UpdateRelease) async throws -> URL {
        let (temporaryURL, response) = try await URLSession.shared.download(from: release.assetURL)

        guard let http = response as? HTTPURLResponse,
              200..<300 ~= http.statusCode else {
            throw UpdateError.downloadFailed
        }

        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("BottleForge-\(UUID().uuidString).dmg")

        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: temporaryURL, to: destination)

        if let expected = release.assetDigest,
           expected.lowercased().hasPrefix("sha256:") {
            statusMessage = "Validando download…"
            let expectedHash = String(expected.dropFirst("sha256:".count)).lowercased()
            let actualHash = try await Task.detached {
                try Self.sha256(of: destination)
            }.value

            guard expectedHash == actualHash else {
                try? FileManager.default.removeItem(at: destination)
                throw UpdateError.hashMismatch
            }
        }

        return destination
    }

    private func startInstaller(dmg: URL, release: UpdateRelease) throws {
        let target = Bundle.main.bundleURL
        let parent = target.deletingLastPathComponent()

        guard FileManager.default.isWritableFile(atPath: parent.path) else {
            throw UpdateError.applicationNotWritable
        }

        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("bottleforge-update-\(UUID().uuidString).sh")

        let script = Self.installerScript(
            currentPID: ProcessInfo.processInfo.processIdentifier,
            dmg: dmg,
            target: target,
            releaseTag: release.tag
        )

        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: scriptURL.path
        )

        let logURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BottleForge-update.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [scriptURL.path]

        if let handle = try? FileHandle(forWritingTo: logURL) {
            process.standardOutput = handle
            process.standardError = handle
        }

        try process.run()
    }

    nonisolated private static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }

        var hasher = SHA256()

        while true {
            let chunk = try handle.read(upToCount: 4 * 1024 * 1024) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }

        return hasher.finalize()
            .map { String(format: "%02x", $0) }
            .joined()
    }

    nonisolated private static func installerScript(
        currentPID: Int32,
        dmg: URL,
        target: URL,
        releaseTag: String
    ) -> String {
        let qDMG = shellQuote(dmg.path)
        let qTarget = shellQuote(target.path)
        let qTag = shellQuote(releaseTag)

        return """
        #!/bin/zsh
        set -euo pipefail

        PID=\(currentPID)
        DMG=\(qDMG)
        TARGET=\(qTarget)
        RELEASE_TAG=\(qTag)
        MOUNT="$(mktemp -d /tmp/BottleForgeUpdate.XXXXXX)"
        NEW="${TARGET}.update.$$"
        OLD="${TARGET}.previous.$$"

        cleanup() {
          /usr/bin/hdiutil detach "$MOUNT" -quiet 2>/dev/null || true
          /bin/rm -rf "$MOUNT" "$NEW"
          /bin/rm -f "$DMG" "$0"
        }
        trap cleanup EXIT

        while /bin/kill -0 "$PID" 2>/dev/null; do
          /bin/sleep 0.25
        done

        /usr/bin/hdiutil attach "$DMG" -nobrowse -readonly -mountpoint "$MOUNT" >/dev/null
        SOURCE="$MOUNT/BottleForge.app"
        [[ -d "$SOURCE" ]] || { echo "BottleForge.app ausente no DMG"; exit 20; }

        /bin/rm -rf "$NEW" "$OLD"
        /usr/bin/ditto "$SOURCE" "$NEW"
        /usr/bin/codesign --verify --deep --strict "$NEW"

        if [[ -e "$TARGET" ]]; then
          /bin/mv "$TARGET" "$OLD"
        fi

        if ! /bin/mv "$NEW" "$TARGET"; then
          [[ -e "$OLD" ]] && /bin/mv "$OLD" "$TARGET"
          exit 21
        fi

        /usr/bin/xattr -dr com.apple.quarantine "$TARGET" 2>/dev/null || true
        /bin/rm -rf "$OLD"
        /usr/bin/open "$TARGET"
        echo "Atualizado para $RELEASE_TAG"
        """
    }

    nonisolated private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

private enum UpdateError: LocalizedError {
    case githubAPI
    case invalidCurrentVersion
    case downloadFailed
    case hashMismatch
    case applicationNotWritable

    var errorDescription: String? {
        switch self {
        case .githubAPI:
            return "o GitHub não respondeu corretamente"
        case .invalidCurrentVersion:
            return "a versão instalada é inválida"
        case .downloadFailed:
            return "o download da release falhou"
        case .hashMismatch:
            return "o SHA-256 do arquivo não confere"
        case .applicationNotWritable:
            return "mova o BottleForge para a pasta Aplicativos antes de atualizar"
        }
    }
}
