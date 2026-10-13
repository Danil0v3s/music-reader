import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

/// A minimal immutable XML tree (Foundation's `XMLDocument` isn't available on iOS). Built with
/// `XMLParser`; enough for MusicXML, which uses elements and attributes and no mixed content worth keeping.
public final class XMLTree {
    public let name: String
    public let attributes: [String: String]
    public fileprivate(set) var children: [XMLTree] = []
    public fileprivate(set) var text: String = ""

    init(name: String, attributes: [String: String]) {
        self.name = name
        self.attributes = attributes
    }

    public func child(_ name: String) -> XMLTree? { children.first { $0.name == name } }
    public func children(_ name: String) -> [XMLTree] { children.filter { $0.name == name } }
    /// Text of a descendant reached by a slash path ("pitch/step").
    public func string(_ path: String) -> String? {
        var node: XMLTree? = self
        for part in path.split(separator: "/") { node = node?.child(String(part)) }
        return node.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
    }
    public func int(_ path: String) -> Int? { string(path).flatMap { Int($0) ?? Double($0).map { Int($0.rounded()) } } }
    public func double(_ path: String) -> Double? { string(path).flatMap(Double.init) }
    public func has(_ path: String) -> Bool { string(path) != nil }

    public static func parse(_ data: Data) throws -> XMLTree {
        let builder = Builder()
        let parser = XMLParser(data: data)
        parser.delegate = builder
        // MusicXML files declare a DTD on the web; never fetch it.
        parser.shouldResolveExternalEntities = false
        guard parser.parse(), let root = builder.root else {
            throw MusicXMLError.malformed(parser.parserError?.localizedDescription ?? "unreadable XML")
        }
        return root
    }

    private final class Builder: NSObject, XMLParserDelegate {
        var root: XMLTree?
        var stack: [XMLTree] = []

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                    attributes: [String: String] = [:]) {
            let node = XMLTree(name: name, attributes: attributes)
            stack.last?.children.append(node)
            if root == nil { root = node }
            stack.append(node)
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            stack.removeLast()
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            stack.last?.text += string
        }
    }
}

public enum MusicXMLError: Error, LocalizedError, Equatable {
    case malformed(String)
    case unsupported(String)
    case empty

    public var errorDescription: String? {
        switch self {
        case .malformed(let s): "The MusicXML couldn't be read: \(s)"
        case .unsupported(let s): "This MusicXML isn't supported: \(s)"
        case .empty: "The file has no measures."
        }
    }
}
