import Foundation

enum SteamLibraries {
    static func roots(steam: URL, prefix: URL) -> [URL] {
        let primary = steam.deletingLastPathComponent()
        let config = primary.appendingPathComponent("steamapps/libraryfolders.vdf")
        guard let text = try? String(contentsOf: config, encoding: .utf8) else { return [primary] }
        return roots(primary: primary, prefix: prefix, vdf: text)
    }

    static func roots(primary: URL, prefix: URL, vdf: String) -> [URL] {
        var roots = [primary.standardizedFileURL]
        let pattern = #""(?:path|[0-9]+)"\s+"((?:\\.|[^"\\])*)""#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return roots }
        for match in regex.matches(in: vdf, range: NSRange(vdf.startIndex..., in: vdf)) {
            guard let range = Range(match.range(at: 1), in: vdf) else { continue }
            let path = String(vdf[range]).replacingOccurrences(of: #"\\"#, with: #"\"#)
            guard let url = resolve(path, prefix: prefix), !roots.contains(url.standardizedFileURL) else { continue }
            roots.append(url.standardizedFileURL)
        }
        return roots
    }

    private static func resolve(_ path: String, prefix: URL) -> URL? {
        if path.hasPrefix("/") { return URL(fileURLWithPath: path) }
        let bytes = Array(path.utf8)
        guard bytes.count >= 3, bytes[1] == 58, bytes[2] == 92 || bytes[2] == 47,
              let drive = String(bytes: bytes.prefix(1), encoding: .ascii)?.lowercased(),
              drive.range(of: #"^[a-z]$"#, options: .regularExpression) != nil else { return nil }
        var root = prefix.appendingPathComponent("dosdevices/" + drive + ":")
        if !FileManager.default.fileExists(atPath: root.path) {
            guard drive == "c" else { return nil }
            root = prefix.appendingPathComponent("drive_c")
        }
        let relative = String(path.dropFirst(3)).replacingOccurrences(of: "\\", with: "/")
        return root.resolvingSymlinksInPath().appendingPathComponent(relative)
    }
}
