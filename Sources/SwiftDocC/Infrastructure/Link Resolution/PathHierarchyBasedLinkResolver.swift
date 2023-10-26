/*
 This source file is part of the Swift.org open source project

 Copyright (c) 2022-2023 Apple Inc. and the Swift project authors
 Licensed under Apache License v2.0 with Runtime Library Exception

 See https://swift.org/LICENSE.txt for license information
 See https://swift.org/CONTRIBUTORS.txt for Swift project authors
*/

import Foundation
import SymbolKit

/// A type that encapsulates resolving links by searching a hierarchy of path components.
final class PathHierarchyBasedLinkResolver {
    /// A hierarchy of path components used to resolve links in the documentation.
    private(set) var pathHierarchy: PathHierarchy!
    
    /// Map between resolved identifiers and resolved topic references.
    private(set) var resolvedReferenceMap = BidirectionalMap<ResolvedIdentifier, UniqueTopicIdentifier>()
    
    /// Initializes a link resolver with a given path hierarchy.
    init(pathHierarchy: PathHierarchy) {
        self.pathHierarchy = pathHierarchy
    }
    
    /// Remove all matches from a given documentation bundle from the link resolver.
    func unregisterBundle(identifier: BundleIdentifier) {
        var newMap = BidirectionalMap<ResolvedIdentifier, UniqueTopicIdentifier>()
        for (id, reference) in resolvedReferenceMap {
            if reference.bundleIdentifier == identifier {
                pathHierarchy.removeNodeWithID(id)
            } else {
                newMap[id] = reference
            }
        }
        resolvedReferenceMap = newMap
    }
    
    func moduleUniqueIdentifier(for moduleName: String) -> UniqueTopicIdentifier? {
        guard let moduleIdentifier = pathHierarchy.modules[moduleName]?.identifier else { return nil }
        return resolvedReferenceMap[moduleIdentifier]
    }
    
    func parent(of reference: UniqueTopicIdentifier) -> UniqueTopicIdentifier? {
        guard let resolvedID = resolvedReferenceMap[reference],
              let parentID = pathHierarchy.lookup[resolvedID]?.parent?.identifier else {
            return nil
        }
        
        return resolvedReferenceMap[parentID]
    }
    
    /// Creates a path string—that can be used to find documentation in the path hierarchy—from an unresolved topic reference,
    private static func path(for unresolved: UnresolvedTopicReference) -> String {
        guard let fragment = unresolved.fragment else {
            return unresolved.path
        }
        return "\(unresolved.path)#\(urlReadableFragment(fragment))"
    }
    
    /// Traverse all the pairs of symbols and their parents.
    func traverseSymbolAndParentPairs(_ observe: (_ symbol: UniqueTopicIdentifier, _ parent: UniqueTopicIdentifier) -> Void) {
        for (id, node) in pathHierarchy.lookup {
            guard node.symbol != nil else { continue }
            
            guard let parentID = node.parent?.identifier else { continue }
            
            // Only symbols in the symbol index are added to the reference map.
            guard let reference = resolvedReferenceMap[id], let parentReference = resolvedReferenceMap[parentID] else { continue }
            observe(reference, parentReference)
        }
    }
    
    /// Returns a list of all the top level symbols.
    func topLevelSymbols() -> [UniqueTopicIdentifier] {
        return pathHierarchy.topLevelSymbols().map { resolvedReferenceMap[$0]! }
    }
    
    /// Returns a list of all module symbols.
    func modules() -> [UniqueTopicIdentifier] {
        return pathHierarchy.modules.values.map { resolvedReferenceMap[$0.identifier]! }
    }
    
    // MARK: - Adding non-symbols
    
    private(set) var tutorialContainerID: UniqueTopicIdentifier!
    private(set) var articlesContainerID: UniqueTopicIdentifier!
    private(set) var tutorialRootContainerID: UniqueTopicIdentifier!
    
