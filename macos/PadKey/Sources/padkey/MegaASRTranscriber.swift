import Foundation

final class MegaASRTranscriber {
    var isReady: Bool {
        configuration != nil
    }

    var statusMessage: String {
        if let configuration {
            return "Mega-ASR ready: \(configuration.modelURL.lastPathComponent)"
        }

        if findBinary() == nil {
            return "Mega-ASR missing: run ./script/setup_mega_asr.sh"
        }

        return "Mega-ASR missing: no GGUF model found"
    }

    func transcribe(audioURL: URL, completion: @escaping (Result<String, Error>) -> Void) {
        guard let configuration else {
            completion(.failure(MegaASRError.notConfigured))
            return
        }

        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = configuration.binaryURL
            process.currentDirectoryURL = configuration.binaryURL.deletingLastPathComponent()
            process.environment = Self.environment(for: configuration)
            process.arguments = [
                "--backend", "mega-asr",
                "-m", configuration.modelURL.path,
                "--no-timestamps",
                "--no-prints",
                "-l", "en",
                "-f",
                audioURL.path
            ]

            let outputPipe = Pipe()
            process.standardOutput = outputPipe
            process.standardError = outputPipe

            do {
                try process.run()
                process.waitUntilExit()

                let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: outputData, encoding: .utf8) ?? ""

                guard process.terminationStatus == 0 else {
                    completion(.failure(MegaASRError.processFailed(output)))
                    return
                }

                let cleaned = Self.cleanedTranscript(output)
                guard !cleaned.isEmpty else {
                    completion(.failure(MegaASRError.emptyTranscript))
                    return
                }

                completion(.success(cleaned))
            } catch {
                completion(.failure(error))
            }
        }
    }

    private var configuration: MegaASRConfiguration? {
        guard
            let binaryURL = findBinary(),
            let modelURL = findModel()
        else {
            return nil
        }

        return MegaASRConfiguration(binaryURL: binaryURL, modelURL: modelURL)
    }

    private func findBinary() -> URL? {
        let candidates = resourceRoots().map {
            $0.appendingPathComponent("bin/crispasr")
        }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    private func findModel() -> URL? {
        let preferred = [
            "mega-asr-1.7b-q4_k.gguf",
            "mega-asr-1.7b-f16.gguf"
        ]

        for root in resourceRoots() {
            let modelsDirectory = root.appendingPathComponent("models")
            for modelName in preferred {
                let modelURL = modelsDirectory.appendingPathComponent(modelName)
                if FileManager.default.fileExists(atPath: modelURL.path) {
                    return modelURL
                }
            }

            guard let modelNames = try? FileManager.default.contentsOfDirectory(atPath: modelsDirectory.path) else {
                continue
            }

            if let modelName = modelNames.sorted().first(where: { $0.hasSuffix(".gguf") }) {
                return modelsDirectory.appendingPathComponent(modelName)
            }
        }

        return nil
    }

    private func resourceRoots() -> [URL] {
        var roots: [URL] = []
        if let bundleResourceURL = Bundle.main.resourceURL {
            roots.append(bundleResourceURL.appendingPathComponent("MegaASR"))
        }

        roots.append(URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Support/MegaASR"))

        return roots
    }

    private static func environment(for configuration: MegaASRConfiguration) -> [String: String] {
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

    static func cleanedTranscript(_ transcript: String) -> String {
        let cleaned = transcript
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { line in
                guard !line.isEmpty else { return false }
                let lowercased = line.lowercased()
                let diagnosticPrefixes = [
                    "#",
                    "%",
                    "ggml",
                    "gguf",
                    "backend:",
                    "crisp_audio:",
                    "crispasr ",
                    "crispasr:",
                    "crispasr[",
                    "crispasr_",
                    "loading ",
                    "loading:",
                    "qwen3_asr:",
                    "sampling:",
                    "system info",
                    "whisper_",
                    "whisper:",
                    "error:",
                    "warning:"
                ]
                return !diagnosticPrefixes.contains { lowercased.hasPrefix($0) }
            }
            .joined(separator: " ")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return removingLanguagePrefix(from: cleaned)
    }

    private static func removingLanguagePrefix(from transcript: String) -> String {
        let languagePrefixes = [
            "language English",
            "language en",
            "language Spanish",
            "language French",
            "language German",
            "language Italian",
            "language Portuguese",
            "language Chinese",
            "language Japanese",
            "language Korean"
        ]

        for prefix in languagePrefixes where transcript.lowercased().hasPrefix(prefix.lowercased()) {
            return String(transcript.dropFirst(prefix.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return transcript
    }
}

private struct MegaASRConfiguration {
    let binaryURL: URL
    let modelURL: URL
}

enum MegaASRError: LocalizedError {
    case notConfigured
    case processFailed(String)
    case emptyTranscript

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Mega-ASR is not set up. Run ./script/setup_mega_asr.sh from the padkey folder."
        case .processFailed(let output):
            let detail = output.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !detail.isEmpty else {
                return "Mega-ASR failed to transcribe the recording."
            }
            return "Mega-ASR failed: \(detail)"
        case .emptyTranscript:
            return "Mega-ASR returned an empty transcript."
        }
    }
}
