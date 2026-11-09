import Foundation

public enum ToolLimits {
    public static let maxLines = 2000
    public static let maxBytes = 50 * 1024
    /// Characters kept of each grep match line.
    public static let grepMaxLineLength = 500
}

struct Truncation {
    var content: String
    var truncated: Bool
    var truncatedByLines: Bool
    var totalLines: Int
    var outputLines: Int
    var firstLineExceedsLimit: Bool
}

func formatSize(_ bytes: Int) -> String {
    if bytes < 1024 { return "\(bytes)B" }
    if bytes < 1024 * 1024 { return String(format: "%.1fKB", Double(bytes) / 1024) }
    return String(format: "%.1fMB", Double(bytes) / 1024 / 1024)
}

func splitLines(_ content: String) -> [Substring] {
    guard !content.isEmpty else { return [] }
    var lines = content.split(separator: "\n", omittingEmptySubsequences: false)
    if content.hasSuffix("\n") { lines.removeLast() }
    return lines
}

/// Keeps the first lines up to `maxLines` lines or `maxBytes` bytes, whichever comes first, never cutting a line.
func truncateHead(_ content: String, maxLines: Int = ToolLimits.maxLines, maxBytes: Int = ToolLimits.maxBytes) -> Truncation {
    let lines = splitLines(content)
    let totalBytes = content.utf8.count
    if lines.count <= maxLines, totalBytes <= maxBytes {
        return Truncation(content: content, truncated: false, truncatedByLines: false, totalLines: lines.count, outputLines: lines.count, firstLineExceedsLimit: false)
    }
    if let first = lines.first, first.utf8.count > maxBytes {
        return Truncation(content: "", truncated: true, truncatedByLines: false, totalLines: lines.count, outputLines: 0, firstLineExceedsLimit: true)
    }
    var kept: [Substring] = []
    var bytes = 0
    var byLines = false
    for line in lines {
        if kept.count >= maxLines {
            byLines = true
            break
        }
        let lineBytes = line.utf8.count + (kept.isEmpty ? 0 : 1)
        if bytes + lineBytes > maxBytes { break }
        kept.append(line)
        bytes += lineBytes
    }
    return Truncation(content: kept.joined(separator: "\n"), truncated: true, truncatedByLines: byLines, totalLines: lines.count, outputLines: kept.count, firstLineExceedsLimit: false)
}

/// Whether the data looks binary: a NUL byte in its first 8KB.
func looksBinary(_ data: Data) -> Bool {
    data.prefix(8192).contains(0)
}
