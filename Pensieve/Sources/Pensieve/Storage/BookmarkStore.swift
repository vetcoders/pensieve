import Foundation

@MainActor
final class BookmarkStore {
    static let shared = BookmarkStore()

    private let defaults: UserDefaults
    private let legacyFolderBookmarkKey = "Pensieve.openFolder.bookmark"
    private let rootBookmarksKey = "Pensieve.workspace.rootBookmarks"
    private let fileBookmarksKey = "Pensieve.workspace.fileBookmarks"
    private var activeAccess: [URL: Bool] = [:]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var bookmarkData: Data? {
        rootBookmarkData.first ?? defaults.data(forKey: legacyFolderBookmarkKey)
    }

    func persist(url: URL, into appState: AppState) throws {
        try persistRoot(url: url, into: appState)
    }

    func persistRoot(url: URL, into appState: AppState) throws {
        let data = try url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        var bookmarks = rootBookmarkData
        if !bookmarks.contains(data) {
            bookmarks.append(data)
        }
        defaults.set(bookmarks, forKey: rootBookmarksKey)
        defaults.set(data, forKey: legacyFolderBookmarkKey)
        appState.bookmarkData = data
        activate(url)
    }

    func persistFile(url: URL, into appState: AppState) throws {
        let data = try url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        var bookmarks = fileBookmarkData
        if !bookmarks.contains(data) {
            bookmarks.append(data)
        }
        defaults.set(bookmarks, forKey: fileBookmarksKey)
        activate(url)
        appState.lastError = nil
    }

    func restore(into appState: AppState) -> URL? {
        guard let data = bookmarkData else {
            appState.bookmarkData = nil
            return nil
        }

        appState.bookmarkData = data
        var bookmarkIsStale = false

        do {
            let url = try URL(
                resolvingBookmarkData: data,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &bookmarkIsStale
            )

            guard isExistingDirectory(url) else {
                clear(into: appState, error: "Saved folder bookmark no longer points to an existing folder.")
                return nil
            }

            activate(url)

            if bookmarkIsStale {
                try persist(url: url, into: appState)
            }

            return url
        } catch {
            clear(into: appState, error: "Could not restore saved folder: \(error.localizedDescription)")
            return nil
        }
    }

    func restoreWorkspace(into appState: AppState) -> RestoredWorkspaceBookmarks {
        let roots = rootBookmarkData.isEmpty
            ? defaults.data(forKey: legacyFolderBookmarkKey).map { [$0] } ?? []
            : rootBookmarkData
        let files = fileBookmarkData

        appState.bookmarkData = roots.first

        let rootURLs = restoreURLs(
            from: roots,
            expectedKind: .directory,
            staleHandler: { [weak self] url, appState in
                try self?.persistRoot(url: url, into: appState)
            },
            into: appState
        )
        let fileURLs = restoreURLs(
            from: files,
            expectedKind: .file,
            staleHandler: { [weak self] url, appState in
                try self?.persistFile(url: url, into: appState)
            },
            into: appState
        )

        return RestoredWorkspaceBookmarks(rootURLs: rootURLs, fileURLs: fileURLs)
    }

    func clear(into appState: AppState, error: String? = nil) {
        stopAllAccess()
        defaults.removeObject(forKey: legacyFolderBookmarkKey)
        defaults.removeObject(forKey: rootBookmarksKey)
        defaults.removeObject(forKey: fileBookmarksKey)
        appState.bookmarkData = nil
        if let error {
            appState.lastError = error
        }
    }

    private func activate(_ url: URL) {
        if activeAccess[url] != nil {
            return
        }

        activeAccess[url] = url.startAccessingSecurityScopedResource()
    }

    private func stopAllAccess() {
        for (url, accessWasGranted) in activeAccess where accessWasGranted {
            url.stopAccessingSecurityScopedResource()
        }
        activeAccess.removeAll()
    }

    private func isExistingDirectory(_ url: URL) -> Bool {
        var isDirectory = ObjCBool(false)
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    private func isExistingFile(_ url: URL) -> Bool {
        var isDirectory = ObjCBool(false)
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && !isDirectory.boolValue
    }

    private var rootBookmarkData: [Data] {
        defaults.array(forKey: rootBookmarksKey) as? [Data] ?? []
    }

    private var fileBookmarkData: [Data] {
        defaults.array(forKey: fileBookmarksKey) as? [Data] ?? []
    }

    private enum ExpectedKind {
        case directory
        case file
    }

    private func restoreURLs(
        from bookmarks: [Data],
        expectedKind: ExpectedKind,
        staleHandler: (URL, AppState) throws -> Void,
        into appState: AppState
    ) -> [URL] {
        bookmarks.compactMap { data in
            var bookmarkIsStale = false
            do {
                let url = try URL(
                    resolvingBookmarkData: data,
                    options: [.withSecurityScope],
                    relativeTo: nil,
                    bookmarkDataIsStale: &bookmarkIsStale
                )

                let exists = expectedKind == .directory
                    ? isExistingDirectory(url)
                    : isExistingFile(url)
                guard exists else {
                    return nil
                }

                activate(url)

                if bookmarkIsStale {
                    try staleHandler(url, appState)
                }

                return url
            } catch {
                appState.lastError = "Could not restore saved workspace item: \(error.localizedDescription)"
                return nil
            }
        }
    }
}

struct RestoredWorkspaceBookmarks {
    var rootURLs: [URL]
    var fileURLs: [URL]
}
