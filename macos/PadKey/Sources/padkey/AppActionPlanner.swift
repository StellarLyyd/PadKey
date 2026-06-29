import Foundation

struct PlannerActionArguments: Codable, Equatable {
    let nodeId: String?
    let text: String?
    let option: String?
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

    init(client: LocalModelClient = LocalModelClient()) {
        self.client = client
    }

    func plan(
        transcript: String,
        frontmostApp: FrontmostAppInfo,
        nodes: [AccessibilityNode],
        completion: @escaping (Result<AppActionPlan, Error>) -> Void
    ) {
        let limitedNodes = Array(nodes.prefix(180))
        guard let treeData = try? JSONEncoder().encode(limitedNodes),
              let treeJSON = String(data: treeData, encoding: .utf8)
        else {
            completion(.failure(LocalModelError.invalidResponse))
            return
        }

        let system = """
        You are PadKey's local macOS accessibility action planner.
        You are running inside the Computer Atlas runtime for the user's current app.
        Return strict JSON only. Never invent coordinates or node IDs. Use only nodes supplied by the user.
        Resolve live-app instructions such as "choose the second option" or "click the visible continue button" using the supplied accessibility nodes.
        Allowed tools: focus_element, click_element, set_element_value, select_option.
        Never choose a tool that sends a message, starts a call, submits a form, purchases, deletes, uploads, posts publicly, runs shell commands, or exposes private data.
        If more than one element plausibly matches, return type clarification with no actions and short options.
        Output schema: {"type":"ui_action|clarification","spoken":"...","actions":[{"tool":"...","args":{"nodeId":"node_1","text":"optional","option":"optional"}}],"options":["optional"]}
        """
        let user = """
        Transcript: \(transcript)
        Frontmost app: \(frontmostApp.name)
        Accessibility tree: \(treeJSON)
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
        guard ["ui_action", "clarification"].contains(plan.type) else {
            throw AppActionPlannerError.invalidPlan("The local model returned an unsupported plan type.")
        }
        guard plan.actions.count <= 4 else {
            throw AppActionPlannerError.invalidPlan("The local model requested too many actions.")
        }
        let validIDs = Set(validNodes.map(\.id))
        let allowedTools: Set<String> = ["focus_element", "click_element", "set_element_value", "select_option"]
        for action in plan.actions {
            guard allowedTools.contains(action.tool) else {
                throw AppActionPlannerError.invalidPlan("The local model requested an unsafe tool.")
            }
            guard let nodeId = action.args.nodeId, validIDs.contains(nodeId) else {
                throw AppActionPlannerError.invalidPlan("The local model referenced an unknown interface element.")
            }
            if action.tool == "set_element_value", action.args.text?.isEmpty != false {
                throw AppActionPlannerError.invalidPlan("The local model omitted text for a field action.")
            }
        }
        if plan.type == "clarification", !plan.actions.isEmpty {
            throw AppActionPlannerError.invalidPlan("Clarification plans cannot execute actions.")
        }
        return plan
    }
}
