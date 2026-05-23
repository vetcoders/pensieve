import Foundation
import GRDB

@MainActor
final class IndexDatabase {
    static let shared = IndexDatabase()

    private var databaseQueue: DatabaseQueue?
    private(set) var databaseURL: URL?

    private init() {}

    func open(into appState: AppState? = nil) {
        do {
            let directory = try applicationSupportDirectory()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

            let url = directory.appendingPathComponent("index.db", isDirectory: false)
            let queue = try DatabaseQueue(path: url.path)

            var migrator = DatabaseMigrator()
            migrator.registerMigration("mvp_noop") { _ in
                // SQLite is reserved for Wave 2 indexing; MVP keeps files authoritative.
            }
            try migrator.migrate(queue)

            databaseQueue = queue
            databaseURL = url
        } catch {
            let message = "Could not open VC Notes index database: \(error.localizedDescription)"
            appState?.lastError = message
            NSLog(message)
        }
    }

    private func applicationSupportDirectory() throws -> URL {
        try FileManager.default
            .url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            .appendingPathComponent("VCNotes", isDirectory: true)
    }
}
