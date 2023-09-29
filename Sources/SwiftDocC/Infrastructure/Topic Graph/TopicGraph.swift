/*
 This source file is part of the Swift.org open source project

 Copyright (c) 2021-2023 Apple Inc. and the Swift project authors
 Licensed under Apache License v2.0 with Runtime Library Exception

 See https://swift.org/LICENSE.txt for license information
 See https://swift.org/CONTRIBUTORS.txt for Swift project authors
*/

import Foundation
import Markdown

/**
 A directed graph of topics.
 
 Nodes represent a pointer to a `DocumentationNode`, the source of its contents, and a short title.
 */
struct TopicGraph {
    /// A decision about whether to continue a depth-first or breadth-first traversal after visiting a node.
    enum Traversal {
        /// Stop here, do not visit any more nodes.
        case stop
        
        /// Continue to visit nodes.
        case `continue`
    }
    
    /// A node in the graph.
    class Node: Hashable, CustomDebugStringConvertible {
        /// The location of the node's contents.
        enum ContentLocation: Hashable {

            // TODO: make this take multiple URLs?
            /// The node exists as a whole file at some URL.
            case file(url: URL)
            
            /// The node exists as a subrange in a file at some URL, such as a documentation comment in source code.
            case range(SourceRange, url: URL)
            
            /// The node exist externally and doesn't have a local source.
            case external
            
            static func == (lhs: ContentLocation, rhs: ContentLocation) -> Bool {
                switch (lhs, rhs) {
                case (.file(let lhsURL), .file(let rhsURL)):
                    return lhsURL == rhsURL
                case (.range(let lhsRange, let lhsURL), .range(let rhsRange, let rhsURL)):
                    return lhsRange == rhsRange && lhsURL == rhsURL
                case (.external, .external):
                    return true
                default:
                    return false
                }
            }
            
            func hash(into hasher: inout Hasher) {
                switch self {
                case .file(let url):
                    hasher.combine(1)
                    hasher.combine(url)
                case .range(let range, let url):
                    hasher.combine(2)
                    hasher.combine(range)
                    hasher.combine(url)
                case .external:
                    hasher.combine(3)
                }
            }
        }
        
        /// The identifier for the `DocumentationNode` this node represents.
        let identifier: UniqueTopicIdentifier
        
        /// The reference to the `DocumentationNode` this node represents.
        let reference: ResolvedTopicReference
        
        /// The kind of node.
        let kind: DocumentationNode.Kind
        
        /// The source of the node.
        let source: ContentLocation
        
        /// A short display title of the node.
        let title: String
        
        /// If true, the hierarchy path is resolvable.
        let isResolvable: Bool
        
        /// If true, the topic should not be rendered and exists solely to mark relationships.
        let isVirtual: Bool

        /// If true, the topic has been removed from the hierarchy due to being an extension whose children have been curated elsewhere.
        let isEmptyExtension: Bool
        
        init(identifier: UniqueTopicIdentifier, reference: ResolvedTopicReference, kind: DocumentationNode.Kind, source: ContentLocation, title: String, isResolvable: Bool = true, isVirtual: Bool = false, isEmptyExtension: Bool = false) {
            self.identifier = identifier
            self.reference = reference
            self.kind = kind
            self.source = source
            self.title = title
            self.isResolvable = isResolvable
            self.isVirtual = isVirtual
            self.isEmptyExtension = isEmptyExtension
        }
        
        func withIdentifier(_ identifier: UniqueTopicIdentifier) -> Node {
            Node(identifier: identifier, reference: reference, kind: kind, source: source, title: title)
        }
        
        func withReference(_ reference: ResolvedTopicReference) -> Node {
            Node(identifier: identifier, reference: reference, kind: kind, source: source, title: title)
        }
        
        func hash(into hasher: inout Hasher) {
            hasher.combine(identifier)
        }
        
        var debugDescription: String {
            return "TopicGraph.Node(identifier: \(identifier), kind: \(kind), source: \(source), title: \(title)"
        }
        
        static func == (lhs: Node, rhs: Node) -> Bool {
            return lhs.identifier == rhs.identifier
        }
    }
        
    /// The nodes in the graph.
    var nodes: [UniqueTopicIdentifier: Node]
    
    /// The edges in the graph.
    var edges: [UniqueTopicIdentifier: [UniqueTopicIdentifier]]
    /// A reversed lookup of the graph's edges.
    var reverseEdges: [UniqueTopicIdentifier: [UniqueTopicIdentifier]]
    
