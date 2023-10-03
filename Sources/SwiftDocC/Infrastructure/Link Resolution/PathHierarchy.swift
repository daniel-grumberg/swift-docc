/*
 This source file is part of the Swift.org open source project

 Copyright (c) 2022-2023 Apple Inc. and the Swift project authors
 Licensed under Apache License v2.0 with Runtime Library Exception

 See https://swift.org/LICENSE.txt for license information
 See https://swift.org/CONTRIBUTORS.txt for Swift project authors
*/

import Foundation
import SymbolKit
import Markdown

/// A hierarchy of path components corresponding to the documentation hierarchy with disambiguation information at every level.
///
/// The main purpose of the path hierarchy is finding documentation entities based on relative paths from other documentation entities with good handling of link disambiguation.
/// This disambiguation aware hierarchy also makes it suitable for determining the least disambiguated paths for each documentation page.
///
/// The documentation hierarchy exist both in the path hierarchy and in the topic graph but for different purposes and in formats with different specialization. Neither is a replacement for the other.
///
/// ### Creation
///
/// Due to the rich relationships between symbols, a path hierarchy is created in two steps. First, the path hierarchy is initialized with all the symbols for all modules.
/// Next, non-symbols are added to the path hierarchy and on-page landmarks for both symbols and non-symbols are added where applicable.
/// It is not possible to add symbols to a path hierarchy after it has been initialized.
///
/// ### Usage
///
/// After a path hierarchy has been fully created — with both symbols and non-symbols — it can be used to find elements in the hierarchy and to determine the least disambiguated paths for all elements.
struct PathHierarchy {
    
    /// A map of module names to module nodes.
    private(set) var modules: [String: Node]
    /// The container of top-level articles in the documentation hierarchy.
    let articlesContainer: Node
    /// The container of tutorials in the documentation hierarchy.
    let tutorialContainer: Node
    /// The container of tutorial overview pages in the documentation hierarchy.
    let tutorialOverviewContainer: Node
    
    /// A map of known documentation nodes based on their unique identifiers.
    private(set) var lookup: [LanguageAwareUniqueTopicIdentifier: Node]
    
    // MARK: Creating a path hierarchy
    
    /// Initializes a path hierarchy with the all the symbols from all modules that a the given symbol graph loader provides.
    ///
    /// - Parameters:
    ///   - loader: The symbol graph loader that provides all symbols.
    ///   - bundleName: The name of the documentation bundle, used as a container for articles and tutorials.
    ///   - moduleKindDisplayName: The display name for the "module" kind of symbol.
    ///   - knownDisambiguatedPathComponents: A list of path components with known required disambiguations.
    init(
        symbolGraphLoader loader: SymbolGraphLoader,
        bundleName: String,
        moduleKindDisplayName: String = "Framework",
        knownDisambiguatedPathComponents: [String: [String]]? = nil
    ) {
        var roots: [String: Node] = [:]
        var allNodes: [String: [Node]] = [:]
        
        let symbolGraphs = loader.symbolGraphs
            .sorted(by: { lhs, _ in
                return !lhs.key.lastPathComponent.contains("@")
            })
        
        for (url, graph) in symbolGraphs {
            let moduleName = graph.module.name
            let moduleNode: Node
            
            if !loader.hasPrimaryURL(moduleName: moduleName) {
                guard let moduleName = SymbolGraphLoader.moduleNameFor(url),
                      let existingModuleNode = roots[moduleName]
                else { continue }
                moduleNode = existingModuleNode
            } else if let existingModuleNode = roots[moduleName] {
                moduleNode = existingModuleNode
            } else {
                let moduleIdentifierLanguage = graph.symbols.values.first?.identifier.interfaceLanguage ?? SourceLanguage.swift.id
                let moduleSymbol = SymbolGraph.Symbol(
                    identifier: .init(precise: moduleName, interfaceLanguage: moduleIdentifierLanguage),
                    names: SymbolGraph.Symbol.Names(title: moduleName, navigator: nil, subHeading: nil, prose: nil),
                    pathComponents: [moduleName],
                    docComment: nil,
                    accessLevel: SymbolGraph.Symbol.AccessControl(rawValue: "public"),
                    kind: SymbolGraph.Symbol.Kind(parsedIdentifier: .module, displayName: moduleKindDisplayName),
                    mixins: [:])
                let newModuleNode = Node(symbol: moduleSymbol)
                roots[moduleName] = newModuleNode
                moduleNode = newModuleNode
                allNodes[moduleName] = [moduleNode]
            }
            
            var nodes: [String: Node] = [:]
            nodes.reserveCapacity(graph.symbols.count)
            for (id, symbol) in graph.symbols {
                if let existingNode = allNodes[id]?.first(where: { $0.symbol!.identifier == symbol.identifier }) {
                    nodes[id] = existingNode
                } else {
                    let node = Node(symbol: symbol)
                    // Disfavor synthesized symbols when they collide with other symbol with the same path.
                    // FIXME: Get information about synthesized symbols from SymbolKit https://github.com/apple/swift-docc-symbolkit/issues/58
                    node.isDisfavoredInCollision = symbol.identifier.precise.contains("::SYNTHESIZED::")
                    nodes[id] = node
                    allNodes[id, default: []].append(node)
                }
            }
            
            var topLevelCandidates = nodes
            for relationship in graph.relationships where [.memberOf, .requirementOf, .optionalRequirementOf].contains(relationship.kind) {
                guard let sourceNode = nodes[relationship.source] else {
                    continue
                }
                if let targetNode = nodes[relationship.target] {
                    targetNode.add(symbolChild: sourceNode)
                    topLevelCandidates.removeValue(forKey: relationship.source)
                } else if let targetNodes = allNodes[relationship.target] {
                    for targetNode in targetNodes {
                        targetNode.add(symbolChild: sourceNode)
                    }
                    topLevelCandidates.removeValue(forKey: relationship.source)
                } else {
                    // Symbols that are not added to the path hierarchy based on relationships will be added to the path hierarchy based on the symbol's path components.
                    // Using relationships over path components is preferred because it provides information needed to disambiguate path collisions.
                    //
                    // In full symbol graphs this is expected to be rare. In partial symbol graphs from the ConvertService it is expected that parent symbols and relationships
                    // will be missing. The ConvertService is expected to provide the necessary `knownDisambiguatedPathComponents` to disambiguate any collisions.
                    continue
                }
            }
            
            for relationship in graph.relationships where relationship.kind == .defaultImplementationOf {
                guard let sourceNode = nodes[relationship.source] else {
                    continue
                }
                // Default implementations collide with the protocol requirement that they implement.
                // Disfavor the default implementation to favor the protocol requirement (or other symbol with the same path).
                sourceNode.isDisfavoredInCollision = true
                
                let targetNodes = nodes[relationship.target].map { [$0] } ?? allNodes[relationship.target] ?? []
                guard !targetNodes.isEmpty else {
                    continue
                }
                
                for requirementTarget in targetNodes {
                    assert(
                        requirementTarget.parent != nil,
                        "The 'defaultImplementationOf' symbol should be a 'memberOf' a known protocol symbol but didn't have a parent relationship in the hierarchy."
                    )
                    requirementTarget.parent?.add(symbolChild: sourceNode)
                }
                topLevelCandidates.removeValue(forKey: relationship.source)
            }
            
            // The hierarchy doesn't contain any non-symbol nodes yet. It's OK to unwrap the `symbol` property.
            for topLevelNode in topLevelCandidates.values where topLevelNode.symbol!.pathComponents.count == 1 {
                moduleNode.add(symbolChild: topLevelNode)
            }
            
            for node in topLevelCandidates.values where node.symbol!.pathComponents.count > 1 {
                var parent = moduleNode
                var components = { (symbol: SymbolGraph.Symbol) -> [String] in
                    let original = symbol.pathComponents
                    if let disambiguated = knownDisambiguatedPathComponents?[node.symbol!.identifier.precise], disambiguated.count == original.count {
                        return disambiguated
                    } else {
                        return original
                    }
                }(node.symbol!)[...].dropLast()
                while !components.isEmpty, let child = try? parent.children[components.first!]?.find(nil, nil) {
                    parent = child
                    components = components.dropFirst()
                }
                for component in components {
                    assert(
                        parent.children[components.first!] == nil,
                        "Shouldn't create a new sparse node when symbol node already exist. This is an indication that a symbol is missing a relationship."
                    )
                    let component = Self.parse(pathComponent: component[...])
                    let nodeWithoutSymbol = Node(name: component.name, identifier: UniqueTopicIdentifier(type: .sparseSymbol, id: component.full, sourceLanguage: .swift).languageAware)
                    nodeWithoutSymbol.isDisfavoredInCollision = true
                    parent.add(child: nodeWithoutSymbol, kind: component.kind, hash: component.hash)
                    parent = nodeWithoutSymbol
                }
                parent.add(symbolChild: node)
            }
        }
        
        assert(
            allNodes.allSatisfy({ $0.value[0].parent != nil || roots[$0.key] != nil }),
            "Every node should either have a parent node or be a root node. This wasn't true for \(allNodes.filter({ $0.value[0].parent != nil || roots[$0.key] != nil }).map(\.key).sorted())"
        )
        allNodes.removeAll()
        
        // build the lookup list by traversing the hierarchy and adding identifiers to each node
        
        var lookup = [LanguageAwareUniqueTopicIdentifier: Node]()
        func descend(_ node: Node) {
            if node.symbol != nil {
                lookup[node.identifier] = node
            }
            for tree in node.children.values {
                for (_, subtree) in tree.storage {
                    for (_, node) in subtree {
                        descend(node)
                    }
                }
            }
        }
        
        for module in roots.values {
            descend(module)
        }
        
        func newNode(_ name: String, id: UniqueTopicIdentifier) -> Node {
            let node = Node(name: name, identifier: id.languageAware)
            lookup[id.languageAware] = node
            return node
        }
        self.articlesContainer = roots[bundleName] ?? newNode(bundleName, id: UniqueTopicIdentifierGenerator.identifierForArticlesRoot(bundleName: bundleName))
        self.tutorialContainer = newNode(bundleName, id: UniqueTopicIdentifierGenerator.identifierForTutorialTechnology(technologyName: bundleName))
        self.tutorialOverviewContainer = newNode("tutorials", id: UniqueTopicIdentifierGenerator.identifierForTutorialsRoot())
        
        assert(
            lookup.allSatisfy({ $0.key == $0.value.identifier }),
            "Every node lookup should match a node with that identifier."
        )
        
        self.modules = roots
        self.lookup = lookup
        
        assert(topLevelSymbols().allSatisfy({ lookup[$0] != nil }))
    }
    
