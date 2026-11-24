import Foundation

/// One event of the web Chat view: a harness transcript reduced to a small,
/// ACP-shaped list the client renders as chat bubbles instead of a TUI.
///
/// Read-only and best-effort. The agents keep running in tmux; this parses the
/// JSONL the harness already writes (`~/.claude/projects/…`, Codex rollouts) so
/// unknown record types are skipped, never fatal.
public struct ChatEvent: Sendable, Equatable {
    public enum Kind: String, Sendable {
        case user
        case assistant
        case toolCall = "tool_call"
        case toolResult = "tool_result"
        case turnEnd = "turn_end"
        /// Harness-side notices: compaction, interrupts, task notifications.
        case notice
    }

    public var kind: Kind
    public var text: String
    /// Tool name for `.toolCall`.
    public var toolName: String?
    /// Pairs a `.toolCall` with its `.toolResult`.
    public var toolID: String?
    public var isError: Bool
    public var timestamp: String?
    /// `.turnEnd` only, when the harness recorded it.
    public var durationMs: Int?
    /// Claude's `AskUserQuestion` (CROW-1512): the questions, on the
    /// `.toolCall`, so Chat can render a question card instead of the raw
    /// input JSON. On the `.toolResult` too when the harness recorded them
    /// there, so a result whose call fell before the tail window still renders.
    public var questions: [ChatQuestion]?
    /// The `AskUserQuestion` result's answers, question text → answer (a
    /// multi-select's labels comma-joined, as Claude Code records them). Nil
    /// for a declined question; `isError` is set then.
    public var answers: [String: String]?

    public init(
        kind: Kind, text: String, toolName: String? = nil, toolID: String? = nil,
        isError: Bool = false, timestamp: String? = nil, durationMs: Int? = nil,
        questions: [ChatQuestion]? = nil, answers: [String: String]? = nil
    ) {
        self.kind = kind
        self.text = text
        self.toolName = toolName
        self.toolID = toolID
        self.isError = isError
        self.timestamp = timestamp
        self.durationMs = durationMs
        self.questions = questions
        self.answers = answers
    }
}

/// One question of a Claude `AskUserQuestion` call (CROW-1512).
public struct ChatQuestion: Sendable, Equatable {
    public struct Option: Sendable, Equatable {
        public var label: String
        public var description: String

        public init(label: String, description: String = "") {
            self.label = label
            self.description = description
        }
    }

    public var question: String
    public var header: String
    public var multiSelect: Bool
    public var options: [Option]

    public init(question: String, header: String, multiSelect: Bool, options: [Option]) {
        self.question = question
        self.header = header
        self.multiSelect = multiSelect
        self.options = options
    }

    /// The tool's name in Claude Code transcripts and hooks.
    public static let toolName = "AskUserQuestion"
    /// The tool schema allows 1–4 questions of 2–4 options. Anything past
    /// these caps is dropped rather than drawn: the input is model-written.
    static let maxQuestions = 8
    static let maxOptions = 8

    /// `input.questions` of an `AskUserQuestion` tool_use (or the
    /// `toolUseResult.questions` echo). Nil when there is no usable question.
    public static func parse(_ raw: Any?) -> [ChatQuestion]? {
        guard let list = raw as? [[String: Any]] else { return nil }
        let qs: [ChatQuestion] = list.prefix(maxQuestions).compactMap { q in
            guard let text = q["question"] as? String,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            let options: [Option] = ((q["options"] as? [[String: Any]]) ?? []).prefix(maxOptions).compactMap { o in
                guard let label = o["label"] as? String, !label.isEmpty else { return nil }
                return Option(label: label, description: o["description"] as? String ?? "")
            }
            guard !options.isEmpty else { return nil }
            return ChatQuestion(
                question: text, header: q["header"] as? String ?? "",
                multiSelect: q["multiSelect"] as? Bool ?? false, options: options)
        }
        return qs.isEmpty ? nil : qs
    }

    /// The call's one-line text: the first question, not the input JSON.
    public static func summary(_ qs: [ChatQuestion]) -> String {
        guard let first = qs.first else { return "" }
        let more = qs.count > 1 ? " (+\(qs.count - 1) more)" : ""
        return ChatTranscript.clip(first.question, ChatTranscript.maxToolInputChars) + more
    }
}

