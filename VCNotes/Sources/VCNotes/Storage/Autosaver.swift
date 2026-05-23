import Foundation

@MainActor
final class Autosaver {
    static let shared = Autosaver()

    private let delayNanoseconds: UInt64
    private var task: Task<Void, Never>?

    init(delayMilliseconds: UInt64 = 500) {
        self.delayNanoseconds = delayMilliseconds * 1_000_000
    }

    func schedule(_ save: @escaping @MainActor () -> Void) {
        task?.cancel()
        task = Task { [delayNanoseconds] in
            try? await Task.sleep(nanoseconds: delayNanoseconds)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                save()
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }
}
