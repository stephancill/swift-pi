import Foundation
import PiAgent
import PiAI

/// The file tools for a workspace: read, write, edit, ls, find and grep.
public func fileTools(workspace: Workspace) -> [AgentTool] {
    [
        readTool(workspace: workspace),
        writeTool(workspace: workspace),
        editTool(workspace: workspace),
        lsTool(workspace: workspace),
        findTool(workspace: workspace),
        grepTool(workspace: workspace),
    ]
}

private func schema(properties: JSONObject, required: [String]) -> JSONValue {
    ["type": "object", "properties": .object(properties), "required": .array(required.map(JSONValue.string))]
}

private func string(_ description: String) -> JSONValue {
    ["type": "string", "description": .string(description)]
}

private func number(_ description: String) -> JSONValue {
    ["type": "number", "description": .string(description)]
}

private func boolean(_ description: String) -> JSONValue {
    ["type": "boolean", "description": .string(description)]
}

private func fileExists(_ url: URL, isDirectory: inout Bool) -> Bool {
    var flag: ObjCBool = false
    let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &flag)
    isDirectory = flag.boolValue
    return exists
}

// MARK: - read

private let imageTypes = ["png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "gif": "image/gif", "webp": "image/webp", "bmp": "image/bmp", "heic": "image/heic"]
/// Larger images are described rather than attached.
private let maxImageBytes = 5 * 1024 * 1024

public func readTool(workspace: Workspace) -> AgentTool {
    AgentTool(
        name: "read",
        description: "Read the contents of a file. Supports text files and images (jpg, png, gif, webp, bmp, heic). Images are sent as attachments. For text files, output is truncated to \(ToolLimits.maxLines) lines or \(ToolLimits.maxBytes / 1024)KB (whichever is hit first). Use offset/limit for large files. When you need the full file, continue with offset until complete.",
        parameters: schema(properties: [
            "path": string("Path to the file to read (relative or absolute)"),
            "offset": number("Line number to start reading from (1-indexed)"),
            "limit": number("Maximum number of lines to read"),
        ], required: ["path"])
    ) { _, arguments, _ in
        let path = arguments["path"]?.stringValue ?? ""
        let url = try workspace.resolve(path)
        var isDirectory = false
        guard fileExists(url, isDirectory: &isDirectory) else { throw WorkspaceError("File not found: \(path)") }
        if isDirectory { throw WorkspaceError("\(path) is a directory. Use ls to list it.") }

        if let mimeType = imageTypes[url.pathExtension.lowercased()] {
            let data = try Data(contentsOf: url)
            if data.count > maxImageBytes {
                return AgentToolResult(text: "Read image file [\(mimeType)]\nThe image is \(formatSize(data.count)), over the \(formatSize(maxImageBytes)) limit for attachments.")
            }
            return AgentToolResult(content: [
                .text(TextContent(text: "Read image file [\(mimeType)]")),
                .image(ImageContent(data: data.base64EncodedString(), mimeType: mimeType)),
            ])
        }

        let data = try Data(contentsOf: url)
        if looksBinary(data) {
            return AgentToolResult(text: "\(path) is a binary file (\(formatSize(data.count))).")
        }
        let text = String(decoding: data, as: UTF8.self)
        let lines = splitLines(text)
        let offset = arguments["offset"]?.intValue
        let limit = arguments["limit"]?.intValue
        let startLine = max(0, (offset ?? 1) - 1)
        if startLine > 0, startLine >= lines.count {
            throw WorkspaceError("Offset \(offset ?? 0) is beyond end of file (\(lines.count) lines total)")
        }
        let endLine = limit.map { min(lines.count, startLine + max(0, $0)) } ?? lines.count
        let selected = lines[startLine ..< endLine].joined(separator: "\n")
        let truncation = truncateHead(selected)
        let startDisplay = startLine + 1

        var output: String
        if truncation.firstLineExceedsLimit {
            output = "[Line \(startDisplay) is longer than the \(formatSize(ToolLimits.maxBytes)) limit and can't be shown.]"
        } else if truncation.truncated {
            let endDisplay = startDisplay + truncation.outputLines - 1
            output = truncation.content
            let limitNote = truncation.truncatedByLines ? "" : " (\(formatSize(ToolLimits.maxBytes)) limit)"
            output += "\n\n[Showing lines \(startDisplay)-\(endDisplay) of \(lines.count)\(limitNote). Use offset=\(endDisplay + 1) to continue.]"
        } else if limit != nil, endLine < lines.count {
            output = "\(truncation.content)\n\n[\(lines.count - endLine) more lines in file. Use offset=\(endLine + 1) to continue.]"
        } else {
            output = truncation.content
        }
        return AgentToolResult(text: output)
    }
}

// MARK: - write

public func writeTool(workspace: Workspace) -> AgentTool {
    AgentTool(
        name: "write",
        description: "Write content to a file. Creates the file if it doesn't exist, overwrites if it does. Automatically creates parent directories.",
        parameters: schema(properties: [
            "path": string("Path to the file to write (relative or absolute)"),
            "content": string("Content to write to the file"),
        ], required: ["path", "content"])
    ) { _, arguments, _ in
        let path = arguments["path"]?.stringValue ?? ""
        let content = arguments["content"]?.stringValue ?? ""
        let url = try workspace.resolve(path)
        return try await FileMutationQueue.shared.run(url.path) {
            try Task.checkCancellation()
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(content.utf8).write(to: url, options: .atomic)
            return AgentToolResult(text: "Successfully wrote \(content.utf8.count) bytes to \(path)")
        }
    }
}

// MARK: - edit

public func editTool(workspace: Workspace) -> AgentTool {
    AgentTool(
        name: "edit",
        description: "Edit a single file using exact text replacement. Every edits[].oldText must match a unique, non-overlapping region of the original file. If two changes affect the same block or nearby lines, merge them into one edit instead of emitting overlapping edits. Do not include large unchanged regions just to connect distant changes.",
        parameters: schema(properties: [
            "path": string("Path to the file to edit (relative or absolute)"),
            "edits": [
                "type": "array",
                "description": "One or more targeted replacements. Each edit is matched against the original file, not incrementally. Do not include overlapping or nested edits. If two changes touch the same block or nearby lines, merge them into one edit instead.",
                "items": schema(properties: [
                    "oldText": string("Exact text for one targeted replacement. It must be unique in the original file and must not overlap with any other edits[].oldText in the same call."),
                    "newText": string("Replacement text for this targeted edit."),
                ], required: ["oldText", "newText"]),
            ],
        ], required: ["path", "edits"]),
        prepareArguments: { arguments in
            // The older single-edit shape: `oldText`/`newText` at the top level.
            guard arguments["edits"] == nil, let oldText = arguments["oldText"], let newText = arguments["newText"] else { return arguments }
            var prepared = arguments
            prepared["oldText"] = nil
            prepared["newText"] = nil
            prepared["edits"] = [["oldText": oldText, "newText": newText]]
            return prepared
        }
    ) { _, arguments, _ in
        let path = arguments["path"]?.stringValue ?? ""
        let edits = (arguments["edits"]?.arrayValue ?? []).map { edit in
            TextEdit(oldText: edit["oldText"]?.stringValue ?? "", newText: edit["newText"]?.stringValue ?? "")
        }
        let url = try workspace.resolve(path)
        return try await FileMutationQueue.shared.run(url.path) {
            try Task.checkCancellation()
            var isDirectory = false
            guard fileExists(url, isDirectory: &isDirectory), !isDirectory else {
                throw WorkspaceError("Could not edit file: \(path). The file does not exist.")
            }
            let original = String(decoding: try Data(contentsOf: url), as: UTF8.self)
            let result = try applyEdits(edits, to: original, path: path)
            try Task.checkCancellation()
            try Data(result.content.utf8).write(to: url, options: .atomic)
            return AgentToolResult(
                text: "Successfully replaced \(edits.count) block(s) in \(path).",
                details: ["firstChangedLine": result.firstChangedLine.map { .number(Double($0)) } ?? .null]
            )
        }
    }
}

public struct TextEdit: Sendable, Hashable {
    public var oldText: String
    public var newText: String

    public init(oldText: String, newText: String) {
        self.oldText = oldText
        self.newText = newText
    }
}

/// Normalizes what models get wrong when copying text: trailing whitespace, smart quotes, dashes and special spaces.
func normalizeForFuzzyMatch(_ text: String) -> String {
    var result = text.precomposedStringWithCompatibilityMapping
        .split(separator: "\n", omittingEmptySubsequences: false)
        .map { line -> String in
            var line = String(line)
            while let last = line.last, last == " " || last == "\t" { line.removeLast() }
            return line
        }
        .joined(separator: "\n")
    let replacements: [(Set<Character>, String)] = [
        (["\u{2018}", "\u{2019}", "\u{201A}", "\u{201B}"], "'"),
        (["\u{201C}", "\u{201D}", "\u{201E}", "\u{201F}"], "\""),
        (["\u{2010}", "\u{2011}", "\u{2012}", "\u{2013}", "\u{2014}", "\u{2015}", "\u{2212}"], "-"),
        (["\u{00A0}", "\u{2002}", "\u{2003}", "\u{2004}", "\u{2005}", "\u{2006}", "\u{2007}", "\u{2008}", "\u{2009}", "\u{200A}", "\u{202F}", "\u{205F}", "\u{3000}"], " "),
    ]
    for (characters, replacement) in replacements {
        result = String(result.map { characters.contains($0) ? Character(replacement) : $0 })
    }
    return result
}

private func occurrences(of needle: String, in haystack: String) -> [Range<String.Index>] {
    var ranges: [Range<String.Index>] = []
    var searchStart = haystack.startIndex
    while searchStart < haystack.endIndex, let range = haystack.range(of: needle, range: searchStart ..< haystack.endIndex) {
        ranges.append(range)
        searchStart = range.upperBound
    }
    return ranges
}

/// Applies the edits, each matched against the original text. Line endings are normalized to LF for matching and
/// restored to CRLF when the file used them. When an exact match fails, matching retries on text normalized with
/// `normalizeForFuzzyMatch`, and the result is written in that normalized form.
public func applyEdits(_ edits: [TextEdit], to original: String, path: String) throws -> (content: String, firstChangedLine: Int?) {
    let bom = original.hasPrefix("\u{FEFF}") ? "\u{FEFF}" : ""
    let withoutBom = bom.isEmpty ? original : String(original.dropFirst())
    let usesCRLF = withoutBom.contains("\r\n")
    let content = withoutBom.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    let edits = edits.map { TextEdit(oldText: $0.oldText.replacingOccurrences(of: "\r\n", with: "\n"), newText: $0.newText.replacingOccurrences(of: "\r\n", with: "\n")) }
    let single = edits.count == 1

    for (index, edit) in edits.enumerated() where edit.oldText.isEmpty {
        throw WorkspaceError(single ? "oldText must not be empty in \(path)." : "edits[\(index)].oldText must not be empty in \(path).")
    }

    let needsFuzzy = edits.contains { !content.contains($0.oldText) }
    let base = needsFuzzy ? normalizeForFuzzyMatch(content) : content

    var matches: [(index: Int, range: Range<String.Index>, newText: String)] = []
    for (index, edit) in edits.enumerated() {
        let oldText = needsFuzzy ? normalizeForFuzzyMatch(edit.oldText) : edit.oldText
        let found = occurrences(of: oldText, in: base)
        if found.isEmpty {
            throw WorkspaceError(single
                ? "Could not find the exact text in \(path). The old text must match exactly including all whitespace and newlines."
                : "Could not find edits[\(index)] in \(path). The oldText must match exactly including all whitespace and newlines.")
        }
        if found.count > 1 {
            throw WorkspaceError(single
                ? "Found \(found.count) occurrences of the text in \(path). The text must be unique. Please provide more context to make it unique."
                : "Found \(found.count) occurrences of edits[\(index)] in \(path). Each oldText must be unique. Please provide more context to make it unique.")
        }
        matches.append((index, found[0], edit.newText))
    }

    matches.sort { $0.range.lowerBound < $1.range.lowerBound }
    for pair in zip(matches, matches.dropFirst()) where pair.0.range.upperBound > pair.1.range.lowerBound {
        throw WorkspaceError("edits[\(pair.0.index)] and edits[\(pair.1.index)] overlap in \(path). Merge them into one edit or target disjoint regions.")
    }

    var result = base
    for match in matches.reversed() {
        result.replaceSubrange(match.range, with: match.newText)
    }
    if result == content {
        throw WorkspaceError(single
            ? "No changes made to \(path). The replacement produced identical content. This might indicate an issue with special characters or the text not existing as expected."
            : "No changes made to \(path). The replacements produced identical content.")
    }

    let firstChangedLine = matches.first.map { base[..<$0.range.lowerBound].filter { $0 == "\n" }.count + 1 }
    let output = usesCRLF ? result.replacingOccurrences(of: "\n", with: "\r\n") : result
    return (bom + output, firstChangedLine)
}

// MARK: - ls

public func lsTool(workspace: Workspace) -> AgentTool {
    let defaultLimit = 500
    return AgentTool(
        name: "ls",
        description: "List directory contents. Returns entries sorted alphabetically, with '/' suffix for directories. Includes dotfiles. Output is truncated to \(defaultLimit) entries or \(ToolLimits.maxBytes / 1024)KB (whichever is hit first).",
        parameters: schema(properties: [
            "path": string("Directory to list (default: workspace root)"),
            "limit": number("Maximum number of entries to return (default: \(defaultLimit))"),
        ], required: [])
    ) { _, arguments, _ in
        let path = arguments["path"]?.stringValue ?? "."
        let limit = max(1, arguments["limit"]?.intValue ?? defaultLimit)
        let url = try workspace.resolve(path)
        var isDirectory = false
        guard fileExists(url, isDirectory: &isDirectory) else { throw WorkspaceError("Path not found: \(path)") }
        guard isDirectory else { throw WorkspaceError("Not a directory: \(path)") }

        let names = try FileManager.default.contentsOfDirectory(atPath: url.path)
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        if names.isEmpty { return AgentToolResult(text: "(empty directory)") }
        let entries = names.prefix(limit).map { name -> String in
            var childIsDirectory = false
            _ = fileExists(url.appendingPathComponent(name), isDirectory: &childIsDirectory)
            return childIsDirectory ? name + "/" : name
        }
        let truncation = truncateHead(entries.joined(separator: "\n"), maxLines: .max)
        var notices: [String] = []
        if names.count > limit { notices.append("\(limit) entries limit reached. Use limit=\(limit * 2) for more") }
        if truncation.truncated { notices.append("\(formatSize(ToolLimits.maxBytes)) limit reached") }
        var output = truncation.content
        if !notices.isEmpty { output += "\n\n[\(notices.joined(separator: ". "))]" }
        return AgentToolResult(text: output)
    }
}

// MARK: - find and grep

/// Directories the search tools skip.
private let skippedDirectories: Set<String> = [".git", "node_modules", ".build", "DerivedData", ".DS_Store"]

/// Every regular file under `directory`, depth first, skipping `skippedDirectories`.
private func walkFiles(_ directory: URL) -> [URL] {
    guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey], options: []) else { return [] }
    var files: [URL] = []
    for case let url as URL in enumerator {
        if Task.isCancelled { break }
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
        if values?.isDirectory == true {
            if skippedDirectories.contains(url.lastPathComponent) { enumerator.skipDescendants() }
            continue
        }
        if values?.isRegularFile == true { files.append(url) }
    }
    return files
}