    /// Adds an article to the path hierarchy.
    /// - Parameter name: The path component name of the article (the file name without the file extension).
    mutating func addArticle(name: String, identifier: UniqueTopicIdentifier) {
        addArticle(name: name, identifier: identifier.languageAware)
    }
    
    mutating func addArticle(name: String, identifier: LanguageAwareUniqueTopicIdentifier) {
        addNonSymbolChild(parent: articlesContainer.identifier, name: name, identifier: identifier, kind: "article")
    }
    
    /// Adds a tutorial to the path hierarchy.
    /// - Parameter name: The path component name of the tutorial (the file name without the file extension).
    /// - Returns: The new unique identifier that represent this tutorial.
    mutating func addTutorial(name: String, identifier: UniqueTopicIdentifier) {
        addTutorial(name: name, identifier: identifier.languageAware)
    }
    
    mutating func addTutorial(name: String, identifier: LanguageAwareUniqueTopicIdentifier) {
        addNonSymbolChild(parent: tutorialContainer.identifier, name: name, identifier: identifier, kind: "tutorial")
    }
    
    /// Adds a tutorial overview page to the path hierarchy.
    /// - Parameter name: The path component name of the tutorial overview (the file name without the file extension).
    mutating func addTutorialOverview(name: String, identifier: UniqueTopicIdentifier) {
        addTutorialOverview(name: name, identifier: identifier.languageAware)
    }
    
    mutating func addTutorialOverview(name: String, identifier: LanguageAwareUniqueTopicIdentifier) {
        addNonSymbolChild(parent: tutorialOverviewContainer.identifier, name: name, identifier: identifier, kind: "technology")
    }
    
    
    /// Adds a non-symbol child element to an existing element in the path hierarchy.
    /// - Parameters:
    ///   - parent: The unique identifier of the existing element to add the new child element to.
    ///   - name: The path component name of the new element.
    ///   - kind: The kind of the new element
    /// - Returns: The new unique identifier that represent this element.
    mutating func addNonSymbolChild(parent: LanguageAwareUniqueTopicIdentifier, name: String, identifier: LanguageAwareUniqueTopicIdentifier, kind: String) {
        let parent = lookup[parent]!
        
        let newNode = Node(name: name, identifier: identifier)
        self.lookup[identifier] = newNode
        parent.add(child: newNode, kind: kind, hash: nil)
    }
    
    /// Adds a non-symbol technology root.
    /// - Parameters:
    ///   - name: The path component name of the technology root.
    /// - Returns: The new unique identifier that represent the root.
    mutating func addTechnologyRoot(name: String, identifier: UniqueTopicIdentifier) {
        addTechnologyRoot(name: name, identifier: identifier.languageAware)
    }
    
    mutating func addTechnologyRoot(name: String, identifier: LanguageAwareUniqueTopicIdentifier) {
        let newNode = Node(name: name, identifier: identifier)
        self.lookup[identifier] = newNode
        
        modules[name] = newNode
    }

    // MARK: Finding elements in the hierarchy
    
    /// Attempts to find an element in the path hierarchy for a given path relative to another element.
    ///
    /// - Parameters:
    ///   - rawPath: The documentation link path string.
    ///   - parent: An optional identifier for the node in the hierarchy to search relative to.
    ///   - onlyFindSymbols: Whether or not only symbol matches should be found.
    /// - Returns: Returns the unique identifier for the found match or raises an error if no match can be found.
    /// - Throws: Raises a ``PathHierarchy/Error`` if no match can be found.
    func find(path rawPath: String, parent: LanguageAwareUniqueTopicIdentifier? = nil, onlyFindSymbols: Bool) throws -> LanguageAwareUniqueTopicIdentifier {
        let node = try findNode(path: rawPath, parentID: parent, onlyFindSymbols: onlyFindSymbols)
        if node.identifier == nil {
            throw Error.unfindableMatch(node)
        }
        if onlyFindSymbols, node.symbol == nil {
            throw Error.nonSymbolMatchForSymbolLink
        }
        
        return node.identifier
    }
    
