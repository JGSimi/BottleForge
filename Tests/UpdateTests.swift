import Foundation
import AppKit

func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fputs("FAIL: \(message)\n", stderr); exit(1) }
}

@main
struct UpdateTests {
    @MainActor static func main() async throws {
        let args = CommandLine.arguments
        if args.count == 7, args[1] == "--emit-installer", let pid = Int32(args[2]) {
            print(UpdateInstaller.script(currentPID: pid, dmg: URL(fileURLWithPath: args[3]),
                                         target: URL(fileURLWithPath: args[4]), releaseTag: args[5], stateRoot: URL(fileURLWithPath: args[6])))
            return
        }
        check(ReleaseVersion("") == nil, "Empty tags must not crash")
        check(ReleaseVersion("v0.bad.11") == nil, "Malformed versions must not be accepted")
        check(ReleaseVersion("v0.1.12-") == nil && ReleaseVersion("v0.1.12+") == nil, "Empty prerelease/build identifiers must be invalid")
        check(ReleaseVersion("v0.1.12-alpha.2")! < ReleaseVersion("v0.1.12-alpha.10")!, "Numeric prerelease identifiers must compare numerically")
        check(ReleaseVersion("v0.1.12-rc.1")! < ReleaseVersion("v0.1.12")!, "Stable releases outrank prereleases")
        check(ReleaseVersion("v0.1.12+build.9")! == ReleaseVersion("v0.1.12+build.1")!, "Build metadata must not change precedence")
        let releases = Data("""
        [
          {"tag_name":"v0.1.12-alpha", "name":"next", "draft":false,"prerelease":true,"assets":[{"name":"BottleForge-v0.1.12-alpha-macOS.dmg","state":"uploaded","size":4,"digest":null,"browser_download_url":"https://github.com/JGSimi/BottleForge/releases/download/v0.1.12-alpha/BottleForge-v0.1.12-alpha-macOS.dmg"},{"name":"SHA256SUMS.txt","state":"uploaded","size":100,"browser_download_url":"https://github.com/JGSimi/BottleForge/releases/download/v0.1.12-alpha/SHA256SUMS.txt"}]},
          {"tag_name":"v0.1.13-alpha", "draft":true,"prerelease":true,"assets":[]},
          {"tag_name":"v0.1.14-alpha", "draft":false,"prerelease":true,"assets":[{"name":"BottleForge-wrong-version-macOS.dmg","state":"uploaded","size":4,"browser_download_url":"https://github.com/JGSimi/BottleForge/releases/download/v0.1.14-alpha/wrong.dmg"}]}
        ]
        """.utf8)
        let selected = try UpdateReleaseSelector.latest(data: releases, currentTag: "v0.1.11-alpha")
        check(selected?.tag == "v0.1.12-alpha", "Only complete, correctly named releases must be selected")
        check(selected?.checksumURL != nil, "Missing GitHub digests must use the published checksum manifest")
        check(try! UpdateReleaseSelector.latest(data: releases, currentTag: "v0.1.11") == nil, "Stable builds must not install prereleases")
        check(try! UpdateReleaseSelector.latest(data: releases, currentTag: "v0.1.12-alpha") == nil, "Main branch merges do not create newer release versions")

        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("payload.dmg")
        try Data("test".utf8).write(to: file)
        let hash = "9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08"
        try UpdateIntegrity.verify(file: file, expectedHash: hash, expectedSize: 4)
        do {
            try UpdateIntegrity.verify(file: file, expectedHash: String(repeating: "0", count: 64), expectedSize: 4)
            fatalError("Wrong checksums must fail")
        } catch {}
        do {
            try UpdateIntegrity.verify(file: file, expectedHash: hash, expectedSize: 5)
            fatalError("Truncated downloads must fail")
        } catch {}
        check(UpdateIntegrity.manifestHash("\(hash)  BottleForge-v0.1.12-alpha-macOS.dmg\n", assetName: "BottleForge-v0.1.12-alpha-macOS.dmg") == hash, "Read published SHA256SUMS format")
        check(UpdateIntegrity.manifestHash("\(hash)  another.dmg\n", assetName: "payload.dmg") == nil, "Do not accept a checksum belonging to another asset")
        check(UpdateIntegrity.digestHash("sha256:garbage") == nil, "Reject malformed digests")

        let target = root.appendingPathComponent("BottleForge.app")
        try FileManager.default.createDirectory(at: target.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        let plist: [String: String] = ["CFBundleIdentifier": "app.bottleforge.BottleForge", "CFBundleVersion": "1", "CFBundleShortVersionString": "0.1.11", "BottleForgeReleaseTag": "v0.1.11-alpha"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: target.appendingPathComponent("Contents/Info.plist"))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [UpdateProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        UpdateProtocol.reply = (503, Data())
        let manager = UpdateManager(session: session, bundle: Bundle(url: target)!, updateRoot: root.appendingPathComponent("state"))
        await manager.checkForUpdates(silent: true)?.value
        check(manager.errorMessage != nil && !manager.isChecking, "Automatic check failures must remain visible to manual checks")
        UpdateProtocol.reply = (200, releases)
        await manager.checkForUpdates()?.value
        check(manager.availableUpdate?.tag == "v0.1.12-alpha" && manager.errorMessage == nil, "Manual retry must recover and clear a stale error")
        UpdateProtocol.reply = (200, Data("checksum unavailable".utf8))
        await manager.installAvailableUpdate()?.value
        check(manager.errorMessage?.contains("SHA-256") == true && !manager.isDownloading, "Installation must refuse downloads with unavailable integrity data and recover its busy state")
        check(FileManager.default.fileExists(atPath: target.appendingPathComponent("Contents/Info.plist").path), "A failed checksum lookup must preserve the installed app")
        UpdateProtocol.reply = (200, Data("[]".utf8))
        await manager.checkForUpdates()?.value
        check(manager.availableUpdate == nil && manager.statusMessage?.contains("mais recente") == true, "No newer release must report an explicit up-to-date status")
        let script = UpdateInstaller.script(currentPID: 999999, dmg: file, target: target, releaseTag: "v0.1.12-alpha", stateRoot: root.appendingPathComponent("state"))
        try script.write(to: root.appendingPathComponent("installer.sh"), atomically: true, encoding: .utf8)
        let syntax = Process()
        syntax.executableURL = URL(fileURLWithPath: "/bin/zsh")
        syntax.arguments = ["-n", root.appendingPathComponent("installer.sh").path]
        try syntax.run(); syntax.waitUntilExit()
        check(syntax.terminationStatus == 0, "Installer shell must be valid")
        print("Update policy, integrity and check-state tests passed")
    }
}

final class UpdateProtocol: URLProtocol {
    static var reply = (200, Data())
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (status, data) = Self.reply
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
