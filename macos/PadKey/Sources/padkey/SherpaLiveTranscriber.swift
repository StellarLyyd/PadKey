import Foundation

final class SherpaLiveTranscriber {
    private let outputQueue = DispatchQueue(label: "com.stellarlyyd.padkey.sherpa-output")
    private var process: Process?
    private var outputPipe: Pipe?
    private var outputBuffer = ""
    private var segmentText: [Int: String] = [:]
    private var activeSegment: Int?
    private var latestTranscript = ""

    var isReady: Bool {
        configuration != nil
    }

    var statusMessage: String {
        if let configuration {
            return "Sherpa live ready: \(configuration.modelDirectory.lastPathComponent)"
        }

        if findSherpaBinary() == nil {
            return "Sherpa live missing: run ./script/setup_sherpa.sh"
        }

        return "Sherpa live missing: no streaming model found"
    }

    func start(
        onPartial: @escaping (String) -> Void,
        onError: @escaping (Error) -> Void
    ) throws {
        guard process == nil else { return }
        guard let configuration else {
            throw SherpaLiveError.notConfigured
        }

        outputQueue.sync {
            outputBuffer = ""
            segmentText = [:]
            activeSegment = nil
            latestTranscript = ""
        }

        let liveProcess = Process()
        liveProcess.executableURL = configuration.binaryURL
        liveProcess.currentDirectoryURL = configuration.binaryURL.deletingLastPathComponent()
        liveProcess.environment = Self.environment(for: configuration)
        liveProcess.arguments = [
            "--tokens=\(configuration.tokensURL.path)",
            "--encoder=\(configuration.encoderURL.path)",
            "--decoder=\(configuration.decoderURL.path)",
            "--joiner=\(configuration.joinerURL.path)",
            "--provider=cpu",
            "--num-threads=\(Self.threadCount)",
            "--decoding-method=greedy_search"
        ]

        let outputPipe = Pipe()
        liveProcess.standardOutput = outputPipe
        liveProcess.standardError = outputPipe

        outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.consume(data: data, onPartial: onPartial)
        }

        liveProcess.terminationHandler = { [weak self] finishedProcess in
            self?.outputQueue.async {
                let shouldReportError = self?.process === finishedProcess && finishedProcess.terminationStatus != 0
                if self?.process === finishedProcess {
                    self?.process = nil
                    self?.outputPipe = nil
                }
                guard shouldReportError else { return }
                DispatchQueue.main.async {
                    onError(SherpaLiveError.processFailed(Int(finishedProcess.terminationStatus)))
                }
            }
        }

