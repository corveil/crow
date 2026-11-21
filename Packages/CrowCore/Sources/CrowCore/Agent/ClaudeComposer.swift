import Foundation

/// Reads Claude Code's composer (the `❯` input box between two `─` rules) out
/// of a pane capture taken **with** SGR escapes, to tell whether the operator
/// left text in it unsent (CROW-1493).
///
/// Crow's pre-expiry `/compact` pastes into this box and presses Enter, so a
/// draft there would be submitted with `/compact` glued to its end. The check
/// is deliberately one-sided: anything it can't read as an empty composer is
/// reported as not empty, and the caller skips the session.
///
/// Claude Code draws placeholder and suggested-prompt text in the box dimmed
/// or gray, so those cells don't count as input. Typed text is drawn in the
/// default color. A color this doesn't recognize as gray counts as input.
public enum ClaudeComposer {
    public enum State: String, Sendable, Equatable {
        /// The composer was found and holds nothing typed.
        case empty
        /// The composer holds text that isn't placeholder styling.
        case hasInput = "has_input"
        /// No composer in the capture (another screen is up, a menu, bash
        /// mode, or a layout this doesn't know).
        case notFound = "not_found"
    }

    public static func state(ofCapture capture: String) -> State {
        let lines = capture.split(separator: "\n", omittingEmptySubsequences: false).map(cells)
        let plain = lines.map { String($0.map(\.character)) }
        let rules = plain.indices.filter { isRule(plain[$0]) }
        guard rules.count >= 2 else { return .notFound }
        // The composer is the bottom-most pair of rules with a prompt line
        // right under the top one. Claude Code's footer sits below it.
        for k in stride(from: rules.count - 1, to: 0, by: -1) {
            let top = rules[k - 1], bottom = rules[k]
            guard bottom - top >= 2 else { continue }
            var first = lines[top + 1]
            while let c = first.first, c.character == " " { first.removeFirst() }
            guard let glyph = first.first, promptGlyphs.contains(glyph.character) else { continue }
            first.removeFirst()
            let body = [first] + lines[(top + 2)..<bottom]
            let typed = body.joined().contains { !$0.character.isWhitespace && !$0.isMuted }
            return typed ? .hasInput : .empty
        }
        return .notFound
    }

    static let promptGlyphs: Set<Character> = ["❯", ">"]

    static func isRule(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces).hasPrefix("──")
    }

    // MARK: - SGR

    struct Cell: Equatable {
        var character: Character
        var dim: Bool
        var foreground: Foreground

        /// Placeholder styling: dimmed, or a mid gray.
        var isMuted: Bool { dim || foreground.isGray }
    }

    enum Foreground: Equatable {
        case `default`
        case basic(Int)
        case indexed(Int)
        case rgb(Int, Int, Int)

        var isGray: Bool {
            switch self {
            case .default: return false
            case .basic(let n): return n == 90
            case .indexed(let n): return [8, 59, 102, 145].contains(n) || (240...250).contains(n)
            case .rgb(let r, let g, let b):
                // Gray, but not near-white or near-black: a theme can draw
                // typed text in either.
                let hi = max(r, g, b), lo = min(r, g, b)
                return hi - lo <= 24 && (64...200).contains((r + g + b) / 3)
            }
        }
    }

    /// The printable cells of one captured line, each with the SGR state it
    /// was drawn in. Non-SGR escape sequences (cursor moves, OSC hyperlinks)
    /// are dropped.
    static func cells(_ line: Substring) -> [Cell] {
        var out: [Cell] = []
        var dim = false
        var fg = Foreground.default
        var i = line.startIndex
        while i < line.endIndex {
            let c = line[i]
            guard c == "\u{1B}" else {
                if c != "\r" { out.append(Cell(character: c, dim: dim, foreground: fg)) }
                i = line.index(after: i)
                continue
            }
            let next = line.index(after: i)
            guard next < line.endIndex else { break }
            if line[next] == "[" {
                // CSI: parameters, then one final byte in @…~.
                var j = line.index(after: next)
                var params = ""
                while j < line.endIndex, let a = line[j].asciiValue, !(0x40...0x7E).contains(a) {
                    params.append(line[j])
                    j = line.index(after: j)
                }
                guard j < line.endIndex else { break }
                if line[j] == "m" { applySGR(params, dim: &dim, fg: &fg) }
                i = line.index(after: j)
            } else if line[next] == "]" {
                // OSC: up to BEL or ST (ESC \).
                var j = line.index(after: next)
                while j < line.endIndex, line[j] != "\u{07}", line[j] != "\u{1B}" { j = line.index(after: j) }
                if j < line.endIndex, line[j] == "\u{1B}" {
                    let after = line.index(after: j)
                    j = after < line.endIndex ? after : j
                }
                i = j < line.endIndex ? line.index(after: j) : j
            } else {
                // Two-byte escape.
                i = line.index(after: next)
            }
        }
        return out
    }

    static func applySGR(_ params: String, dim: inout Bool, fg: inout Foreground) {
        let codes = params.split(separator: ";", omittingEmptySubsequences: false)
            .flatMap { $0.split(separator: ":", omittingEmptySubsequences: false) }
            .map { Int($0) ?? 0 }
        var k = 0
        while k < codes.count {
            let code = codes[k]
            switch code {
            case 0: dim = false; fg = .default
            case 2: dim = true
            case 22: dim = false
            case 39: fg = .default
            case 30...37, 90...97: fg = .basic(code)
            case 38:
                if k + 2 < codes.count, codes[k + 1] == 5 {
                    fg = .indexed(codes[k + 2])
                    k += 2
                } else if k + 4 < codes.count, codes[k + 1] == 2 {
                    fg = .rgb(codes[k + 2], codes[k + 3], codes[k + 4])
                    k += 4
                }
            case 48:
                // Background colors carry the same sub-parameters; skip them.
                if k + 1 < codes.count { k += codes[k + 1] == 5 ? 2 : (codes[k + 1] == 2 ? 4 : 0) }
            default: break
            }
            k += 1
        }
    }
}