    /// Map the resolved identifiers to resolved topic references for a given bundle's article, tutorial, and technology root pages.
    func addMappingForRoots(bundle: DocumentationBundle) {
        tutorialContainerID = UniqueTopicIdentifierGenerator.identifierForTutorialTechnology(technologyName: bundle.displayName, bundleIdentifier: bundle.identifier)
        resolvedReferenceMap[pathHierarchy.tutorialContainer.identifier] = tutorialContainerID
        
         articlesContainerID = UniqueTopicIdentifierGenerator.identifierForArticlesRoot(articleName: bundle.displayName, bundleIdentifier: bundle.identifier)
        resolvedReferenceMap[pathHierarchy.articlesContainer.identifier] = articlesContainerID
        
        tutorialRootContainerID = UniqueTopicIdentifierGenerator.identifierForTutorialsRoot(bundleIdentifier: bundle.identifier)
        resolvedReferenceMap[pathHierarchy.tutorialOverviewContainer.identifier] = tutorialRootContainerID
    }
    
    /// Map the resolved identifiers to resolved topic references for all symbols in the given symbol index.
    func addMappingForSymbols(symbolIndex: [String: UniqueTopicIdentifier]) {
        for (id, node) in pathHierarchy.lookup {
            guard let symbol = node.symbol, let reference = symbolIndex[symbol.identifier.precise] else {
                continue
            }
            resolvedReferenceMap[id] = reference
        }
    }
    
    /// Adds a tutorial and its landmarks to the path hierarchy.
    func addTutorial(_ tutorial: DocumentationContext.SemanticResult<Tutorial>, bundleIdentifier: BundleIdentifier) {
        addTutorial(
            identifier: 
                UniqueTopicIdentifierGenerator.identifierForSemantic(
                    tutorial.value,
                    source: tutorial.source,
                    bundleIdentifier: bundleIdentifier
                ),
            source: tutorial.source,
            landmarks: tutorial.value.landmarks
        )
    }
    
    /// Adds a tutorial article and its landmarks to the path hierarchy.
    func addTutorialArticle(_ tutorial: DocumentationContext.SemanticResult<TutorialArticle>, bundleIdentifier: BundleIdentifier) {
        addTutorial(
            identifier: 
                UniqueTopicIdentifierGenerator.identifierForSemantic(
                    tutorial.value,
                    source: tutorial.source,
                    bundleIdentifier: bundleIdentifier
                ),
            source: tutorial.source,
            landmarks: tutorial.value.landmarks
        )
    }
    
    private func addTutorial(identifier: UniqueTopicIdentifier, source: URL, landmarks: [Landmark]) {
        let tutorialID = pathHierarchy.addTutorial(name: urlReadablePath(source.deletingPathExtension().lastPathComponent))
        resolvedReferenceMap[tutorialID] = identifier
        
        for landmark in landmarks {
            let landmarkID = pathHierarchy.addNonSymbolChild(parent: tutorialID, name: urlReadableFragment(landmark.title), kind: "landmark")
            resolvedReferenceMap[landmarkID] = identifier.addingFragment(landmark.title)
        }
    }
    
