import XCTest
@testable import Starfiler

final class DefaultShortcutCoverageTests: XCTestCase {
    func testDefaultBindingsKeepSpaceMarkingWorkflow() throws {
        let bindings = try loadDefaultBindings()
        let normalBindings = try XCTUnwrap(bindings["normal"])

        XCTAssertEqual(normalBindings["Space"], "toggleMark")
        XCTAssertEqual(normalBindings["Shift-Space"], "toggleMark")
        XCTAssertEqual(normalBindings["Ctrl-p"], "togglePreview")
        XCTAssertEqual(normalBindings["Cmd-z"], "undo")
        XCTAssertEqual(normalBindings["Option-r"], "rename")
    }

    func testDefaultBindingsCoverAllKeyActions() throws {
        let bindings = try loadDefaultBindings()
        let configuredActions = Set(bindings.values.flatMap { $0.values }.compactMap(KeyAction.fromConfigName))
        let allowedUnboundActions: Set<KeyAction> = [
            .copyToClipboard,
            .cutToClipboard,
            .pasteFromClipboard,
            .syncPanesLeftToRight,
            .syncPanesRightToLeft,
            .openHistory,
            .enterSpotlightSearch
        ]

        let allActions = Set(KeyAction.allCases)
        let unboundActions = allActions.subtracting(configuredActions)
        XCTAssertEqual(unboundActions, allowedUnboundActions)
        XCTAssertEqual(configuredActions.union(allowedUnboundActions), allActions)
    }

    func testAllDefaultSequencesResolveToExpectedActions() throws {
        let bindings = try loadDefaultBindings()
        let manager = try makeManager(bindings: bindings)

        for (modeName, modeBindings) in bindings {
            guard let mode = VimMode(rawValue: modeName.lowercased()) else {
                XCTFail("Unknown mode in defaults: \(modeName)")
                continue
            }

            for (sequence, actionName) in modeBindings {
                let expectedAction = try XCTUnwrap(KeyAction.fromConfigName(actionName), "Unknown action: \(actionName)")
                let events = try parseSequence(sequence)
                var interpreter = KeyInterpreter(keybindingManager: manager, mode: mode, timeout: 1.0)

                var now = Date()
                var finalResult: KeyInterpreterResult = .unhandled
                for event in events {
                    now = now.addingTimeInterval(0.01)
                    finalResult = interpreter.interpret(event, now: now)
                }

                XCTAssertEqual(
                    finalResult,
                    .action(expectedAction),
                    "Failed sequence '\(sequence)' in mode '\(modeName)'"
                )
            }
        }
    }

    private func loadDefaultBindings() throws -> [String: [String: String]] {
        let defaultsURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Keyboard
            .deletingLastPathComponent() // starfilerTests
            .appendingPathComponent("../starfiler/Resources/DefaultKeybindings.json")
            .standardizedFileURL

        let data = try Data(contentsOf: defaultsURL)
        let config = try JSONDecoder().decode(KeybindingsConfig.self, from: data)
        return config.bindings
    }

    private func makeManager(bindings: [String: [String: String]]) throws -> KeybindingManager {
        let config = KeybindingsConfig(bindings: bindings)
        let data = try JSONEncoder().encode(config)
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("json")
        try data.write(to: tempURL)

        return KeybindingManager(bundle: Bundle(for: type(of: self)), userConfigURL: tempURL)
    }

    private func parseSequence(_ rawSequence: String) throws -> [KeyEvent] {
        let tokens = rawSequence.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        return try tokens.map(parseToken)
    }

    private func parseToken(_ rawToken: String) throws -> KeyEvent {
        let segments = rawToken.split(separator: "-").map(String.init)
        guard let keySegment = segments.last else {
            throw parserError("Invalid token: \(rawToken)")
        }

        var modifiers: KeyModifiers = []
        for modifierToken in segments.dropLast() {
            guard let modifier = parseModifier(modifierToken) else {
                throw parserError("Invalid modifier '\(modifierToken)' in '\(rawToken)'")
            }
            modifiers.insert(modifier)
        }

        guard let key = parseKey(keySegment, modifiers: &modifiers) else {
            throw parserError("Invalid key '\(keySegment)' in '\(rawToken)'")
        }

        return KeyEvent(key: key, modifiers: modifiers)
    }

    private func parseModifier(_ token: String) -> KeyModifiers? {
        switch token.lowercased() {
        case "shift":
            return .shift
        case "ctrl", "control":
            return .control
        case "alt", "opt", "option":
            return .option
        case "cmd", "command":
            return .command
        default:
            return nil
        }
    }

    private func parseKey(_ rawKey: String, modifiers: inout KeyModifiers) -> String? {
        let normalized = rawKey.lowercased()
        let namedKeys: [String: String] = [
            "space": "Space",
            "return": "Return",
            "enter": "Return",
            "escape": "Escape",
            "esc": "Escape",
            "tab": "Tab",
            "backspace": "Backspace",
            "delete": "Delete",
            "pageup": "PageUp",
            "pagedown": "PageDown",
            "home": "Home",
            "end": "End",
            "left": "ArrowLeft",
            "arrowleft": "ArrowLeft",
            "right": "ArrowRight",
            "arrowright": "ArrowRight",
            "up": "ArrowUp",
            "arrowup": "ArrowUp",
            "down": "ArrowDown",
            "arrowdown": "ArrowDown"
        ]

        if let namedKey = namedKeys[normalized] {
            return namedKey
        }

        guard rawKey.count == 1 else {
            return nil
        }

        if rawKey != rawKey.lowercased(), rawKey.lowercased() != rawKey.uppercased() {
            modifiers.insert(.shift)
        }

        let scalar = String(rawKey)
        if scalar.lowercased() != scalar.uppercased() {
            return scalar.lowercased()
        }

        return scalar
    }

    private func parserError(_ message: String) -> NSError {
        NSError(domain: "DefaultShortcutCoverageTests", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
