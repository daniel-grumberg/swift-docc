/*
 This source file is part of the Swift.org open source project

 Copyright (c) 2023 Apple Inc. and the Swift project authors
 Licensed under Apache License v2.0 with Runtime Library Exception

 See https://swift.org/LICENSE.txt for license information
 See https://swift.org/CONTRIBUTORS.txt for Swift project authors
*/

import Foundation
import ArgumentParser
import SwiftDocC

extension Docc {
    public struct Compress: ParsableCommand {
        public init() { }
        
        @OptionGroup()
        public var documentationArchive: DocCArchiveOption
        
        /// A user-provided location where the convert action writes the built documentation.
        @Option(
            name: [.customLong("output-path")], help: "The location where the documentation compiler writes the compressed documentation.",
            transform: URL.init(fileURLWithPath:)
        )
        var providedOutputURL: URL
        
        public mutating func run() throws {
            if FileManager.default.fileExists(atPath: providedOutputURL.path) {
                try FileManager.default.removeItem(at: providedOutputURL)
            }
            
            let uncompressedArchive = UncompressedArchive(url: documentationArchive.urlOrFallback)
            let _ = try uncompressedArchive.compress(into: providedOutputURL)
        }
    }
    
    public struct Inflate: ParsableCommand {
        public init() {}
        
        @OptionGroup()
        public var documentationArchive: DocCCompressedArchiveOption
        
        /// A user-provided location where the convert action writes the built documentation.
        @Option(
            name: [.customLong("output-path"), .customLong("output-dir")], // Remove "output-dir" when other tools no longer pass that option. (rdar://72449411)
            help: "The location where the documentation compiler writes the built documentation.",
            transform: URL.init(fileURLWithPath:)
        )
        var providedOutputURL: URL
        
        @Flag(
            help: ArgumentHelp(
                "Writes an LMDB representation of the navigator index to the output directory.",
                discussion: "A JSON representation of the navigator index is emitted by default."
            )
        )
        
        public var emitLMDBIndex = false
        
        public mutating func run() throws {
            let compressed = CompressedArchive(url: documentationArchive.urlOrFallback)
            
            let uncompressed = try compressed.inflate()
            
            try moveOutput(from: uncompressed.url, to: providedOutputURL)
        }
    }
    

    /// Resolves and validates a URL value that provides the path to a documentation archive.
    public struct DocCCompressedArchiveOption: DirectoryPathOption {

        public init(){}

        /// The name of the command line argument used to specify a source archive path.
        static let argumentValueName = "source-archive-path"
        static let expectedContent: Set<String> = ["data.aar"]

        /// The path to an archive to be used by DocC.
        @Argument(
            help: ArgumentHelp(
                "Path to the DocC Archive ('.doccarchive') that should be processed.",
                valueName: argumentValueName),
            transform: URL.init(fileURLWithPath:))
        public var url: URL?

        public mutating func validate() throws {

            // Validate that the URL represents a directory
            guard urlOrFallback.hasDirectoryPath else {
                throw ValidationError("'\(urlOrFallback.path)' is not a valid DocC Archive. Expected a directory but a path to a file was provided")
            }
            
            var archiveContents: [String]
            do {
                archiveContents = try FileManager.default.contentsOfDirectory(atPath: urlOrFallback.path)
            } catch {
                throw ValidationError("'\(urlOrFallback.path)' is not a valid DocC Archive: \(error)")
            }
            
            let missingContents = Array(Set(Self.expectedContent).subtracting(archiveContents))
            guard missingContents.isEmpty else {
                throw ValidationError(
                    """
                    '\(urlOrFallback.path)' is not a valid DocC Archive.
                    Expected a 'data' directory at the root of the archive.
                    """
                )
            }
            
        }
    }
}

fileprivate func moveOutput(from: URL, to: URL) throws {
    // We only need to move output if it exists
    guard FileManager.default.fileExists(atPath: from.path) else { return }
    
    if FileManager.default.fileExists(atPath: to.path) {
        try FileManager.default.removeItem(at: to)
    }
    
    if !FileManager.default.directoryExists(
        atPath: to.deletingLastPathComponent().path
    ) {
        try FileManager.default.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: false)
    }
    
    try FileManager.default.moveItem(at: from, to: to)
}
