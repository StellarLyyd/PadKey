import XCTest
@testable import padkey

final class MacCommandTests: XCTestCase {
    func testDeterministicCommandParsing() {
        XCTAssertEqual(
            MacCommandParser.parse("Hey PadKey, make a note about the BLE test"),
            .makeNote("about the BLE test")
        )
        XCTAssertEqual(MacCommandParser.parse("Hey PadKey, open FaceTime"), .openFaceTime)
        XCTAssertEqual(
            MacCommandParser.parse("Hey PadKey, call Chukwudi on FaceTime"),
            .faceTimeContact("Chukwudi")
        )
        XCTAssertEqual(
            MacCommandParser.parse("Hey PadKey, fill the name field with Chukwudi"),
            .genericUI(.fill(target: "name field", value: "Chukwudi"))
        )
        XCTAssertEqual(
            MacCommandParser.parse("Hey PadKey, type hello into the message field"),
            .genericUI(.fill(target: "message field", value: "hello"))
        )
        XCTAssertEqual(
            MacCommandParser.parse("Hey PadKey, click the continue button"),
            .genericUI(.click(target: "continue button"))
        )
    }

    func testOrdinaryDictationIsNotIntercepted() {
        XCTAssertFalse(MacCommandParser.looksLikeVoiceCommand("This is an ordinary paragraph for my document."))
        XCTAssertTrue(MacCommandParser.looksLikeVoiceCommand("Hey PadKey, open Notes"))
        XCTAssertTrue(MacCommandParser.looksLikeVoiceCommand("Open Safari"))
        XCTAssertTrue(MacCommandParser.looksLikeVoiceCommand("Open app Safari"))
        XCTAssertTrue(MacCommandParser.looksLikeVoiceCommand("Scroll down"))
        XCTAssertTrue(MacCommandParser.looksLikeVoiceCommand("Paste that"))
        XCTAssertTrue(MacCommandParser.looksLikeVoiceCommand("Confirm"))
    }

    func testHoldToTalkDirectCommandParsing() {
        XCTAssertEqual(MacCommandParser.parse("Open app Safari"), .openApplication("Safari"))
        XCTAssertEqual(MacCommandParser.parse("Open the app FaceTime"), .openFaceTime)
        XCTAssertEqual(MacCommandParser.parse("Copy that"), .copy)
        XCTAssertEqual(MacCommandParser.parse("Paste that"), .paste)
        XCTAssertEqual(MacCommandParser.parse("Scroll down"), .scroll(direction: "down"))
        XCTAssertEqual(MacCommandParser.parse("Go back"), .goBack)
        XCTAssertEqual(MacCommandParser.parse("Close window"), .closeWindow)
    }

    func testSafetyPolicyRequiresConfirmationForConsequentialActions() {
        XCTAssertTrue(MacActionSafetyPolicy.requiresConfirmation(command: "press send", target: "Send button"))
        XCTAssertTrue(MacActionSafetyPolicy.requiresConfirmation(command: "submit the form", target: "Continue"))
        XCTAssertTrue(MacActionSafetyPolicy.requiresConfirmation(command: "call Chukwudi", target: "FaceTime"))
        XCTAssertFalse(MacActionSafetyPolicy.requiresConfirmation(command: "click continue", target: "Continue button"))
        XCTAssertFalse(MacActionSafetyPolicy.requiresConfirmation(command: "fill the search field", target: "Search"))
    }

    func testAccessibilityMatcherPrioritizesExactAccessibleLabel() {
        let nodes = [
            node(id: "node_1", role: "AXTextField", label: "Message field"),
            node(id: "node_2", role: "AXSearchField", label: "Search field"),
            node(id: "node_3", role: "AXButton", label: "Search")
        ]
        let matches = AccessibilityMatcher.matches(
            nodes: nodes,
            query: "search field",
            preferredRoles: ["AXTextField", "AXSearchField"]
        )
        XCTAssertEqual(matches.first?.id, "node_2")
    }

    func testPlannerRejectsInventedNodeAndUnsafeTool() throws {
        let validNode = node(id: "node_12", role: "AXTextField", label: "Search")
        let invented = """
        {"type":"ui_action","spoken":"Typing.","actions":[{"tool":"set_element_value","args":{"nodeId":"node_99","text":"hello"}}]}
        """
        XCTAssertThrowsError(try AppActionPlanner.decodeAndValidate(invented, validNodes: [validNode]))

        let unsafe = """
        {"type":"ui_action","spoken":"Running.","actions":[{"tool":"run_shell","args":{"nodeId":"node_12","text":"rm"}}]}
        """
        XCTAssertThrowsError(try AppActionPlanner.decodeAndValidate(unsafe, validNodes: [validNode]))
    }

    func testPlannerAcceptsKnownNodeAndAllowedTool() throws {
        let validNode = node(id: "node_12", role: "AXTextField", label: "Search")
        let json = """
        {"type":"ui_action","spoken":"Filling the search field.","actions":[{"tool":"set_element_value","args":{"nodeId":"node_12","text":"silent speech devices"}}]}
        """
        let plan = try AppActionPlanner.decodeAndValidate(json, validNodes: [validNode])
        XCTAssertEqual(plan.actions.first?.args.nodeId, "node_12")
    }

    private func node(id: String, role: String, label: String) -> AccessibilityNode {
        AccessibilityNode(
            id: id,
            role: role,
            title: nil,
            label: label,
            value: nil,
            placeholder: nil,
            description: nil,
            help: nil,
            enabled: true,
            focused: false,
            bounds: nil,
            actions: []
        )
    }
}