    private func findNode(path rawPath: String, parentID: LanguageAwareUniqueTopicIdentifier?, onlyFindSymbols: Bool) throws -> Node {
        // The search for a documentation element can be though of as 3 steps:
        // - First, parse the path into structured path components.
        // - Second, find nodes that match the beginning of the path as starting points for the search
        // - Third, traverse the hierarchy from those starting points to search for the node.
        let (path, isAbsolute) = Self.parse(path: rawPath)
        guard !path.isEmpty else {
            throw Error.notFound(remaining: [], availableChildren: [])
        }
        
        var remaining = path[...]
        
        // If the first path component is "tutorials" or "documentation" then use that information to narrow the search.
        let isKnownTutorialPath      = remaining.first!.full == NodeURLGenerator.Path.tutorialsFolderName
        let isKnownDocumentationPath = remaining.first!.full == NodeURLGenerator.Path.documentationFolderName
        if isKnownDocumentationPath || isKnownTutorialPath {
            // Skip this component since it isn't represented in the path hierarchy.
            remaining.removeFirst()
        }
        
        guard let firstComponent = remaining.first else {
            throw Error.notFound(remaining: [], availableChildren: [])
        }
        
        // A function to avoid eagerly computing the full path unless it needs to be presented in an error message.
        func parsedPathForError() -> [PathComponent] {
            Self.parse(path: rawPath, omittingEmptyComponents: false).components
        }
        
        if !onlyFindSymbols {
            // If non-symbol matches are possible there is a fixed order to try resolving the link:
            // Articles match before tutorials which match before the tutorial overview page which match before symbols.
            
            // Non-symbols have a very shallow hierarchy so the simplified search peak at the first few layers and then searches only one subtree once if finds a probable match.
            lookForArticleRoot: if !isKnownTutorialPath {
                if articlesContainer.matches(firstComponent) {
                    if let next = remaining.dropFirst().first {
                        if !articlesContainer.anyChildMatches(next) {
                            break lookForArticleRoot
                        }
                    }
                    return try searchForNode(descendingFrom: articlesContainer, pathComponents: remaining.dropFirst(), parsedPathForError: parsedPathForError, onlyFindSymbols: onlyFindSymbols)
                } else if articlesContainer.anyChildMatches(firstComponent) {
                    return try searchForNode(descendingFrom: articlesContainer, pathComponents: remaining, parsedPathForError: parsedPathForError, onlyFindSymbols: onlyFindSymbols)
                }
            }
            if !isKnownDocumentationPath {
                if tutorialContainer.matches(firstComponent) {
                    return try searchForNode(descendingFrom: tutorialContainer, pathComponents: remaining.dropFirst(), parsedPathForError: parsedPathForError, onlyFindSymbols: onlyFindSymbols)
                } else if tutorialContainer.anyChildMatches(firstComponent)  {
                    return try searchForNode(descendingFrom: tutorialContainer, pathComponents: remaining, parsedPathForError: parsedPathForError, onlyFindSymbols: onlyFindSymbols)
                }
                // The parent for tutorial overviews / technologies is "tutorials" which has already been removed above, so no need to check against that name.
                else if tutorialOverviewContainer.anyChildMatches(firstComponent)  {
                    return try searchForNode(descendingFrom: tutorialOverviewContainer, pathComponents: remaining, parsedPathForError: parsedPathForError, onlyFindSymbols: onlyFindSymbols)
                }
            }
        }
        
        // A function to avoid repeating the
        func searchForNodeInModules() throws -> Node {
            // Note: This captures `parentID`, `remaining`, and `parsedPathForError`.
            if let moduleMatch = modules[firstComponent.full] ?? modules[firstComponent.name] {
                return try searchForNode(descendingFrom: moduleMatch, pathComponents: remaining.dropFirst(), parsedPathForError: parsedPathForError, onlyFindSymbols: onlyFindSymbols)
            }
            if modules.count == 1 {
                do {
                    return try searchForNode(descendingFrom: modules.first!.value, pathComponents: remaining, parsedPathForError: parsedPathForError, onlyFindSymbols: onlyFindSymbols)
                } catch {
                    // Ignore this error and raise an error about not finding the module instead.
                }
            }
            let topLevelNames = Set(modules.keys + [articlesContainer.name, tutorialContainer.name])
            throw Error.notFound(remaining: Array(remaining), availableChildren: topLevelNames)
        }
        
        // A recursive function to traverse up the path hierarchy searching for the matching node
        func searchForNodeUpTheHierarchy(from startingPoint: Node?, path: ArraySlice<PathComponent>) throws -> Node {
            guard let possibleStartingPoint = startingPoint else {
                // If the search has reached the top of the hierarchy, check the modules as a base case to break the recursion.
                do {
                    return try searchForNodeInModules()
                } catch {
                    // If the node couldn't be found in the modules, search the non-matching parent to achieve a more specific error message
                    if let parentID = parentID {
                        return try searchForNode(descendingFrom: lookup[parentID]!, pathComponents: path, parsedPathForError: parsedPathForError, onlyFindSymbols: onlyFindSymbols)
                    }
                    throw error
                }
            }
            
            // If the path isn't empty we would have already found a node.
            let firstComponent = path.first!
            
            // Keep track of the inner most error and raise that if no node is found.
            var innerMostError: Swift.Error?
            
            // If the starting point's children match this component, descend the path hierarchy from there.
            if possibleStartingPoint.anyChildMatches(firstComponent) {
                do {
                    return try searchForNode(descendingFrom: possibleStartingPoint, pathComponents: path, parsedPathForError: parsedPathForError, onlyFindSymbols: onlyFindSymbols)
                } catch {
                    innerMostError = error
                }
            }
            // It's possible that the component is ambiguous at the parent. Checking if this node matches the first component avoids that ambiguity.
            if possibleStartingPoint.matches(firstComponent) {
                do {
                    return try searchForNode(descendingFrom: possibleStartingPoint, pathComponents: path.dropFirst(), parsedPathForError: parsedPathForError, onlyFindSymbols: onlyFindSymbols)
                } catch {
                    if innerMostError == nil {
                        innerMostError = error
                    }
                }
            }
            
            do {
                return try searchForNodeUpTheHierarchy(from: possibleStartingPoint.parent, path: path)
            } catch {
                throw innerMostError ?? error
            }
        }
        
        if !isAbsolute, let parentID = parentID {
            // If this is a relative link with a known starting point, search from that node up the hierarchy.
            return try searchForNodeUpTheHierarchy(from: lookup[parentID]!, path: remaining)
        }
        return try searchForNodeInModules()
    }
    
    private func searchForNode(
        descendingFrom startingPoint: Node,
        pathComponents: ArraySlice<PathComponent>,
        parsedPathForError: () -> [PathComponent],
        onlyFindSymbols: Bool
    ) throws -> Node {
        var node = startingPoint
        var remaining = pathComponents[...]
        
        // Third, search for the match relative to the start node.
        if remaining.isEmpty {
            // If all path components were consumed, then the start of the search is the match.
            return node
        }
        
        // Search for the remaining components from the node
        while true {
            let (children, pathComponent) = try findChildTree(node: &node, parsedPath: parsedPathForError(), remaining: remaining)
            
            do {
                guard let child = try children.find(pathComponent.kind, pathComponent.hash) else {
                    // The search has ended with a node that doesn't have a child matching the next path component.
                    throw makePartialResultError(node: node, parsedPath: parsedPathForError(), remaining: remaining)
                }
                node = child
                remaining = remaining.dropFirst()
                if remaining.isEmpty {
                    // If all path components are consumed, then the match is found.
                    return child
                }
            } catch DisambiguationTree.Error.lookupCollision(let collisions) {
                func handleWrappedCollision() throws -> Node {
                    try handleCollision(node: node, parsedPath: parsedPathForError, remaining: remaining, collisions: collisions, onlyFindSymbols: onlyFindSymbols)
                }
                
                // See if the collision can be resolved by looking ahead on level deeper.
                guard let nextPathComponent = remaining.dropFirst().first else {
                    // This was the last path component so there's nothing to look ahead.
                    //
                    // It's possible for a symbol that exist on multiple languages to collide with itself.
                    // Check if the collision can be resolved by finding a unique symbol or an otherwise preferred match.
                    var uniqueCollisions: [String: Node] = [:]
                    for (node, _) in collisions {
                        guard let symbol = node.symbol else {
                            // Non-symbol collisions should have already been resolved
                            return try handleWrappedCollision()
                        }
                        
                        let id = symbol.identifier.precise
                        if symbol.identifier.interfaceLanguage == "swift" || !uniqueCollisions.keys.contains(id) {
                            uniqueCollisions[id] = node
                        }
                        
                        guard uniqueCollisions.count < 2 else {
                            // Encountered more than one unique symbol
                            return try handleWrappedCollision()
                        }
                    }
                    // A wrapped error would have been raised while iterating over the collection.
                    return uniqueCollisions.first!.value
                }
                // Try resolving the rest of the path for each collision ...
                let possibleMatches = collisions.compactMap {
                    return try? $0.node.children[nextPathComponent.name]?.find(nextPathComponent.kind, nextPathComponent.hash)
                }
                // If only one collision matches, return that match.
                if possibleMatches.count == 1 {
                    return possibleMatches.first!
                }
                // If all matches are the same symbol, return the Swift version of that symbol
                if !possibleMatches.isEmpty, possibleMatches.dropFirst().allSatisfy({ $0.symbol?.identifier.precise == possibleMatches.first!.symbol?.identifier.precise }) {
                    return possibleMatches.first(where: { $0.symbol?.identifier.interfaceLanguage == "swift" }) ?? possibleMatches.first!
                }
                // Couldn't resolve the collision by look ahead.
                return try handleCollision(node: node, parsedPath: parsedPathForError, remaining: remaining, collisions: collisions, onlyFindSymbols: onlyFindSymbols)
            }
        }
    }
                        
