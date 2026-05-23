import Darwin
import Foundation

final class FileWatcher {
    enum WatchError: LocalizedError {
        case cannotOpen(URL)

        var errorDescription: String? {
            switch self {
            case .cannotOpen(let url):
                return "Could not watch folder at \(url.path)."
            }
        }
    }

    private let queue = DispatchQueue(label: "io.vetcoders.pensieve.file-watcher", qos: .utility)
    private var source: (any DispatchSourceFileSystemObject)?
    private var pendingChange: DispatchWorkItem?

    deinit {
        stop()
    }

    func start(watching url: URL, onChange: @escaping @Sendable () -> Void) throws {
        stop()

        let fileDescriptor = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return Darwin.open(path, O_EVTONLY)
        }

        guard fileDescriptor >= 0 else {
            throw WatchError.cannotOpen(url)
        }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fileDescriptor,
            eventMask: [.write, .delete, .rename, .attrib, .extend],
            queue: queue
        )

        source.setEventHandler { [weak self] in
            self?.debounce(onChange)
        }
        source.setCancelHandler {
            Darwin.close(fileDescriptor)
        }

        self.source = source
        source.resume()
    }

    func stop() {
        pendingChange?.cancel()
        pendingChange = nil
        source?.cancel()
        source = nil
    }

    private func debounce(_ onChange: @escaping @Sendable () -> Void) {
        pendingChange?.cancel()
        let item = DispatchWorkItem {
            onChange()
        }
        pendingChange = item
        queue.asyncAfter(deadline: .now() + .milliseconds(500), execute: item)
    }
}