    /// Create an empty topic graph.
    init() {
        edges = [:]
        nodes = [:]
        reverseEdges = [:]
    }
    
    /// Adds a node to the graph.
    mutating func addNode(_ node: Node) {
        guard nodes[node.identifier] == nil else {
            return
        }
        nodes[node.identifier] = node
    }
    
    mutating func updateReference(_ old: ResolvedTopicReference, newReference: ResolvedTopicReference) {
        guard old != newReference else { return }
        assert(old.identifier == newReference.identifier)
        
        let node = nodes[old.identifier]!
        nodes.updateValue(node.withReference(newReference), forKey: old.identifier)
    }
    
    /// Replaces one node with another in the graph, and preserves the edges.
    mutating func replaceNode(_ node: Node, with newNode: Node) {
        if let childEdges = edges.removeValue(forKey: node.identifier) {
            for childID in childEdges {
                // We found this relationship via the node's edge so it's guaranteed to exist in reverseEdges
                let oldIndex = reverseEdges[childID]!.firstIndex(of: node.identifier)!
                reverseEdges[childID]!.remove(at: oldIndex)
                reverseEdges[childID]!.append(newNode.identifier)
            }
            
            edges[newNode.identifier] = childEdges
        }
        
        if let parentEdges = reverseEdges[node.identifier] {
            for parentID in parentEdges {
                // We found this relationship via the node's reverse edges so it's guaranteed to exist in reverseEdges
                let oldIndex = edges[parentID]!.firstIndex(of: node.identifier)!
                edges[parentID]!.remove(at: oldIndex)
                edges[parentID]!.append(newNode.identifier)
            }
        }
        
        nodes.removeValue(forKey: node.identifier)
        addNode(newNode)
    }
    
    /// Adds a topic edge but it doesn't verify if the nodes exist for the given references.
    /// > Warning: If the references don't match already existing nodes this operation might corrupt the topic graph.
    /// - Parameters:
    ///   - source: A source for the new edge.
    ///   - target: A target for the new edge.
    mutating func unsafelyAddEdge(source: UniqueTopicIdentifier, target: UniqueTopicIdentifier) {
        precondition(source != target, "Attempting to add edge between two equal nodes. \nsource: \(source)\ntarget: \(target)\n")
        
        // Do not add the edge if it exists already.
        guard edges[source]?.contains(target) != true else {
            return
        }
        
        edges[source, default: []].append(target)
        reverseEdges[target, default: []].append(source)
    }
    
    /**
     Adds a directed edge from a source node to a target node.
     - Note: Implicitly adds the `source` and `target` nodes to the graph, if they haven't been added yet.
     - Warning: A precondition is `source != target`.
     */
    mutating func addEdge(from source: Node, to target: Node) {
        precondition(source != target, "Attempting to add edge between two equal nodes. \nsource: \(source)\ntarget: \(target)\n")
        addNode(source)
        addNode(target)
        
        // Do not add the edge if it exists already.
        guard edges[source.identifier]?.contains(target.identifier) != true else {
            return
        }
        
        edges[source.identifier, default: []].append(target.identifier)
        reverseEdges[target.identifier, default: []].append(source.identifier)
    }
    
    /// Removes the edges for a given node.
    ///
    /// For example, when a symbol's children are curated we need to remove
    /// the symbol-graph vended children.
    mutating func removeEdges(from source: Node) {
        guard edges.keys.contains(source.identifier) else {
            return
        }
        for target in edges[source.identifier, default: []] {
            reverseEdges[target]!.removeAll(where: { $0 == source.identifier})
        }
        
        edges[source.identifier] = []
    }

    mutating func removeEdges(to target: Node) {
        guard reverseEdges.keys.contains(target.identifier) else {
            return
        }

        for source in reverseEdges[target.identifier, default: []] {
            edges[source]!.removeAll(where: { $0 == target.identifier})
        }

        reverseEdges[target.identifier] = []
    }

    /// Removes the edge from one reference to another.
    /// - Parameters:
    ///   - source: The parent reference in the edge.
    ///   - target: The child reference in the edge.
    mutating func removeEdge(fromIdentifier source: UniqueTopicIdentifier, toIdentifier target: UniqueTopicIdentifier) {
        guard var nodeEdges = edges[source],
            let index = nodeEdges.firstIndex(of: target) else {
            return
        }
        
        reverseEdges[target]?.removeAll(where: { $0 == source })
        
        nodeEdges.remove(at: index)
        edges[source] = nodeEdges
    }

