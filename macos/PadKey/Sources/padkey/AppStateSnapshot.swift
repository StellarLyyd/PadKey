import Foundation

struct AppStateElementSummary: Codable, Equatable {
    let ref: String
    let nodeId: String
    let role: String?
    let name: String
    let value: String?
    let enabled: Bool?
    let focused: Bool?
    let actions: [String]
}

struct AppStateSnapshot: Codable, Equatable {
    let app: FrontmostAppInfo
    let totalNodes: Int
    let roleCounts: [String: Int]
    let focusedElement: AppStateElementSummary?
    let actionableElements: [AppStateElementSummary]
    let readablePreview: String

    var compactDescription: String {
        let roles = roleCounts
            .sorted { lhs, rhs in
                if lhs.value != rhs.value { return lhs.value > rhs.value }
                return lhs.key < rhs.key
            }
            .prefix(8)
            .map { "\($0.key): \($0.value)" }
            .joined(separator: ", ")
        let focused = focusedElement.map { "\($0.ref) \($0.name)" } ?? "none"
        let elements = actionableElements.prefix(24).map { element in
            let actionText = element.actions.isEmpty ? "no actions" : element.actions.joined(separator: "/")
            return "\(element.ref) \(element.role ?? "AX") \"\(element.name)\" nodeId=\(element.nodeId) actions=\(actionText)"
        }
        .joined(separator: "\n")

        return """
        App: \(app.name)
        Nodes: \(totalNodes)
        Roles: \(roles.isEmpty ? "none" : roles)
        Focused: \(focused)
        Elements:
        \(elements.isEmpty ? "none" : elements)
        Readable text preview:
        \(readablePreview.isEmpty ? "none" : readablePreview)
        """
    }
}

enum AppStateSnapshotBuilder {
    static func snapshot(
        app: FrontmostAppInfo,
        nodes: [AccessibilityNode],
        readableTextLimit: Int = 1_200,
        maxElements: Int = 80
    ) -> AppStateSnapshot {
        let roleCounts = Dictionary(grouping: nodes.compactMap(\.role), by: { $0 })
            .mapValues(\.count)
        let summaries = nodes.enumerated().map { index, node in
            AppStateElementSummary(
                ref: "@e\(index + 1)",
                nodeId: node.id,
                role: node.role,
                name: node.displayName,
                value: sanitizedValue(for: node),
                enabled: node.enabled,
                focused: node.focused,
                actions: node.actions
            )
        }
        let actionable = summaries.filter { summary in
            summary.enabled != false
                && (!summary.actions.isEmpty || summary.role?.localizedCaseInsensitiveContains("Text") == true)
        }
        let readablePreview = readableText(from: nodes, limit: readableTextLimit)

        return AppStateSnapshot(
            app: app,
            totalNodes: nodes.count,
            roleCounts: roleCounts,
            focusedElement: summaries.first(where: { $0.focused == true }),
            actionableElements: Array(actionable.prefix(maxElements)),
            readablePreview: readablePreview
        )
    }

    private static func sanitizedValue(for node: AccessibilityNode) -> String? {
        guard let value = node.value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty
        else {
            return nil
        }
        let looksSecret = [node.role, node.title, node.label, node.placeholder, node.description]
            .compactMap { $0?.lowercased() }
            .contains { text in
                text.contains("password") || text.contains("token") || text.contains("secret")
            }
        guard !looksSecret else { return "[redacted]" }
        return String(value.prefix(120))
    }

    private static func readableText(from nodes: [AccessibilityNode], limit: Int) -> String {
        var seen = Set<String>()
        var pieces: [String] = []
        var count = 0
        for node in nodes {
            for candidate in [node.title, node.label, node.value, node.placeholder, node.description, node.help] {
                guard let candidate else { continue }
                let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
                guard trimmed.count > 2, !seen.contains(trimmed) else { continue }
                seen.insert(trimmed)
                let remaining = limit - count
                guard remaining > 0 else { return pieces.joined(separator: "\n") }
                let clipped = String(trimmed.prefix(remaining))
                pieces.append(clipped)
                count += clipped.count + 1
            }
        }
        return pieces.joined(separator: "\n")
    }
}
