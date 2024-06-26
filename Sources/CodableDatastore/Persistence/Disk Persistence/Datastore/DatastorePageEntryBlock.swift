//
//  DatastorePageEntryBlock.swift
//  CodableDatastore
//
//  Created by Dimitri Bouniol on 2023-06-27.
//  Copyright © 2023-24 Mochi Development, Inc. All rights reserved.
//

import Foundation
import AsyncSequenceReader
import Bytes

/// A block of data that represents a portion of an entry on a page.
@usableFromInline
enum DatastorePageEntryBlock: Hashable, Sendable {
    /// The tail end of an entry.
    ///
    /// This must be combined with a previous block to form an entry.
    case tail(Bytes)
    
    /// A complete entry.
    case complete(Bytes)
    
    /// The head end of an entry.
    ///
    /// This must be combined with a subsequent block to form an entry.
    case head(Bytes)
    
    /// A sclice of an entry.
    ///
    /// This must be combined with both the previous and subsequent blocks to form an entry.
    case slice(Bytes)
}

// MARK: - Decoding

extension AsyncIteratorProtocol where Element == Byte {
    @usableFromInline
    mutating func next(_ type: DatastorePageEntryBlock.Type) async throws -> DatastorePageEntryBlock? {
        guard let blockType = try await nextIfPresent(utf8: String.self, count: 1) else {
            return nil
        }
        
        /// Fail early if the block type is not supported.
        switch blockType {
        case "<", "=", ">", "~": break
        default:
            throw DiskPersistenceError.invalidPageFormat
        }
        
        /// Artificially limit ourselves to ~ 9 GB, though realistically our limit will be much, much lower.
        guard let blockSizeBytes = try await collect(upToIncluding: "\n".utf8Bytes, throwsIfOver: 11)
        else { throw DiskPersistenceError.invalidPageFormat }
        
        let decimalSizeString = String(utf8Bytes: blockSizeBytes.dropLast(1))
        guard let blockSize = Int(decimalSizeString), blockSize > 0
        else { throw DiskPersistenceError.invalidPageFormat }
        
        let payload = try await next(Bytes.self, count: blockSize)
        
        try await check(utf8: "\n")
        
        switch blockType {
        case "<": return .tail(payload)
        case "=": return .complete(payload)
        case ">": return .head(payload)
        case "~": return .slice(payload)
        default: throw DiskPersistenceError.invalidPageFormat
        }
    }
}

// MARK: - Encoding

extension DatastorePageEntryBlock {
    var bytes: Bytes {
        var bytes = Bytes()
        
        let blockType: String
        let payload: Bytes
        
        switch self {
        case .tail(let contents):
            blockType = "<"
            payload = contents
        case .complete(let contents):
            blockType = "="
            payload = contents
        case .head(let contents):
            blockType = ">"
            payload = contents
        case .slice(let contents):
            blockType = "~"
            payload = contents
        }
        
        let payloadSize = String(payload.count).utf8Bytes
        
        bytes.reserveCapacity(1 + payloadSize.count + 1 + payload.count + 1)
        
        bytes.append(contentsOf: blockType.utf8Bytes)
        bytes.append(contentsOf: payloadSize)
        bytes.append(contentsOf: "\n".utf8Bytes)
        bytes.append(contentsOf: payload)
        bytes.append(contentsOf: "\n".utf8Bytes)
        
        return bytes
    }
}

// MARK: - Sizing

extension DatastorePageEntryBlock {
    var contents: Bytes {
        switch self {
        case .tail(let contents),
             .complete(let contents),
             .head(let contents),
             .slice(let contents):
            return contents
        }
    }
    
    var encodedSize: Int {
        let payload = contents
        let payloadSize = String(payload.count).utf8Bytes
        
        return 1 + payloadSize.count + 1 + payload.count + 1
    }
}

extension RandomAccessCollection where Element == DatastorePageEntryBlock {
    var encodedSize: Int {
        self.reduce(into: 0) { partialResult, block in
            partialResult += block.encodedSize
        }
    }
}
