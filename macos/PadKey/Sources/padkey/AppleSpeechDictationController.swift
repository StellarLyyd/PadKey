import AVFoundation
import Foundation
import Speech

final class AppleSpeechDictationController {
    private let audioEngine = AVAudioEngine()
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var speechRecognizer: SFSpeechRecognizer?

    private var partialHandler: ((String) -> Void)?
    private var meterHandler: ((VoiceMeterFrame) -> Void)?
    private var completionHandler: ((String) -> Void)?
    private var errorHandler: ((Error) -> Void)?

    private var latestTranscript = ""
    private var isRecording = false
    private var isStarting = false
    private var isStopping = false
    private var tapInstalled = false
    private var sessionID = UUID()

    func start(
        onPartial: @escaping (String) -> Void,
        onMeter: @escaping (VoiceMeterFrame) -> Void,
        onComplete: @escaping (String) -> Void,
        onError: @escaping (Error) -> Void
    ) {
        guard !isRecording, !isStarting else { return }

        let sessionID = UUID()
        self.sessionID = sessionID
        isStarting = true
        partialHandler = onPartial
        meterHandler = onMeter
        completionHandler = onComplete
        errorHandler = onError
        latestTranscript = ""

        PermissionHelper.requestSpeechAndMicrophone { [weak self] allowed in
            DispatchQueue.main.async {
                guard let self else { return }
                guard self.sessionID == sessionID, self.isStarting else { return }
                guard allowed else {
                    self.fail(DictationError.permissionDenied)
                    return
                }

                do {
                    try self.startRecognition()
                } catch {
                    self.fail(error)
                }
            }
        }
    }

    func stop() {
        if isStarting, !isRecording {
            let completion = completionHandler
            cancel()
            partialHandler = nil
            meterHandler = nil
            completionHandler = nil
            errorHandler = nil
            completion?("")
            return
        }

        guard isRecording else { return }
        isStopping = true

        if tapInstalled {
            audioEngine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }

        audioEngine.stop()
        recognitionRequest?.endAudio()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
            self?.finishIfNeeded()
        }
    }

    func cancel() {
        sessionID = UUID()
        if tapInstalled {
            audioEngine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }

        audioEngine.stop()
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
        meterHandler?(.idle)
        meterHandler = nil
        isRecording = false
        isStarting = false
        isStopping = false
        latestTranscript = ""
    }

    private func startRecognition() throws {
        speechRecognizer = SFSpeechRecognizer(locale: Locale.current)

        guard let speechRecognizer else {
            throw DictationError.recognizerUnavailable
        }

        guard speechRecognizer.isAvailable else {
            throw DictationError.recognizerUnavailable
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        if #available(macOS 13.0, *) {
            request.requiresOnDeviceRecognition = false
        }

        recognitionRequest = request

        let inputNode = audioEngine.inputNode
        if tapInstalled {
            inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        if audioEngine.isRunning {
            audioEngine.stop()
        }

        let recordingFormat = inputNode.outputFormat(forBus: 0)
        guard recordingFormat.channelCount > 0, recordingFormat.sampleRate > 0 else {
            throw DictationError.microphoneUnavailable
        }

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak self, weak request] buffer, _ in
            request?.append(buffer)
            self?.meterHandler?(VoiceMeterFrame.from(buffer: buffer))
        }
        tapInstalled = true

        audioEngine.prepare()
        try audioEngine.start()

        isRecording = true
        isStarting = false
        isStopping = false

        recognitionTask = speechRecognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }

            DispatchQueue.main.async {
                if let result {
                    self.latestTranscript = result.bestTranscription.formattedString
                    self.partialHandler?(self.latestTranscript)

                    if result.isFinal && self.isStopping {
                        self.finishIfNeeded()
                    }
                }

                if let error {
                    if self.isStopping {
                        self.finishIfNeeded()
                    } else {
                        self.fail(error)
                    }
                }
            }
        }
    }

    private func finishIfNeeded() {
        guard isRecording || isStopping else { return }

        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil

        let transcript = latestTranscript
        let completion = completionHandler

        partialHandler = nil
        meterHandler?(.idle)
        meterHandler = nil
        completionHandler = nil
        errorHandler = nil
        isRecording = false
        isStarting = false
        isStopping = false

        completion?(transcript)
    }

    private func fail(_ error: Error) {
        cancel()
        let handler = errorHandler
        partialHandler = nil
        meterHandler = nil
        completionHandler = nil
        errorHandler = nil
        handler?(error)
    }
}

enum DictationError: LocalizedError {
    case permissionDenied
    case recognizerUnavailable
    case microphoneUnavailable

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "Enable Microphone and Speech Recognition permissions for PadKey."
        case .recognizerUnavailable:
            return "Speech recognition is unavailable right now. Check your network or installed language support."
        case .microphoneUnavailable:
            return "PadKey could not access a microphone input."
        }
    }
}