    private func handleCollision(
        node: Node,
        parsedPath: () -> [PathComponent],
        remaining: ArraySlice<PathComponent>,
        collisions: [(node: PathHierarchy.Node, disambiguation: String)],
        onlyFindSymbols: Bool
    ) throws -> Node {
        if let favoredMatch = collisions.singleMatch({ $0.node.isDisfavoredInCollision == false }) {
            return favoredMatch.node
        }
        // If a module has the same name as the article root (which is named after the bundle display name) then its possible
        // for an article a symbol to collide. Articles aren't supported in symbol links but symbols are supported in general
        // documentation links (although the non-symbol result is prioritized).
        //
        // There is a later check that the returned node is a symbol for symbol links, but that won't happen if the link is a
        // collision. To fully handle the collision in both directions, the check below uses `onlyFindSymbols` in the closure
        // so that only symbol matches are returned for symbol links (when `onlyFindSymbols` is `true`) and non-symbol matches
        // for general documentation links (when `onlyFindSymbols` is `false`).
        //
        // It's a more compact way to write
        //
        //     if onlyFindSymbols {
        //        return $0.node.symbol != nil
        //     } else {
        //        return $0.node.symbol == nil
        //     }
        if let symbolOrNonSymbolMatch = collisions.singleMatch({ ($0.node.symbol != nil) == onlyFindSymbols }) {
            return symbolOrNonSymbolMatch.node
        }
        
        throw Error.lookupCollision(
            partialResult: (
                node,
                Array(parsedPath().dropLast(remaining.count))
            ),
            remaining: Array(remaining),
            collisions: collisions.map { ($0.node, $0.disambiguation) }
        )
    }
    
    private func makePartialResultError(
        node: Node,
        parsedPath: [PathComponent],
        remaining: ArraySlice<PathComponent>
    ) -> Error {
        if let disambiguationTree = node.children[remaining.first!.name] {
            return Error.unknownDisambiguation(
                partialResult: (
                    node,
                    Array(parsedPath.dropLast(remaining.count))
                ),
                remaining: Array(remaining),
                candidates: disambiguationTree.disambiguatedValues().map {
                    (node: $0.value, disambiguation: String($0.disambiguation.makeSuffix().dropFirst()))
                }
            )
        }
        
        return Error.unknownName(
            partialResult: (
                node,
                Array(parsedPath.dropLast(remaining.count))
            ),
            remaining: Array(remaining),
            availableChildren: node.children.keys.sorted(by: availableChildNameIsBefore)
        )
    }
    
    /// Finds the child disambiguation tree for a given node that match the remaining path components.
    /// - Parameters:
    ///   - node: The current node.
    ///   - remaining: The remaining path components.
    /// - Returns: The child disambiguation tree and path component.
    private func findChildTree(node: inout Node, parsedPath: @autoclosure () -> [PathComponent], remaining: ArraySlice<PathComponent>) throws -> (DisambiguationTree, PathComponent) {
        var pathComponent = remaining.first!
        if let match = node.children[pathComponent.full] {
            // The path component parsing may treat dash separated words as disambiguation information.
            // If the parsed name didn't match, also try the original.
            pathComponent.kind = nil
            pathComponent.hash = nil
            return (match, pathComponent)
        } else if let match = node.children[pathComponent.name] {
            return (match, pathComponent)
        }
        // The search has ended with a node that doesn't have a child matching the next path component.
        throw makePartialResultError(node: node, parsedPath: parsedPath(), remaining: remaining)
    }
}

private extension Sequence {
    /// Returns the only element of the sequence that satisfies the given predicate.
    /// - Parameters:
    ///   - predicate: A closure that takes an element of the sequence as its argument and returns a Boolean value indicating whether the element is a match.
    /// - Returns: The only element of the sequence that satisfies `predicate`, or `nil` if  multiple elements satisfy the predicate or if no element satisfy the predicate.
    /// - Complexity: O(_n_), where _n_ is the length of the sequence.
    func singleMatch(_ predicate: (Element) -> Bool) -> Element? {
        var match: Element?
        for element in self where predicate(element) {
            guard match == nil else {
                // Found a second match. No need to check the rest of the sequence.
                return nil
            }
            match = element
        }
        return match
    }
}

extension PathHierarchy {
    /// A node in the path hierarchy.
    final class Node {
        /// The unique identifier for this node.
        fileprivate(set) var identifier: LanguageAwareUniqueTopicIdentifier!
        
        // Everything else is file-private or private.
        
        /// The name of this path component in the hierarchy.
        private(set) var name: String
        
        /// The descendants of this node in the hierarchy.
        /// Each name maps to a disambiguation tree that handles
        fileprivate private(set) var children: [String: DisambiguationTree]
        
        private(set) unowned var parent: Node?
        /// The symbol, if a node has one.
        private(set) var symbol: SymbolGraph.Symbol?
        
        /// If the path hierarchy should disfavor this node in a link collision.
        ///
        /// By default, nodes are not disfavored.
        ///
        /// If a favored node collides with a disfavored node the link will resolve to the favored node without
        /// requiring any disambiguation. Referencing the disfavored node requires disambiguation.
        var isDisfavoredInCollision: Bool
        
        /// Initializes a symbol node.
        fileprivate init(symbol: SymbolGraph.Symbol!) {
            let sourceLanguage = SourceLanguage(knownLanguageIdentifier: symbol.identifier.interfaceLanguage)!
            if symbol.kind.identifier == .module {
                self.identifier = UniqueTopicIdentifier(type: .container, id: symbol.preciseIdentifier ?? "", sourceLanguage: sourceLanguage).languageAware
            } else {
                self.identifier = UniqueTopicIdentifier(type: .symbol, id: symbol.preciseIdentifier ?? "", sourceLanguage: sourceLanguage).languageAware
            }
            self.symbol = symbol
            self.name = symbol.pathComponents.last!
            self.children = [:]
            self.isDisfavoredInCollision = false
        }
        
        /// Initializes a non-symbol node with a given name.
        fileprivate init(name: String, identifier: LanguageAwareUniqueTopicIdentifier) {
            self.identifier = identifier
            self.symbol = nil
            self.name = name
            self.children = [:]
            self.isDisfavoredInCollision = false
        }
        
        /// Adds a descendant to this node, providing disambiguation information from the node's symbol.
        fileprivate func add(symbolChild: Node) {
            precondition(symbolChild.symbol != nil)
            add(
                child: symbolChild,
                kind: symbolChild.symbol!.kind.identifier.identifier,
                hash: symbolChild.symbol!.identifier.precise.stableHashString
            )
        }
        
        /// Adds a descendant of this node.
        fileprivate func add(child: Node, kind: String?, hash: String?) {
            child.parent = self
            children[child.name, default: .init()].add(kind ?? "_", hash ?? "_", child)
        }
        
        /// Combines this node with another node.
        fileprivate func merge(with other: Node) {
            assert(self.parent?.symbol?.identifier.precise == other.parent?.symbol?.identifier.precise)
            self.children = self.children.merging(other.children, uniquingKeysWith: { $0.merge(with: $1) })
            
            for (_, tree) in self.children {
                for subtree in tree.storage.values {
                    for node in subtree.values {
                        node.parent = self
                    }
                }
            }
        }
    }
}

private extension PathHierarchy.Node {
    func matches(_ component: PathHierarchy.PathComponent) -> Bool {
        if let symbol = symbol {
            return name == component.name
            && (component.kind == nil || component.kind == symbol.kind.identifier.identifier)
            && (component.hash == nil || component.hash == symbol.identifier.precise.stableHashString)
        } else {
            return name == component.full
        }
    }
    
    func anyChildMatches(_ component: PathHierarchy.PathComponent) -> Bool {
        let keys = children.keys
        return keys.contains(component.name) || keys.contains(component.full)
    }
}

// MARK: Parsing documentation links

