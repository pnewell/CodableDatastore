//
//  IndexName.swift
//  CodableDatastore
//
//  Created by Dimitri Bouniol on 2023-07-20.
//  Copyright © 2023-24 Mochi Development, Inc. All rights reserved.
//

/// A typed name that an index is keyed under. This is typically the path component of the key path that leads to an index.
public struct IndexName: RawRepresentable, Hashable, Comparable, Sendable {
    public var rawValue: String
    
    public init(rawValue: String) {
        self.rawValue = rawValue
    }
    
    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }
    
    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

extension IndexName: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) {
        self.init(rawValue: value)
    }
}

extension IndexName: Decodable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(rawValue: try container.decode(String.self))
    }
}

extension IndexName: Encodable {
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
