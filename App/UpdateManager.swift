import Foundation
import AppKit
import Combine

@MainActor
final class UpdateManager: ObservableObject {
    @Published var availableUpdate: UpdateRelease?
    @Published var isChecking = false
    @Published var isDownloading = false
    @Published var statusMessage: String?
    @Published var errorMessage: String?
    @Published var lastInstallationResult: UpdateInstallationResult?

    private let releasesURL = URL(string: "https://api.github.com/repos/JGSimi/BottleForge/releases?per_page=100")!
    private let session: URLSession
    private let bundle: Bundle
    let updateRoot: URL
    private var lastSuccessfulCheck: Date?
    private var lastAutomaticAttempt: Date?

    init(session: URLSession = .shared, bundle: Bundle = .main, updateRoot: URL? = nil) {
        self.session = session
        self.bundle = bundle
        let override = ProcessInfo.processInfo.environment["BOTTLEFORGE_SUPPORT_ROOT"].flatMap {
            $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true).appendingPathComponent("Updates")
        }
        self.updateRoot = updateRoot ?? override ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/BottleForge/Updates")
        if let data = try? Data(contentsOf: self.updateRoot.appendingPathComponent("latest-result.plist")) {
            lastInstallationResult = try? PropertyListDecoder().decode(UpdateInstallationResult.self, from: data)
        }
    }

    var currentTag: String {
        if let tag = bundle.object(forInfoDictionaryKey: "BottleForgeReleaseTag") as? String { return tag }
        if let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String { return "v" + version }
        return "desenvolvimento"
    }

    @discardableResult
    func checkForUpdates(silent: Bool = false) -> Task<Void, Never>? {
        guard !isChecking, !isDownloading else { return nil }
        if silent {
            if let lastSuccessfulCheck, Date().timeIntervalSince(lastSuccessfulCheck) < 15 * 60 { return nil }
            if let lastAutomaticAttempt, Date().timeIntervalSince(lastAutomaticAttempt) < 60 { return nil }
            lastAutomaticAttempt = Date()
        }
        isChecking = true
        errorMessage = nil
        statusMessage = "Verificando atualizações…"
        return Task {
            defer { isChecking = false }
            do {
                let release = try await fetchLatestRelease()
                availableUpdate = release
                lastSuccessfulCheck = Date()
                statusMessage = release.map { "BottleForge \($0.tag) disponível" }
                    ?? "Você já está na versão mais recente publicada para este canal."
            } catch {
                errorMessage = "Não foi possível verificar atualizações: \(error.localizedDescription)"
                statusMessage = nil
            }
        }
    }

    @discardableResult
    func installAvailableUpdate() -> Task<Void, Never>? {
        guard let release = availableUpdate, !isDownloading, !isChecking else { return nil }
        isDownloading = true
        errorMessage = nil
        statusMessage = "Baixando \(release.tag)…"
        return Task {
            defer { isDownloading = false }
            do {
                try validateInstalledApplication()
                let dmg = try await downloadAndVerify(release)
                statusMessage = "Preparando instalação de \(release.tag)…"
                let code = try await startInstaller(dmg: dmg, release: release)
                if code != 0 {
                    loadInstallationResult()
                    errorMessage = lastInstallationResult?.message ?? "A instalação falhou (código \(code)). Consulte o log."
                    statusMessage = nil
                }
            } catch {
                errorMessage = "Falha na atualização: \(error.localizedDescription)"
                statusMessage = nil
            }
        }
    }

    func revealUpdateLogs() {
        try? FileManager.default.createDirectory(at: updateRoot, withIntermediateDirectories: true)
        NSWorkspace.shared.open(updateRoot)
    }

    private func loadInstallationResult() {
        guard let data = try? Data(contentsOf: updateRoot.appendingPathComponent("latest-result.plist")) else { return }
        lastInstallationResult = try? PropertyListDecoder().decode(UpdateInstallationResult.self, from: data)
    }

    private func fetchLatestRelease() async throws -> UpdateRelease? {
        var request = URLRequest(url: releasesURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("BottleForge/\(currentTag)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw UpdateError.githubAPI(0) }
        guard 200..<300 ~= http.statusCode else { throw UpdateError.githubAPI(http.statusCode) }
        return try UpdateReleaseSelector.latest(data: data, currentTag: currentTag)
    }

    private func expectedHash(for release: UpdateRelease) async throws -> String {
        if let hash = UpdateIntegrity.digestHash(release.assetDigest) { return hash }
        guard let url = release.checksumURL else { throw UpdateError.checksumUnavailable }
        let (data, response) = try await session.data(for: URLRequest(url: url, timeoutInterval: 30))
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode,
              data.count <= 256 * 1024, let manifest = String(data: data, encoding: .utf8),
              let hash = UpdateIntegrity.manifestHash(manifest, assetName: release.assetName) else {
            throw UpdateError.checksumUnavailable
        }
        return hash
    }

    private func downloadAndVerify(_ release: UpdateRelease) async throws -> URL {
        // Refuse to start an 800 MB download if its official integrity data is unavailable.
        let hash = try await expectedHash(for: release)
        let (temporaryURL, response) = try await session.download(for: URLRequest(url: release.assetURL, timeoutInterval: 60 * 60))
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else { throw UpdateError.downloadFailed }
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("BottleForge-\(UUID().uuidString).dmg")
        try FileManager.default.moveItem(at: temporaryURL, to: destination)
        do {
            statusMessage = "Validando download…"
            try await Task.detached {
                try UpdateIntegrity.verify(file: destination, expectedHash: hash, expectedSize: release.assetSize)
            }.value
            return destination
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    private func validateInstalledApplication() throws {
        let target = bundle.bundleURL
        guard target.pathExtension == "app",
              bundle.bundleIdentifier == "app.bottleforge.BottleForge",
              !target.standardizedFileURL.path.hasPrefix("/Volumes/") else { throw UpdateError.invalidApplication }
        guard FileManager.default.isWritableFile(atPath: target.deletingLastPathComponent().path),
              FileManager.default.isWritableFile(atPath: target.path) else { throw UpdateError.applicationNotWritable }
    }

    private func startInstaller(dmg: URL, release: UpdateRelease) async throws -> Int32 {
        let attempt = updateRoot.appendingPathComponent(UUID().uuidString)
        let scriptURL = attempt.appendingPathComponent("install.sh")
        do {
            try FileManager.default.createDirectory(at: attempt, withIntermediateDirectories: true)
            let script = UpdateInstaller.script(currentPID: ProcessInfo.processInfo.processIdentifier,
                                                dmg: dmg, target: bundle.bundleURL, releaseTag: release.tag, stateRoot: attempt)
            try script.write(to: scriptURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptURL.path)
            let logURL = attempt.appendingPathComponent("installer.log")
            guard FileManager.default.createFile(atPath: logURL.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
            let log = try FileHandle(forWritingTo: logURL)
            defer { try? log.close() }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = [scriptURL.path]
            process.standardOutput = log
            process.standardError = log
            try process.run()
            let deadline = Date().addingTimeInterval(15 * 60)
            var terminationRequested = false
            while process.isRunning {
                if !terminationRequested, FileManager.default.fileExists(atPath: attempt.appendingPathComponent("ready").path) {
                    terminationRequested = true
                    statusMessage = "Reiniciando para concluir a atualização…"
                    NSApplication.shared.terminate(nil)
                }
                if Date() > deadline {
                    process.terminate()
                    throw UpdateError.installerTimedOut
                }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            return process.terminationStatus
        } catch {
            try? FileManager.default.removeItem(at: dmg)
            throw error
        }
    }
}