/// All known symbol kind identifiers.
///
/// This is used to identify parsed path components as kind information.
private let knownSymbolKinds = Set(SymbolGraph.Symbol.KindIdentifier.allCases.map { $0.identifier })
/// All known source language identifiers.
///
/// This is used to skip language prefixes from kind disambiguation information.
private let knownLanguagePrefixes = SourceLanguage.knownLanguages.flatMap { [$0.id] + $0.idAliases }.map { $0 + "." }

extension PathHierarchy {
    /// The parsed information for a documentation URI path component.
    struct PathComponent {
        /// The full original path component
        let full: String
        /// The parsed entity name
        let name: String
        /// The parsed entity kind, if any.
        var kind: String?
        /// The parsed entity hash, if any.
        var hash: String?
    }
    
    /// Parsed a documentation link path (and optional fragment) string into structured path component values.
    /// - Parameters:
    ///   - path: The documentation link string, containing a path and an optional fragment.
    ///   - omittingEmptyComponents: If empty path components should be omitted from the parsed path. By default the are omitted.
    /// - Returns: A pair of the parsed path components and a flag that indicate if the documentation link is absolute or not.
    static func parse(path: String, omittingEmptyComponents: Bool = true) -> (components: [PathComponent], isAbsolute: Bool) {
        guard !path.isEmpty else { return ([], true) }
        var components = path.split(separator: "/", omittingEmptySubsequences: omittingEmptyComponents)
        let isAbsolute = path.first == "/"
            || String(components.first ?? "") == NodeURLGenerator.Path.documentationFolderName
            || String(components.first ?? "") == NodeURLGenerator.Path.tutorialsFolderName

        // If there is a # character in the last component, split that into two components
        if let hashIndex = components.last?.firstIndex(of: "#") {
            let last = components.removeLast()
            // Allow anrhor-only links where there's nothing before #.
            // In case the pre-# part is empty, and we're omitting empty components, don't add it in.
            let pathName = last[..<hashIndex]
            if !pathName.isEmpty || !omittingEmptyComponents {
                components.append(pathName)
            }
            
            let fragment = String(last[hashIndex...].dropFirst())
            return (components.map(Self.parse(pathComponent:)) + [PathComponent(full: fragment, name: fragment, kind: nil, hash: nil)], isAbsolute)
        }
        
        return (components.map(Self.parse(pathComponent:)), isAbsolute)
    }
    
    /// Parses a single path component string into a structured format.
    private static func parse(pathComponent original: Substring) -> PathComponent {
        let full = String(original)
        guard let dashIndex = original.lastIndex(of: "-") else {
            return PathComponent(full: full, name: full, kind: nil, hash: nil)
        }
        
        let hash = String(original[dashIndex...].dropFirst())
        let name = String(original[..<dashIndex])
        
        func isValidHash(_ hash: String) -> Bool {
            var index: UInt8 = 0
            for char in hash.utf8 {
                guard index <= 5, (48...57).contains(char) || (97...122).contains(char) else { return false }
                index += 1
            }
            return true
        }
        
        if knownSymbolKinds.contains(hash) {
            // The parsed hash value is a symbol kind
            return PathComponent(full: full, name: name, kind: hash, hash: nil)
        }
        if let languagePrefix = knownLanguagePrefixes.first(where: { hash.starts(with: $0) }) {
            // The hash is actually a symbol kind with a language prefix
            return PathComponent(full: full, name: name, kind: String(hash.dropFirst(languagePrefix.count)), hash: nil)
        }
        if !isValidHash(hash) {
            // The parsed hash is neither a symbol not a valid hash. It's probably a hyphen-separated name.
            return PathComponent(full: full, name: full, kind: nil, hash: nil)
        }
        
        if let dashIndex = name.lastIndex(of: "-") {
            let kind = String(name[dashIndex...].dropFirst())
            let name = String(name[..<dashIndex])
            if let languagePrefix = knownLanguagePrefixes.first(where: { kind.starts(with: $0) }) {
                return PathComponent(full: full, name: name, kind: String(kind.dropFirst(languagePrefix.count)), hash: hash)
            } else {
                return PathComponent(full: full, name: name, kind: kind, hash: hash)
            }
        }
        return PathComponent(full: full, name: name, kind: nil, hash: hash)
    }
    
    static func joined<PathComponents>(_ pathComponents: PathComponents) -> String where PathComponents: Sequence, PathComponents.Element == PathComponent {
        return pathComponents.map(\.full).joined(separator: "/")
    }
}

// MARK: Determining disambiguated paths

private let nonAllowedPathCharacters = CharacterSet.urlPathAllowed.inverted

private func symbolFileName(_ symbolName: String) -> String {
    return symbolName.components(separatedBy: nonAllowedPathCharacters).joined(separator: "_")
}

extension PathHierarchy {
    /// Determines the least disambiguated paths for all symbols in the path hierarchy.
    ///
    /// - Parameters:
    ///   - includeDisambiguationForUnambiguousChildren: Whether or not descendants unique to a single collision should maintain the containers disambiguation.
    ///   - includeLanguage: Whether or not kind disambiguation information should include the source language.
    /// - Returns: A map of unique identifier strings to disambiguated file paths
    func caseInsensitiveDisambiguatedPaths(
        includeDisambiguationForUnambiguousChildren: Bool = false,
        includeLanguage: Bool = false
    ) -> [String: String] {
        func descend(_ node: Node, accumulatedPath: String) -> [(String, (String, Bool))] {
            var results: [(String, (String, Bool))] = []
            let caseInsensitiveChildren = [String: DisambiguationTree](node.children.map { (symbolFileName($0.key.lowercased()), $0.value) }, uniquingKeysWith: { $0.merge(with: $1) })
            
            for (_, tree) in caseInsensitiveChildren {
                let disambiguatedChildren = tree.disambiguatedValuesWithCollapsedUniqueSymbols(includeLanguage: includeLanguage)
                let uniqueNodesWithChildren = Set(disambiguatedChildren.filter { $0.disambiguation.value() != nil && !$0.value.children.isEmpty }.map { $0.value.symbol?.identifier.precise })
                for (node, disambiguation) in disambiguatedChildren {
                    var path: String
                    if node.identifier == nil && disambiguatedChildren.count == 1 {
                        // When descending through placeholder nodes, we trust that the known disambiguation
                        // that they were created with is necessary.
                        var knownDisambiguation = ""
                        let (kind, subtree) = tree.storage.first!
                        if kind != "_" {
                            knownDisambiguation += "-\(kind)"
                        }
                        let hash = subtree.keys.first!
                        if hash != "_" {
                            knownDisambiguation += "-\(hash)"
                        }
                        path = accumulatedPath + "/" + symbolFileName(node.name) + knownDisambiguation
                    } else {
                        path = accumulatedPath + "/" + symbolFileName(node.name)
                    }
                    if let symbol = node.symbol {
                        results.append(
                            (symbol.identifier.precise, (path + disambiguation.makeSuffix(), symbol.identifier.interfaceLanguage == "swift"))
                        )
                    }
                    if includeDisambiguationForUnambiguousChildren || uniqueNodesWithChildren.count > 1 {
                        path += disambiguation.makeSuffix()
                    }
                    results += descend(node, accumulatedPath: path)
                }
            }
            return results
        }
        
        var gathered: [(String, (String, Bool))] = []
        
        for (moduleName, node) in modules {
            let path = "/" + moduleName
            gathered.append(
                (moduleName, (path, node.symbol == nil || node.symbol!.identifier.interfaceLanguage == "swift"))
            )
            gathered += descend(node, accumulatedPath: path)
        }
        
        // If a symbol node exist in multiple languages, prioritize the Swift variant.
        let result = [String: (String, Bool)](gathered, uniquingKeysWith: { lhs, rhs in lhs.1 ? lhs : rhs }).mapValues({ $0.0 })
        
        assert(
            Set(result.values).count == result.keys.count,
            {
                let collisionDescriptions = result
                    .reduce(into: [String: [String]](), { $0[$1.value, default: []].append($1.key) })
                    .filter({ $0.value.count > 1 })
                    .map { "\($0.key)\n\($0.value.map({ "  " + $0 }).joined(separator: "\n"))" }
                return """
                Disambiguated paths contain \(collisionDescriptions.count) collision(s):
                \(collisionDescriptions.joined(separator: "\n"))
                """
            }()
        )
        
        return result
    }
}

