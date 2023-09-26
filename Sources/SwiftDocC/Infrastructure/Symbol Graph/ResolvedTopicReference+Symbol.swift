/*
 This source file is part of the Swift.org open source project

 Copyright (c) 2021 Apple Inc. and the Swift project authors
 Licensed under Apache License v2.0 with Runtime Library Exception

 See https://swift.org/LICENSE.txt for license information
 See https://swift.org/CONTRIBUTORS.txt for Swift project authors
*/

import SymbolKit

extension ResolvedTopicReference {
    /// Creates a resolved topic reference out of a symbol reference.
    /// - Parameters:
    ///   - symbolReference: A reference to a symbol.
    ///   - moduleName: The module, to which the symbol belongs.
    ///   - bundle: A documentation bundle, to which the symbol belongs.
    init(symbolReference: SymbolReference, moduleName: String, bundle: DocumentationBundle) {
        let path = symbolReference.path.isEmpty ? "" : "/" + symbolReference.path
        
        let identifier = UniqueTopicIdentifier(type: .symbol, id: symbolReference.preciseIdentifier, bundleIdentifier: bundle.identifier, bundleDisplayName: bundle.displayName)
        self = bundle.documentationRootReference.appendingPath(moduleName + path, identifier: identifier).withSourceLanguages(symbolReference.interfaceLanguages)
    }
    
    init(moduleName: String, bundle: DocumentationBundle, interfaceLanguages: Set<SourceLanguage>) {
        let identifier = UniqueTopicIdentifier(type: .container, id: moduleName, bundleIdentifier: bundle.identifier, bundleDisplayName: bundle.displayName)
        self = bundle.documentationRootReference.appendingPath(moduleName, identifier: identifier).withSourceLanguages(interfaceLanguages)
    }
}
