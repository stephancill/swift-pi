import Foundation

/// Parses a JSON object that is still arriving, such as streamed tool call arguments: closes open strings, arrays and
/// objects and drops a dangling key or separator. Returns nil when even the repaired text doesn't parse.
public func parsePartialJSONObject(_ text: String) -> JSONObject? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return [:] }
    if let value = try? JSONValue.parse(trimmed), let object = value.objectValue { return object }

    var closers: [Character] = []
    var inString = false
    var escaped = false
    for character in trimmed {
        if inString {
            if escaped {
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "\"" {
                inString = false
            }
            continue
        }
        switch character {
        case "\"": inString = true
        case "{": closers.append("}")
        case "[": closers.append("]")
        case "}", "]": if !closers.isEmpty { closers.removeLast() }
        default: break
        }
    }

    var repaired = trimmed
    if inString {
        // A trailing backslash would escape the closing quote.
        if escaped { repaired.removeLast() }
        repaired.append("\"")
    }
    // Candidates from least to most aggressive: as is, then without a dangling `"key"` / `"key":` / `,`.
    var candidates = [repaired]
    var stripped = repaired
    for _ in 0 ..< 3 {
        let before = stripped
        stripped = stripped.trimmingCharacters(in: .whitespacesAndNewlines)
        if stripped.hasSuffix(",") || stripped.hasSuffix(":") {
            stripped.removeLast()
        } else if stripped.hasSuffix("\""), let keyStart = danglingKeyStart(stripped) {
            stripped = String(stripped[..<keyStart])
        }
        if stripped != before { candidates.append(stripped) }
    }
    for candidate in candidates {
        let closed = candidate + String(closers.reversed())
        if let value = try? JSONValue.parse(closed), let object = value.objectValue { return object }
    }
    return nil
}

/// Where a trailing string that is an object key without a value starts (after `{` or `,`).
private func danglingKeyStart(_ text: String) -> String.Index? {
    guard text.hasSuffix("\""), text.count >= 2 else { return nil }
    var index = text.index(before: text.endIndex)
    while index > text.startIndex {
        index = text.index(before: index)
        if text[index] == "\"", index == text.startIndex || text[text.index(before: index)] != "\\" {
            let before = text[..<index].trimmingCharacters(in: .whitespacesAndNewlines)
            return before.hasSuffix("{") || before.hasSuffix(",") ? index : nil
        }
    }
    return nil
}