// MARK: Traversing

extension PathHierarchy {
    /// Returns the list of top level symbols
    func topLevelSymbols() -> [LanguageAwareUniqueTopicIdentifier] {
        var result: Set<LanguageAwareUniqueTopicIdentifier> = []
        // Roots represent modules and only have direct symbol descendants.
        for root in modules.values {
            for (_, tree) in root.children {
                for subtree in tree.storage.values {
                    for node in subtree.values where node.symbol != nil {
                        result.insert(node.identifier)
                    }
                }
            }
        }
        return Array(result) + modules.values.map { $0.identifier }
    }
}

// MARK: Error messages

extension PathHierarchy {
    /// An error finding an entry in the path hierarchy.
    enum Error: Swift.Error {
        /// Information about the portion of a link that could be found.
        ///
        /// Includes information about:
        /// - The node that was found
        /// - The remaining portion of the path.
        typealias PartialResult = (node: Node, path: [PathComponent])
        
        /// No element was found at the beginning of the path.
        ///
        /// Includes information about:
        /// - The remaining portion of the path. This may be empty
        /// - A list of the names for the top level elements.
        case notFound(remaining: [PathComponent], availableChildren: Set<String>)
        
        /// Matched node does not correspond to a documentation page.
        ///
        /// For partial symbol graph files, sometimes sparse nodes that don't correspond to known documentation need to be created to form a hierarchy. These nodes are not findable.
        case unfindableMatch(Node)
        
        /// A symbol link found a non-symbol match.
        case nonSymbolMatchForSymbolLink
        
        /// Encountered an unknown disambiguation for a found node.
        ///
        /// Includes information about:
        /// - The partial result for as much of the path that could be found.
        /// - The remaining portion of the path.
        /// - A list of possible matches paired with the disambiguation suffixes needed to distinguish them.
        case unknownDisambiguation(partialResult: PartialResult, remaining: [PathComponent], candidates: [(node: Node, disambiguation: String)])
        
        /// Encountered an unknown name in the path.
        ///
        /// Includes information about:
        /// - The partial result for as much of the path that could be found.
        /// - The remaining portion of the path.
        /// - A list of the names for the children of the partial result.
        case unknownName(partialResult: PartialResult, remaining: [PathComponent], availableChildren: [String])
        
        /// Multiple matches are found partway through the path.
        ///
        /// Includes information about:
        /// - The partial result for as much of the path that could be found unambiguously.
        /// - The remaining portion of the path.
        /// - A list of possible matches paired with the disambiguation suffixes needed to distinguish them.
        case lookupCollision(partialResult: PartialResult, remaining: [PathComponent], collisions: [(node: Node, disambiguation: String)])
    }
}
    
/// A comparison/sort function for the list of names for the children of the partial result in a diagnostic.
private func availableChildNameIsBefore(_ lhs: String, _ rhs: String) -> Bool {
    return lhs.localizedCaseInsensitiveCompare(rhs) == .orderedAscending
}

extension PathHierarchy.Error {
    /// Generate a ``TopicReferenceResolutionError`` from this error using the given `context` and `originalReference`.
    ///
    /// The resulting ``TopicReferenceResolutionError`` is human-readable and provides helpful solutions.
    ///
    /// - Parameters:
    ///     - context: The ``DocumentationContext`` the `originalReference` was resolved in.
    ///     - originalReference: The raw input string that represents the body of the reference that failed to resolve. This string is
    ///     used to calculate the proper replacement-ranges for fixits.
    ///
    /// - Note: `Replacement`s produced by this function use `SourceLocation`s relative to the `originalReference`, i.e. the beginning
    /// of the _body_ of the original reference.
    func asTopicReferenceResolutionErrorInfo(context: DocumentationContext, originalReference: String) -> TopicReferenceResolutionErrorInfo {
        
        // This is defined inline because it captures `context`.
        func collisionIsBefore(_ lhs: (node: PathHierarchy.Node, disambiguation: String), _ rhs: (node: PathHierarchy.Node, disambiguation: String)) -> Bool {
            return lhs.node.fullNameOfValue(context: context) + lhs.disambiguation
                 < rhs.node.fullNameOfValue(context: context) + rhs.disambiguation
        }
        
        switch self {
        case .notFound(remaining: let remaining, availableChildren: let availableChildren):
            guard let firstPathComponent = remaining.first else {
                return TopicReferenceResolutionErrorInfo(
                    "No local documentation matches this reference"
                )
            }
            
            let solutions: [Solution]
            if let pathComponentIndex = originalReference.range(of: firstPathComponent.full) {
                let startColumn = originalReference.distance(from: originalReference.startIndex, to: pathComponentIndex.lowerBound)
                let replacementRange = SourceRange.makeRelativeRange(startColumn: startColumn, length: firstPathComponent.full.count)
                
                let nearMisses = NearMiss.bestMatches(for: availableChildren, against: firstPathComponent.name)
                solutions = nearMisses.map { candidate in
                    Solution(summary: "\(Self.replacementOperationDescription(from: firstPathComponent.full, to: candidate))", replacements: [
                        Replacement(range: replacementRange, replacement: candidate)
                    ])
                }
            } else {
                solutions = []
            }
            
            return TopicReferenceResolutionErrorInfo("""
                Can't resolve \(firstPathComponent.full.singleQuoted)
                """,
                solutions: solutions
            )

        case .unfindableMatch(let node):
            return TopicReferenceResolutionErrorInfo("""
                \(node.name.singleQuoted) can't be linked to in a partial documentation build
            """)

        case .nonSymbolMatchForSymbolLink:
            return TopicReferenceResolutionErrorInfo("Symbol links can only resolve symbols", solutions: [
                Solution(summary: "Use a '<doc:>' style reference.", replacements: [
                    // the SourceRange points to the opening double-backtick
                    Replacement(range: .makeRelativeRange(startColumn: -2, endColumn: 0), replacement: "<doc:"),
                    // the SourceRange points to the closing double-backtick
                    Replacement(range: .makeRelativeRange(startColumn: originalReference.count, endColumn: originalReference.count+2), replacement: ">"),
                ])
            ])
            
        case .unknownDisambiguation(partialResult: let partialResult, remaining: let remaining, candidates: let candidates):
            let nextPathComponent = remaining.first!
            var validPrefix = ""
            if !partialResult.path.isEmpty {
                validPrefix += PathHierarchy.joined(partialResult.path) + "/"
            }
            validPrefix += nextPathComponent.name
            
            let disambiguations = nextPathComponent.full.dropFirst(nextPathComponent.name.count)
            let replacementRange = SourceRange.makeRelativeRange(startColumn: validPrefix.count, length: disambiguations.count)
            
            let solutions: [Solution] = candidates
                .sorted(by: collisionIsBefore)
                .map { (node: PathHierarchy.Node, disambiguation: String) -> Solution in
                    return Solution(summary: "\(Self.replacementOperationDescription(from: disambiguations.dropFirst(), to: disambiguation)) for\n\(node.fullNameOfValue(context: context).singleQuoted)", replacements: [
                        Replacement(range: replacementRange, replacement: "-" + disambiguation)
                    ])
                }
            
            return TopicReferenceResolutionErrorInfo("""
                \(disambiguations.dropFirst().singleQuoted) isn't a disambiguation for \(nextPathComponent.name.singleQuoted) at \(partialResult.node.pathWithoutDisambiguation().singleQuoted)
                """,
                solutions: solutions,
                rangeAdjustment: .makeRelativeRange(startColumn: validPrefix.count, length: disambiguations.count)
            )
            
        case .unknownName(partialResult: let partialResult, remaining: let remaining, availableChildren: let availableChildren):
            let nextPathComponent = remaining.first!
            let nearMisses = NearMiss.bestMatches(for: availableChildren, against: nextPathComponent.name)
            
            // Use the authored disambiguation to try and reduce the possible near misses. For example, if the link was disambiguated with `-struct` we should
            // only make suggestions for similarly spelled structs.
            let filteredNearMisses = nearMisses.filter { name in
                (try? partialResult.node.children[name]?.find(nextPathComponent.kind, nextPathComponent.hash)) != nil
            }

            var validPrefix = ""
            if !partialResult.path.isEmpty {
                validPrefix += PathHierarchy.joined(partialResult.path) + "/"
            }
            let solutions: [Solution]
            if filteredNearMisses.isEmpty {
                // If there are no near-misses where the authored disambiguation narrow down the results, replace the full path component
                let replacementRange = SourceRange.makeRelativeRange(startColumn: validPrefix.count, length: nextPathComponent.full.count)
                solutions = nearMisses.map { candidate in
                    Solution(summary: "\(Self.replacementOperationDescription(from: nextPathComponent.full, to: candidate))", replacements: [
                        Replacement(range: replacementRange, replacement: candidate)
                    ])
                }
            } else {
                // If the authored disambiguation narrows down the possible near-misses, only replace the name part of the path component
                let replacementRange = SourceRange.makeRelativeRange(startColumn: validPrefix.count, length: nextPathComponent.name.count)
                solutions = filteredNearMisses.map { candidate in
                    Solution(summary: "\(Self.replacementOperationDescription(from: nextPathComponent.name, to: candidate))", replacements: [
                        Replacement(range: replacementRange, replacement: candidate)
                    ])
                }
            }
            
            return TopicReferenceResolutionErrorInfo("""
                \(nextPathComponent.full.singleQuoted) doesn't exist at \(partialResult.node.pathWithoutDisambiguation().singleQuoted)
                """,
                solutions: solutions,
                rangeAdjustment: .makeRelativeRange(startColumn: validPrefix.count, length: nextPathComponent.full.count)
            )
            
        case .lookupCollision(partialResult: let partialResult, remaining: let remaining, collisions: let collisions):
            let nextPathComponent = remaining.first!
            
            var validPrefix = ""
            if !partialResult.path.isEmpty {
                validPrefix += PathHierarchy.joined(partialResult.path) + "/"
            }
            validPrefix += nextPathComponent.name

            let disambiguations = nextPathComponent.full.dropFirst(nextPathComponent.name.count)
            let replacementRange = SourceRange.makeRelativeRange(startColumn: validPrefix.count, length: disambiguations.count)
            
            let solutions: [Solution] = collisions.sorted(by: collisionIsBefore).map { (node: PathHierarchy.Node, disambiguation: String) -> Solution in
                return Solution(summary: "\(Self.replacementOperationDescription(from: disambiguations.dropFirst(), to: disambiguation)) for\n\(node.fullNameOfValue(context: context).singleQuoted)", replacements: [
                    Replacement(range: replacementRange, replacement: "-" + disambiguation)
                ])
            }
            
            return TopicReferenceResolutionErrorInfo("""
                \(nextPathComponent.full.singleQuoted) is ambiguous at \(partialResult.node.pathWithoutDisambiguation().singleQuoted)
                """,
                solutions: solutions,
                rangeAdjustment: .makeRelativeRange(startColumn: validPrefix.count - nextPathComponent.full.count, length: nextPathComponent.full.count)
            )
        }
    }
    
