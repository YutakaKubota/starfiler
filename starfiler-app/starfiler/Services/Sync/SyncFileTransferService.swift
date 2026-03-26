import Foundation
import CommonCrypto
import OSLog

private let logger = Logger(subsystem: "com.nilone.starfiler.sync", category: "Transfer")

// MARK: - Protocol

protocol SyncFileTransferring: Sendable {
    func sendFile(
        at localURL: URL,
        relativePath: String,
        to peerID: SyncPeerID,
        fromOffset: Int64,
        connection: any SyncConnectionManaging
    ) async throws

    func receiveFile(
        header: FileHeaderPayload,
        to localURL: URL,
        from peerID: SyncPeerID,
        connection: any SyncConnectionManaging
    ) async throws

    func computeHash(for url: URL) async throws -> String
}

// MARK: - Implementation

actor SyncFileTransferService: SyncFileTransferring {
    static let chunkSize: Int = 256 * 1024 // 256KB

    func sendFile(
        at localURL: URL,
        relativePath: String,
        to peerID: SyncPeerID,
        fromOffset: Int64,
        connection: any SyncConnectionManaging
    ) async throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: localURL.path)
        let fileSize = (attributes[.size] as? Int64) ?? 0
        let modDate = attributes[.modificationDate] as? Date
        let permissions = (attributes[.posixPermissions] as? UInt16)

        let isDirectory = (attributes[.type] as? FileAttributeType) == .typeDirectory
        if isDirectory {
            // Send directory creation header
            let header = FileHeaderPayload(
                relativePath: relativePath,
                totalSize: 0,
                contentHash: nil,
                isDirectory: true,
                contentModificationDate: modDate,
                permissions: permissions
            )
            try await connection.send(.fileHeader(header), to: peerID)

            let complete = FileCompletePayload(
                relativePath: relativePath,
                success: true,
                error: nil,
                syncVersion: 0
            )
            try await connection.send(.fileComplete(complete), to: peerID)
            return
        }

        // Compute hash for small files
        var contentHash: String? = nil
        if fileSize <= 10 * 1024 * 1024 {
            contentHash = try? await computeHash(for: localURL)
        }

        // Send header
        let header = FileHeaderPayload(
            relativePath: relativePath,
            totalSize: fileSize,
            contentHash: contentHash,
            isDirectory: false,
            contentModificationDate: modDate,
            permissions: permissions
        )
        try await connection.send(.fileHeader(header), to: peerID)

        // Send chunks
        guard let fileHandle = FileHandle(forReadingAtPath: localURL.path) else {
            throw SyncFileTransferError.cannotOpenFile(localURL.path)
        }
        defer { try? fileHandle.close() }

        if fromOffset > 0 {
            fileHandle.seek(toFileOffset: UInt64(fromOffset))
        }

        var offset = fromOffset
        while true {
            let data = fileHandle.readData(ofLength: Self.chunkSize)
            let isLast = data.count < Self.chunkSize || offset + Int64(data.count) >= fileSize

            let chunk = FileChunkPayload(
                relativePath: relativePath,
                offset: offset,
                data: data,
                isLastChunk: isLast
            )
            try await connection.send(.fileChunk(chunk), to: peerID)

            offset += Int64(data.count)

            if isLast { break }
        }

        logger.info("Sent file \(relativePath, privacy: .public) (\(fileSize) bytes)")
    }

    func receiveFile(
        header: FileHeaderPayload,
        to localURL: URL,
        from peerID: SyncPeerID,
        connection: any SyncConnectionManaging
    ) async throws {
        if header.isDirectory {
            try FileManager.default.createDirectory(at: localURL, withIntermediateDirectories: true)
            logger.info("Created directory \(header.relativePath, privacy: .public)")
            return
        }

        // Write to temp file first, then rename (atomic)
        let tempURL = localURL.deletingLastPathComponent()
            .appendingPathComponent(".starfiler-sync-\(UUID().uuidString).tmp")

        // Ensure parent directory exists
        let parentDir = localURL.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: parentDir.path) {
            try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)
        }

        FileManager.default.createFile(atPath: tempURL.path, contents: nil)
        guard let fileHandle = FileHandle(forWritingAtPath: tempURL.path) else {
            throw SyncFileTransferError.cannotCreateFile(tempURL.path)
        }

        var receivedBytes: Int64 = 0

        // The actual chunk receiving is done by the caller (SyncEngine) which
        // forwards chunks to us via writeChunk method
        // For now, this sets up the infrastructure

        try fileHandle.close()

        // Move temp to final location
        if FileManager.default.fileExists(atPath: localURL.path) {
            try FileManager.default.removeItem(at: localURL)
        }
        try FileManager.default.moveItem(at: tempURL, to: localURL)

        // Set modification date
        if let modDate = header.contentModificationDate {
            try FileManager.default.setAttributes(
                [.modificationDate: modDate],
                ofItemAtPath: localURL.path
            )
        }

        // Set permissions
        if let permissions = header.permissions {
            try FileManager.default.setAttributes(
                [.posixPermissions: permissions],
                ofItemAtPath: localURL.path
            )
        }

        logger.info("Received file \(header.relativePath, privacy: .public) (\(header.totalSize) bytes)")
    }

    func writeChunk(to tempURL: URL, chunk: FileChunkPayload) throws {
        guard let fileHandle = FileHandle(forWritingAtPath: tempURL.path) else {
            throw SyncFileTransferError.cannotOpenFile(tempURL.path)
        }
        defer { try? fileHandle.close() }

        fileHandle.seek(toFileOffset: UInt64(chunk.offset))
        fileHandle.write(chunk.data)
    }

    func finalizeTempFile(tempURL: URL, finalURL: URL, header: FileHeaderPayload) throws {
        let parentDir = finalURL.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: parentDir.path) {
            try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)
        }

        if FileManager.default.fileExists(atPath: finalURL.path) {
            try FileManager.default.removeItem(at: finalURL)
        }
        try FileManager.default.moveItem(at: tempURL, to: finalURL)

        if let modDate = header.contentModificationDate {
            try FileManager.default.setAttributes(
                [.modificationDate: modDate],
                ofItemAtPath: finalURL.path
            )
        }

        if let permissions = header.permissions {
            try FileManager.default.setAttributes(
                [.posixPermissions: permissions],
                ofItemAtPath: finalURL.path
            )
        }
    }

    func computeHash(for url: URL) async throws -> String {
        guard let fileHandle = FileHandle(forReadingAtPath: url.path) else {
            throw SyncFileTransferError.cannotOpenFile(url.path)
        }
        defer { try? fileHandle.close() }

        var context = CC_SHA256_CTX()
        CC_SHA256_Init(&context)

        while true {
            let data = fileHandle.readData(ofLength: 64 * 1024)
            if data.isEmpty { break }
            data.withUnsafeBytes { bytes in
                CC_SHA256_Update(&context, bytes.baseAddress, CC_LONG(data.count))
            }
        }

        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        CC_SHA256_Final(&digest, &context)

        return digest.map { String(format: "%02x", $0) }.joined()
    }

    func createTempFile(for relativePath: String, in rootURL: URL) -> URL {
        rootURL.appendingPathComponent(".starfiler-sync-\(UUID().uuidString).tmp")
    }
}

// MARK: - Errors

enum SyncFileTransferError: Error, Sendable, LocalizedError {
    case cannotOpenFile(String)
    case cannotCreateFile(String)
    case hashMismatch(expected: String, actual: String)
    case transferIncomplete(relativePath: String)

    var errorDescription: String? {
        switch self {
        case .cannotOpenFile(let path): return "Cannot open file: \(path)"
        case .cannotCreateFile(let path): return "Cannot create file: \(path)"
        case .hashMismatch(let expected, let actual): return "Hash mismatch: expected \(expected), got \(actual)"
        case .transferIncomplete(let path): return "Transfer incomplete: \(path)"
        }
    }
}
