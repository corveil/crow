import ArgumentParser
import Foundation

/// Parsing for the `crow batch-work-on-issues` URL flags.
///
/// Mirrors the `--prompt` / `--prompt-file` pair on `crow job add`: repeatable
/// inline values first, then the contents of a newline-delimited file (or
/// stdin), so a ticket list can be piped straight out of `gh issue list`.
enum BoardArgs {
    /// Merge `--url` values with the lines of `--urls-file`, inline values
    /// first. Blank lines and surrounding whitespace are dropped — a trailing
    /// newline from a pipe must not become an empty URL the server then has to
    /// report as rejected.
    ///
    /// Duplicates are left in: the server dedupes while it validates, and
    /// stripping them here would hide the count difference from `sent`.
    ///
    /// - Throws: `ValidationError` when the file is unreadable or not UTF-8.
    static func urlList(url: [String], urlsFile: String?) throws -> [String] {
        var urls = url.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if let urlsFile {
            let text = try readURLFile(urlsFile)
            urls += text.split(separator: "\n", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }
        return urls
    }

    /// Read a URL list from a file path, or from stdin when the path is "-".
    /// Same shape as `JobScheduleArgs.readPromptText`.
    static func readURLFile(_ path: String) throws -> String {
        if path == "-" {
            let data = FileHandle.standardInput.readDataToEndOfFile()
            guard let text = String(data: data, encoding: .utf8) else {
                throw ValidationError("stdin is not valid UTF-8.")
            }
            return text
        }
        do {
            return try String(contentsOfFile: path, encoding: .utf8)
        } catch {
            throw ValidationError("Could not read URL file '\(path)': \(error.localizedDescription)")
        }
    }
}