    private static func replacementOperationDescription<S1: StringProtocol, S2: StringProtocol>(from: S1, to: S2) -> String {
        if from.isEmpty {
            return "Insert \(to.singleQuoted)"
        }
        if to.isEmpty {
            return "Remove \(from.singleQuoted)"
        }
        return "Replace \(from.singleQuoted) with \(to.singleQuoted)"
    }
}

private extension PathHierarchy.Node {
    /// Creates a path string without any disambiguation.
    ///
    /// > Note: This value is only intended for error messages and other presentation.
    func pathWithoutDisambiguation() -> String {
        var components = [name]
        var node = self
        while let parent = node.parent {
            components.insert(parent.name, at: 0)
            node = parent
        }
        return "/" + components.joined(separator: "/")
    }
    
    /// Determines the full name of a node's value using information from the documentation context.
    ///
    /// > Note: This value is only intended for error messages and other presentation.
    func fullNameOfValue(context: DocumentationContext) -> String {
        guard let identifier = identifier else { return name }
        if let symbol = symbol {
            if let fragments = symbol[mixin: SymbolGraph.Symbol.DeclarationFragments.self]?.declarationFragments {
                return fragments.map(\.spelling).joined().split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
            }
            return context.nodeWithSymbolIdentifier(symbol.identifier.precise)!.name.description
        }
        // This only gets called for PathHierarchy error messages, so hierarchyBasedLinkResolver is never nil.
        let reference = context.hierarchyBasedLinkResolver.resolvedReferenceMap[identifier]!
        if reference.fragment != nil {
            return context.nodeAnchorSections[reference]!.title
        } else {
            return context.documentationCache[reference]!.name.description
        }
    }
}

// MARK: Dump

/// A node in a tree structure that can be printed into a visual representation for debugging.
private struct DumpableNode {
    var name: String
    var children: [DumpableNode]
}

private extension PathHierarchy.Node {
    /// Maps the path hierarchy subtree into a representation that can be printed into a visual form for debugging.
    func dumpableNode() -> DumpableNode {
        // Each node is printed as 3-layer hierarchy with the child names, their kind disambiguation, and their hash disambiguation.
        return DumpableNode(
            name: symbol.map { "{ \($0.identifier.precise) : \($0.identifier.interfaceLanguage).\($0.kind.identifier.identifier) }" } ?? "[ \(name) ]",
            children: children.sorted(by: \.key).map { (key, disambiguationTree) -> DumpableNode in
                DumpableNode(
                    name: key,
                    children: disambiguationTree.storage.sorted(by: \.key).map { (kind, kindTree) -> DumpableNode in
                        DumpableNode(
                            name: kind,
                            children: kindTree.sorted(by: \.key).map { (usr, node) -> DumpableNode in
                                DumpableNode(
                                    name: usr,
                                    children: [node.dumpableNode()]
                                )
                            }
                        )
                    }
                )
            }
        )
    }
}

extension PathHierarchy {
    /// Creates a visual representation or the path hierarchy for debugging.
    func dump() -> String {
        var children = modules.sorted(by: \.key).map { $0.value.dumpableNode() }
        if articlesContainer.symbol == nil {
            children.append(articlesContainer.dumpableNode()) // The article parent can be the same node as the module
        }
        children.append(contentsOf: [tutorialContainer.dumpableNode(), tutorialOverviewContainer.dumpableNode()])
        
        let root = DumpableNode(name: ".", children: children)
        return Self.dump(root)
    }
    
    fileprivate static func dump(_ node: DumpableNode, decorator: String = "") -> String {
        var result = ""
        result.append("\(decorator) \(node.name)\n")
        
        let children = node.children
        for (index, child) in children.enumerated() {
            var decorator = decorator
            if decorator.hasSuffix("├") {
                decorator = decorator.dropLast() + "│"
            }
            if decorator.hasSuffix("╰") {
                decorator = decorator.dropLast() + " "
            }
            let newDecorator = decorator + " " + (index == children.count-1 ? "╰" : "├")
            result.append(dump(child, decorator: newDecorator))
        }
        return result
    }
}

// MARK: Removing nodes

extension PathHierarchy {
    // When unregistering a documentation bundle from a context, entries for that bundle should no longer be findable.
    // The below implementation marks nodes as "not findable" while leaving them in the hierarchy so that they can be
    // traversed.
    // This would be problematic if it happened repeatedly but in practice the path hierarchy will only be in this state
    // after unregistering a data provider until a new data provider is registered.
    
    /// Removes a node from the path hierarchy so that it can no longer be found.
    /// - Parameter id: The unique identifier for the node.
    mutating func removeNodeWithID(_ id: LanguageAwareUniqueTopicIdentifier) {
        // Remove the node from the lookup and unset its identifier
        lookup.removeValue(forKey: id)!.identifier = nil
    }
}

// MARK: Disambiguation tree

/// A fixed-depth tree that stores disambiguation information and finds values based on partial disambiguation.
private struct DisambiguationTree {
    // Each disambiguation tree is fixed at two levels and stores a limited number of values.
    // In practice, almost all trees store either 1, 2, or 3 elements with 1 being the most common.
    // It's very rare to have more than 10 values and 20+ values is extremely rare.
    //
    // Given this expected amount of data, a nested dictionary implementation performs well.
    private(set) var storage: [String: [String: PathHierarchy.Node]] = [:]
    