/// A glob as a regular expression: `**` crosses directories, `*` and `?` don't, `{a,b}` alternates, `[...]` is a class.
func globRegex(_ glob: String) -> NSRegularExpression? {
    var pattern = "^"
    var characters = Array(glob)
    var index = 0
    var braceDepth = 0
    // `**/` at the start also matches files at the root.
    if glob.hasPrefix("**/") {
        pattern += "(?:.*/)?"
        characters = Array(glob.dropFirst(3))
    }
    while index < characters.count {
        let character = characters[index]
        switch character {
        case "*":
            if index + 1 < characters.count, characters[index + 1] == "*" {
                if index + 2 < characters.count, characters[index + 2] == "/" {
                    pattern += "(?:.*/)?"
                    index += 2
                } else {
                    pattern += ".*"
                    index += 1
                }
            } else {
                pattern += "[^/]*"
            }
        case "?": pattern += "[^/]"
        case "{":
            braceDepth += 1
            pattern += "(?:"
        case "}" where braceDepth > 0:
            braceDepth -= 1
            pattern += ")"
        case "," where braceDepth > 0: pattern += "|"
        case "[":
            if let close = characters[(index + 1)...].firstIndex(of: "]") {
                var set = String(characters[(index + 1) ..< close])
                if set.hasPrefix("!") { set = "^" + set.dropFirst() }
                pattern += "[\(set)]"
                index = close
            } else {
                pattern += "\\["
            }
        default:
            pattern += NSRegularExpression.escapedPattern(for: String(character))
        }
        index += 1
    }
    pattern += "$"
    return try? NSRegularExpression(pattern: pattern)
}