    /// Returns a ``Node`` in the graph with the given `identifier` if it exists.
    func nodeWithIdentifier(_ identifier: UniqueTopicIdentifier) -> Node? {
        return nodes[identifier]
    }
    
    /// Returns a ``Node`` in the graph with the given reference if it exists.
    func nodeWithReference(_ reference: ResolvedTopicReference) -> Node? {
        return nodes[reference.identifier]
    }
    
    /// Returns the targets of the given ``Node``.
    subscript(node: Node) -> [UniqueTopicIdentifier] {
        return edges[node.identifier] ?? []
    }
    
    /// Traverses the graph depth-first and passes each node to `observe`.
    func traverseDepthFirst(from startingNode: Node, _ observe: (Node) -> Traversal) {
        var seen = Set<Node>()
        var nodesToVisit = [startingNode]
        while !nodesToVisit.isEmpty {
            let node = nodesToVisit.removeLast()
            guard !seen.contains(node) else {
                continue
            }
            let children = self[node].map {
                nodeWithIdentifier($0)!
            }
            nodesToVisit.append(contentsOf: children)
            guard case .continue = observe(node) else {
                break
            }
            seen.insert(node)
        }
    }
    
    /// Traverses the graph breadth-first and passes each node to `observe`.
    func traverseBreadthFirst(from startingNode: Node, _ observe: (Node) -> Traversal) {
        var seen = Set<Node>()
        var nodesToVisit = [startingNode]
        while !nodesToVisit.isEmpty {
            let node = nodesToVisit.removeFirst()
            guard !seen.contains(node) else {
                continue
            }
            let children = self[node].map {
                nodeWithIdentifier($0)!
            }
            nodesToVisit.append(contentsOf: children)
            guard case .continue = observe(node) else {
                break
            }
            seen.insert(node)
        }
    }

    /// Returns true if a node exists with the given reference and it's set as linkable.
    func isLinkable(_ identifier: UniqueTopicIdentifier) -> Bool {
        // Sections (represented by the node path + fragment with the section name)
        // don't have nodes in the topic graph so we verify that
        // the path without the fragment is resolvable.
        return nodeWithIdentifier(identifier.removingFragment())?.isResolvable == true
    }
    
    func isLinkable(_ reference: ResolvedTopicReference) -> Bool {
        return nodeWithReference(reference.withFragment(nil))?.isResolvable == true
    }
    
    /// Generates a hierarchical dump of the topic graph, starting at the given node.
    ///
    /// To print the graph using the absolute URL of each node use:
    /// ```swift
    /// print(topicGraph.dump(startingAt: moduleNode, keyPath: \.reference.absoluteString))
    /// ```
    /// This will produce output along the lines of:
    /// ```
    /// doc://com.testbundle/documentation/MyFramework
    /// ├ doc://com.testbundle/documentation/MyFramework/MyProtocol
    /// │ ╰ doc://com.testbundle/documentation/MyFramework/MyClass
    /// │   ├ doc://com.testbundle/documentation/MyFramework/MyClass/myfunction()
    /// │   ╰ doc://com.testbundle/documentation/MyFramework/MyClass/init()
    /// ...
    /// ```
    func dump(startingAt node: Node, keyPath: KeyPath<TopicGraph.Node, String> = \.title, decorator: String = "") -> String {
        var result = ""
        result.append("\(decorator) \(node[keyPath: keyPath])\r\n")
        if let childEdges = edges[node.identifier]?.sorted(by: { self.nodes[$0]!.reference.description < self.nodes[$1]!.reference.description }) {
            for (index, childID) in childEdges.enumerated() {
                var decorator = decorator
                if decorator.hasSuffix("├") {
                    decorator = decorator.dropLast() + "│"
                }
                if decorator.hasSuffix("╰") {
                    decorator = decorator.dropLast() + " "
                }
                let newDecorator = decorator + " " + (index == childEdges.count-1 ? "╰" : "├")
                if let node = nodeWithIdentifier(childID) {
                    // We recurse into the child's hierarchy only if it's a legit topic node;
                    // otherwise, when for example this is a symbol curated via external resolving and it's
                    // not found in the current topic graph, we skip it.
                    result.append(dump(startingAt: node, keyPath: keyPath, decorator: newDecorator))
                }
            }
        }
        return result
    }
}