    /// Add a new value to the tree for a given pair of kind and hash disambiguations.
    /// - Parameters:
    ///   - kind: The kind disambiguation for this value.
    ///   - hash: The hash disambiguation for this value.
    ///   - value: The new value
    /// - Returns: If a value already exist with the same pair of kind and hash disambiguations.
    mutating func add(_ kind: String, _ hash: String, _ value: PathHierarchy.Node) {
        if let existing = storage[kind]?[hash] {
            existing.merge(with: value)
        } else if storage.count == 1, let existing = storage["_"]?["_"] {
            // It is possible for articles and other non-symbols to collide with unfindable symbol placeholder nodes.
            // When this happens, remove the placeholder node and move its children to the real (non-symbol) node.
            value.merge(with: existing)
            storage = [kind: [hash: value]]
        } else {
            storage[kind, default: [:]][hash] = value
        }
    }
    
    /// Combines the data from this tree with another tree to form a new, merged disambiguation tree.
    func merge(with other: DisambiguationTree) -> DisambiguationTree {
        return DisambiguationTree(storage: self.storage.merging(other.storage, uniquingKeysWith: { lhs, rhs in
            lhs.merging(rhs, uniquingKeysWith: {
                lhsValue, rhsValue in
                assert(lhsValue.symbol!.identifier.precise == rhsValue.symbol!.identifier.precise)
                return lhsValue
            })
        }))
    }
    
    /// Errors finding values in the disambiguation tree
    enum Error: Swift.Error {
        /// Multiple matches found.
        ///
        /// Includes a list of values paired with their missing disambiguation suffixes.
        case lookupCollision([(node: PathHierarchy.Node, disambiguation: String)])
    }
    
    /// Attempts to find a value in the disambiguation tree based on partial disambiguation information.
    ///
    /// There are 3 possible results:
    ///  - No match is found; indicated by a `nil` return value.
    ///  - Exactly one match is found; indicated by a non-nil return value.
    ///  - More than one match is found; indicated by a raised error listing the matches and their missing disambiguation.
    func find(_ kind: String?, _ hash: String?) throws -> PathHierarchy.Node? {
        if let kind = kind {
            // Need to match the provided kind
            guard let subtree = storage[kind] else { return nil }
            if let hash = hash {
                return subtree[hash]
            } else if subtree.count == 1 {
                return subtree.values.first
            } else {
                // Subtree contains more than one match.
                throw Error.lookupCollision(subtree.map { ($0.value, $0.key) })
            }
        } else if storage.count == 1, let subtree = storage.values.first {
            // Tree only contains one kind subtree
            if let hash = hash {
                return subtree[hash]
            } else if subtree.count == 1 {
                return subtree.values.first
            } else {
                // Subtree contains more than one match.
                throw Error.lookupCollision(subtree.map { ($0.value, $0.key) })
            }
        } else if let hash = hash {
            // Need to match the provided hash
            let kinds = storage.filter { $0.value.keys.contains(hash) }
            if kinds.isEmpty {
                return nil
            } else if kinds.count == 1 {
                return kinds.first!.value[hash]
            } else {
                // Subtree contains more than one match
                throw Error.lookupCollision(kinds.map { ($0.value[hash]!, $0.key) })
            }
        }
        // Disambiguate by a mix of kinds and USRs
        throw Error.lookupCollision(self.disambiguatedValues().map { ($0.value, $0.disambiguation.value()) })
    }
    
    /// Returns all values paired with their disambiguation suffixes.
    ///
    /// - Parameter includeLanguage: Whether or not the kind disambiguation information should include the language, for example: "swift".
    func disambiguatedValues(includeLanguage: Bool = false) -> [(value: PathHierarchy.Node, disambiguation: Disambiguation)] {
        if storage.count == 1 {
            let tree = storage.values.first!
            if tree.count == 1 {
                return [(tree.values.first!, .none)]
            }
        }
        
        var collisions: [(value: PathHierarchy.Node, disambiguation: Disambiguation)] = []
        for (kind, kindTree) in storage {
            if kindTree.count == 1 {
                // No other match has this kind
                if includeLanguage, let symbol = kindTree.first!.value.symbol {
                    collisions.append((value: kindTree.first!.value, disambiguation: .kind("\(SourceLanguage(id: symbol.identifier.interfaceLanguage).linkDisambiguationID).\(kind)")))
                } else {
                    collisions.append((value: kindTree.first!.value, disambiguation: .kind(kind)))
                }
                continue
            }
            for (usr, value) in kindTree {
                collisions.append((value: value, disambiguation: .hash(usr)))
            }
        }
        return collisions
    }
    
    /// Returns all values paired with their disambiguation suffixes without needing to disambiguate between two different versions of the same symbol.
    ///
    /// - Parameter includeLanguage: Whether or not the kind disambiguation information should include the language, for example: "swift".
    func disambiguatedValuesWithCollapsedUniqueSymbols(includeLanguage: Bool) -> [(value: PathHierarchy.Node, disambiguation: Disambiguation)] {
        typealias DisambiguationPair = (String, String)
        
        var uniqueSymbolIDs = [String: [DisambiguationPair]]()
        var nonSymbols = [DisambiguationPair]()
        for (kind, kindTree) in storage {
            for (hash, value) in kindTree {
                guard let symbol = value.symbol else {
                    nonSymbols.append((kind, hash))
                    continue
                }
                if symbol.identifier.interfaceLanguage == "swift" {
                    uniqueSymbolIDs[symbol.identifier.precise, default: []].insert((kind, hash), at: 0)
                } else {
                    uniqueSymbolIDs[symbol.identifier.precise, default: []].append((kind, hash))
                }
            }
        }
        
        var duplicateSymbols = [String: ArraySlice<DisambiguationPair>]()
        
        var new = DisambiguationTree()
        for (kind, hash) in nonSymbols {
            new.add(kind, hash, storage[kind]![hash]!)
        }
        for (id, symbolDisambiguations) in uniqueSymbolIDs {
            let (kind, hash) = symbolDisambiguations[0]
            new.add(kind, hash, storage[kind]![hash]!)
            
            if symbolDisambiguations.count > 1 {
                duplicateSymbols[id] = symbolDisambiguations.dropFirst()
            }
        }
     
        var disambiguated = new.disambiguatedValues(includeLanguage: includeLanguage)
        guard !duplicateSymbols.isEmpty else {
            return disambiguated
        }
        
        for (id, disambiguations) in duplicateSymbols {
            let primaryDisambiguation = disambiguated.first(where: { $0.value.symbol?.identifier.precise == id })!.disambiguation
            for (kind, hash) in disambiguations {
                disambiguated.append((storage[kind]![hash]!, primaryDisambiguation.updated(kind: kind, hash: hash)))
            }
        }
        
        return disambiguated
    }
    
    /// The computed disambiguation for a given path hierarchy node.
    enum Disambiguation {
        /// No disambiguation is needed.
        case none
        /// This node is disambiguated by its kind.
        case kind(String)
        /// This node is disambiguated by its hash.
        case hash(String)
       
        /// Returns the kind or hash value that disambiguates this node.
        func value() -> String! {
            switch self {
            case .none:
                return nil
            case .kind(let value), .hash(let value):
                return value
            }
        }
        /// Makes a new disambiguation suffix string.
        func makeSuffix() -> String {
            switch self {
            case .none:
                return ""
            case .kind(let value), .hash(let value):
                return "-"+value
            }
        }
        
        /// Creates a new disambiguation with a new kind or hash value.
        func updated(kind: String, hash: String) -> Self {
            switch self {
            case .none:
                return .none
            case .kind:
                return .kind(kind)
            case .hash:
                return .hash(hash)
            }
        }
    }
}

private extension SourceRange {
    static func makeRelativeRange(startColumn: Int, endColumn: Int) -> SourceRange {
        return SourceLocation(line: 0, column: startColumn, source: nil) ..< SourceLocation(line: 0, column: endColumn, source: nil)
    }
    
    static func makeRelativeRange(startColumn: Int, length: Int) -> SourceRange {
        return .makeRelativeRange(startColumn: startColumn, endColumn: startColumn + length)
    }
}

