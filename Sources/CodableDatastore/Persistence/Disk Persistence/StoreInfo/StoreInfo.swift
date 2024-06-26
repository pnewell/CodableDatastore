//
//  StoreInfo.swift
//  CodableDatastore
//
//  Created by Dimitri Bouniol on 2023-06-07.
//  Copyright © 2023-24 Mochi Development, Inc. All rights reserved.
//

import Foundation

/// Versions supported by ``DiskPersisitence``.
///
/// These are used when dealing with format changes at the library level.
enum StoreInfoVersion: String, Codable, Sendable {
    case alpha
}

/// A struct to store information about a ``DiskPersistence`` on disk.
struct StoreInfo: Codable, Equatable, Sendable {
    /// The version of the persistence, used when dealing with format changes at the library level.
    var version: StoreInfoVersion = .alpha
    
    /// A pointer to the current snapshot.
    var currentSnapshot: SnapshotIdentifier?
    
    /// The last modification date of the persistence.
    var modificationDate: Date
}
