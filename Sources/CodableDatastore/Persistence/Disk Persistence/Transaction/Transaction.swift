//
//  Transaction.swift
//  CodableDatastore
//
//  Created by Dimitri Bouniol on 2023-06-21.
//  Copyright © 2023 Mochi Development, Inc. All rights reserved.
//

import Foundation
import Bytes

extension DiskPersistence {
    actor Transaction: AnyDiskTransaction {
        let persistence: DiskPersistence
        
        unowned let parent: Transaction?
        var childTransactions: [Transaction] = []
        
        private(set) var task: Task<Void, Error>!
        let options: TransactionOptions
        
        var rootObjects: [DatastoreKey : Datastore.RootObject] = [:]
        
        var createdRootObjects: Set<Datastore.RootObject> = []
        var createdIndexes: Set<Datastore.Index> = []
        var createdPages: Set<Datastore.Page> = []
        
        var deletedRootObjects: Set<Datastore.RootObject> = []
        var deletedIndexes: Set<Datastore.Index> = []
        var deletedPages: Set<Datastore.Page> = []
        
        // TODO: entryMutations, so we can send events to observers once the whole thing is finished.
        
        var isActive = false
        
        private init(
            persistence: DiskPersistence,
            parent: Transaction?,
            options: TransactionOptions
        ) {
            self.persistence = persistence
            self.parent = parent
            self.options = options
        }
        
        private func attachTask<T>(
            options: TransactionOptions,
            handler: @escaping () async throws -> T
        ) async -> Task<T, Error> {
            let task = Task {
                isActive = true
                let returnValue = try await TransactionTaskLocals.$transaction.withValue(self) {
                    try await handler()
                }
                isActive = false
                
                /// If we don't care to collate our writes, go ahead and wait for the persistence to stick
                if !options.contains(.collateWrites) {
                    try await self.persist()
                }
                
                return returnValue
            }
            
            self.task = Task {
                _ = try await task.value
                
                /// If we previously skipped persisting, go ahead and do so now.
                if options.contains(.collateWrites) {
                    try await self.persist()
                }
            }
            
            return task
        }
        
        func checkIsActive() throws {
            guard isActive else {
                assertionFailure(DatastoreInterfaceError.transactionInactive.localizedDescription)
                throw DatastoreInterfaceError.transactionInactive
            }
        }
        
        func apply(_ rootObjects: [DatastoreKey : Datastore.RootObject]) throws {
            try checkIsActive()
            
            for (key, value) in rootObjects {
                self.rootObjects[key] = value
            }
        }
        
        private func persist() async throws {
            if let parent {
                try await parent.apply(rootObjects)
                return
            }
            
            for (_, root) in rootObjects {
                try await root.persistIfNeeded()
            }
            
            try await persistence.persist(roots: rootObjects)
        }
        
        static func makeTransaction<T>(
            persistence: DiskPersistence,
            lastTransaction: Transaction?,
            options: TransactionOptions,
            handler: @escaping (_ transaction: Transaction) async throws -> T
        ) async -> (Transaction, Task<T, Error>) {
            if let parent = Self.unsafeCurrentTransaction {
                let (child, task) = await parent.childTransaction(options: options, handler: handler)
                return (child, task)
            }
            
            let transaction = Transaction(
                persistence: persistence,
                parent: nil,
                options: options
            )
            
            let task = await transaction.attachTask(options: options) {
                /// If the transaction is not read only, wait for the last transaction to properly finish before starting the next one.
                if !options.contains(.readOnly) {
                    try? await lastTransaction?.task.value
                }
                return try await handler(transaction)
            }
            
            return (transaction, task)
        }
        
        func childTransaction<T>(
            options: TransactionOptions,
            handler: @escaping (_ transaction: Transaction) async throws -> T
        ) async -> (Transaction, Task<T, Error>) {
            let transaction = Transaction(
                persistence: persistence,
                parent: self,
                options: options
            )
            
            /// Get the last non-concurrent transaction from the list. Note that disk persistence currently does not support concurrent idempotent transactions.
            let lastChild = childTransactions.last { !$0.options.contains(.readOnly) }
            childTransactions.append(transaction)
            
            let task = await transaction.attachTask(options: options) {
                try self.checkIsActive()
                
                /// If the transaction is not read only, wait for the last transaction to properly finish before starting the next one.
                if !options.contains(.readOnly) {
                    _ = try? await lastChild?.task.value
                }
                return try await handler(transaction)
            }
            
            return (transaction, task)
        }
        
        func rootObject(for datastoreKey: DatastoreKey) async throws -> Datastore.RootObject? {
            if let rootObject = rootObjects[datastoreKey] {
                return rootObject
            }
            
            if let parent = parent {
                guard let rootObject = try await parent.rootObject(for: datastoreKey)
                else { return nil }
                rootObjects[datastoreKey] = rootObject
                return rootObject
            }
            
            let (persistenceDatastore, rootID) = try await persistence.persistenceDatastore(for: datastoreKey)
            
            guard let rootID else { return nil }
            
            let rootObject = await persistenceDatastore.rootObject(for: rootID)
            rootObjects[datastoreKey] = rootObject
            return rootObject
        }
        
        nonisolated static var unsafeCurrentTransaction: Self? {
            TransactionTaskLocals.transaction.map({ $0 as! Self })
        }
    }
}

