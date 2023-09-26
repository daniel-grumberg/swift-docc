/*
 This source file is part of the Swift.org open source project

 Copyright (c) 2021-2023 Apple Inc. and the Swift project authors
 Licensed under Apache License v2.0 with Runtime Library Exception

 See https://swift.org/LICENSE.txt for license information
 See https://swift.org/CONTRIBUTORS.txt for Swift project authors
*/

import Foundation

/// Identifies the type of a ``UniqueTopicIdentifier``.
public struct UniqueTopicIdentifierType: Hashable, Codable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    private let _storage: String
    
    /// Create a new resolved reference type, prefer to use one of the predefined types such as ``symbol`` when possible.
    public init(_ type: String) {
        self._storage = type
    }
    
    /// Used to create a topic identifier for the root page
    public static let root = Self.init("root")
    /// Used to create a symbol topic identifier.
    public static let symbol = Self.init("symbol")
    static let sparseSymbol = Self.init("sparseSymbol")
    static let overridable = Self.init("overridable")
    static let unresolved = Self.init("unresolved")
    /// Used to create a module topic identifier
    public static let module = Self.init("module")
    /// Used to create a technology root topic identifier
    public static let technology = Self.init("technology")
    /// Used to create a non-symbol topic identifier.
    public static let article = Self.init("article")
    /// Used to create a topic identifier for an automatically generated collection article.
    public static let collection = Self.init("collection")
    /// Used to create a topic identifier for a tutorial technology.
    public static let tutorialTechnology = Self.init("tutorialTechnology")
    /// Used to create a topic identifier for a tutorial.
    public static let tutorial = Self.init("tutorial")
    /// Used to create a topic identifier for a top level container.
    public static let container = Self.init("container")
    /// Used to create topic identifier for a tutorial volume
    public static let volume = Self.init("volume")
    /// Used to create topic identifier for a tutorial chapter
    public static let chapter = Self.init("chapter")
    static let placeholder = Self.init("placeholder")
    
    public var description: String { _storage }
    public var debugDescription: String { _storage }
}

/// Unique identifier that describes a single piece of documentation regardless of where it is curated.
public struct UniqueTopicIdentifier: Hashable, Codable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    private class _Storage {
        /// The type of reference.
        public let type: UniqueTopicIdentifierType
        
        /// The unique identifier string.
        public let id: String
        
        public let bundleIdentifier: String?
        
        public let bundleDisplayName: String?
        
        /// Optionally represent a specifc location in the piece of documentation referenced by ``id``.
        public let fragment: String?
        
