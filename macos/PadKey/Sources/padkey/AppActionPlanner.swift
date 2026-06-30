import Foundation

struct PlannerActionArguments: Codable, Equatable {
    let nodeId: String?
    let text: String?
    let option: String?
    let key: String?
    let direction: String?
}

struct PlannerAction: Codable, Equatable {
    let tool: String
    let args: PlannerActionArguments
}

struct AppActionPlan: Codable, Equatable {
    let type: String
    let spoken: String
    let actions: [PlannerAction]
    let options: [String]?
}

private struct PlannerNodeContext: Codable {
    let ref: String
    let nodeId: String
    let role: String?
    let name: String
    let value: String?
    let enabled: Bool?
    let focused: Bool?
    let actions: [String]
}

enum AppActionPlannerError: LocalizedError {
    case invalidPlan(String)

    var errorDescription: String? {
        switch self {
        case .invalidPlan(let message): return message
        }
    }
}

final class AppActionPlanner {
    private let client: LocalModelClient

    init(client: LocalModelClient? = nil) {
        self.client = client ?? LocalModelClient(model: Self.defaultPlannerModel())
    }

    private static func defaultPlannerModel() -> String {
        ProcessInfo.processInfo.environment["PADKEY_PLANNER_MODEL"] ?? "qwen3:4b"
    }

    func plan(
        transcript: String,
        frontmostApp: FrontmostAppInfo,
        nodes: [AccessibilityNode],
        visualContext: String? = nil,
        completion: @escaping (Result<AppActionPlan, Error>) -> Void
    ) {
        let limitedNodes = Array(nodes.prefix(120))
        let snapshot = AppStateSnapshotBuilder.snapshot(app: frontmostApp, nodes: limitedNodes, maxElements: 60)
        let plannerNodes = snapshot.actionableElements.map {
            PlannerNodeContext(
                ref: $0.ref,
                nodeId: $0.nodeId,
                role: $0.role,
                name: $0.name,
                value: $0.value,
                enabled: $0.enabled,
                focused: $0.focused,
                actions: $0.actions
            )
        }
        guard let nodeData = try? JSONEncoder().encode(plannerNodes),
              let nodeJSON = String(data: nodeData, encoding: .utf8)
        else {
            completion(.failure(LocalModelError.invalidResponse))
            return
        }

        let system = """
        You are PadKey's universal local macOS computer-use planner.
        The user is speaking naturally, possibly with filler words, indirect wording, accents, or corrections. Infer intent from the current app state; do not require command grammar.
        Return strict JSON only. Never invent coordinates, refs, or node IDs. Use only nodes supplied by the user.
        Resolve live-app instructions such as "make a new note", "choose the second option", "open the sidebar", "type this there", "go to search", "new chat", "scroll until I can see it", or "fix this" using the supplied app-state summary first, then verify against the compact node list.
        The app-state summary uses compact refs like @e12, but executable actions must use the matching nodeId value.
        Allowed tools:
        - focus_element: args {"nodeId":"node_1"}
        - click_element: args {"nodeId":"node_1"}
        - set_element_value: args {"nodeId":"node_1","text":"..."}
        - select_option: args {"nodeId":"node_1","option":"..."}
        - keyboard_shortcut: args {"key":"n"} for Command-key shortcuts only
        - press_key: args {"key":"enter|tab|escape|space|up|down|left|right|pageup|pagedown|delete|forwarddelete"}
        - scroll: args {"direction":"up|down|left|right"}
        Never choose a tool that sends a message, starts a call, submits a form, purchases, deletes, uploads, posts publicly, runs shell commands, or exposes private data.
        Prefer one small reversible action, then let PadKey re-observe. If a task needs multiple steps, return up to four safe steps.
        If more than one element plausibly matches, return type clarification with no actions and short options.
        Return type answer with no actions only when the user is clearly chatting or asking about the current state rather than asking you to operate the app.
        Output schema: {"type":"ui_action|clarification|answer","spoken":"...","actions":[{"tool":"...","args":{"nodeId":"node_1","text":"optional","option":"optional","key":"optional","direction":"optional"}}],"options":["optional"]}
        """
        let user = """
        Transcript: \(transcript)
        Frontmost app: \(frontmostApp.name)
        App-state summary:
        \(snapshot.compactDescription)

        Visible screen OCR:
        \(visualContext?.isEmpty == false ? visualContext! : "not available")

        Compact node list: \(nodeJSON)
        """

        client.chat(system: system, user: user, requireJSON: true) { [weak self] result in
            guard self != nil else { return }
            switch result {
            case .failure(let error):
                completion(.failure(error))
            case .success(let content):
                do {
                    let plan = try Self.decodeAndValidate(content, validNodes: limitedNodes)
                    completion(.success(plan))
                } catch {
                    completion(.failure(error))
                }
            }
        }
    }