// MARK: - Datastore Interface

extension DiskPersistence.Transaction: DatastoreInterfaceProtocol {
    func register<Version, CodedType, IdentifierType, Access>(
        datastore: Datastore<Version, CodedType, IdentifierType, Access>
    ) async throws -> DatastoreDescriptor? {
        try checkIsActive()
        
        try await persistence.register(datastore: datastore)
        return try await datastoreDescriptor(for: datastore.key)
    }
    
    func datastoreDescriptor(
        for datastoreKey: DatastoreKey
    ) async throws -> DatastoreDescriptor? {
        try checkIsActive()
        
        let rootObject = try await rootObject(for: datastoreKey)
        return try await rootObject?.manifest.descriptor
    }
    
    func apply(descriptor: DatastoreDescriptor, for datastoreKey: DatastoreKey) async throws {
        try checkIsActive()
        
        if let rootObject = try await rootObject(for: datastoreKey) {
            var manifest = try await rootObject.manifest
            
            // TODO: Do a better merge of these descriptors, especially since size is something we want to preserve, amongst other properties
            guard manifest.descriptor != descriptor else { return }
            
            manifest.id = DatastoreRootIdentifier()
            manifest.modificationDate = Date()
            manifest.descriptor = descriptor
            
            let newRoot = DiskPersistence.Datastore.RootObject(
                datastore: rootObject.datastore,
                id: manifest.id,
                rootObject: manifest
            )
            rootObjects[datastoreKey] = newRoot
            createdRootObjects.insert(newRoot)
            await newRoot.datastore.adopt(rootObject: newRoot)
            
            // TODO: Don't forget to create the new index objects too!
        } else {
            let (datastore, _) = try await persistence.persistenceDatastore(for: datastoreKey)
            
            /// Create index objects first so they are available when requested.
            let primaryManifestIdentifier = DatastoreIndexManifestIdentifier()
            
            let directIndexManifests = descriptor.directIndexes.map { (_, index) in
                DatastoreRootManifest.IndexInfo(
                    key: index.key,
                    id: DatastoreIndexIdentifier(name: index.key),
                    root: DatastoreIndexManifestIdentifier()
                )
            }
            
            let secondaryIndexManifests = descriptor.secondaryIndexes.map { (_, index) in
                DatastoreRootManifest.IndexInfo(
                    key: index.key,
                    id: DatastoreIndexIdentifier(name: index.key),
                    root: DatastoreIndexManifestIdentifier()
                )
            }
            
            let primaryIndex = DiskPersistence.Datastore.Index(
                datastore: datastore,
                id: .primary(manifest: primaryManifestIdentifier),
                manifest: DatastoreIndexManifest(
                    id: primaryManifestIdentifier,
                    orderedPages: []
                )
            )
            createdIndexes.insert(primaryIndex)
            await datastore.adopt(index: primaryIndex)
            
            for indexInfo in directIndexManifests {
                let index = DiskPersistence.Datastore.Index(
                    datastore: datastore,
                    id: .direct(index: indexInfo.id, manifest: indexInfo.root),
                    manifest: DatastoreIndexManifest(
                        id: indexInfo.root,
                        orderedPages: []
                    )
                )
                createdIndexes.insert(index)
                await datastore.adopt(index: index)
            }
            
            for indexInfo in secondaryIndexManifests {
                let index = DiskPersistence.Datastore.Index(
                    datastore: datastore,
                    id: .secondary(index: indexInfo.id, manifest: indexInfo.root),
                    manifest: DatastoreIndexManifest(
                        id: indexInfo.root,
                        orderedPages: []
                    )
                )
                createdIndexes.insert(index)
                await datastore.adopt(index: index)
            }
            
            /// Create the root object from the indexes that were created
            let manifest = DatastoreRootManifest(
                id: DatastoreRootIdentifier(),
                modificationDate: Date(),
                descriptor: descriptor,
                primaryIndexManifest: primaryManifestIdentifier,
                directIndexManifests: directIndexManifests,
                secondaryIndexManifests: secondaryIndexManifests
            )
            
            let newRoot = DiskPersistence.Datastore.RootObject(
                datastore: datastore,
                id: manifest.id,
                rootObject: manifest
            )
            rootObjects[datastoreKey] = newRoot
            createdRootObjects.insert(newRoot)
            await datastore.adopt(rootObject: newRoot)
        }
    }
}