        init(type: UniqueTopicIdentifierType, id: String, bundleIdentifier: String?, bundleDisplayName: String?, fragment: String?) {
            self.type = type
            self.id = id
            self.bundleIdentifier = bundleIdentifier
            self.bundleDisplayName = bundleDisplayName
            self.fragment = fragment
        }
    }
    
    enum CodingKeys: CodingKey {
        case bundleIdentifier, type, id, fragment
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(bundleIdentifier, forKey: .bundleIdentifier)
        try container.encode(type, forKey: .type)
        try container.encode(id, forKey: .id)
        try container.encode(fragment, forKey: .fragment)
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let bundleIdentifier = try container.decodeIfPresent(String.self, forKey: .bundleIdentifier)
        let type = try container.decode(UniqueTopicIdentifierType.self, forKey: .type)
        let id = try container.decode(String.self, forKey: .id)
        let fragment = try container.decodeIfPresent(String.self, forKey: .fragment)
        
        self.init(type: type, id: id, bundleIdentifier: bundleIdentifier, fragment: fragment)
    }
    
    private let _storage: _Storage
    
    /// The type of reference.
    public var type: UniqueTopicIdentifierType { _storage.type }
    
    /// The unique identifier string.
    public var id: String { _storage.id }
    
    public var bundleIdentifier: String? { _storage.bundleIdentifier }
    
    public var bundleDisplayName: String? { _storage.bundleDisplayName }
    
    /// Optionally represent a specifc location in the piece of documentation referenced by ``id``.
    public var fragment: String? { _storage.fragment }
    
    static var sharedPool = Synchronized([String: UniqueTopicIdentifier]())
    
    static func cacheKey(bundleIdentifier: String?, type: UniqueTopicIdentifierType, id: String, fragment: String?) -> String {
        var fragmentString = ""
        if let fragment { fragmentString = "#\(fragment)" }
        return "\(bundleIdentifier ?? "")@\(type.description)@(\(id)\(fragmentString))"
    }
    
    public init(type: UniqueTopicIdentifierType, id: String, bundleIdentifier: String? = nil, bundleDisplayName: String? = nil, fragment: String? = nil) {
        let cacheKey = Self.cacheKey(bundleIdentifier: bundleIdentifier, type: type, id: id, fragment: fragment)
        if let cached = Self.sharedPool.sync({ $0[cacheKey] }) {
            self = cached
            return
        }
        
        _storage = _Storage(type: type, id: id, bundleIdentifier: bundleIdentifier, bundleDisplayName: bundleDisplayName, fragment: fragment)
        
        Self.sharedPool.sync {
            $0[cacheKey] = self
        }
    }
    
    /// Used to create a placeholder unique topic identifier.
    init() {
        self.init(type: .placeholder, id: "")
    }
    
    public static func ==(lhs: UniqueTopicIdentifier, rhs: UniqueTopicIdentifier) -> Bool {
        return lhs.type == rhs.type && lhs.id == rhs.id && lhs.fragment == rhs.fragment
    }
    
    public func hash(into hasher: inout Hasher) {
        hasher.combine(type)
        hasher.combine(id)
        hasher.combine(fragment)
    }
    
    public var description: String {
        Self.cacheKey(bundleIdentifier: bundleIdentifier, type: type, id: id, fragment: fragment)
    }
    
    public var debugDescription: String { description }
    
    public func addingFragment(_ fragment: String?) -> UniqueTopicIdentifier {
        let newID = UniqueTopicIdentifier(type: type, id: id, bundleIdentifier: bundleIdentifier, bundleDisplayName: bundleDisplayName, fragment: fragment)
        
        return newID
    }
    
    public func removingFragment() -> UniqueTopicIdentifier {
        return UniqueTopicIdentifier(type: type, id: id, bundleIdentifier: bundleIdentifier, bundleDisplayName: bundleDisplayName)
    }
    
    public func referenceForNonSymbol() -> ResolvedTopicReference {
        let path: String
        switch type {
        case .tutorialTechnology:
            path = NodeURLGenerator.Path.technology(technologyName: id).stringValue
        case .tutorial:
            path = NodeURLGenerator.Path.tutorial(bundleName: bundleDisplayName!, tutorialName: id).stringValue
        case .technology:
            path = NodeURLGenerator.Path.documentation(path: id).stringValue
        case .article:
            path = NodeURLGenerator.Path.article(bundleName: bundleDisplayName!, articleName: id).stringValue
        default:
            fatalError("Attempting to generate a resolved reference we can not do.")
        }
        
        return ResolvedTopicReference(bundleIdentifier: bundleIdentifier ?? "", identifier: self, path: path, sourceLanguage: .swift)
    }
}

public struct UniqueTopicIdentifierGenerator {
    public static func identifierForSemantic(_ semantic: Semantic, source: URL, bundle: DocumentationBundle) -> UniqueTopicIdentifier {
        let fileName = source.deletingPathExtension().lastPathComponent
        let urlReadableFileName = urlReadablePath(fileName)
        
        switch semantic {
        case is Technology:
            return UniqueTopicIdentifier(type: .tutorialTechnology, id: urlReadableFileName, bundleIdentifier: bundle.identifier, bundleDisplayName: bundle.displayName)
        case is Tutorial, is TutorialArticle:
            return UniqueTopicIdentifier(type: .tutorial, id: urlReadableFileName, bundleIdentifier: bundle.identifier, bundleDisplayName: bundle.displayName)
        case let article as Article:
            return UniqueTopicIdentifier(
                type: article.metadata?.technologyRoot != nil ? .container: .article,
                id: urlReadableFileName, bundleIdentifier: bundle.identifier,
                bundleDisplayName: bundle.displayName
            )
        default:
            return UniqueTopicIdentifier(type: .placeholder, id: urlReadableFileName, bundleIdentifier: bundle.identifier, bundleDisplayName: bundle.displayName)
        }
    }
}