    func summarize(text: String, completion: @escaping (Result<String, Error>) -> Void) {
        let clipped = String(text.prefix(12_000))
        let system = "Summarize the supplied active-page text locally in five concise sentences or fewer. Do not invent facts."
        client.chat(system: system, user: clipped, requireJSON: false) { result in
            completion(result.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) })
        }
    }

    static func decodeAndValidate(_ content: String, validNodes: [AccessibilityNode]) throws -> AppActionPlan {
        let clean = content
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = clean.data(using: .utf8),
              let plan = try? JSONDecoder().decode(AppActionPlan.self, from: data)
        else {
            throw AppActionPlannerError.invalidPlan("The local model returned malformed action JSON.")
        }
        guard ["ui_action", "clarification", "answer"].contains(plan.type) else {
            throw AppActionPlannerError.invalidPlan("The local model returned an unsupported plan type.")
        }
        guard plan.actions.count <= 4 else {
            throw AppActionPlannerError.invalidPlan("The local model requested too many actions.")
        }
        let validIDs = Set(validNodes.map(\.id))
        let allowedTools: Set<String> = [
            "focus_element",
            "click_element",
            "set_element_value",
            "select_option",
            "keyboard_shortcut",
            "press_key",
            "scroll"
        ]
        if plan.type == "answer" {
            guard plan.actions.isEmpty else {
                throw AppActionPlannerError.invalidPlan("Answer plans cannot execute actions.")
            }
            guard !plan.spoken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw AppActionPlannerError.invalidPlan("Answer plans must include spoken text.")
            }
            return plan
        }
        for action in plan.actions {
            guard allowedTools.contains(action.tool) else {
                throw AppActionPlannerError.invalidPlan("The local model requested an unsafe tool.")
            }
            switch action.tool {
            case "focus_element", "click_element":
                try validateNodeId(action.args.nodeId, validIDs: validIDs)
            case "set_element_value":
                try validateNodeId(action.args.nodeId, validIDs: validIDs)
                guard action.args.text?.isEmpty == false else {
                    throw AppActionPlannerError.invalidPlan("The local model omitted text for a field action.")
                }
            case "select_option":
                try validateNodeId(action.args.nodeId, validIDs: validIDs)
                guard action.args.option?.isEmpty == false else {
                    throw AppActionPlannerError.invalidPlan("The local model omitted an option for a selection action.")
                }
            case "keyboard_shortcut":
                guard isAllowedCommandShortcut(action.args.key) else {
                    throw AppActionPlannerError.invalidPlan("The local model requested an unsupported keyboard shortcut.")
                }
            case "press_key":
                guard isAllowedKey(action.args.key) else {
                    throw AppActionPlannerError.invalidPlan("The local model requested an unsupported key press.")
                }
            case "scroll":
                guard isAllowedScrollDirection(action.args.direction) else {
                    throw AppActionPlannerError.invalidPlan("The local model requested an unsupported scroll direction.")
                }
            default:
                throw AppActionPlannerError.invalidPlan("The local model requested an unsafe tool.")
            }
        }
        if plan.type == "ui_action", plan.actions.isEmpty {
            throw AppActionPlannerError.invalidPlan("Action plans must include at least one executable action.")
        }
        if plan.type == "clarification", !plan.actions.isEmpty {
            throw AppActionPlannerError.invalidPlan("Clarification plans cannot execute actions.")
        }
        return plan
    }

    private static func validateNodeId(_ nodeId: String?, validIDs: Set<String>) throws {
        guard let nodeId, validIDs.contains(nodeId) else {
            throw AppActionPlannerError.invalidPlan("The local model referenced an unknown interface element.")
        }
    }

    private static func isAllowedCommandShortcut(_ key: String?) -> Bool {
        guard let key = normalizedKey(key) else { return false }
        let allowed: Set<String> = [
            "a", "c", "f", "l", "n", "r", "s", "t", "v", "w", "x", "z",
            "1", "2", "3", "4", "5", "6", "7", "8", "9", "0", ",", "."
        ]
        return allowed.contains(key)
    }

    private static func isAllowedKey(_ key: String?) -> Bool {
        guard let key = normalizedKey(key) else { return false }
        let allowed: Set<String> = [
            "enter", "return", "tab", "escape", "esc", "space",
            "up", "down", "left", "right", "pageup", "pagedown",
            "page up", "page down", "delete", "backspace", "forwarddelete",
            "forward delete"
        ]
        return allowed.contains(key)
    }

    private static func isAllowedScrollDirection(_ direction: String?) -> Bool {
        guard let direction = normalizedKey(direction) else { return false }
        return ["up", "down", "left", "right"].contains(direction)
    }

    private static func normalizedKey(_ key: String?) -> String? {
        guard let key else { return nil }
        let normalized = key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.isEmpty ? nil : normalized
    }
}
