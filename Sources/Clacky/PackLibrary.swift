import Foundation

/// Imported Mechvibes packs live in ~/Library/Application Support/Clacky/Packs/<folder>.
enum PackLibrary {
    struct Entry {
        let folder: String
        let name: String
        var sourceID: String { "pack:\(folder)" }
    }

    static var root: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Clacky/Packs", isDirectory: true)
    }

    static func folder(named name: String) -> URL {
        root.appendingPathComponent(name, isDirectory: true)
    }

    static func installed() -> [Entry] {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey],
                                                      options: [.skipsHiddenFiles]) else { return [] }
        return items.compactMap { url -> Entry? in
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true,
                  let config = PackSource.findConfig(in: url) else { return nil }
            let json = (try? Data(contentsOf: config)).flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
            let name = (json?["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? url.lastPathComponent
            return Entry(folder: url.lastPathComponent, name: name)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Copies a pack folder (or unzips a .zip) into the library and checks it loads.
    @discardableResult
    static func install(from url: URL) throws -> Entry {
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)

        let base = url.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: "[^A-Za-z0-9 _.-]", with: "-", options: .regularExpression)
        var folderName = base.isEmpty ? "pack" : base
        var n = 2
        while fm.fileExists(atPath: folder(named: folderName).path) {
            folderName = "\(base)-\(n)"
            n += 1
        }
        let dest = folder(named: folderName)

        do {
            if url.pathExtension.lowercased() == "zip" {
                let unzip = Process()
                unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
                unzip.arguments = ["-x", "-k", url.path, dest.path]
                try unzip.run()
                unzip.waitUntilExit()
                guard unzip.terminationStatus == 0 else { throw SoundPackError.badConfig("the zip couldn't be opened") }
            } else {
                try fm.copyItem(at: url, to: dest)
            }
            let pack = try PackSource(folder: dest)
            return Entry(folder: folderName, name: pack.displayName)
        } catch {
            try? fm.removeItem(at: dest)
            throw error
        }
    }

    static func remove(_ entry: Entry) {
        try? FileManager.default.trashItem(at: folder(named: entry.folder), resultingItemURL: nil)
    }
}
