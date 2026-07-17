import CoreServices
import Foundation

struct FileWatcherEvent: Equatable, Sendable {
  struct Flags: OptionSet, Equatable, Sendable {
    let rawValue: UInt32

    static let mustScanSubdirectories = Self(
      rawValue: UInt32(kFSEventStreamEventFlagMustScanSubDirs))
    static let userDropped = Self(rawValue: UInt32(kFSEventStreamEventFlagUserDropped))
    static let kernelDropped = Self(rawValue: UInt32(kFSEventStreamEventFlagKernelDropped))
    static let eventIDsWrapped = Self(rawValue: UInt32(kFSEventStreamEventFlagEventIdsWrapped))
    static let rootChanged = Self(rawValue: UInt32(kFSEventStreamEventFlagRootChanged))
    static let itemIsFile = Self(rawValue: UInt32(kFSEventStreamEventFlagItemIsFile))
    static let itemCreated = Self(rawValue: UInt32(kFSEventStreamEventFlagItemCreated))
    static let itemRemoved = Self(rawValue: UInt32(kFSEventStreamEventFlagItemRemoved))
    static let itemRenamed = Self(rawValue: UInt32(kFSEventStreamEventFlagItemRenamed))
    static let itemModified = Self(rawValue: UInt32(kFSEventStreamEventFlagItemModified))

    var requiresFullReconcile: Bool {
      !intersection([
        .mustScanSubdirectories,
        .userDropped,
        .kernelDropped,
        .eventIDsWrapped,
        .rootChanged,
      ]).isEmpty
    }
  }

  let path: String
  let flags: Flags

  init(path: String, flags: Flags = []) {
    self.path = Self.canonicalPath(for: path)
    self.flags = flags
  }

  /// `resolvingSymlinksInPath()` strips the `/private` prefix only while the file still exists,
  /// but FSEvents reports removed/renamed-away items under the canonical `/private/...` form.
  /// Strip it unconditionally so live and after-deletion events of one item compare equal.
  /// Every path compared against an event (roots, self-writes) must go through this one door.
  static func canonicalPath(for path: String) -> String {
    let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    for prefix in ["/private/var/", "/private/tmp/", "/private/etc/"]
    where resolved.hasPrefix(prefix) {
      return String(resolved.dropFirst("/private".count))
    }
    return resolved
  }

  var requiresFullReconcile: Bool { flags.requiresFullReconcile }
}

protocol FileWatcherEventSource: AnyObject {
  func start(
    paths: [String],
    onEvents: @escaping @Sendable ([FileWatcherEvent]) -> Void
  ) throws
  func stop()
}

final class FileWatcher {
  typealias Event = FileWatcherEvent
  typealias SourceFactory = @Sendable () -> any FileWatcherEventSource

  enum WatchError: LocalizedError {
    case cannotOpen(URL)
    case cannotCreateStream
    case cannotStartStream

    var errorDescription: String? {
      switch self {
      case .cannotOpen(let url):
        return "Could not watch folder at \(url.path)."
      case .cannotCreateStream:
        return "Could not create the filesystem event stream."
      case .cannotStartStream:
        return "Could not start the filesystem event stream."
      }
    }
  }

  private let sourceFactory: SourceFactory
  private let stateLock = NSLock()
  private var generation: UInt64 = 0
  private var source: (any FileWatcherEventSource)?
  private(set) var watchedPaths: [String] = []

  init(sourceFactory: @escaping SourceFactory = { FSEventsFileWatcherEventSource() }) {
    self.sourceFactory = sourceFactory
  }

  deinit {
    stop()
  }

  func start(watching url: URL, onChange: @escaping @Sendable () -> Void) throws {
    try start(watching: [url]) { _ in onChange() }
  }

  func start(
    watching urls: [URL],
    onEvents: @escaping @Sendable ([Event]) -> Void
  ) throws {
    stop()

    let paths = Array(Set(urls.map { FileWatcherEvent.canonicalPath(for: $0.path) })).sorted()
    guard !paths.isEmpty else { return }
    for path in paths {
      var isDirectory: ObjCBool = false
      guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
        isDirectory.boolValue
      else {
        throw WatchError.cannotOpen(URL(fileURLWithPath: path))
      }
    }

    let nextSource = sourceFactory()
    let token: UInt64
    stateLock.lock()
    generation &+= 1
    token = generation
    source = nextSource
    watchedPaths = paths
    stateLock.unlock()

    do {
      try nextSource.start(paths: paths) { [weak self] events in
        guard let self, self.isCurrentGeneration(token) else { return }
        onEvents(events)
      }
    } catch {
      discardSource(generation: token)
      nextSource.stop()
      throw error
    }
  }

