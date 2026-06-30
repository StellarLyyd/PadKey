import AppKit
import CoreGraphics
import Foundation
import Vision

struct RuntimeCapability: Codable, Equatable {
    let name: String
    let available: Bool
    let detail: String
    let version: String?
}

struct OllamaModelSummary: Codable, Equatable {
    let name: String
    let size: String
    let modified: String
}

struct OllamaRuntimeStatus: Codable, Equatable {
    let available: Bool
    let detail: String
    let models: [OllamaModelSummary]

    var hasMLXModel: Bool {
        models.contains { $0.name.localizedCaseInsensitiveContains("mlx") }
    }
}

struct VisualPerceptionReadiness: Codable, Equatable {
    let screenRecordingGranted: Bool
    let visionOCRAvailable: Bool
    let detail: String
}

struct AgentBridgeStatus: Codable, Equatable {
    let port: UInt16
    let listening: Bool
    let detail: String
}

struct AgentRuntimeStatus: Codable, Equatable {
    let generatedAt: Date
    let machine: String
    let chip: String
    let architecture: String
    let memoryGB: Int?
    let osVersion: String
    let mlx: RuntimeCapability
    let coreMLTools: RuntimeCapability
    let ollama: OllamaRuntimeStatus
    let visualPerception: VisualPerceptionReadiness
    let bridge: AgentBridgeStatus
    let recommendedBrain: String
    let gaps: [String]
}

struct VisualTextElement: Codable, Equatable {
    let text: String
    let confidence: Float
    let x: Double
    let y: Double
    let width: Double
    let height: Double
}

struct VisualScreenSnapshot: Codable, Equatable {
    let capturedAt: Date
    let screenRecordingGranted: Bool
    let imageWidth: Int?
    let imageHeight: Int?
    let textElements: [VisualTextElement]
    let compactDescription: String
    let message: String?
}

enum AgentRuntimeInspector {
    private static var cachedStatus: (createdAt: Date, value: AgentRuntimeStatus)?

    static func status(
        bridgePort: UInt16 = LocalCommandServer.defaultPort,
        bridgeListening: Bool
    ) -> AgentRuntimeStatus {
        if let cachedStatus, Date().timeIntervalSince(cachedStatus.createdAt) < 10 {
            var value = cachedStatus.value
            value = AgentRuntimeStatus(
                generatedAt: value.generatedAt,
                machine: value.machine,
                chip: value.chip,
                architecture: value.architecture,
                memoryGB: value.memoryGB,
                osVersion: value.osVersion,
                mlx: value.mlx,
                coreMLTools: value.coreMLTools,
                ollama: value.ollama,
                visualPerception: visualReadiness(),
                bridge: bridgeStatus(port: bridgePort, listening: bridgeListening),
                recommendedBrain: value.recommendedBrain,
                gaps: gaps(mlx: value.mlx, ollama: value.ollama, visual: visualReadiness(), bridgeListening: bridgeListening)
            )
            return value
        }

        let mlx = pythonModuleCapability(module: "mlx.core", name: "MLX")
        let coreMLTools = pythonModuleCapability(module: "coremltools", name: "Core ML tools")
        let ollama = ollamaStatus()
        let visual = visualReadiness()
        let bridge = bridgeStatus(port: bridgePort, listening: bridgeListening)
        let status = AgentRuntimeStatus(
            generatedAt: Date(),
            machine: shell("/usr/sbin/sysctl", ["-n", "hw.model"]).output.trimmedNonEmpty ?? "Unknown Mac",
            chip: shell("/usr/sbin/sysctl", ["-n", "machdep.cpu.brand_string"]).output.trimmedNonEmpty ?? "Apple Silicon",
            architecture: shell("/usr/bin/uname", ["-m"]).output.trimmedNonEmpty ?? "arm64",
            memoryGB: memoryGB(),
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            mlx: mlx,
            coreMLTools: coreMLTools,
            ollama: ollama,
            visualPerception: visual,
            bridge: bridge,
            recommendedBrain: recommendedBrain(mlx: mlx, ollama: ollama),
            gaps: gaps(mlx: mlx, ollama: ollama, visual: visual, bridgeListening: bridgeListening)
        )
        cachedStatus = (Date(), status)
        return status
    }

