import Foundation

enum SyncMessageFrameType: UInt8, Sendable {
    case json = 0x01
    case binary = 0x02
}

enum SyncMessageCodecError: Error, Sendable {
    case insufficientData
    case unknownFrameType(UInt8)
    case decodingFailed(String)
    case encodingFailed(String)
    case frameTooLarge(Int)
}

struct SyncMessageCodec: Sendable {
    static let maxFrameSize: Int = 64 * 1024 * 1024 // 64MB max frame

    // Frame format: [1 byte type][4 bytes length (big-endian)][payload]
    static let headerSize = 5

    func encode(_ message: SyncMessage) throws -> Data {
        switch message {
        case .fileChunk(let payload):
            return try encodeBinaryChunk(payload)
        default:
            return try encodeJSON(message)
        }
    }

    func decode(from data: Data) throws -> SyncMessage {
        guard data.count >= SyncMessageCodec.headerSize else {
            throw SyncMessageCodecError.insufficientData
        }

        let frameType = data[data.startIndex]
        guard let type = SyncMessageFrameType(rawValue: frameType) else {
            throw SyncMessageCodecError.unknownFrameType(frameType)
        }

        let payloadLength = data.withUnsafeBytes { bytes -> UInt32 in
            let offset = bytes.baseAddress!.advanced(by: 1)
            return offset.loadUnaligned(as: UInt32.self).bigEndian
        }

        let totalLength = SyncMessageCodec.headerSize + Int(payloadLength)
        guard data.count >= totalLength else {
            throw SyncMessageCodecError.insufficientData
        }

        let payloadData = data[data.startIndex.advanced(by: SyncMessageCodec.headerSize)..<data.startIndex.advanced(by: totalLength)]

        switch type {
        case .json:
            return try decodeJSON(Data(payloadData))
        case .binary:
            return try decodeBinaryChunk(Data(payloadData))
        }
    }

    func extractFrameLength(from data: Data) -> Int? {
        guard data.count >= SyncMessageCodec.headerSize else {
            return nil
        }

        let payloadLength = data.withUnsafeBytes { bytes -> UInt32 in
            let offset = bytes.baseAddress!.advanced(by: 1)
            return offset.loadUnaligned(as: UInt32.self).bigEndian
        }

        let totalLength = SyncMessageCodec.headerSize + Int(payloadLength)

        guard totalLength <= SyncMessageCodec.maxFrameSize else {
            return nil
        }

        return totalLength
    }

    // MARK: - JSON Encoding

    private func encodeJSON(_ message: SyncMessage) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let jsonData: Data
        do {
            jsonData = try encoder.encode(message)
        } catch {
            throw SyncMessageCodecError.encodingFailed(error.localizedDescription)
        }

        guard jsonData.count <= SyncMessageCodec.maxFrameSize else {
            throw SyncMessageCodecError.frameTooLarge(jsonData.count)
        }

        return makeFrame(type: .json, payload: jsonData)
    }

    private func decodeJSON(_ data: Data) throws -> SyncMessage {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode(SyncMessage.self, from: data)
        } catch {
            throw SyncMessageCodecError.decodingFailed(error.localizedDescription)
        }
    }

    // MARK: - Binary Encoding (for file chunks)

    private func encodeBinaryChunk(_ payload: FileChunkPayload) throws -> Data {
        // Binary format: [2 bytes path-length][path-utf8][8 bytes offset][1 byte isLast][chunk-data]
        guard let pathData = payload.relativePath.data(using: .utf8) else {
            throw SyncMessageCodecError.encodingFailed("Failed to encode path as UTF-8")
        }

        var binaryPayload = Data()
        var pathLength = UInt16(pathData.count).bigEndian
        binaryPayload.append(Data(bytes: &pathLength, count: 2))
        binaryPayload.append(pathData)
        var offset = payload.offset.bigEndian
        binaryPayload.append(Data(bytes: &offset, count: 8))
        binaryPayload.append(payload.isLastChunk ? 1 : 0)
        binaryPayload.append(payload.data)

        guard binaryPayload.count <= SyncMessageCodec.maxFrameSize else {
            throw SyncMessageCodecError.frameTooLarge(binaryPayload.count)
        }

        return makeFrame(type: .binary, payload: binaryPayload)
    }

    private func decodeBinaryChunk(_ data: Data) throws -> SyncMessage {
        guard data.count >= 11 else { // 2 (path len) + min 0 path + 8 (offset) + 1 (isLast)
            throw SyncMessageCodecError.insufficientData
        }

        var cursor = data.startIndex

        let pathLength = data.withUnsafeBytes { bytes -> UInt16 in
            bytes.baseAddress!.advanced(by: cursor).loadUnaligned(as: UInt16.self).bigEndian
        }
        cursor = cursor.advanced(by: 2)

        guard data.count >= 2 + Int(pathLength) + 9 else {
            throw SyncMessageCodecError.insufficientData
        }

        let pathData = data[cursor..<cursor.advanced(by: Int(pathLength))]
        guard let path = String(data: pathData, encoding: .utf8) else {
            throw SyncMessageCodecError.decodingFailed("Invalid UTF-8 path")
        }
        cursor = cursor.advanced(by: Int(pathLength))

        let offset = data.withUnsafeBytes { bytes -> Int64 in
            bytes.baseAddress!.advanced(by: cursor).loadUnaligned(as: Int64.self).bigEndian
        }
        cursor = cursor.advanced(by: 8)

        let isLastChunk = data[cursor] != 0
        cursor = cursor.advanced(by: 1)

        let chunkData = Data(data[cursor...])

        let payload = FileChunkPayload(
            relativePath: path,
            offset: offset,
            data: chunkData,
            isLastChunk: isLastChunk
        )

        return .fileChunk(payload)
    }

    // MARK: - Frame Construction

    private func makeFrame(type: SyncMessageFrameType, payload: Data) -> Data {
        var frame = Data(capacity: SyncMessageCodec.headerSize + payload.count)
        frame.append(type.rawValue)
        var length = UInt32(payload.count).bigEndian
        frame.append(Data(bytes: &length, count: 4))
        frame.append(payload)
        return frame
    }
}