  func stop() {
    let stoppedSource: (any FileWatcherEventSource)?
    stateLock.lock()
    generation &+= 1
    stoppedSource = source
    source = nil
    watchedPaths = []
    stateLock.unlock()
    stoppedSource?.stop()
  }

  var isWatching: Bool {
    stateLock.lock()
    defer { stateLock.unlock() }
    return source != nil
  }

  private func isCurrentGeneration(_ token: UInt64) -> Bool {
    stateLock.lock()
    defer { stateLock.unlock() }
    return source != nil && generation == token
  }

  private func discardSource(generation token: UInt64) {
    stateLock.lock()
    defer { stateLock.unlock() }
    guard generation == token else { return }
    generation &+= 1
    source = nil
    watchedPaths = []
  }
}

private final class FSEventsFileWatcherEventSource: FileWatcherEventSource {
  private let queue = DispatchQueue(
    label: "io.vetcoders.pensieve.file-watcher",
    qos: .utility
  )
  private let queueKey = DispatchSpecificKey<Void>()
  private var stream: FSEventStreamRef?
  private var onEvents: (@Sendable ([FileWatcherEvent]) -> Void)?

  init() {
    queue.setSpecific(key: queueKey, value: ())
  }

  deinit {
    stop()
  }

  func start(
    paths: [String],
    onEvents: @escaping @Sendable ([FileWatcherEvent]) -> Void
  ) throws {
    try syncOnQueue {
      stopOnQueue()
      self.onEvents = onEvents

      var context = FSEventStreamContext(
        version: 0,
        info: Unmanaged.passUnretained(self).toOpaque(),
        retain: nil,
        release: nil,
        copyDescription: nil
      )
      let createFlags = FSEventStreamCreateFlags(
        kFSEventStreamCreateFlagUseCFTypes
          | kFSEventStreamCreateFlagNoDefer
          | kFSEventStreamCreateFlagWatchRoot
          | kFSEventStreamCreateFlagFileEvents
      )
      guard
        let stream = FSEventStreamCreate(
          nil,
          Self.callback,
          &context,
          paths as CFArray,
          FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
          0.05,
          createFlags
        )
      else {
        self.onEvents = nil
        throw FileWatcher.WatchError.cannotCreateStream
      }

      FSEventStreamSetDispatchQueue(stream, queue)
      guard FSEventStreamStart(stream) else {
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.onEvents = nil
        throw FileWatcher.WatchError.cannotStartStream
      }
      self.stream = stream
    }
  }

  func stop() {
    syncOnQueue { stopOnQueue() }
  }

  private func stopOnQueue() {
    guard let stream else {
      onEvents = nil
      return
    }
    FSEventStreamStop(stream)
    FSEventStreamInvalidate(stream)
    FSEventStreamRelease(stream)
    self.stream = nil
    onEvents = nil
  }

  private func deliver(
    count: Int,
    rawPaths: UnsafeMutableRawPointer,
    rawFlags: UnsafePointer<FSEventStreamEventFlags>
  ) {
    guard count > 0, let onEvents else { return }
    let pathObjects = unsafeBitCast(rawPaths, to: NSArray.self)
    let paths = pathObjects.compactMap { $0 as? String }
    let eventCount = min(count, paths.count)
    guard eventCount > 0 else { return }

    let flags = UnsafeBufferPointer(start: rawFlags, count: count)
    var events: [FileWatcherEvent] = []
    events.reserveCapacity(eventCount)
    for index in 0..<eventCount {
      events.append(
        FileWatcherEvent(
          path: paths[index],
          flags: .init(rawValue: UInt32(flags[index]))
        ))
    }
    onEvents(events)
  }

  private func syncOnQueue<T>(_ operation: () throws -> T) rethrows -> T {
    if DispatchQueue.getSpecific(key: queueKey) != nil {
      return try operation()
    }
    return try queue.sync(execute: operation)
  }

  private static let callback: FSEventStreamCallback = {
    _, clientInfo, eventCount, eventPaths, eventFlags, _ in
    guard let clientInfo else { return }
    let source = Unmanaged<FSEventsFileWatcherEventSource>
      .fromOpaque(clientInfo)
      .takeUnretainedValue()
    source.deliver(
      count: eventCount,
      rawPaths: eventPaths,
      rawFlags: eventFlags
    )
  }
}
