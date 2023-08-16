/*
 This source file is part of the Swift.org open source project

 Copyright (c) 2023 Apple Inc. and the Swift project authors
 Licensed under Apache License v2.0 with Runtime Library Exception

 See https://swift.org/LICENSE.txt for license information
 See https://swift.org/CONTRIBUTORS.txt for Swift project authors
*/

import Foundation
import AppleArchive
import System

public struct ArchiveCompressionError: Error {
    public enum ErrorKind {
        case fileStreamCreation
        case compressionStreamCreation
        case encodingStreamCreation
        case archiveKeySetError
        case sourceOpeningError
    }
    
    public let kind: ErrorKind
    public let destination: URL
    
    public init(_ kind: ErrorKind, destination: URL) {
        self.kind = kind
        self.destination = destination
    }
}

public struct UncompressedArchive {
    /// The url of the archive on disk
    public let url: URL
    
    var data: URL { 
        url.appendingPathComponent(NodeURLGenerator.Path.dataFolderName)
    }

    var tutorials: URL {
        url.appendingPathComponent(NodeURLGenerator.Path.tutorialsFolderName)
    }
    
    var downloads: URL! {
        URL(string: DownloadReference.baseURL.path.removingLeadingSlash, relativeTo: url)?.absoluteURL
    }
    
    var images: URL! {
        URL(string: ImageReference.baseURL.path.removingLeadingSlash, relativeTo: url)?.absoluteURL
    }
    
    var videos: URL! {
        URL(string: VideoReference.baseURL.path.removingLeadingSlash, relativeTo: url)?.absoluteURL
    }
    
    var metadataJSON: URL {
        url.appendingPathComponent("metadata.json")
    }
    
    public init(url: URL) {
        self.url = url
    }
    
    var sources: [URL] {
        [data, tutorials, images, videos, metadataJSON]
    }
    
    public func compress(into destination: URL) throws -> CompressedArchive {
        if #available(macOS 12.0, *) {
            guard let path = FilePath(destination),
                  let writeFileStream = ArchiveByteStream.fileStream(
                    path: path,
                    mode: .writeOnly,
                    options: [.create],
                    permissions: FilePermissions(rawValue: 0o644)
                  ) else {
                throw ArchiveCompressionError(.fileStreamCreation, destination: destination)
            }
            defer { try? writeFileStream.close() }
            
            guard let compressStream = ArchiveByteStream.compressionStream(
                using: .lzma,
                writingTo: writeFileStream,
                blockSize: 8 * (1 << 20) // 8MiB
            ) else {
                throw ArchiveCompressionError(.compressionStreamCreation, destination: destination)
            }
            
            defer { try? compressStream.close() }
            
            guard let encodeStream = ArchiveStream.encodeStream(writingTo: compressStream) else {
                throw ArchiveCompressionError(.encodingStreamCreation, destination: destination)
            }
            
            defer { try? encodeStream.close() }
            
            guard let keySet = ArchiveHeader.FieldKeySet(
                "TYP,PAT,LNK,DAT" // entry TYPe, PATh, symbolic LiNK, and file DATa
            ) else {
                throw ArchiveCompressionError(.archiveKeySetError, destination: destination)
            }
            
            try encodeStream.writeDirectoryContents(
                archiveFrom: FilePath(url)!,
                keySet: keySet
            ) { message, path, data in
                if sources.contains(where: {
                    path.string.contains($0.lastPathComponent)
                }) {
                    return .ok
                } else {
                    return .skip
                }
            }
        }
        
        return CompressedArchive(url: destination)
    }
}

public struct CompressedArchive {
    /// The url of the archive on disk
    public let url: URL
    
    public init(url: URL) {
        self.url = url
    }
    
    public func inflate() throws -> UncompressedArchive {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        
        if #available(macOS 11.0, *) {
            guard let archiveFilePath = FilePath(url),
                  let readFileStream = ArchiveByteStream.fileStream(
                    path: archiveFilePath,
                    mode: .readOnly,
                    options: [ ],
                    permissions: FilePermissions(rawValue: 0o644)
                  ) else {
                throw ArchiveCompressionError(.fileStreamCreation, destination: url)
            }
            
            defer {
                try? readFileStream.close()
            }
            
            guard let decompressStream = ArchiveByteStream.decompressionStream(
                readingFrom: readFileStream
            ) else {
                throw ArchiveCompressionError(.compressionStreamCreation, destination: url)
            }
            
            defer {
                try? decompressStream.close()
            }
            
            guard let decodeStream = ArchiveStream.decodeStream(
                readingFrom: decompressStream
            ) else {
                throw ArchiveCompressionError(.encodingStreamCreation, destination: url)
            }
            
            defer {
                try? decodeStream.close()
            }
            
            if FileManager.default.fileExists(atPath: tempDir.path) {
                try FileManager.default.removeItem(at: tempDir)
            }
            
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            
            
            guard let decompressDestination = FilePath(tempDir),
                  let extractStream = ArchiveStream.extractStream(
                    extractingTo: decompressDestination,
                    flags: [.ignoreOperationNotPermitted]
                  ) else {
                throw ArchiveCompressionError(.sourceOpeningError, destination: tempDir)
            }
            
            defer {
                try? extractStream.close()
            }
            
            _ = try ArchiveStream.process(readingFrom: decodeStream,
                                          writingTo: extractStream)
        }
        
        return UncompressedArchive(url: tempDir)
    }
}