/// Context-window occupancy as of the latest main-conversation model call.
public struct ChatUsage: Sendable, Equatable {
    /// Prompt tokens of that call. Claude: `input_tokens +
    /// cache_read_input_tokens + cache_creation_input_tokens`.
    public var usedTokens: Int
    public var model: String?
    /// The window, when the transcript states it (Codex does; Claude's JSONL
    /// does not — see `ChatContextWindow`).
    public var maxTokens: Int?

    public init(usedTokens: Int, model: String?, maxTokens: Int? = nil) {
        self.usedTokens = usedTokens
        self.model = model
        self.maxTokens = maxTokens
    }
}

/// Context-window size by model name, for transcripts that don't record it.
///
/// Every current Claude model reported `contextWindow: 1000000` in stream-json
/// `result.modelUsage` (Claude Code 2.1.309, 2026-10-26: haiku-5-5, sonnet-5-5,
/// opus-5-5 with and without `[1m]`, fable-5-1). The transcript names the model
/// without the `[1m]` suffix. Unknown models return nil so the UI shows a raw
/// token count instead of a guessed percentage.
public enum ChatContextWindow {
    public static func maxTokens(model: String?) -> Int? {
        guard let raw = model?.lowercased(), !raw.isEmpty else { return nil }
        if raw.hasSuffix("[1m]") { return 1_000_000 }
        let m = raw.hasPrefix("anthropic/") ? String(raw.dropFirst("anthropic/".count)) : raw
        let oneMillion = ["claude-opus-5", "claude-sonnet-5", "claude-haiku-5", "claude-fable-5"]
        if oneMillion.contains(where: { m.hasPrefix($0) }) { return 1_000_000 }
        let legacy = ["claude-3", "claude-opus-4", "claude-sonnet-4", "claude-haiku-4"]
        if legacy.contains(where: { m.hasPrefix($0) }) { return 200_000 }
        return nil
    }
}

public enum ChatTranscriptFormat: String, Sendable {
    case claude
    case codex
}

public enum ChatTranscript {
    /// Tool results are clipped to this many characters; the TUI is still the
    /// place to read a 4,000-line build log.
    public static let maxToolResultChars = 2_000
    public static let maxToolInputChars = 300
    /// Without a cursor, start this far from the end of a large file.
    public static let initialTailBytes = 2 * 1_024 * 1_024
    /// One page reads at most this many bytes; a cursor far behind EOF (or 0
    /// on a huge log) catches up over several polls instead of one huge read.
    public static let maxPageBytes = 4 * 1_024 * 1_024

    public struct Page: Sendable, Equatable {
        public var events: [ChatEvent]
        /// Byte offset just past the last complete line consumed. Pass it back
        /// as `cursor` to tail.
        public var cursor: Int
        /// True when the read started mid-file (initial tail of a large log).
        public var truncated: Bool
        /// The latest usage seen in this page's lines; nil when none (keep the
        /// previous page's value).
        public var usage: ChatUsage? = nil
    }

    /// Read complete lines of `path` from `cursor` (or the tail, when nil) and
    /// parse them. A trailing partial line is left for the next read.
    public static func read(
        path: String, format: ChatTranscriptFormat, cursor: Int?,
        maxPageBytes: Int = ChatTranscript.maxPageBytes
    ) throws -> Page {
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        defer { try? handle.close() }
        let size = Int(try handle.seekToEnd())
        // A negative cursor (any `/rpc` peer can send one) is treated like no
        // cursor: `UInt64(start)` below would otherwise trap and take crowd down.
        let cursor = cursor.flatMap { $0 >= 0 ? $0 : nil }
        var start = cursor ?? max(0, size - initialTailBytes)
        // The file shrank or was replaced (a rewrite, not an append): restart.
        if start > size { start = 0 }
        try handle.seek(toOffset: UInt64(start))
        let data = try handle.read(upToCount: max(1, maxPageBytes)) ?? Data()
        let windowFull = start + data.count < size
        var body = data[...]
        var truncated = false
        if cursor == nil, start > 0 {
            // Skip the partial first line of the tail window.
            if let nl = body.firstIndex(of: 0x0A) {
                body = body[body.index(after: nl)...]
            } else {
                body = body[body.endIndex...]
            }
            truncated = true
        }
        let consumedEnd: Int
        if let lastNL = body.lastIndex(of: 0x0A) {
            consumedEnd = lastNL + 1
            body = body[body.startIndex..<consumedEnd]
        } else if windowFull {
            // One line longer than a whole page: skip it rather than stall the
            // cursor. Its tail is undecodable next time and is skipped too.
            consumedEnd = data.endIndex
            body = body[body.startIndex..<body.startIndex]
        } else {
            consumedEnd = body.startIndex
            body = body[body.startIndex..<body.startIndex]
        }
        // `Data` slices keep the parent's indices, which here are 0-based into
        // `data`, so the absolute offset is `start + consumedEnd`.
        let (events, usage) = parseWithUsage(Data(body), format: format)
        return Page(events: events, cursor: start + consumedEnd, truncated: truncated, usage: usage)
    }

