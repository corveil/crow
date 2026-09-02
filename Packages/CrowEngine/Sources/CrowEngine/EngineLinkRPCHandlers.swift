import CrowCore
import CrowIPC
import CrowPersistence
import Foundation

/// Session link CRUD.
///
/// Extracted from `makeEngineRouter`'s dictionary literal (CROW-1174). These
/// methods have no daemon registration — `crowd` answers them only via
/// `fallback: makeEngineRouter(ctx)`.
@MainActor
func makeEngineLinkHandlers(
    appState: AppState,
    store: JSONStore
) -> [String: CommandRouter.Handler] {
    let capturedAppState = appState
    let capturedStore = store
    // The explicit annotation is load-bearing, not decoration: a large
    // dictionary of closures without a contextual type blows Swift's
    // type-checker solver budget (CROW-1134 / CROW-1174).
    let handlers: [String: CommandRouter.Handler] = [
        "add-link": { @Sendable params in
            guard let idStr = params["session_id"]?.stringValue, let sessionID = UUID(uuidString: idStr),
                  let label = params["label"]?.stringValue, !label.isEmpty,
                  let url = params["url"]?.stringValue, !url.isEmpty else {
                throw RPCError.invalidParams("session_id, label, url required (non-empty)")
            }
            let link = SessionLink(sessionID: sessionID, label: label, url: url,
                                   linkType: LinkType(rawValue: params["type"]?.stringValue ?? "custom") ?? .custom)
            return await MainActor.run {
                capturedAppState.links[sessionID, default: []].append(link)
                capturedStore.mutate { $0.links.append(link) }
                return ["link_id": .string(link.id.uuidString)]
            }
        },

        "list-links": { @Sendable params in
            guard let idStr = params["session_id"]?.stringValue, let id = UUID(uuidString: idStr) else {
                throw RPCError.invalidParams("session_id required")
            }
            let lnks = await MainActor.run { capturedAppState.links(for: id) }
            let items: [JSONValue] = lnks.map { l in
                .object(["id": .string(l.id.uuidString), "label": .string(l.label), "url": .string(l.url), "type": .string(l.linkType.rawValue)])
            }
            return ["links": .array(items)]
        },

        "remove-link": { @Sendable params in
            guard let idStr = params["session_id"]?.stringValue, let sessionID = UUID(uuidString: idStr) else {
                throw RPCError.invalidParams("session_id required")
            }
            let linkID = params["link_id"]?.stringValue.flatMap { UUID(uuidString: $0) }
            let url = params["url"]?.stringValue
            guard linkID != nil || url != nil else {
                throw RPCError.invalidParams("link_id or url required")
            }
            func matches(_ l: SessionLink) -> Bool {
                (linkID != nil && l.id == linkID) || (url != nil && l.url == url)
            }
            return await MainActor.run {
                let before = capturedAppState.links(for: sessionID).count
                if var existing = capturedAppState.links[sessionID] {
                    existing.removeAll(where: matches)
                    capturedAppState.links[sessionID] = existing.isEmpty ? nil : existing
                }
                capturedStore.mutate { data in
                    data.links.removeAll { $0.sessionID == sessionID && matches($0) }
                }
                let removed = before - capturedAppState.links(for: sessionID).count
                return ["removed": .int(removed)]
            }
        },

        "edit-link": { @Sendable params in
            guard let idStr = params["session_id"]?.stringValue, let sessionID = UUID(uuidString: idStr) else {
                throw RPCError.invalidParams("session_id required")
            }
            let linkID = params["link_id"]?.stringValue.flatMap { UUID(uuidString: $0) }
            let selectorURL = params["url"]?.stringValue
            guard linkID != nil || selectorURL != nil else {
                throw RPCError.invalidParams("link_id or url required to identify the link")
            }
            let newLabel = params["label"]?.stringValue
            let newURL = params["new_url"]?.stringValue
            // Blank label/URL would break URL-keyed consumers; reject them
            // like add-link does rather than silently wiping a field.
            if let newLabel, newLabel.trimmingCharacters(in: .whitespaces).isEmpty {
                throw RPCError.invalidParams("label must not be empty")
            }
            if let newURL, newURL.trimmingCharacters(in: .whitespaces).isEmpty {
                throw RPCError.invalidParams("new_url must not be empty")
            }
            var newType: LinkType?
            if let typeStr = params["type"]?.stringValue {
                guard let parsed = LinkType(rawValue: typeStr) else {
                    throw RPCError.invalidParams("invalid type '\(typeStr)' (expected ticket, pr, repo, or custom)")
                }
                newType = parsed
            }
            guard newLabel != nil || newURL != nil || newType != nil else {
                throw RPCError.invalidParams("at least one of label, new_url, type required")
            }
            func matches(_ l: SessionLink) -> Bool {
                (linkID != nil && l.id == linkID) || (selectorURL != nil && l.url == selectorURL)
            }
            func apply(_ l: inout SessionLink) {
                if let newLabel { l.label = newLabel }
                if let newURL { l.url = newURL }
                if let newType { l.linkType = newType }
            }
            return await MainActor.run {
                var updated = 0
                if var existing = capturedAppState.links[sessionID] {
                    for i in existing.indices where matches(existing[i]) {
                        apply(&existing[i])
                        updated += 1
                    }
                    capturedAppState.links[sessionID] = existing
                }
                capturedStore.mutate { data in
                    for i in data.links.indices where data.links[i].sessionID == sessionID && matches(data.links[i]) {
                        apply(&data.links[i])
                    }
                }
                return ["updated": .int(updated)]
            }
        },
    ]
    return handlers
}