        do {
            try liveProcess.run()
            process = liveProcess
            self.outputPipe = outputPipe
        } catch {
            process = nil
            self.outputPipe = nil
            throw error
        }
    }

    func stop() -> String {
        let transcript = outputQueue.sync { latestTranscript }
        stopProcess()
        return transcript
    }

    func cancel() {
        stopProcess()
        outputQueue.sync {
            outputBuffer = ""
            segmentText = [:]
            activeSegment = nil
            latestTranscript = ""
        }
    }

    private func stopProcess() {
        guard let process else { return }
        outputPipe = nil
        self.process = nil

        if process.isRunning {
            process.terminate()
            DispatchQueue.global(qos: .utility).async {
                process.waitUntilExit()
            }
        }
    }

    private func consume(data: Data, onPartial: @escaping (String) -> Void) {
        guard let chunk = String(data: data, encoding: .utf8), !chunk.isEmpty else { return }

        outputQueue.async { [weak self] in
            guard let self else { return }
            let sanitized = Self.stripANSIEscapes(from: chunk)

            for character in sanitized {
                if character == "\r" || character == "\n" {
                    self.processLine(self.outputBuffer, onPartial: onPartial)
                    self.outputBuffer = ""
                } else {
                    self.outputBuffer.append(character)
                }
            }

            self.processLine(self.outputBuffer, onPartial: onPartial)
        }
    }

    private func processLine(_ line: String, onPartial: @escaping (String) -> Void) {
        let cleaned = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }

        if let match = cleaned.range(of: #"^\d+:"#, options: .regularExpression) {
            let prefix = String(cleaned[match]).dropLast()
            guard let index = Int(prefix) else { return }
            let text = cleaned[match.upperBound...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            activeSegment = index
            segmentText[index] = text
            publishIfChanged(onPartial: onPartial)
            return
        }

        guard let activeSegment, looksLikeTranscriptContinuation(cleaned) else { return }
        let current = segmentText[activeSegment] ?? ""
        let appended = [current, cleaned]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        segmentText[activeSegment] = appended
        publishIfChanged(onPartial: onPartial)
    }

    private func publishIfChanged(onPartial: @escaping (String) -> Void) {
        let transcript = segmentText
            .keys
            .sorted()
            .compactMap { segmentText[$0] }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !transcript.isEmpty, transcript != latestTranscript else { return }
        latestTranscript = transcript
        DispatchQueue.main.async {
            onPartial(transcript)
        }
    }

    private func looksLikeTranscriptContinuation(_ text: String) -> Bool {
        guard !text.contains("="), !text.contains("--") else { return false }
        guard text.rangeOfCharacter(from: .letters) != nil else { return false }

        let lowercased = text.lowercased()
        let diagnosticNeedles = [
            "onlinerecognizerconfig",
            "featureextractorconfig",
            "available input devices",
            "default input device",
            "portaudio",
            "caught ctrl",
            "errors in config",
            "please refer"
        ]

        return !diagnosticNeedles.contains { lowercased.contains($0) }
    }

    private var configuration: SherpaLiveConfiguration? {
        guard
            let binaryURL = findSherpaBinary(),
            let model = findStreamingModel()
        else {
            return nil
        }

        return SherpaLiveConfiguration(
            binaryURL: binaryURL,
            modelDirectory: model.modelDirectory,
            tokensURL: model.tokensURL,
            encoderURL: model.encoderURL,
            decoderURL: model.decoderURL,
            joinerURL: model.joinerURL
        )
    }

    private func findSherpaBinary() -> URL? {
        let candidates = sherpaResourceRoots().flatMap {
            [
                $0.appendingPathComponent("bin/sherpa-onnx-microphone"),
                $0.appendingPathComponent("bin/sherpa-onnx")
            ]
        }

        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    private func findStreamingModel() -> SherpaStreamingModel? {
        let fileManager = FileManager.default

        for root in sherpaResourceRoots() {
            let modelsDirectory = root.appendingPathComponent("models")
            guard
                let enumerator = fileManager.enumerator(
                    at: modelsDirectory,
                    includingPropertiesForKeys: [.isDirectoryKey],
                    options: [.skipsHiddenFiles]
                )
            else {
                continue
            }

            var directories: [URL] = [modelsDirectory]
            for case let url as URL in enumerator {
                guard
                    let values = try? url.resourceValues(forKeys: [.isDirectoryKey]),
                    values.isDirectory == true
                else {
                    continue
                }
                directories.append(url)
            }

            let sortedDirectories = directories.sorted {
                Self.modelRank($0.lastPathComponent) < Self.modelRank($1.lastPathComponent)
            }

            for directory in sortedDirectories {
                if let model = streamingModel(in: directory) {
                    return model
                }
            }
        }

        return nil
    }

    private func streamingModel(in directory: URL) -> SherpaStreamingModel? {
        let tokensURL = directory.appendingPathComponent("tokens.txt")
        guard FileManager.default.fileExists(atPath: tokensURL.path) else { return nil }

        let fileNames = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        let onnxNames = fileNames.filter { $0.hasSuffix(".onnx") }

        guard
            let encoder = Self.preferredModelFile(from: onnxNames, containing: "encoder", in: directory),
            let decoder = Self.preferredModelFile(from: onnxNames, containing: "decoder", in: directory),
            let joiner = Self.preferredModelFile(from: onnxNames, containing: "joiner", in: directory)
        else {
            return nil
        }

        return SherpaStreamingModel(
            modelDirectory: directory,
            tokensURL: tokensURL,
            encoderURL: encoder,
            decoderURL: decoder,
            joinerURL: joiner
        )
    }

    private func sherpaResourceRoots() -> [URL] {
        var roots: [URL] = []

        if let bundleResourceURL = Bundle.main.resourceURL {
            roots.append(bundleResourceURL.appendingPathComponent("Sherpa"))
        }

        roots.append(URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Support/Sherpa"))

        return roots
    }

    private static func preferredModelFile(from names: [String], containing needle: String, in directory: URL) -> URL? {
        let matchingNames = names
            .filter { $0.localizedCaseInsensitiveContains(needle) }
            .sorted { lhs, rhs in
                let preferInt8 = needle != "decoder"
                let lhsRank = modelFileRank(lhs, preferInt8: preferInt8)
                let rhsRank = modelFileRank(rhs, preferInt8: preferInt8)
                if lhsRank != rhsRank { return lhsRank < rhsRank }
                return lhs < rhs
            }

        guard let name = matchingNames.first else { return nil }
        return directory.appendingPathComponent(name)
    }

    private static func modelRank(_ name: String) -> Int {
        let lowercased = name.lowercased()
        if lowercased.contains("20m") { return 0 }
        if lowercased.contains("zipformer") { return 1 }
        return 2
    }

    private static func modelFileRank(_ name: String, preferInt8: Bool) -> Int {
        var rank = 0
        let lowercased = name.lowercased()
        if lowercased.contains(".int8.") {
            rank += preferInt8 ? -20 : 20
        }
        if lowercased.contains("chunk-16-left-128") { rank -= 10 }
        if lowercased.contains("epoch-99") { rank -= 5 }
        return rank
    }

    private static func stripANSIEscapes(from text: String) -> String {
        text.replacingOccurrences(
            of: #"\u{001B}\[[0-9;?]*[ -/]*[@-~]"#,
            with: "",
            options: .regularExpression
        )
    }

    private static func environment(for configuration: SherpaLiveConfiguration) -> [String: String] {
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

    private static var threadCount: Int {
        max(1, min(4, ProcessInfo.processInfo.processorCount - 2))
    }
}

private struct SherpaLiveConfiguration {
    let binaryURL: URL
    let modelDirectory: URL
    let tokensURL: URL
    let encoderURL: URL
    let decoderURL: URL
    let joinerURL: URL
}

private struct SherpaStreamingModel {
    let modelDirectory: URL
    let tokensURL: URL
    let encoderURL: URL
    let decoderURL: URL
    let joinerURL: URL
}

enum SherpaLiveError: LocalizedError {
    case notConfigured
    case processFailed(Int)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Sherpa live transcription is not set up. Run ./script/setup_sherpa.sh from the padkey folder."
        case .processFailed(let code):
            return "Sherpa live transcription stopped unexpectedly with exit code \(code)."
        }
    }
}