    /// Parse NDJSON bytes. Lines that don't decode are skipped.
    public static func parse(_ data: Data, format: ChatTranscriptFormat) -> [ChatEvent] {
        parseWithUsage(data, format: format).events
    }

    public static func parseWithUsage(
        _ data: Data, format: ChatTranscriptFormat
    ) -> (events: [ChatEvent], usage: ChatUsage?) {
        var out: [ChatEvent] = []
        var usage: ChatUsage?
        var codexModel: String?
        for line in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else {
                continue
            }
            switch format {
            case .claude:
                appendClaude(obj, to: &out)
                if let u = claudeUsage(obj) { usage = u }
            case .codex:
                appendCodex(obj, to: &out)
                if let u = codexUsage(obj, model: &codexModel) { usage = u }
            }
        }
        return (out, usage)
    }

    /// Main-conversation assistant records carry the call's `usage`.
    static func claudeUsage(_ obj: [String: Any]) -> ChatUsage? {
        guard obj["type"] as? String == "assistant", obj["isSidechain"] as? Bool != true,
              let message = obj["message"] as? [String: Any],
              let u = message["usage"] as? [String: Any] else { return nil }
        func n(_ k: String) -> Int { (u[k] as? NSNumber)?.intValue ?? 0 }
        let used = n("input_tokens") + n("cache_read_input_tokens") + n("cache_creation_input_tokens")
        guard used > 0 else { return nil }
        let model = message["model"] as? String
        // `<synthetic>` marks harness-made messages (e.g. an API error), not a real call.
        if model == "<synthetic>" { return nil }
        return ChatUsage(usedTokens: used, model: model)
    }

    /// Codex: `turn_context` names the model; `event_msg/token_count` carries the
    /// last call's input tokens and the model's context window.
    static func codexUsage(_ obj: [String: Any], model: inout String?) -> ChatUsage? {
        guard let payload = obj["payload"] as? [String: Any] else { return nil }
        if obj["type"] as? String == "turn_context", let m = payload["model"] as? String { model = m }
        guard obj["type"] as? String == "event_msg", payload["type"] as? String == "token_count",
              let info = payload["info"] as? [String: Any],
              let last = info["last_token_usage"] as? [String: Any],
              let input = (last["input_tokens"] as? NSNumber)?.intValue, input > 0 else { return nil }
        return ChatUsage(
            usedTokens: input, model: model,
            maxTokens: (info["model_context_window"] as? NSNumber)?.intValue)
    }

    // MARK: - Claude Code

    private static func appendClaude(_ obj: [String: Any], to out: inout [ChatEvent]) {
        // Subagent (Task) traffic is a separate conversation interleaved in the
        // same file; the TUI collapses it, so do we.
        if obj["isSidechain"] as? Bool == true { return }
        let ts = obj["timestamp"] as? String
        switch obj["type"] as? String {
        case "user":
            if obj["isMeta"] as? Bool == true { return }
            guard let message = obj["message"] as? [String: Any] else { return }
            if let text = message["content"] as? String {
                appendClaudeUserText(text, ts: ts, to: &out)
            } else if let blocks = message["content"] as? [[String: Any]] {
                // `toolUseResult` is the record's structured result, so it can
                // only be read for a record carrying one tool_result.
                let single = blocks.filter { $0["type"] as? String == "tool_result" }.count == 1
                for block in blocks {
                    switch block["type"] as? String {
                    case "tool_result":
                        let isError = block["is_error"] as? Bool ?? false
                        var event = ChatEvent(
                            kind: .toolResult,
                            text: clip(contentText(block["content"]), maxToolResultChars),
                            toolID: block["tool_use_id"] as? String,
                            isError: isError, timestamp: ts)
                        if single, !isError, let r = obj["toolUseResult"] as? [String: Any],
                           let answers = r["answers"] as? [String: Any] {
                            event.answers = answers.compactMapValues { $0 as? String }
                            event.questions = ChatQuestion.parse(r["questions"])
                        }
                        out.append(event)
                    case "text":
                        appendClaudeUserText(block["text"] as? String ?? "", ts: ts, to: &out)
                    case "image":
                        out.append(ChatEvent(kind: .user, text: "[image]", timestamp: ts))
                    default:
                        break
                    }
                }
            }
        case "assistant":
            guard let message = obj["message"] as? [String: Any],
                  let blocks = message["content"] as? [[String: Any]] else { return }
            for block in blocks {
                switch block["type"] as? String {
                case "text":
                    let text = (block["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    if !text.isEmpty { out.append(ChatEvent(kind: .assistant, text: text, timestamp: ts)) }
                case "tool_use":
                    let name = block["name"] as? String ?? "tool"
                    let questions = name == ChatQuestion.toolName
                        ? ChatQuestion.parse((block["input"] as? [String: Any])?["questions"]) : nil
                    out.append(ChatEvent(
                        kind: .toolCall,
                        text: questions.map(ChatQuestion.summary)
                            ?? toolInputSummary(name: name, input: block["input"]),
                        toolName: name, toolID: block["id"] as? String, timestamp: ts,
                        questions: questions))
                default:
                    // `thinking` is persisted as an empty string plus a signature.
                    break
                }
            }
        case "system":
            switch obj["subtype"] as? String {
            case "turn_duration":
                let ms = (obj["durationMs"] as? NSNumber)?.intValue
                out.append(ChatEvent(kind: .turnEnd, text: "", timestamp: ts, durationMs: ms))
            case "compact_boundary":
                out.append(ChatEvent(kind: .notice, text: "Conversation compacted", timestamp: ts))
            default:
                break
            }
        default:
            break
        }
    }

    /// User strings carry harness envelopes (`<command-name>`, `<bash-input>`,
    /// `<task-notification>`, …). Unwrap the ones a human typed; demote the rest.
    private static func appendClaudeUserText(_ raw: String, ts: String?, to out: inout [ChatEvent]) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return }
        if text.hasPrefix("<local-command-caveat>") || text.hasPrefix("<system-reminder>") { return }
        if let name = tagContent(text, "command-name") {
            // `/skill args` the user typed; the expanded skill body follows as a
            // meta record, which is skipped.
            let args = tagContent(text, "command-args") ?? ""
            out.append(ChatEvent(kind: .user, text: args.isEmpty ? name : "\(name) \(args)", timestamp: ts))
            return
        }
        if let cmd = tagContent(text, "bash-input") {
            out.append(ChatEvent(kind: .user, text: "! \(cmd)", timestamp: ts))
            return
        }
        if text.hasPrefix("<bash-stdout>") || text.hasPrefix("<local-command-stdout>") {
            let body = tagContent(text, "bash-stdout") ?? tagContent(text, "local-command-stdout") ?? ""
            if !body.isEmpty {
                out.append(ChatEvent(kind: .toolResult, text: clip(stripANSI(body), maxToolResultChars), timestamp: ts))
            }
            return
        }
        if text.hasPrefix("<task-notification>") {
            let summary = tagContent(text, "summary") ?? "Background task update"
            out.append(ChatEvent(kind: .notice, text: summary, timestamp: ts))
            return
        }
        if text.hasPrefix("[Request interrupted by user") {
            out.append(ChatEvent(kind: .notice, text: "Interrupted", timestamp: ts))
            out.append(ChatEvent(kind: .turnEnd, text: "", timestamp: ts))
            return
        }
        out.append(ChatEvent(kind: .user, text: text, timestamp: ts))
    }

    // MARK: - Codex

    private static func appendCodex(_ obj: [String: Any], to out: inout [ChatEvent]) {
        let ts = obj["timestamp"] as? String
        guard let payload = obj["payload"] as? [String: Any] else { return }
        switch obj["type"] as? String {
        case "response_item":
            switch payload["type"] as? String {
            case "message":
                let role = payload["role"] as? String
                let text = codexContentText(payload["content"]).trimmingCharacters(in: .whitespacesAndNewlines)
                if text.isEmpty { return }
                if role == "assistant" {
                    out.append(ChatEvent(kind: .assistant, text: text, timestamp: ts))
                } else if role == "user" {
                    // Codex injects context as user-role messages.
                    if text.hasPrefix("<environment_context>") || text.hasPrefix("<user_instructions>")
                        || text.hasPrefix("# AGENTS.md") || text.hasPrefix("<app-context>") { return }
                    out.append(ChatEvent(kind: .user, text: text, timestamp: ts))
                }
            case "function_call":
                let name = payload["name"] as? String ?? "tool"
                var input: Any? = payload["arguments"]
                if let s = input as? String, let d = s.data(using: .utf8),
                   let decoded = try? JSONSerialization.jsonObject(with: d) {
                    input = decoded
                }
                out.append(ChatEvent(
                    kind: .toolCall, text: toolInputSummary(name: name, input: input),
                    toolName: name, toolID: payload["call_id"] as? String, timestamp: ts))
            case "custom_tool_call":
                let name = payload["name"] as? String ?? "tool"
                out.append(ChatEvent(
                    kind: .toolCall, text: toolInputSummary(name: name, input: payload["input"]),
                    toolName: name, toolID: payload["call_id"] as? String, timestamp: ts))
            case "function_call_output", "custom_tool_call_output":
                var output = payload["output"]
                // Older rollouts wrap the output as `{"output": "...", "metadata": …}`.
                if let s = output as? String, s.hasPrefix("{"), let d = s.data(using: .utf8),
                   let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                   let inner = o["output"] as? String {
                    output = inner
                }
                // `exec_command` prefixes `Chunk ID / Wall time / … / Output:`.
                if let s = output as? String, s.hasPrefix("Chunk ID:") || s.hasPrefix("Exit code:"),
                   let r = s.range(of: "\nOutput:\n") {
                    output = String(s[r.upperBound...])
                }
                out.append(ChatEvent(
                    kind: .toolResult, text: clip(contentText(output), maxToolResultChars),
                    toolID: payload["call_id"] as? String, timestamp: ts))
            case "web_search_call":
                let action = payload["action"] as? [String: Any]
                out.append(ChatEvent(
                    kind: .toolCall, text: action?["query"] as? String ?? "",
                    toolName: "web_search", toolID: payload["id"] as? String, timestamp: ts))
            default:
                break
            }
        case "event_msg":
            if payload["type"] as? String == "task_complete" {
                let ms = (payload["duration_ms"] as? NSNumber)?.intValue
                out.append(ChatEvent(kind: .turnEnd, text: "", timestamp: ts, durationMs: ms))
            } else if payload["type"] as? String == "turn_aborted" {
                out.append(ChatEvent(kind: .notice, text: "Interrupted", timestamp: ts))
                out.append(ChatEvent(kind: .turnEnd, text: "", timestamp: ts))
            }
        default:
            break
        }
    }

    private static func codexContentText(_ content: Any?) -> String {
        guard let blocks = content as? [[String: Any]] else { return content as? String ?? "" }
        return blocks.compactMap { $0["text"] as? String }.joined(separator: "\n")
    }

    // MARK: - Helpers

    /// One-line summary of a tool's input: the field a human would look at.
    public static func toolInputSummary(name: String, input: Any?) -> String {
        if let s = input as? String { return clip(firstLine(s), maxToolInputChars) }
        guard let dict = input as? [String: Any] else { return "" }
        let preferred = ["command", "cmd", "file_path", "path", "pattern", "url", "query",
                         "description", "prompt", "skill", "notebook_path"]
        for key in preferred {
            if let v = dict[key] as? String, !v.isEmpty { return clip(v, maxToolInputChars) }
            if let v = dict[key] as? [String] { return clip(v.joined(separator: " "), maxToolInputChars) }
        }
        if let d = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]),
           let s = String(data: d, encoding: .utf8) {
            return clip(s, maxToolInputChars)
        }
        return ""
    }

    /// Tool-result `content` is a string or an array of `{type: text|image}`.
    static func contentText(_ content: Any?) -> String {
        if let s = content as? String { return s }
        guard let blocks = content as? [[String: Any]] else { return "" }
        return blocks.map { block -> String in
            if let t = block["text"] as? String { return t }
            if block["type"] as? String == "image" { return "[image]" }
            return ""
        }.filter { !$0.isEmpty }.joined(separator: "\n")
    }

    static func clip(_ s: String, _ limit: Int) -> String {
        guard s.count > limit else { return s }
        return String(s.prefix(limit)) + "…"
    }

    private static func firstLine(_ s: String) -> String {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? trimmed
    }

    private static func tagContent(_ text: String, _ tag: String) -> String? {
        guard let open = text.range(of: "<\(tag)>"),
              let close = text.range(of: "</\(tag)>", range: open.upperBound..<text.endIndex) else { return nil }
        return String(text[open.upperBound..<close.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func stripANSI(_ s: String) -> String {
        s.replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[A-Za-z]", with: "", options: .regularExpression)
    }
}
