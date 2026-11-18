import CrowCore
import Foundation

/// The HTML for `/oauth/authorize` (CROW-1465): the consent form, and the pages
/// that refuse.
///
/// Self-contained — inline styles, no script, no external asset — because it is
/// served on the public OAuth surface without the web-auth gate, under a CSP of
/// `default-src 'none'`. Every interpolated value goes through `escape`: the
/// client name and redirect URI are chosen by whoever registered the client.
public enum MCPOAuthConsentPage {

    /// What each scope lets a connected app read, in the operator's terms.
    public static func describe(_ scope: MCPScope) -> String {
        switch scope {
        case .sessionsRead: return "Sessions: what each one is doing, its status, and what is stuck"
        case .boardRead: return "The ticket and review boards"
        case .todosRead: return "The Scratch list"
        }
    }

    /// The consent form.
    ///
    /// The redirect URI's host is shown on its own line in bold, because the client
    /// name is self-asserted at registration and the host is what actually decides
    /// where the code goes.
    public static func consent(
        request: MCPOAuth.AuthorizationRequest,
        consentID: String,
        checked: Set<MCPScope>? = nil,
        message: String? = nil
    ) -> String {
        let ticked = checked ?? request.offeredScopes
        let redirectHost = URLComponents(string: request.redirectURI)?.host ?? request.redirectURI
        var scopeRows = ""
        for scope in MCPScope.allCases.sorted() {
            let isChecked = ticked.contains(scope) ? " checked" : ""
            scopeRows += """
                <label class="scope"><input type="checkbox" name="scope" value="\(escape(scope.rawValue))"\(isChecked)>
                <span><code>\(escape(scope.rawValue))</code><br><small>\(escape(describe(scope)))</small></span></label>

                """
        }
        let notice = message.map { #"<p class="error" role="alert">\#(escape($0))</p>"# } ?? ""
        return page(title: "Connect \(request.client.clientName) to Crow", body: """
            <h1>Connect an app to Crow</h1>
            <p><strong>\(escape(request.client.clientName))</strong> wants read-only access to this Crow.</p>
            <dl>
              <dt>Sends you back to</dt>
              <dd><strong>\(escape(redirectHost))</strong><br><small>\(escape(request.redirectURI))</small></dd>
              <dt>For</dt>
              <dd><small>\(escape(request.resource))</small></dd>
            </dl>
            <p class="hint">The app name is chosen by the app. Approve only if you started this connection
            and you recognise the host above (Claude uses <code>claude.ai</code>).</p>
            \(notice)
            <form method="post" action="\(escape(MCPOAuth.authorizePath))">
              <input type="hidden" name="consent_id" value="\(escape(consentID))">
              <fieldset>
                <legend>Allow it to read</legend>
                \(scopeRows)
              </fieldset>
              <label for="pw">Crow web password</label>
              <input id="pw" type="password" name="password" autocomplete="current-password" autofocus>
              <div class="actions">
                <button type="submit" name="decision" value="approve">Approve</button>
                <button type="submit" name="decision" value="deny" class="secondary">Deny</button>
              </div>
            </form>
            <p class="hint">Nothing here can change Crow: every MCP tool is read-only. Revoke access any time with
            <code>crow mcp token revoke</code> or Settings → Web access.</p>
            """)
    }

    /// The page shown when a web password has not been set. Consent is the only
    /// gate once the OAuth endpoints are public, so without a password there is
    /// nothing to check and nothing is issued — from loopback too.
    public static func passwordRequired() -> String {
        refusal(
            title: "Set a web password first",
            message: "Crow approves an app only after you enter its web password, and none is set. "
                + "On the machine running crowd, set one with `crow web-password set` or in "
                + "Settings → Web access, then start the connection again from the app.")
    }

    /// A page that explains why nothing was issued.
    public static func refusal(title: String, message: String) -> String {
        page(title: title, body: """
            <h1>\(escape(title))</h1>
            <p>\(escapeWithCode(message))</p>
            <p class="hint">No access was granted.</p>
            """)
    }

    /// HTML-escape text for both element content and quoted attributes.
    public static func escape(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        for char in text {
            switch char {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&#39;"
            default: out.append(char)
            }
        }
        return out
    }

    /// Escape, then render `` `code` `` spans. Only for messages this file writes.
    static func escapeWithCode(_ text: String) -> String {
        let parts = escape(text).components(separatedBy: "`")
        return parts.enumerated().map { index, part in
            index % 2 == 1 ? "<code>\(part)</code>" : part
        }.joined()
    }

    private static func page(title: String, body: String) -> String {
        """
        <!doctype html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta name="referrer" content="no-referrer">
        <title>\(escape(title))</title>
        <style>
        :root { color-scheme: light dark; --bg: #f6f6f4; --fg: #1d1d1b; --muted: #6b6b66; --card: #fff;
          --line: #deded8; --accent: #2f5d50; --err: #a33; }
        @media (prefers-color-scheme: dark) { :root { --bg: #141413; --fg: #ececea; --muted: #9a9a94;
          --card: #1e1e1c; --line: #33332f; --accent: #7fb8a6; --err: #e88; } }
        * { box-sizing: border-box; }
        body { margin: 0; background: var(--bg); color: var(--fg);
          font: 16px/1.5 -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; }
        main { max-width: 34rem; margin: 2rem auto; padding: 1.5rem; background: var(--card);
          border: 1px solid var(--line); border-radius: 12px; }
        @media (max-width: 36rem) { main { margin: 0; border-radius: 0; border-width: 0 0 1px; } }
        h1 { font-size: 1.3rem; margin: 0 0 1rem; }
        dl { margin: 1rem 0; } dt { color: var(--muted); font-size: .85rem; } dd { margin: 0 0 .75rem; word-break: break-all; }
        small, .hint { color: var(--muted); } .hint { font-size: .85rem; }
        fieldset { border: 1px solid var(--line); border-radius: 8px; margin: 1rem 0; padding: .5rem 1rem; }
        legend { padding: 0 .25rem; color: var(--muted); font-size: .85rem; }
        .scope { display: flex; gap: .6rem; align-items: flex-start; margin: .6rem 0; }
        .scope input { margin-top: .3rem; }
        input[type=password] { width: 100%; padding: .6rem; font: inherit; color: inherit; background: var(--bg);
          border: 1px solid var(--line); border-radius: 8px; margin: .25rem 0 1rem; }
        .actions { display: flex; gap: .75rem; }
        button { flex: 1; padding: .7rem; font: inherit; border-radius: 8px; border: 1px solid var(--accent);
          background: var(--accent); color: var(--card); cursor: pointer; }
        button.secondary { background: transparent; color: var(--fg); border-color: var(--line); }
        .error { color: var(--err); font-weight: 600; }
        code { font-size: .9em; }
        </style>
        </head>
        <body><main>
        \(body)
        </main></body>
        </html>
        """
    }
}