private func matchesGlob(_ regex: NSRegularExpression, _ path: String) -> Bool {
    regex.firstMatch(in: path, range: NSRange(path.startIndex..., in: path)) != nil
}

public func findTool(workspace: Workspace) -> AgentTool {
    let defaultLimit = 1000
    return AgentTool(
        name: "find",
        description: "Search for files by glob pattern. Returns matching file paths relative to the search directory. Skips .git, node_modules and build folders. Output is truncated to \(defaultLimit) results or \(ToolLimits.maxBytes / 1024)KB (whichever is hit first).",
        parameters: schema(properties: [
            "pattern": string("Glob pattern to match files, e.g. '*.swift', '**/*.json', or 'src/**/*.spec.ts'"),
            "path": string("Directory to search in (default: workspace root)"),
            "limit": number("Maximum number of results (default: \(defaultLimit))"),
        ], required: ["pattern"])
    ) { _, arguments, _ in
        let pattern = arguments["pattern"]?.stringValue ?? "*"
        let path = arguments["path"]?.stringValue ?? "."
        let limit = max(1, arguments["limit"]?.intValue ?? defaultLimit)
        let directory = try workspace.resolve(path)
        var isDirectory = false
        guard fileExists(directory, isDirectory: &isDirectory) else { throw WorkspaceError("Path not found: \(path)") }
        guard isDirectory else { throw WorkspaceError("Not a directory: \(path)") }
        // A pattern without a slash matches the file name anywhere, like fd.
        guard let regex = globRegex(pattern.contains("/") ? pattern : "**/" + pattern) else {
            throw WorkspaceError("Invalid glob pattern: \(pattern)")
        }

        let directoryWorkspace = Workspace(root: directory)
        var results: [String] = []
        var limitHit = false
        for file in walkFiles(directory) {
            let relative = directoryWorkspace.relativePath(file)
            guard matchesGlob(regex, relative) else { continue }
            if results.count >= limit {
                limitHit = true
                break
            }
            results.append(relative)
        }
        if results.isEmpty { return AgentToolResult(text: "No files found matching pattern") }
        results.sort()
        let truncation = truncateHead(results.joined(separator: "\n"), maxLines: .max)
        var notices: [String] = []
        if limitHit { notices.append("\(limit) results limit reached. Use limit=\(limit * 2) for more, or refine pattern") }
        if truncation.truncated { notices.append("\(formatSize(ToolLimits.maxBytes)) limit reached") }
        var output = truncation.content
        if !notices.isEmpty { output += "\n\n[\(notices.joined(separator: ". "))]" }
        return AgentToolResult(text: output)
    }
}

