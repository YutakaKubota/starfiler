import Foundation
import OSLog

private let logger = Logger(subsystem: "com.nilone.starfiler.sync", category: "FSEvents")

// MARK: - Protocol

protocol FileChangeDetecting: Sendable {
    func startMonitoring(rootURL: URL) async
    func stopMonitoring() async
    func addToIgnoreSet(_ relativePath: String) async
    func removeFromIgnoreSet(_ relativePath: String) async
    var changeEvents: AsyncStream<FileChangeEvent> { get }
}

// MARK: - FSEvents Change Detection Service

actor FSEventsChangeDetectionService: FileChangeDetecting {
    private var streamRef: FSEventStreamRef?
    private var rootURL: URL?
    private var ignoreSet: Set<String> = []
    private var debounceInterval: TimeInterval
    private var lastEventID: FSEventStreamEventId = FSEventStreamEventId(kFSEventStreamEventIdSinceNow)
    private var pendingChanges: [String: FileChangeEvent] = [:]
    private var debounceTask: Task<Void, Never>?

    private var eventContinuation: AsyncStream<FileChangeEvent>.Continuation?
    nonisolated let changeEvents: AsyncStream<FileChangeEvent>

    init(debounceInterval: TimeInterval = 1.0) {
        self.debounceInterval = debounceInterval

        var continuation: AsyncStream<FileChangeEvent>.Continuation!
        self.changeEvents = AsyncStream { c in
            continuation = c
        }
        Task { await self.storeContinuation(continuation) }
    }

    private func storeContinuation(_ continuation: AsyncStream<FileChangeEvent>.Continuation) {
        self.eventContinuation = continuation
    }

    func startMonitoring(rootURL: URL) async {
        await stopMonitoring()

        self.rootURL = rootURL.standardizedFileURL
        let path = rootURL.path as CFString

        let pathsToWatch = [path] as CFArray
        let latency: CFTimeInterval = 0.5

        var context = FSEventStreamContext()
        let unmanaged = Unmanaged.passUnretained(self)
        context.info = unmanaged.toOpaque()

        guard let stream = FSEventStreamCreate(
            nil,
            fsEventsCallback,
            &context,
            pathsToWatch,
            lastEventID,
            latency,
            FSEventStreamCreateFlags(
                kFSEventStreamCreateFlagFileEvents |
                kFSEventStreamCreateFlagUseCFTypes |
                kFSEventStreamCreateFlagNoDefer
            )
        ) else {
            logger.error("Failed to create FSEventStream")
            return
        }

        streamRef = stream
        FSEventStreamSetDispatchQueue(stream, DispatchQueue.global(qos: .userInitiated))
        FSEventStreamStart(stream)
        logger.info("Started FSEvents monitoring at \(rootURL.path, privacy: .public)")
    }

    func stopMonitoring() async {
        debounceTask?.cancel()
        debounceTask = nil

        if let stream = streamRef {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            streamRef = nil
        }

        pendingChanges.removeAll()
        logger.info("Stopped FSEvents monitoring")
    }

    func addToIgnoreSet(_ relativePath: String) async {
        ignoreSet.insert(relativePath)
    }

    func removeFromIgnoreSet(_ relativePath: String) async {
        ignoreSet.remove(relativePath)
    }

    // MARK: - Internal: called from C callback

    func handleFSEvents(paths: [String], flags: [FSEventStreamEventFlags], ids: [FSEventStreamEventId]) {
        guard let rootURL else { return }
        let rootPath = rootURL.path

        for i in 0..<paths.count {
            let fullPath = paths[i]
            let eventFlags = flags[i]

            if ids[i] > lastEventID {
                lastEventID = ids[i]
            }

            // Must scan subdirs — queue a full rescan event
            if eventFlags & UInt32(kFSEventStreamEventFlagMustScanSubDirs) != 0 {
                let event = FileChangeEvent(
                    relativePath: "",
                    changeType: .modified,
                    metadata: FileChangeMetadata(isDirectory: true, size: nil, contentModificationDate: nil, contentHash: nil)
                )
                eventContinuation?.yield(event)
                continue
            }

            guard fullPath.hasPrefix(rootPath) else { continue }

            var relativePath = String(fullPath.dropFirst(rootPath.count))
            if relativePath.hasPrefix("/") {
                relativePath = String(relativePath.dropFirst())
            }

            guard !relativePath.isEmpty else { continue }
            guard !ignoreSet.contains(relativePath) else { continue }

            let changeType = determineChangeType(flags: eventFlags)
            let isDirectory = eventFlags & UInt32(kFSEventStreamEventFlagItemIsDir) != 0
            let metadata = gatherMetadata(fullPath: fullPath, isDirectory: isDirectory)

            let event = FileChangeEvent(
                relativePath: relativePath,
                changeType: changeType,
                metadata: metadata
            )

            pendingChanges[relativePath] = event
        }

        scheduleDebouncedFlush()
    }

    // MARK: - Private

    private func determineChangeType(flags: FSEventStreamEventFlags) -> FileChangeType {
        if flags & UInt32(kFSEventStreamEventFlagItemRemoved) != 0 {
            return .deleted
        }
        if flags & UInt32(kFSEventStreamEventFlagItemRenamed) != 0 {
            return .renamed
        }
        if flags & UInt32(kFSEventStreamEventFlagItemCreated) != 0 {
            return .created
        }
        return .modified
    }

    private func gatherMetadata(fullPath: String, isDirectory: Bool) -> FileChangeMetadata {
        let url = URL(fileURLWithPath: fullPath)
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        let values = try? url.resourceValues(forKeys: Set(keys))

        return FileChangeMetadata(
            isDirectory: isDirectory,
            size: values?.fileSize.map(Int64.init),
            contentModificationDate: values?.contentModificationDate,
            contentHash: nil
        )
    }

    private func scheduleDebouncedFlush() {
        debounceTask?.cancel()
        let interval = debounceInterval
        debounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            await self.flushPendingChanges()
        }
    }

    private func flushPendingChanges() {
        let changes = pendingChanges
        pendingChanges.removeAll()

        for (_, event) in changes {
            eventContinuation?.yield(event)
        }
    }
}

// MARK: - C Callback

private func fsEventsCallback(
    streamRef: ConstFSEventStreamRef,
    clientCallBackInfo: UnsafeMutableRawPointer?,
    numEvents: Int,
    eventPaths: UnsafeMutableRawPointer,
    eventFlags: UnsafePointer<FSEventStreamEventFlags>,
    eventIds: UnsafePointer<FSEventStreamEventId>
) {
    guard let clientCallBackInfo else { return }

    let service = Unmanaged<FSEventsChangeDetectionService>.fromOpaque(clientCallBackInfo).takeUnretainedValue()

    let cfPaths = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue()
    var paths: [String] = []
    for i in 0..<numEvents {
        if let path = unsafeBitCast(CFArrayGetValueAtIndex(cfPaths, i), to: CFString?.self) as String? {
            paths.append(path)
        }
    }

    let flagsArray = Array(UnsafeBufferPointer(start: eventFlags, count: numEvents))
    let idsArray = Array(UnsafeBufferPointer(start: eventIds, count: numEvents))

    Task {
        await service.handleFSEvents(paths: paths, flags: flagsArray, ids: idsArray)
    }
}
