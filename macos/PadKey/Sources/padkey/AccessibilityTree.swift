import AppKit
import ApplicationServices
import Foundation

enum AccessibilityTreeError: LocalizedError {
    case permissionRequired
    case noFrontmostApplication
    case elementUnavailable
    case actionUnsupported(String)

    var errorDescription: String? {
        switch self {
        case .permissionRequired:
            return "Enable Accessibility for PadKey in System Settings > Privacy & Security > Accessibility."
        case .noFrontmostApplication:
            return "No controllable Mac application is currently active."
        case .elementUnavailable:
            return "The selected control is no longer available. Inspect the app again and retry."
        case .actionUnsupported(let action):
            return "The selected control does not support \(action)."
        }
    }
}

enum AccessibilityMatcher {
    static func matches(
        nodes: [AccessibilityNode],
        query: String,
        preferredRoles: Set<String> = []
    ) -> [AccessibilityNode] {
        let normalizedQuery = normalize(query)
        let tokens = normalizedQuery.split(separator: " ").map(String.init).filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return [] }

        return nodes.compactMap { node -> (AccessibilityNode, Int)? in
            if !preferredRoles.isEmpty, let role = node.role, !preferredRoles.contains(role) {
                return nil
            }
            guard node.enabled != false else { return nil }
            let haystack = normalize(node.searchableText)
            var score = 0
            if haystack == normalizedQuery { score += 100 }
            if haystack.contains(normalizedQuery) { score += 50 }
            for token in tokens where haystack.contains(token) { score += 10 }
            if node.focused == true { score += 2 }
            if preferredRoles.contains(node.role ?? "") { score += 4 }
            return score > 0 ? (node, score) : nil
        }
        .sorted { lhs, rhs in
            if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
            return lhs.0.displayName.localizedCaseInsensitiveCompare(rhs.0.displayName) == .orderedAscending
        }
        .map(\.0)
    }

    private static func normalize(_ text: String) -> String {
        text.lowercased()
            .replacingOccurrences(of: "button", with: "")
            .replacingOccurrences(of: "field", with: "")
            .replacingOccurrences(of: "input", with: "")
            .replacingOccurrences(of: "ax", with: "")
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

final class AccessibilityTreeService {
    static let shared = AccessibilityTreeService()

    private let allowedRoles: Set<String> = [
        kAXTextFieldRole as String,
        kAXTextAreaRole as String,
        kAXSearchFieldSubrole as String,
        kAXButtonRole as String,
        kAXCheckBoxRole as String,
        kAXRadioButtonRole as String,
        kAXPopUpButtonRole as String,
        kAXComboBoxRole as String,
        kAXMenuItemRole as String,
        "AXLink",
        kAXStaticTextRole as String
    ]
    private var elementCache: [String: AXUIElement] = [:]
    private var cachedApplication: NSRunningApplication?

    func frontmostApp(preferred: NSRunningApplication? = nil) throws -> FrontmostAppInfo {
        guard let application = preferred ?? NSWorkspace.shared.frontmostApplication else {
            throw AccessibilityTreeError.noFrontmostApplication
        }
        return FrontmostAppInfo(
            name: application.localizedName ?? "Unknown app",
            bundleIdentifier: application.bundleIdentifier,
            processIdentifier: application.processIdentifier
        )
    }

    func getAccessibilityTree(
        for preferredApplication: NSRunningApplication? = nil,
        maximumNodes: Int = 320
    ) throws -> [AccessibilityNode] {
        guard PermissionHelper.isAccessibilityTrusted else {
            throw AccessibilityTreeError.permissionRequired
        }
        guard let application = preferredApplication ?? NSWorkspace.shared.frontmostApplication else {
            throw AccessibilityTreeError.noFrontmostApplication
        }

        cachedApplication = application
        elementCache.removeAll(keepingCapacity: true)
        let root = AXUIElementCreateApplication(application.processIdentifier)
        var nodes: [AccessibilityNode] = []
        var visited = Set<CFHashCode>()
        collect(
            element: root,
            depth: 0,
            maximumDepth: 10,
            maximumNodes: max(1, min(maximumNodes, 600)),
            visited: &visited,
            nodes: &nodes
        )
        return nodes
    }

    func findElementByDescription(
        _ query: String,
        preferredRoles: Set<String> = [],
        application: NSRunningApplication? = nil
    ) throws -> AccessibilityNode? {
        let nodes = try getAccessibilityTree(for: application)
        return AccessibilityMatcher.matches(nodes: nodes, query: query, preferredRoles: preferredRoles).first
    }

    func focusElement(nodeId: String) throws {
        guard let element = elementCache[nodeId] else { throw AccessibilityTreeError.elementUnavailable }
        let result = AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        guard result == .success else { throw AccessibilityTreeError.actionUnsupported("focus") }
    }

    func clickElement(nodeId: String) throws {
        guard let element = elementCache[nodeId] else { throw AccessibilityTreeError.elementUnavailable }
        let actions = actionNames(for: element)
        let action = actions.contains(kAXPressAction as String)
            ? kAXPressAction
            : actions.contains(kAXConfirmAction as String)
                ? kAXConfirmAction
                : nil
        guard let action else { throw AccessibilityTreeError.actionUnsupported("click") }
        guard AXUIElementPerformAction(element, action as CFString) == .success else {
            throw AccessibilityTreeError.actionUnsupported("click")
        }
    }

    func setElementValue(nodeId: String, value: String) throws {
        guard let element = elementCache[nodeId] else { throw AccessibilityTreeError.elementUnavailable }
        var settable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable) == .success,
              settable.boolValue
        else {
            throw AccessibilityTreeError.actionUnsupported("text entry")
        }
        _ = AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        guard AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, value as CFTypeRef) == .success else {
            throw AccessibilityTreeError.actionUnsupported("text entry")
        }
    }

    func selectOption(_ option: String, from nodeId: String) throws -> AccessibilityNode {
        try clickElement(nodeId: nodeId)
        guard let app = cachedApplication else { throw AccessibilityTreeError.noFrontmostApplication }
        let nodes = try getAccessibilityTree(for: app)
        let matches = AccessibilityMatcher.matches(
            nodes: nodes,
            query: option,
            preferredRoles: [kAXMenuItemRole as String, kAXRadioButtonRole as String]
        )
        guard let selected = matches.first else { throw AccessibilityTreeError.elementUnavailable }
        try clickElement(nodeId: selected.id)
        return selected
    }

    func readableText(from nodes: [AccessibilityNode], limit: Int = 10_000) -> String {
        var seen = Set<String>()
        var pieces: [String] = []
        var count = 0
        for node in nodes {
            for candidate in [node.title, node.label, node.value, node.description, node.help] {
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

    private func collect(
        element: AXUIElement,
        depth: Int,
        maximumDepth: Int,
        maximumNodes: Int,
        visited: inout Set<CFHashCode>,
        nodes: inout [AccessibilityNode]
    ) {
        guard depth <= maximumDepth, nodes.count < maximumNodes else { return }
        let hash = CFHash(element)
        guard visited.insert(hash).inserted else { return }

        let role = stringAttribute(kAXRoleAttribute, from: element)
        let subrole = stringAttribute(kAXSubroleAttribute, from: element)
        let effectiveRole = subrole == (kAXSearchFieldSubrole as String) ? subrole : role
        if let effectiveRole, allowedRoles.contains(effectiveRole) {
            let id = "node_\(cachedApplication?.processIdentifier ?? 0)_\(elementCache.count + 1)"
            elementCache[id] = element
            nodes.append(AccessibilityNode(
                id: id,
                role: effectiveRole,
                title: clipped(stringAttribute(kAXTitleAttribute, from: element)),
                label: clipped(stringAttribute(kAXTitleUIElementAttribute, from: element) ?? stringAttribute(kAXDescriptionAttribute, from: element)),
                value: effectiveRole == (kAXSecureTextFieldSubrole as String) ? nil : clipped(stringAttribute(kAXValueAttribute, from: element)),
                placeholder: clipped(stringAttribute(kAXPlaceholderValueAttribute, from: element)),
                description: clipped(stringAttribute(kAXDescriptionAttribute, from: element)),
                help: clipped(stringAttribute(kAXHelpAttribute, from: element)),
                enabled: boolAttribute(kAXEnabledAttribute, from: element),
                focused: boolAttribute(kAXFocusedAttribute, from: element),
                bounds: bounds(for: element),
                actions: actionNames(for: element)
            ))
        }

        for child in children(of: element) {
            collect(
                element: child,
                depth: depth + 1,
                maximumDepth: maximumDepth,
                maximumNodes: maximumNodes,
                visited: &visited,
                nodes: &nodes
            )
            if nodes.count >= maximumNodes { break }
        }
    }

    private func children(of element: AXUIElement) -> [AXUIElement] {
        var object: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &object) == .success,
              let array = object as? [AXUIElement]
        else {
            return []
        }
        return array
    }

    private func stringAttribute(_ attribute: String, from element: AXUIElement) -> String? {
        var object: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &object) == .success,
              let object
        else {
            return nil
        }
        if let string = object as? String { return string }
        if let number = object as? NSNumber { return number.stringValue }
        return nil
    }

    private func boolAttribute(_ attribute: String, from element: AXUIElement) -> Bool? {
        var object: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &object) == .success else { return nil }
        return (object as? NSNumber)?.boolValue
    }

    private func actionNames(for element: AXUIElement) -> [String] {
        var names: CFArray?
        guard AXUIElementCopyActionNames(element, &names) == .success else { return [] }
        return names as? [String] ?? []
    }

    private func bounds(for element: AXUIElement) -> AccessibilityBounds? {
        var positionObject: CFTypeRef?
        var sizeObject: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionObject) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeObject) == .success,
              let positionObject,
              let sizeObject,
              CFGetTypeID(positionObject) == AXValueGetTypeID(),
              CFGetTypeID(sizeObject) == AXValueGetTypeID()
        else {
            return nil
        }
        var point = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionObject as! AXValue, .cgPoint, &point),
              AXValueGetValue(sizeObject as! AXValue, .cgSize, &size)
        else {
            return nil
        }
        return AccessibilityBounds(
            x: Double(point.x),
            y: Double(point.y),
            width: Double(size.width),
            height: Double(size.height)
        )
    }

    private func clipped(_ value: String?, limit: Int = 240) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(limit))
    }
}