    static func parseOllamaList(_ output: String) -> [OllamaModelSummary] {
        output
            .split(separator: "\n")
            .dropFirst()
            .compactMap { line in
                let parts = line.split(whereSeparator: \.isWhitespace)
                guard parts.count >= 4 else { return nil }
                let size = "\(parts[2]) \(parts[3])"
                let modified = parts.dropFirst(4).joined(separator: " ")
                return OllamaModelSummary(name: String(parts[0]), size: size, modified: modified)
            }
    }

    private static func pythonModuleCapability(module: String, name: String) -> RuntimeCapability {
        let script = """
        import importlib.util
        import importlib.metadata
        module = "\(module)"
        root = module.split(".")[0]
        if importlib.util.find_spec(module) is None:
            raise SystemExit(2)
        try:
            print(importlib.metadata.version(root))
        except Exception:
            print("installed")
        """
        let candidates = [
            "/opt/homebrew/bin/python3",
            "/usr/local/bin/python3",
            "/usr/bin/python3"
        ]
        for python in candidates where FileManager.default.isExecutableFile(atPath: python) {
            let result = shell(python, ["-c", script], timeout: 1.5)
            if result.exitCode == 0 {
                return RuntimeCapability(name: name, available: true, detail: "\(name) is importable from \(python).", version: result.output.trimmedNonEmpty)
            }
        }
        return RuntimeCapability(name: name, available: false, detail: "\(name) is not installed in the checked local Python runtimes.", version: nil)
    }

    private static func ollamaStatus() -> OllamaRuntimeStatus {
        guard let path = executablePath(named: "ollama", candidates: ["/opt/homebrew/bin/ollama", "/usr/local/bin/ollama"]) else {
            return OllamaRuntimeStatus(available: false, detail: "Ollama is not installed on PATH.", models: [])
        }
        let list = shell(path, ["list"], timeout: 2.0)
        let models = parseOllamaList(list.output)
        if list.exitCode == 0 {
            return OllamaRuntimeStatus(
                available: true,
                detail: models.isEmpty ? "Ollama is installed, but no local models were listed." : "Ollama is installed with \(models.count) local model\(models.count == 1 ? "" : "s").",
                models: models
            )
        }
        return OllamaRuntimeStatus(available: false, detail: list.output.trimmedNonEmpty ?? "Ollama did not respond.", models: [])
    }

