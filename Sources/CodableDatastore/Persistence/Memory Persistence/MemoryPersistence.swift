//
//  MemoryPersistence.swift
//  CodableDatastore
//
//  Created by Dimitri Bouniol on 2023-06-03.
//  Copyright © 2023-24 Mochi Development, Inc. All rights reserved.
//

import Foundation

public actor MemoryPersistence: Persistence {
    public typealias AccessMode = ReadWrite
}

extension MemoryPersistence {
    public func _withTransaction<T: Sendable>(
        actionName: String?,
        options: UnsafeTransactionOptions,
        transaction: @Sendable (_ transaction: DatastoreInterfaceProtocol, _ isDurable: Bool) async throws -> T
    ) async throws -> T {
        preconditionFailure("Unimplemented")
    }
}
