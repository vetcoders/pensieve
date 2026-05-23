import Foundation

@MainActor
final class BookmarkStore {
    static let shared = BookmarkStore()

    private let defaults: UserDefaults
    private let bookmarkKey = "Pensieve.openFolder.bookmark"
    private var activeURL: URL?
    private var activeAccessWasGranted = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var bookmarkData: Data? {
        defaults.data(forKey: bookmarkKey)
    }

    func persist(url: URL, into appState: AppState) throws {
        let data = try url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        defaults.set(data, forKey: bookmarkKey)
        appState.bookmarkData = data
        activate(url)
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

    func clear(into appState: AppState, error: String? = nil) {
        stopActiveAccess()
        defaults.removeObject(forKey: bookmarkKey)
        appState.bookmarkData = nil
        if let error {
            appState.lastError = error
        }
    }

    private func activate(_ url: URL) {
        if activeURL == url {
            return
        }

        stopActiveAccess()
        activeAccessWasGranted = url.startAccessingSecurityScopedResource()
        activeURL = url
    }

    private func stopActiveAccess() {
        if activeAccessWasGranted {
            activeURL?.stopAccessingSecurityScopedResource()
        }
        activeURL = nil
        activeAccessWasGranted = false
    }

    private func isExistingDirectory(_ url: URL) -> Bool {
        var isDirectory = ObjCBool(false)
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }
}
