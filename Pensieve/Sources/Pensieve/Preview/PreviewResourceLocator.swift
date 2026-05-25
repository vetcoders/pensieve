import Foundation

/// Locates preview resources without touching SwiftPM's generated
/// `Bundle.module` accessor. That accessor traps when a manually bundled
/// release app does not mirror SwiftPM's expected bundle layout exactly.
enum PreviewResourceLocator {
    static let resourceBundleName = "Pensieve_Pensieve.bundle"

    static func css(named name: String, candidateDirectories: [URL] = defaultCandidateDirectories()) -> String? {
        let fileName = "\(name).css"
        for directory in candidateDirectories {
            let url = directory.appendingPathComponent(fileName)
            if let css = readUTF8File(at: url) {
                return css
            }
        }
        return nil
    }

    static func fallbackBaseURL(candidateDirectories: [URL] = defaultCandidateDirectories()) -> URL? {
        candidateDirectories.first { directory in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory)
                && isDirectory.boolValue
        }
    }

    static func defaultCandidateDirectories() -> [URL] {
        var directories: [URL] = [
            Bundle.main.bundleURL.appendingPathComponent(resourceBundleName)
        ]

        if let resourceURL = Bundle.main.resourceURL {
            directories.append(resourceURL.appendingPathComponent(resourceBundleName))
            directories.append(resourceURL)
        }

        directories.append(sourceResourcesURL())
        return uniqueDirectories(directories)
    }

    private static func sourceResourcesURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources")
    }

    private static func readUTF8File(at url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func uniqueDirectories(_ directories: [URL]) -> [URL] {
        var seen = Set<String>()
        return directories.filter { directory in
            seen.insert(directory.standardizedFileURL.path).inserted
        }
    }
}