// MARK: - Cursor Lookups

extension DiskPersistence.Transaction {
    func primaryIndexCursor<IdentifierType: Indexable>(
        for identifier: IdentifierType,
        datastoreKey: DatastoreKey
    ) async throws -> (
        cursor: any InstanceCursorProtocol,
        instanceData: Data,
        versionData: Data
    ) {
        try checkIsActive()
        
        guard let rootObject = try await rootObject(for: datastoreKey)
        else { throw DatastoreInterfaceError.datastoreKeyNotFound }
        
        let index = try await rootObject.primaryIndex
        
        let pages = try await index.orderedPages
        
        // See https://stackoverflow.com/questions/26678362/how-do-i-insert-an-element-at-the-correct-position-into-a-sorted-array-in-swift/70645571#70645571
        // guard !pages.isEmpty else { return Cursor(index: index, after: nil)
                        
        var bytesForFirstEntry: Bytes?
        
        let middle = pages.count/2
        pageIterator: for page in pages[middle...] {
            let blocks = try await page.blocks
            
            for try await block in blocks {
                switch block {
                case .complete(let bytes):
                    /// We have a complete entry, lets use it and stop scanning
                    bytesForFirstEntry = bytes
                    break pageIterator
                case .head(let bytes):
                    /// We are starting an entry, but will need to go to the next page.
                    bytesForFirstEntry = bytes
                case .slice(let bytes):
                    /// In the first position, lets skip it.
                    guard bytesForFirstEntry != nil else { continue }
                    /// In the final position, lets save and continue.
                    bytesForFirstEntry?.append(contentsOf: bytes)
                case .tail(let bytes):
                    /// In the first position, lets skip it.
                    guard bytesForFirstEntry != nil else { continue }
                    /// In the final position, lets save and stop.
                    bytesForFirstEntry?.append(contentsOf: bytes)
                    break pageIterator
                }
            }
        }
        
        // let entry = try DatastorePageEntry(bytes: bytes)
        let firstEntry = DatastorePageEntry(headers: [], content: [])
        // guard entry.headers.count == 2 else { throw cannot decode page }
//        let versionBytes = firstEntry.headers[0]
        let identifierBytes = firstEntry.headers[1]
        
        let firstEntryIdentifier = try JSONDecoder.shared.decode(IdentifierType.self, from: Data(identifierBytes))
        
        if firstEntryIdentifier < identifier {
            // evaluate [index(after: middle)...]
        } else {
            // evaluate [..<middle]
        }
        // end of page search
        
        // We have the index we could insert the entry as a new page, but it could be located either on the previous page of the specified one, so check the previous page and check every entry from there, continuing to subsequent pages from there.
        // Cursor should include the page _index_ as a hint, as the structure may change between loading the index and writing to it.
        
        
        preconditionFailure("Unimplemented")
    }
    
    func primaryIndexCursor<IdentifierType: Indexable>(
        inserting identifier: IdentifierType,
        datastoreKey: DatastoreKey
    ) async throws -> any InsertionCursorProtocol {
        try checkIsActive()
        
        preconditionFailure("Unimplemented")
    }
    