    /// Adds a technology and its volumes and chapters to the path hierarchy.
    func addTechnology(_ technology: DocumentationContext.SemanticResult<Technology>, bundleIdentifier: BundleIdentifier) {
        let reference = UniqueTopicIdentifierGenerator.identifierForSemantic(technology.value, source: technology.source, bundleIdentifier: bundleIdentifier)

        let technologyID = pathHierarchy.addTutorialOverview(name: urlReadablePath(technology.source.deletingPathExtension().lastPathComponent))
        resolvedReferenceMap[technologyID] = reference
        
        var anonymousVolumeID: ResolvedIdentifier?
        for volume in technology.value.volumes {
            if anonymousVolumeID == nil, volume.name == nil {
                anonymousVolumeID = pathHierarchy.addNonSymbolChild(parent: technologyID, name: "$volume", kind: "volume")
                resolvedReferenceMap[anonymousVolumeID!] = UniqueTopicIdentifierGenerator.identifierForTutorialVolume(technologyName: reference.id, volumeName: "$volume", bundleIdentifier: bundleIdentifier)
            }
            
            let chapterParentID: ResolvedIdentifier
            let chapterParentReference: UniqueTopicIdentifier
            if let name = volume.name {
                chapterParentID = pathHierarchy.addNonSymbolChild(parent: technologyID, name: name, kind: "volume")
                chapterParentReference = UniqueTopicIdentifierGenerator.identifierForTutorialVolume(technologyName: reference.id, volumeName: name, bundleIdentifier: bundleIdentifier)
                resolvedReferenceMap[chapterParentID] = chapterParentReference
            } else {
                chapterParentID = technologyID
                chapterParentReference = reference
            }
            
            for chapter in volume.chapters {
                let chapterID = pathHierarchy.addNonSymbolChild(parent: technologyID, name: chapter.name, kind: "volume")
                resolvedReferenceMap[chapterID] = UniqueTopicIdentifierGenerator.identifierForTutorialChapter(parentName: chapterParentReference.id, chapterName: chapter.name, bundleIdentifier: bundleIdentifier)
            }
        }
    }
    
    /// Adds a technology root article and its headings to the path hierarchy.
    func addRootArticle(_ article: DocumentationContext.SemanticResult<Article>, anchorSections: [AnchorSection], bundleIdentifier: BundleIdentifier) {
        let articleID = pathHierarchy.addTechnologyRoot(name: article.source.deletingPathExtension().lastPathComponent)
        resolvedReferenceMap[articleID] = UniqueTopicIdentifierGenerator.identifierForSemantic(article.value, source: article.source, bundleIdentifier: bundleIdentifier)
        addAnchors(anchorSections, to: articleID)
    }
    
    /// Adds an article and its headings to the path hierarchy.
    func addArticle(_ article: DocumentationContext.SemanticResult<Article>, anchorSections: [AnchorSection], bundleIdentifier: BundleIdentifier) {
        let articleID = pathHierarchy.addArticle(name: article.source.deletingPathExtension().lastPathComponent)
        resolvedReferenceMap[articleID] = UniqueTopicIdentifierGenerator.identifierForSemantic(article.value, source: article.source, bundleIdentifier: bundleIdentifier)
        addAnchors(anchorSections, to: articleID)
    }
    
    /// Adds an article and its headings to the path hierarchy.
    func addArticle(filename: String, reference: UniqueTopicIdentifier, anchorSections: [AnchorSection]) {
        let articleID = pathHierarchy.addArticle(name: filename)
        resolvedReferenceMap[articleID] = reference
        addAnchors(anchorSections, to: articleID)
    }
    
    /// Adds the headings for all symbols in the symbol index to the path hierarchy.
    func addAnchorForSymbols(symbolIndex: [String: UniqueTopicIdentifier], documentationCache: [UniqueTopicIdentifier: DocumentationNode]) {
        for (id, node) in pathHierarchy.lookup {
            guard let symbol = node.symbol, let reference = symbolIndex[symbol.identifier.precise], let node = documentationCache[reference] else { continue }
            addAnchors(node.anchorSections, to: id)
        }
    }
    
    private func addAnchors(_ anchorSections: [AnchorSection], to parent: ResolvedIdentifier) {
        for anchor in anchorSections {
            let identifier = pathHierarchy.addNonSymbolChild(parent: parent, name: anchor.reference.fragment!, kind: "anchor")
            resolvedReferenceMap[identifier] = resolvedReferenceMap[parent]?.addingFragment(anchor.reference.fragment!)
        }
    }
    
