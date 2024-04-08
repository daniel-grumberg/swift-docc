import Foundation
import Markdown

/// A funky  declarative directive definition
public final class Outer: Semantic, AutomaticDirectiveConvertible, MarkupContaining {
    public static let introducedVersion = "6.0" // 👀 👀
    
    /// A really interesting directive argument.
    @DirectiveArgumentWrapped
    public private(set) var some: String = ""
    
    /// I love nested directives!
    @ChildDirective
    public private(set) var inner: Inner
    
    /// The very interesting markup content of this directive
    @ChildMarkup(supportsStructure: true)
    public private(set) var content: MarkupContainer
    
    override var children: [Semantic] {
        return [content]
    }
    
    var childMarkup: [Markup] {
        return content.elements
    }

    static var keyPaths: [String : AnyKeyPath] = [
        "some"    : \Outer._some,
        "inner"   : \Outer._inner,
        "content" : \Outer._content
    ]
    
    public var originalMarkup: Markdown.BlockDirective
    
    @available(*, deprecated, message: "Do not call directly. Requred for 'AutomaticDirectiveConvertible")
    init(originalMarkup: Markdown.BlockDirective) {
        self.originalMarkup = originalMarkup
    }
}

extension Outer {
    /// Another funky declarative directive definition
    public final class Inner:
        Semantic, AutomaticDirectiveConvertible, MarkupContaining {
        public static let introducedVersion = "6.0" // 👀 👀
        
//        /// The most interesting markup content of this directive.
//        @ChildMarkup(supportsStructure: true)
//        public private(set) var content: MarkupContainer
        private var _content = ChildMarkup<MarkupContainer>(supportsStructure: true)
        public var content: MarkupContainer {
            get { _content.wrappedValue }
        }
        
        override var children: [Semantic] {
            return [content]
        }
        
        var childMarkup: [Markup] {
            return content.elements
        }
        
        static var keyPaths: [String : AnyKeyPath] = [
            "content" : \Inner._content
        ]
        
        public var originalMarkup: Markdown.BlockDirective
        
        @available(*, deprecated, message: "Do not call directly. Required for 'AutomaticDirectiveConvertible")
        init(originalMarkup: Markdown.BlockDirective) {
            self.originalMarkup = originalMarkup
        }
    }
}
