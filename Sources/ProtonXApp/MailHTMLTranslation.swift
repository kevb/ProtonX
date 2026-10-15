// Copyright (c) 2026 ProtonX contributors. SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import SwiftSoup

/// Parses only the helper's already-sanitized HTML. SwiftSoup performs no network
/// loads. Translation changes text nodes, never tags, styles, URLs or attributes.
struct MailHTMLTranslationDocument: Sendable {
    struct Replacement: Sendable {
        let ordinal: Int
        let original: String
        let document: MailTranslationDocument
        let indexes: [Int]
    }
    let html: String
    let replacements: [Replacement]
    let strings: [String]
    let sample: String
    init(_ html: String) throws {
        let (document, body) = try Self.parse(html)
        let nodes = try Self.textNodes(body)
        var replacements: [Replacement] = [], strings: [String] = [], indexes: [String: Int] = [:], samples: [String] = []
        var bytes = 0, sampleSize = 0
        for (ordinal, item) in nodes.enumerated() where !item.hidden {
            let value = item.node.getWholeText()
            if !item.quoted, sampleSize < 24_000 {
                let fragment = String(value.prefix(4_000))
                samples.append(fragment); sampleSize += fragment.count
            }
            guard MailLanguage.containsProse(value) else { continue }
            bytes += value.utf8.count
            guard bytes <= MailTranslationDocument.maxBytes else { throw MailTranslationDocument.Failure.tooLong }
            guard let prose = try? MailTranslationDocument(value) else { continue }
            let mapping = prose.strings.map { text in
                if let index = indexes[text] { return index }
                let index = strings.count; indexes[text] = index; strings.append(text); return index
            }
            replacements.append(.init(ordinal: ordinal, original: value, document: prose, indexes: mapping))
        }
        guard !strings.isEmpty, strings.count <= 128 else { throw MailTranslationDocument.Failure.tooLong }
        withExtendedLifetime(document) {} // Keep the tree alive through traversal.
        self.html = html; self.replacements = replacements; self.strings = strings; sample = samples.joined(separator: "\n")
    }
    func assemble(_ translated: [String]) throws -> String {
        guard translated.count == strings.count else { throw MailTranslationDocument.Failure.invalidResult }
        let (document, body) = try Self.parse(html)
        let nodes = try Self.textNodes(body)
        for replacement in replacements {
            guard nodes.indices.contains(replacement.ordinal), nodes[replacement.ordinal].node.getWholeText() == replacement.original else { throw MailTranslationDocument.Failure.invalidResult }
            let value = try replacement.document.assemble(replacement.indexes.map { translated[$0] })
            // TextNode.text escapes model-generated markup on serialization.
            nodes[replacement.ordinal].node.text(value)
        }
        document.outputSettings().prettyPrint(pretty: false)
        // Regenerate from edited nodes rather than the parser's original-source
        // reuse optimization. Never return an unchanged source slice after edits.
        let result = String(decoding: try body.htmlUTF8WithoutSourceReuse(), as: UTF8.self)
        guard result.utf8.count <= 2 * 1024 * 1024 else { throw MailTranslationDocument.Failure.invalidResult }
        return result
    }
    private static func parse(_ html: String) throws -> (Document, Element) {
        guard html.utf8.count <= 2 * 1024 * 1024 else { throw MailTranslationDocument.Failure.tooLong }
        let document = try SwiftSoup.parseBodyFragment(html)
        guard let body = document.body() else { throw MailTranslationDocument.Failure.invalidResult }
        return (document, body)
    }
    private struct TextItem { let node: TextNode; let hidden: Bool; let quoted: Bool }
    private static func textNodes(_ root: Element) throws -> [TextItem] {
        var stack: [(Node, Bool, Bool, Int)] = [(root, false, false, 0)], result: [TextItem] = [], visited = 0
        while let (node, inheritedHidden, inheritedQuote, depth) = stack.popLast() {
            visited += 1
            guard visited <= 20_000, depth <= 256 else { throw MailTranslationDocument.Failure.tooLong }
            var hidden = inheritedHidden, quoted = inheritedQuote
            if let element = node as? Element {
                let tag = element.tagName().lowercased()
                let style = (try element.attr("style")).lowercased().replacingOccurrences(of: " ", with: "")
                let ariaHidden = try element.attr("aria-hidden") == "true"
                hidden = hidden || ["style", "script", "noscript", "head", "title", "svg", "template"].contains(tag) || element.hasAttr("hidden") ||
                    style.contains("display:none") || style.contains("visibility:hidden") || style.contains("mso-hide:all") || ariaHidden
                let classes = try element.attr("class").lowercased().split(separator: " ")
                quoted = quoted || tag == "blockquote" || classes.contains("gmail_quote") || classes.contains("protonmail_quote")
            }
            if let text = node as? TextNode { result.append(.init(node: text, hidden: hidden, quoted: quoted)) }
            for child in node.getChildNodes().reversed() { stack.append((child, hidden, quoted, depth + 1)) }
        }
        return result
    }
}