public func grepTool(workspace: Workspace) -> AgentTool {
    let defaultLimit = 100
    return AgentTool(
        name: "grep",
        description: "Search file contents for a pattern. Returns matching lines with file paths and line numbers. Skips binary files, .git, node_modules and build folders. Output is truncated to \(defaultLimit) matches or \(ToolLimits.maxBytes / 1024)KB (whichever is hit first). Long lines are truncated to \(ToolLimits.grepMaxLineLength) chars.",
        parameters: schema(properties: [
            "pattern": string("Search pattern (regex or literal string)"),
            "path": string("Directory or file to search (default: workspace root)"),
            "glob": string("Filter files by glob pattern, e.g. '*.swift' or '**/*.md'"),
            "ignoreCase": boolean("Case-insensitive search (default: false)"),
            "literal": boolean("Treat pattern as literal string instead of regex (default: false)"),
            "context": number("Number of lines to show before and after each match (default: 0)"),
            "limit": number("Maximum number of matches to return (default: \(defaultLimit))"),
        ], required: ["pattern"])
    ) { _, arguments, _ in
        let pattern = arguments["pattern"]?.stringValue ?? ""
        let path = arguments["path"]?.stringValue ?? "."
        let ignoreCase = arguments["ignoreCase"]?.boolValue ?? false
        let literal = arguments["literal"]?.boolValue ?? false
        let contextLines = max(0, arguments["context"]?.intValue ?? 0)
        let limit = max(1, arguments["limit"]?.intValue ?? defaultLimit)

        let target = try workspace.resolve(path)
        var isDirectory = false
        guard fileExists(target, isDirectory: &isDirectory) else { throw WorkspaceError("Path not found: \(path)") }

        let regexPattern = literal ? NSRegularExpression.escapedPattern(for: pattern) : pattern
        let regex: NSRegularExpression
        do {
            regex = try NSRegularExpression(pattern: regexPattern, options: ignoreCase ? [.caseInsensitive] : [])
        } catch {
            throw WorkspaceError("Invalid regular expression: \(pattern)")
        }
        let globFilter = try arguments["glob"]?.stringValue.map { glob -> NSRegularExpression in
            let cleaned = glob.hasPrefix("./") ? String(glob.dropFirst(2)) : glob
            guard let regex = globRegex(cleaned.contains("/") ? cleaned : "**/" + cleaned) else {
                throw WorkspaceError("Invalid glob pattern: \(glob)")
            }
            return regex
        }

        let files = isDirectory ? walkFiles(target) : [target]
        let base = isDirectory ? Workspace(root: target) : workspace
        var output: [String] = []
        var bytes = 0
        var matchCount = 0
        var limitHit = false
        var linesTruncated = false
        var bytesHit = false

        func push(_ line: String) {
            bytes += line.utf8.count + 1
            if bytes - 1 <= ToolLimits.maxBytes { output.append(line) } else { bytesHit = true }
        }

        fileLoop: for file in files {
            if Task.isCancelled { break }
            let relative = base.relativePath(file)
            if let globFilter, !matchesGlob(globFilter, relative) { continue }
            guard let data = try? Data(contentsOf: file), !looksBinary(data) else { continue }
            let lines = splitLines(String(decoding: data, as: UTF8.self)).map(String.init)
            var lastPrinted = -1
            for (lineIndex, line) in lines.enumerated() where regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil {
                if matchCount >= limit {
                    limitHit = true
                    break fileLoop
                }
                matchCount += 1
                let start = max(lastPrinted + 1, lineIndex - contextLines)
                let end = min(lines.count - 1, lineIndex + contextLines)
                if start <= end {
                    for printIndex in start ... end {
                        var text = lines[printIndex]
                        if text.count > ToolLimits.grepMaxLineLength {
                            text = String(text.prefix(ToolLimits.grepMaxLineLength)) + "…"
                            linesTruncated = true
                        }
                        push(printIndex == lineIndex ? "\(relative):\(printIndex + 1): \(text)" : "\(relative)-\(printIndex + 1)- \(text)")
                    }
                    lastPrinted = end
                }
            }
        }

        if matchCount == 0 { return AgentToolResult(text: "No matches found") }
        var notices: [String] = []
        if limitHit { notices.append("\(limit) matches limit reached. Use limit=\(limit * 2) for more, or refine pattern") }
        if bytesHit { notices.append("\(formatSize(ToolLimits.maxBytes)) limit reached") }
        if linesTruncated { notices.append("Some lines truncated to \(ToolLimits.grepMaxLineLength) chars. Use read tool to see full lines") }
        var text = output.joined(separator: "\n")
        if !notices.isEmpty { text += "\n\n[\(notices.joined(separator: ". "))]" }
        return AgentToolResult(text: text)
    }
}
