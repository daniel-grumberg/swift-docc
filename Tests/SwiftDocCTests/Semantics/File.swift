//
//  File.swift
//  
//
//  Created by Daniel Grumberg on 18/03/2024.
//

import XCTest
@testable import SwiftDocC
import Markdown

class TestDirectiveTests: XCTestCase {
    func testExampleFromSlidesParses() throws {
        let (_, outer) = try parseDirective(Outer.self) {
            """
            @Outer(some: argumentText) {
              @Inner {
                Some structured markup:
                - An
                - unordered
                - list
              }
              Some more structured markup:
              - another
              - unordered
              - list
            }
            """
        }
        
        XCTAssertNotNil(outer)
        XCTAssertEqual(
            outer?.inner.content.computeTexts(),
            [
                "Some structured markup:",
                "- An",
                "- unordered",
                "- list"
            ]
        )
        XCTAssertEqual(outer?.some, "argumentText")
        XCTAssertEqual(
            outer?.content.computeTexts(),
            [
                "Some more structured markup:",
                "- another",
                "- unordered",
                "- list",
            ]
        )
    }
}

private struct ExtractStringsMarkupVisitor: MarkupVisitor {
    private mutating func descendInto(_ markup: Markup) -> [String] {
        return markup.children.flatMap { self.visit($0) }
    }
    
    mutating func defaultVisit(_ markup: any Markdown.Markup) -> [String] {
        return descendInto(markup)
    }
    
    mutating func visitUnorderedList(_ unorderedList: UnorderedList) -> [String] {
        itemPrefix = "- "
        var retVal: Result = []
        for item in unorderedList.listItems {
            retVal.append(contentsOf: visit(item))
        }
        itemPrefix = ""
        return retVal
    }
    
    mutating func visitText(_ text: Text) -> [String] {
        return ["\(itemPrefix)\(text.string)"]
    }
    
    typealias Result = [String]
    
    var itemPrefix: String = ""
}

extension MarkupContainer {
    func computeTexts() -> [String] {
        return self.elements.flatMap { child in
            var visitor = ExtractStringsMarkupVisitor()
            return visitor.visit(child)
        }
    }
}