    func directIndexCursor<IndexType: Indexable, IdentifierType: Indexable>(
        for index: IndexType,
        identifier: IdentifierType,
        indexName: String,
        datastoreKey: DatastoreKey
    ) async throws -> (
        cursor: any InstanceCursorProtocol,
        instanceData: Data,
        versionData: Data
    ) {
        try checkIsActive()
        
        preconditionFailure("Unimplemented")
    }
    
    func directIndexCursor<IndexType: Indexable, IdentifierType: Indexable>(
        inserting index: IndexType,
        identifier: IdentifierType,
        indexName: String,
        datastoreKey: DatastoreKey
    ) async throws -> any InsertionCursorProtocol {
        try checkIsActive()
        
        preconditionFailure("Unimplemented")
    }
    
    func secondaryIndexCursor<IndexType: Indexable, IdentifierType: Indexable>(
        for index: IndexType,
        identifier: IdentifierType,
        indexName: String,
        datastoreKey: DatastoreKey
    ) async throws -> any InstanceCursorProtocol {
        try checkIsActive()
        
        preconditionFailure("Unimplemented")
    }
    
    func secondaryIndexCursor<IndexType: Indexable, IdentifierType: Indexable>(
        inserting index: IndexType,
        identifier: IdentifierType,
        indexName: String,
        datastoreKey: DatastoreKey
    ) async throws -> any InsertionCursorProtocol {
        try checkIsActive()
        
        preconditionFailure("Unimplemented")
    }
}

// MARK: - Entry Manipulation

extension DiskPersistence.Transaction {
    func persistPrimaryIndexEntry<IdentifierType: Indexable>(
        versionData: Data,
        identifierValue: IdentifierType,
        instanceData: Data,
        cursor: some InsertionCursorProtocol,
        datastoreKey: DatastoreKey
    ) async throws {
        try checkIsActive()
        
        preconditionFailure("Unimplemented")
    }
    
    func deletePrimaryIndexEntry(
        cursor: some InstanceCursorProtocol,
        datastoreKey: DatastoreKey
    ) async throws {
        try checkIsActive()
        
        preconditionFailure("Unimplemented")
    }
    
    func resetPrimaryIndex(
        datastoreKey: DatastoreKey
    ) async throws {
        try checkIsActive()
        
        preconditionFailure("Unimplemented")
    }
    
    func persistDirectIndexEntry<IndexType: Indexable, IdentifierType: Indexable>(
        versionData: Data,
        indexValue: IndexType,
        identifierValue: IdentifierType,
        instanceData: Data,
        cursor: some InsertionCursorProtocol,
        indexName: String,
        datastoreKey: DatastoreKey
    ) async throws {
        try checkIsActive()
        
        preconditionFailure("Unimplemented")
    }
    
    func deleteDirectIndexEntry(
        cursor: some InstanceCursorProtocol,
        indexName: String,
        datastoreKey: DatastoreKey
    ) async throws {
        try checkIsActive()
        
        preconditionFailure("Unimplemented")
    }
    
    func deleteDirectIndex(
        indexName: String,
        datastoreKey: DatastoreKey
    ) async throws {
        try checkIsActive()
        
        preconditionFailure("Unimplemented")
    }
    
    func persistSecondaryIndexEntry<IndexType: Indexable, IdentifierType: Indexable>(
        indexValue: IndexType,
        identifierValue: IdentifierType,
        cursor: some InsertionCursorProtocol,
        indexName: String,
        datastoreKey: DatastoreKey
    ) async throws {
        try checkIsActive()
        
        preconditionFailure("Unimplemented")
    }
    
    func deleteSecondaryIndexEntry(
        cursor: some InstanceCursorProtocol,
        indexName: String,
        datastoreKey: DatastoreKey
    ) async throws {
        try checkIsActive()
        
        preconditionFailure("Unimplemented")
    }
    
    func deleteSecondaryIndex(
        indexName: String,
        datastoreKey: DatastoreKey
    ) async throws {
        try checkIsActive()
        
        preconditionFailure("Unimplemented")
    }
}

// MARK: - Helper Types

fileprivate protocol AnyDiskTransaction {}

fileprivate enum TransactionTaskLocals {
    @TaskLocal
    static var transaction: AnyDiskTransaction?
}
