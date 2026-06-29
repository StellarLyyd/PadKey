import AppKit
import Foundation

final class CaptionPlaybackService {
    static let shared = CaptionPlaybackService()

    private let speech = NSSpeechSynthesizer()
    private var activeProcess: Process?
    private var activeAudioURL: URL?

    var statusMessage: String {
        if let model = Self.piperModelURL {
            if Self.piperExecutableURL != nil {
                return "Piper ready with \(model.lastPathComponent). Playback uses an open-source local voice."
            }
            return "Piper model is set, but the piper command is not installed."
        }
        if Self.piperExecutableURL != nil {
            return "Piper is installed. Set PADKEY_PIPER_MODEL to an .onnx voice for open-source playback."
        }
        return "Open-source voice not configured. Playback uses the local macOS voice until Piper is installed."
    }

    var isOpenSourceVoiceReady: Bool {
        Self.piperExecutableURL != nil && Self.piperModelURL != nil
    }

    @discardableResult
    func speak(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            NSSound.beep()
            return "No caption text to read yet."
        }

        stop()
        if let piper = Self.piperExecutableURL, let model = Self.piperModelURL {
            do {
                try speakWithPiper(text: trimmed, piper: piper, model: model)
                return "Reading captions with Piper."
            } catch {
                speakWithSystem(trimmed)
                return "Piper failed, so I used the local macOS voice."
            }
        }

        speakWithSystem(trimmed)
        return "Reading captions with the local macOS voice."
    }

    func stop() {
        speech.stopSpeaking()
        activeProcess?.terminate()
        activeProcess = nil
        if let activeAudioURL {
            try? FileManager.default.removeItem(at: activeAudioURL)
            self.activeAudioURL = nil
        }
    }

    private func speakWithSystem(_ text: String) {
        speech.stopSpeaking()
        speech.startSpeaking(text)
    }

    private func speakWithPiper(text: String, piper: URL, model: URL) throws {
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("padkey-caption-\(UUID().uuidString).wav")
        activeAudioURL = output

        let process = Process()
        process.executableURL = piper
        process.arguments = ["--model", model.path, "--output_file", output.path]
        let input = Pipe()
        process.standardInput = input
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        process.terminationHandler = { [weak self] process in
            guard process.terminationStatus == 0 else {
                DispatchQueue.main.async {
                    self?.speakWithSystem(text)
                }
                return
            }
            DispatchQueue.main.async {
                self?.playAudioFile(output)
            }
        }

        try process.run()
        activeProcess = process
        input.fileHandleForWriting.write(Data(text.utf8))
        input.fileHandleForWriting.closeFile()
    }

    private func playAudioFile(_ url: URL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
        process.arguments = [url.path]
        process.terminationHandler = { [weak self] _ in
            try? FileManager.default.removeItem(at: url)
            if self?.activeAudioURL == url {
                self?.activeAudioURL = nil
            }
        }
        try? process.run()
        activeProcess = process
    }

    private static var piperModelURL: URL? {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["PADKEY_PIPER_MODEL"], !path.isEmpty else { return nil }
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private static var piperExecutableURL: URL? {
        executable(named: "piper") ?? executable(named: "piper-tts")
    }

    private static func executable(named name: String) -> URL? {
        let pathEntries = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":")
            .map(String.init)
        let candidates = (pathEntries + ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"])
            .map { URL(fileURLWithPath: $0).appendingPathComponent(name) }

        return candidates.first { url in
            FileManager.default.isExecutableFile(atPath: url.path)
        }
    }
}
