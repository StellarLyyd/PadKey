import Foundation

struct FrontmostAppInfo: Codable, Equatable {
    let name: String
    let bundleIdentifier: String?
    let processIdentifier: Int32
}

struct AccessibilityBounds: Codable, Equatable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double
}

struct AccessibilityNode: Codable, Equatable, Identifiable {
    let id: String
    let role: String?
    let title: String?
    let label: String?
    let value: String?
    let placeholder: String?
    let description: String?
    let help: String?
    let enabled: Bool?
    let focused: Bool?
    let bounds: AccessibilityBounds?
    let actions: [String]

    var searchableText: String {
        [role, title, label, placeholder, description, help]
            .compactMap { $0 }
            .joined(separator: " ")
            .lowercased()
    }

    var displayName: String {
        [label, title, placeholder, description, role]
            .compactMap { $0 }
            .compactMap { value in
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }
            .first ?? "Accessible control"
    }
}

struct MacCommandRequest: Codable, Equatable {
    let transcript: String
    let source: String?
    let batteryPercent: Int?
    let mode: String?
}

struct MacCommandActionRecord: Codable, Equatable {
    let type: String
    let appName: String?
    let nodeId: String?
    let target: String?
    let text: String?
}

struct MacCommandResponse: Codable, Equatable {
    let ok: Bool
    let intent: String
    let spoken: String
    let actions: [MacCommandActionRecord]
    let frontmostApp: String?
    let selectedTarget: String?
    let actionResult: String?
    let clarification: String?
    let options: [String]?
    let confirmationRequired: Bool
    let confirmationId: String?
    let permissionRequired: String?
    let message: String?

    static func failure(
        intent: String = "unknown",
        spoken: String,
        frontmostApp: String? = nil,
        permissionRequired: String? = nil,
        message: String? = nil
    ) -> MacCommandResponse {
        MacCommandResponse(
            ok: false,
            intent: intent,
            spoken: spoken,
            actions: [],
            frontmostApp: frontmostApp,
            selectedTarget: nil,
            actionResult: nil,
            clarification: nil,
            options: nil,
            confirmationRequired: false,
            confirmationId: nil,
            permissionRequired: permissionRequired,
            message: message
        )
    }
}

struct PermissionRequirement: Codable, Equatable {
    let granted: Bool?
    let required: Bool
    let reason: String
}

struct MacPermissionsResponse: Codable, Equatable {
    let accessibility: PermissionRequirement
    let automation: PermissionRequirement
    let inputMonitoring: PermissionRequirement
    let screenRecording: PermissionRequirement
}

struct CommandConfirmationRequest: Codable, Equatable {
    let confirmationId: String
}

struct AgentControlSnapshot: Equatable {
    var status: String
    var frontmostApp: String
    var lastCommand: String
    var detectedIntent: String
    var accessibilityStatus: String
    var selectedTarget: String
    var actionResult: String
    var spokenResponse: String
    var clarification: String
    var confirmationId: String?

    static let idle = AgentControlSnapshot(
        status: "Ready",
        frontmostApp: "No external app selected",
        lastCommand: "No command yet",
        detectedIntent: "—",
        accessibilityStatus: "Checking",
        selectedTarget: "—",
        actionResult: "Waiting for a command",
        spokenResponse: "—",
        clarification: "",
        confirmationId: nil
    )
}

extension Notification.Name {
    static let padKeyAgentControlDidUpdate = Notification.Name("PadKeyAgentControlDidUpdate")
}

struct APIErrorEnvelope: Codable {
    struct APIErrorBody: Codable {
        let code: String
        let message: String
        let traceId: String
    }

    let error: APIErrorBody
}