    /// Adds a task group on a given page to the documentation hierarchy.
    func addTaskGroup(named name: String, to parent: UniqueTopicIdentifier) -> UniqueTopicIdentifier {
        let parentID = resolvedReferenceMap[parent]!
        let taskGroupID = pathHierarchy.addNonSymbolChild(parent: parentID, name: urlReadablePath(name), kind: "taskGroup")
        let reference = UniqueTopicIdentifierGenerator.identifierForCollection(name: name, parent: parent, bundleIdentifier: parent.bundleIdentifier)
        resolvedReferenceMap[taskGroupID] = reference
        return reference
    }
    
    // MARK: Reference resolving
    
    /// Attempts to resolve an unresolved reference.
    ///
    /// - Parameters:
    ///   - unresolvedReference: The unresolved reference to resolve.
    ///   - parent: The parent reference to resolve the unresolved reference relative to.
    ///   - isCurrentlyResolvingSymbolLink: Whether or not the documentation link is a symbol link.
    ///   - context: The documentation context to resolve the link in.
    /// - Returns: The result of resolving the reference.
    func resolve(_ unresolvedReference: UnresolvedTopicReference, in parent: UniqueTopicIdentifier, fromSymbolLink isCurrentlyResolvingSymbolLink: Bool, context: DocumentationContext) throws -> TopicReferenceResolutionResult {
        let parentID = resolvedReferenceMap[parent]
        let found = try pathHierarchy.find(path: Self.path(for: unresolvedReference), parent: parentID, onlyFindSymbols: isCurrentlyResolvingSymbolLink)
        guard let foundReference = resolvedReferenceMap[found] else {
            // It's possible for the path hierarchy to find a symbol that the local build doesn't create a page for. Such symbols can't be linked to.
            let simplifiedFoundPath = sequence(first: pathHierarchy.lookup[found]!, next: \.parent)
                .map(\.name).reversed().joined(separator: "/")
            return .failure(unresolvedReference, .init("\(simplifiedFoundPath.singleQuoted) has no page and isn't available for linking."))
        }
        
        return .success(foundReference)
    }
    
    func fullName(of node: PathHierarchy.Node, in context: DocumentationContext) -> String {
        guard let identifier = node.identifier else { return node.name }
        if let symbol = node.symbol {
            if let fragments = symbol.declarationFragments {
                return fragments.map(\.spelling).joined().split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
            }
            return symbol.names.title
        }
        let reference = resolvedReferenceMap[identifier]!
        if reference.fragment != nil {
            return context.nodeAnchorSections[reference]!.title
        } else {
            return context.documentationCache[reference]!.name.description
        }
    }
    
    // MARK: Symbol reference creation
    
    /// Returns a map between symbol identifiers and topic references.
    ///
    /// - Parameters:
    ///   - symbolGraph: The complete symbol graph to walk through.
    ///   - bundle: The bundle to use when creating symbol references.
    func referencesForSymbols(in unifiedGraphs: [String: UnifiedSymbolGraph], bundle: DocumentationBundle, context: DocumentationContext) -> [SymbolGraph.Symbol.Identifier: UniqueTopicIdentifier] {
        let disambiguatedPaths = pathHierarchy.caseInsensitiveDisambiguatedPaths(includeDisambiguationForUnambiguousChildren: true, includeLanguage: true)
        
        var result: [SymbolGraph.Symbol.Identifier: UniqueTopicIdentifier] = [:]
        
        for (moduleName, symbolGraph) in unifiedGraphs {
            let references: [UniqueTopicIdentifier?] = Array(symbolGraph.symbols.values).concurrentMap { unifiedSymbol -> UniqueTopicIdentifier? in
                let symbol = unifiedSymbol
                let uniqueIdentifier = unifiedSymbol.uniqueIdentifier
                
                return UniqueTopicIdentifierGenerator.identifierForSymbol(preciseIdentifier: uniqueIdentifier, bundleIdentifier: bundle.identifier).withSourceLanguages(symbol.sourceLanguages)
            }
            for (symbol, reference) in zip(symbolGraph.symbols.values, references) {
                guard let reference = reference else { continue }
                result[symbol.defaultIdentifier] = reference
            }
        }
        return result
    }
}
