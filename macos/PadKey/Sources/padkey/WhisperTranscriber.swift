import Foundation

final class WhisperTranscriber {
    private let store: PadKeyStore

    init(store: PadKeyStore = .shared) {
        self.store = store
    }

    var isReady: Bool {
        configuration != nil
    }

    var statusMessage: String {
        if let configuration {
            return "Local Whisper ready: \(configuration.modelURL.lastPathComponent)"
        }

        if findWhisperBinary() == nil {
            return "Local Whisper missing: run ./script/setup_whisper.sh"
        }

        return "Local Whisper missing: no ggml model found"
    }

    func transcribe(audioURL: URL, completion: @escaping (Result<String, Error>) -> Void) {
        guard let configuration else {
            completion(.failure(WhisperTranscriptionError.notConfigured))
            return
        }

        DispatchQueue.global(qos: .userInitiated).async {
            let outputBase = FileManager.default.temporaryDirectory
                .appendingPathComponent("padkey-whisper-\(UUID().uuidString)")

            let process = Process()
            process.executableURL = configuration.binaryURL
            process.currentDirectoryURL = configuration.binaryURL.deletingLastPathComponent()
            process.environment = Self.environment(for: configuration)
            var arguments = [
                "-m", configuration.modelURL.path,
                "-f", audioURL.path,
                "-l", configuration.language,
                "-t", "\(Self.threadCount)",
                "-nt",
                "-np",
                "-otxt",
                "-of", outputBase.path
            ]

            let voicePrompt = self.store.voiceSyncPrompt
            if !voicePrompt.isEmpty {
                arguments += ["--prompt", voicePrompt, "--carry-initial-prompt"]
            }

            process.arguments = arguments

            let outputPipe = Pipe()
            process.standardOutput = outputPipe
            process.standardError = outputPipe

            do {
                try process.run()
                process.waitUntilExit()

                let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
                let diagnosticOutput = String(data: outputData, encoding: .utf8) ?? ""

                guard process.terminationStatus == 0 else {
                    completion(.failure(WhisperTranscriptionError.processFailed(diagnosticOutput)))
                    return
                }

                let transcriptURL = outputBase.appendingPathExtension("txt")
                let transcript = try String(contentsOf: transcriptURL, encoding: .utf8)
                try? FileManager.default.removeItem(at: transcriptURL)

                completion(.success(Self.cleanedTranscript(transcript)))
            } catch {
                completion(.failure(error))
            }
        }
    }

    private var configuration: WhisperConfiguration? {
        guard
            let binaryURL = findWhisperBinary(),
            let modelURL = findWhisperModel()
        else {
            return nil
        }

        return WhisperConfiguration(binaryURL: binaryURL, modelURL: modelURL)
    }

    private func findWhisperBinary() -> URL? {
        let candidates = whisperResourceRoots().map {
            $0.appendingPathComponent("bin/whisper-cli")
        }

        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    private func findWhisperModel() -> URL? {
        let fileManager = FileManager.default

        for root in whisperResourceRoots() {
            let modelsDirectory = root.appendingPathComponent("models")
            let preferredModels = [
                "ggml-large-v3-turbo.bin",
                "ggml-large-v3.bin",
                "ggml-medium.en.bin",
                "ggml-medium.bin",
                "ggml-small.en.bin",
                "ggml-small.bin",
                "ggml-base.en.bin",
                "ggml-base.bin"
            ]

            for modelName in preferredModels {
                let modelURL = modelsDirectory.appendingPathComponent(modelName)
                if fileManager.fileExists(atPath: modelURL.path) {
                    return modelURL
                }
            }

            guard let modelNames = try? fileManager.contentsOfDirectory(atPath: modelsDirectory.path) else {
                continue
            }

            if let modelName = modelNames.sorted().first(where: { $0.hasPrefix("ggml-") && $0.hasSuffix(".bin") }) {
                return modelsDirectory.appendingPathComponent(modelName)
            }
        }

        return nil
    }

    private func whisperResourceRoots() -> [URL] {
        var roots: [URL] = []

        if let bundleResourceURL = Bundle.main.resourceURL {
            roots.append(bundleResourceURL.appendingPathComponent("Whisper"))
        }

        roots.append(URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Support/Whisper"))

        return roots
    }

    private static var threadCount: Int {
        max(2, min(8, ProcessInfo.processInfo.processorCount - 2))
    }

    private static func environment(for configuration: WhisperConfiguration) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let libraryPath = configuration.binaryURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("lib")
            .path

        if let existingPath = environment["DYLD_LIBRARY_PATH"], !existingPath.isEmpty {
            environment["DYLD_LIBRARY_PATH"] = "\(libraryPath):\(existingPath)"
        } else {
            environment["DYLD_LIBRARY_PATH"] = libraryPath
        }

        return environment
    }

    private static func cleanedTranscript(_ transcript: String) -> String {
        transcript
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private struct WhisperConfiguration {
    let binaryURL: URL
    let modelURL: URL

    var language: String {
        modelURL.lastPathComponent.contains(".en") ? "en" : "auto"
    }
}

enum WhisperTranscriptionError: LocalizedError {
    case notConfigured
    case processFailed(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Local Whisper is not set up. Run ./script/setup_whisper.sh from the padkey folder."
        case .processFailed(let output):
            let detail = output.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !detail.isEmpty else {
                return "Local Whisper failed to transcribe the recording."
            }
            return "Local Whisper failed: \(detail)"
        }
    }
}
