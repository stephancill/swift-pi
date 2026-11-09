import Foundation

/// Converts HTML to Markdown or plain text for a model to read: headings, paragraphs, lists, links, emphasis, code
/// and tables survive; scripts, styles and the rest of the markup don't. Lenient: it reads whatever a page sends.
public enum HTMLText {
    /// `baseURL` resolves relative links, so the model can follow them.
    public static func markdown(_ html: String, baseURL: URL? = nil) -> String {
        convert(html, markdown: true, baseURL: baseURL)
    }

    public static func text(_ html: String) -> String {
        convert(html, markdown: false, baseURL: nil)
    }

    /// Elements dropped with everything inside them.
    private static let droppedElements: Set<String> = ["script", "style", "noscript", "head", "svg", "template", "iframe", "object", "canvas", "select", "button", "form", "nav"]
    private static let blockElements: Set<String> = ["p", "div", "section", "article", "main", "header", "footer", "aside", "figure", "figcaption", "blockquote", "table", "thead", "tbody", "ul", "ol", "dl", "dt", "dd", "address", "details", "summary", "hr"]

    private struct Tag {
        var name: String
        var isClosing: Bool
        var isSelfClosing: Bool
        var attributes: [String: String]
    }

    private static func convert(_ html: String, markdown: Bool, baseURL: URL?) -> String {
        var output = ""
        var linkStack: [String?] = []
        var listStack: [(ordered: Bool, index: Int)] = []
        var preDepth = 0
        var dropDepth = 0
        var droppedName: String?

        func newline(_ count: Int) {
            guard !output.isEmpty else { return }
            let existing = output.reversed().prefix { $0 == "\n" }.count
            if existing < count { output += String(repeating: "\n", count: count - existing) }
        }

        func appendText(_ raw: String) {
            let decoded = decodeEntities(raw)
            if preDepth > 0 {
                output += decoded
                return
            }
            var collapsed = ""
            var lastWasSpace = output.last.map { $0 == " " || $0 == "\n" } ?? true
            for character in decoded {
                if character.isWhitespace {
                    if !lastWasSpace { collapsed.append(" ") }
                    lastWasSpace = true
                } else {
                    collapsed.append(character)
                    lastWasSpace = false
                }
            }
            output += collapsed
        }

        var index = html.startIndex
        while index < html.endIndex {
            if html[index] == "<" {
                // Comments.
                if html[index...].hasPrefix("<!--") {
                    if let end = html.range(of: "-->", range: index ..< html.endIndex) {
                        index = end.upperBound
                    } else {
                        index = html.endIndex
                    }
                    continue
                }
                guard let close = html[index...].firstIndex(of: ">") else {
                    if dropDepth == 0 { appendText(String(html[index...])) }
                    break
                }
                let raw = html[html.index(after: index) ..< close]
                index = html.index(after: close)
                guard let tag = parseTag(raw) else { continue }

                if dropDepth > 0 {
                    if tag.name == droppedName {
                        dropDepth += tag.isClosing ? -1 : (tag.isSelfClosing ? 0 : 1)
                        if dropDepth == 0 { droppedName = nil }
                    }
                    continue
                }
                if droppedElements.contains(tag.name), !tag.isClosing, !tag.isSelfClosing {
                    droppedName = tag.name
                    dropDepth = 1
                    continue
                }

                switch tag.name {
                case "h1", "h2", "h3", "h4", "h5", "h6":
                    newline(2)
                    if !tag.isClosing, markdown, let level = Int(tag.name.dropFirst()) {
                        output += String(repeating: "#", count: level) + " "
                    }
                case "br":
                    output += "\n"
                case "li":
                    if tag.isClosing {
                        newline(1)
                    } else {
                        newline(1)
                        let depth = max(0, listStack.count - 1)
                        output += String(repeating: "  ", count: depth)
                        if var list = listStack.last, list.ordered {
                            list.index += 1
                            listStack[listStack.count - 1] = list
                            output += "\(list.index). "
                        } else {
                            output += "- "
                        }
                    }
                case "ul", "ol":
                    if tag.isClosing {
                        if !listStack.isEmpty { listStack.removeLast() }
                        newline(2)
                    } else {
                        newline(listStack.isEmpty ? 2 : 1)
                        listStack.append((tag.name == "ol", 0))
                    }
                case "tr":
                    newline(1)
                case "td", "th":
                    if !tag.isClosing { output += markdown ? "| " : "\t" }
                case "pre":
                    if tag.isClosing {
                        preDepth = max(0, preDepth - 1)
                        if markdown {
                            if output.last != "\n" { output += "\n" }
                            output += "```"
                        }
                        newline(2)
                    } else {
                        newline(2)
                        if markdown { output += "```\n" }
                        preDepth += 1
                    }
                case "code":
                    if preDepth == 0, markdown { output += "`" }
                case "strong", "b":
                    if markdown { output += "**" }
                case "em", "i":
                    if markdown { output += "*" }
                case "a":
                    if tag.isClosing {
                        if let href = linkStack.popLast() ?? nil, markdown {
                            output += "](\(href))"
                        }
                    } else if !tag.isSelfClosing {
                        let href = tag.attributes["href"].flatMap { href -> String? in
                            let href = decodeEntities(href)
                            if href.hasPrefix("#") || href.lowercased().hasPrefix("javascript:") { return nil }
                            return baseURL.flatMap { URL(string: href, relativeTo: $0)?.absoluteString } ?? href
                        }
                        linkStack.append(href)
                        if href != nil, markdown { output += "[" }
                    }
                case "img":
                    // Images are left out: their paths and alt text are mostly noise to a model reading the page.
                    break
                default:
                    if blockElements.contains(tag.name) {
                        newline(2)
                        if tag.name == "hr", markdown { output += "---"; newline(2) }
                    }
                }
            } else {
                let next = html[index...].firstIndex(of: "<") ?? html.endIndex
                if dropDepth == 0 { appendText(String(html[index ..< next])) }
                index = next
            }
        }

        // Trim each line's trailing spaces and at most one blank line in a row.
        var lines: [String] = []
        var blank = 0
        for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = String(line).replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
            if trimmed.trimmingCharacters(in: .whitespaces).isEmpty {
                blank += 1
                if blank > 1 { continue }
                lines.append("")
            } else {
                blank = 0
                lines.append(trimmed)
            }
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func parseTag(_ raw: Substring) -> Tag? {
        var body = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty, !body.hasPrefix("!"), !body.hasPrefix("?") else { return nil }
        let isClosing = body.hasPrefix("/")
        if isClosing { body.removeFirst() }
        let isSelfClosing = body.hasSuffix("/")
        if isSelfClosing { body.removeLast() }
        let nameEnd = body.firstIndex(where: { $0.isWhitespace || $0 == "/" }) ?? body.endIndex
        let name = body[..<nameEnd].lowercased()
        guard !name.isEmpty else { return nil }
        let voidElements: Set<String> = ["br", "img", "hr", "input", "meta", "link", "source", "wbr", "area", "col", "embed"]
        return Tag(name: name, isClosing: isClosing, isSelfClosing: isSelfClosing || voidElements.contains(name), attributes: parseAttributes(String(body[nameEnd...])))
    }

    private static let attributePattern = try? NSRegularExpression(pattern: #"([a-zA-Z_:][-a-zA-Z0-9_:.]*)\s*(?:=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'=<>`]+)))?"#)

    private static func parseAttributes(_ text: String) -> [String: String] {
        guard let pattern = attributePattern else { return [:] }
        var attributes: [String: String] = [:]
        let range = NSRange(text.startIndex..., in: text)
        for match in pattern.matches(in: text, range: range) {
            guard let nameRange = Range(match.range(at: 1), in: text) else { continue }
            let value = (2 ... 4).lazy.compactMap { Range(match.range(at: $0), in: text) }.first.map { String(text[$0]) } ?? ""
            attributes[text[nameRange].lowercased()] = value
        }
        return attributes
    }

    private static let namedEntities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ", "ndash": "–", "mdash": "—",
        "hellip": "…", "lsquo": "‘", "rsquo": "’", "ldquo": "“", "rdquo": "”", "copy": "©", "reg": "®", "trade": "™",
        "middot": "·", "bull": "•", "times": "×", "rarr": "→", "larr": "←", "euro": "€", "pound": "£", "deg": "°",
    ]

    /// Decodes `&name;`, `&#123;` and `&#x7B;`.
    public static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var result = ""
        var index = text.startIndex
        while index < text.endIndex {
            if text[index] == "&", let semicolon = text[index...].prefix(12).firstIndex(of: ";") {
                let entity = text[text.index(after: index) ..< semicolon]
                var replacement: String?
                if entity.hasPrefix("#x") || entity.hasPrefix("#X") {
                    replacement = UInt32(entity.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
                } else if entity.hasPrefix("#") {
                    replacement = UInt32(entity.dropFirst()).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
                } else {
                    replacement = namedEntities[String(entity)]
                }
                if let replacement {
                    result += replacement
                    index = text.index(after: semicolon)
                    continue
                }
            }
            result.append(text[index])
            index = text.index(after: index)
        }
        return result
    }
}