    private static func executablePath(named name: String, candidates: [String]) -> String? {
        for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }
        let found = shell("/usr/bin/which", [name], timeout: 0.8).output.trimmedNonEmpty
        guard let found, FileManager.default.isExecutableFile(atPath: found) else { return nil }
        return found
    }

    private static func visualReadiness() -> VisualPerceptionReadiness {
        let granted = CGPreflightScreenCaptureAccess()
        return VisualPerceptionReadiness(
            screenRecordingGranted: granted,
            visionOCRAvailable: true,
            detail: granted ? "Screen capture and Vision OCR can run locally." : "Enable Screen Recording for PadKey to let the agent read visible text."
        )
    }

    private static func bridgeStatus(port: UInt16, listening: Bool) -> AgentBridgeStatus {
        AgentBridgeStatus(
            port: port,
            listening: listening,
            detail: listening ? "Loopback agent bridge is serving on 127.0.0.1:\(port)." : "Loopback agent bridge is not listening."
        )
    }

    private static func recommendedBrain(mlx: RuntimeCapability, ollama: OllamaRuntimeStatus) -> String {
        if mlx.available {
            return "Direct MLX runtime is available for a PadKey-owned local model path."
        }
        if ollama.hasMLXModel {
            return "Use the installed Ollama MLX model now; install Python MLX for direct PadKey-owned execution."
        }
        if ollama.available {
            return "Use Ollama now; install an MLX model or Python MLX for the M5-optimized path."
        }
        return "Install MLX or Ollama models before PadKey can run a local agent brain."
    }

    private static func gaps(
        mlx: RuntimeCapability,
        ollama: OllamaRuntimeStatus,
        visual: VisualPerceptionReadiness,
        bridgeListening: Bool
    ) -> [String] {
        var gaps: [String] = []
        if !mlx.available {
            gaps.append("Direct MLX Python runtime is missing.")
        }
        if !ollama.available {
            gaps.append("Ollama local model service is unavailable.")
        }
        if !visual.screenRecordingGranted {
            gaps.append("Screen Recording is not granted, so visual computer-use perception is blocked.")
        }
        if !bridgeListening {
            gaps.append("Local command bridge is not listening.")
        }
        return gaps
    }

    private static func memoryGB() -> Int? {
        guard let bytesString = shell("/usr/sbin/sysctl", ["-n", "hw.memsize"]).output.trimmedNonEmpty,
              let bytes = Double(bytesString) else {
            return nil
        }
        return Int((bytes / 1_073_741_824).rounded())
    }

    private static func shell(_ executable: String, _ arguments: [String], timeout: TimeInterval = 1.0) -> (exitCode: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        let group = DispatchGroup()
        group.enter()
        process.terminationHandler = { _ in group.leave() }
        do {
            try process.run()
        } catch {
            return (127, error.localizedDescription)
        }
        if group.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        return (process.terminationStatus, output.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

enum VisualPerceptionService {
    static func requestScreenRecordingPermission() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    static func captureTextSnapshot(maxElements: Int = 40) -> VisualScreenSnapshot {
        guard CGPreflightScreenCaptureAccess() else {
            return VisualScreenSnapshot(
                capturedAt: Date(),
                screenRecordingGranted: false,
                imageWidth: nil,
                imageHeight: nil,
                textElements: [],
                compactDescription: "Screen Recording is not granted. Visual perception is blocked.",
                message: "Enable Screen Recording for PadKey in System Settings."
            )
        }

        guard let image = CGWindowListCreateImage(.null, .optionOnScreenOnly, kCGNullWindowID, [.bestResolution, .nominalResolution]) else {
            return VisualScreenSnapshot(
                capturedAt: Date(),
                screenRecordingGranted: true,
                imageWidth: nil,
                imageHeight: nil,
                textElements: [],
                compactDescription: "Screen capture returned no image.",
                message: "PadKey could not capture the visible screen."
            )
        }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .fast
        request.usesLanguageCorrection = true
        request.minimumTextHeight = 0.015

        do {
            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            try handler.perform([request])
            let elements = (request.results ?? [])
                .compactMap { observation -> VisualTextElement? in
                    guard let candidate = observation.topCandidates(1).first else { return nil }
                    let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { return nil }
                    let box = observation.boundingBox
                    return VisualTextElement(
                        text: text,
                        confidence: candidate.confidence,
                        x: box.origin.x,
                        y: box.origin.y,
                        width: box.width,
                        height: box.height
                    )
                }
                .sorted { lhs, rhs in
                    if abs(lhs.y - rhs.y) > 0.02 { return lhs.y > rhs.y }
                    return lhs.x < rhs.x
                }
                .prefix(maxElements)
            let textElements = Array(elements)
            return VisualScreenSnapshot(
                capturedAt: Date(),
                screenRecordingGranted: true,
                imageWidth: image.width,
                imageHeight: image.height,
                textElements: textElements,
                compactDescription: compactDescription(for: textElements),
                message: textElements.isEmpty ? "Vision OCR ran, but no readable text was found." : nil
            )
        } catch {
            return VisualScreenSnapshot(
                capturedAt: Date(),
                screenRecordingGranted: true,
                imageWidth: image.width,
                imageHeight: image.height,
                textElements: [],
                compactDescription: "Vision OCR failed: \(error.localizedDescription)",
                message: error.localizedDescription
            )
        }
    }

    private static func compactDescription(for elements: [VisualTextElement]) -> String {
        guard !elements.isEmpty else { return "No visible text detected." }
        return elements
            .prefix(16)
            .enumerated()
            .map { index, element in
                "@v\(index + 1) \(element.text)"
            }
            .joined(separator: "\n")
    }
}

private extension String {
    var trimmedNonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
