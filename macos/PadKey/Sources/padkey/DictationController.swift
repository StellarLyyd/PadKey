import Foundation

enum RecognitionEngine: String, Codable, CaseIterable {
    case autoRobust
    case sherpaWhisper
    case whisper
    case megaASR
    case appleSpeech

    var displayName: String {
        switch self {
        case .autoRobust:
            return "Auto Robust"
        case .sherpaWhisper:
            return "Sherpa live + Whisper final"
        case .whisper:
            return "Whisper final"
        case .megaASR:
            return "Mega-ASR final"
        case .appleSpeech:
            return "Apple Speech"
        }
    }
}

final class DictationController {
    private enum ActiveBackend {
        case autoRobust
        case sherpaWhisper
        case megaASR
        case sherpaOnly
        case localWhisper
        case appleSpeech
    }

    private let sherpaLive = SherpaLiveTranscriber()
    private let whisperRecorder = WhisperAudioRecorder()
    private let whisperTranscriber = WhisperTranscriber()
    private let megaTranscriber = MegaASRTranscriber()
    private let appleSpeech = AppleSpeechDictationController()
    private var activeRecorder: DictationAudioRecorder?

    private var activeBackend: ActiveBackend?
    private var partialHandler: ((String) -> Void)?
    private var completionHandler: ((DictationResult) -> Void)?
    private var errorHandler: ((Error) -> Void)?
    private var recordingSessionID = UUID()

    var prefersLocalWhisper = true
    var recognitionEngine: RecognitionEngine = .autoRobust
    var robustRetryEnabled = true
    var inputSource: PadKeyInputSource = PadKeyStore.shared.selectedInputSource

    var liveTranscriptionStatus: String {
        sherpaLive.statusMessage
    }

    var isSherpaReady: Bool {
        sherpaLive.isReady
    }

    var localWhisperStatus: String {
        whisperTranscriber.statusMessage
    }

    var isLocalWhisperReady: Bool {
        whisperTranscriber.isReady
    }

    var megaASRStatus: String {
        megaTranscriber.statusMessage
    }

    var isMegaASRReady: Bool {
        megaTranscriber.isReady
    }

    func start(
        onPartial: @escaping (String) -> Void,
        onMeter: @escaping (VoiceMeterFrame) -> Void,
        onComplete: @escaping (DictationResult) -> Void,
        onError: @escaping (Error) -> Void
    ) {
        let sessionID = UUID()
        recordingSessionID = sessionID

        if inputSource.isPadKeyHardware {
            guard whisperTranscriber.isReady || megaTranscriber.isReady else {
                onError(DictationError.recognizerUnavailable)
                return
            }
            let hardwareBackend: ActiveBackend = recognitionEngine == .megaASR || !whisperTranscriber.isReady ? .megaASR : .localWhisper
            startLocalWhisper(
                backend: hardwareBackend,
                useSherpaLive: false,
                sessionID: sessionID,
                onPartial: onPartial,
                onMeter: onMeter,
                onComplete: onComplete,
                onError: onError
            )
            return
        }

        switch recognitionEngine {
        case .autoRobust:
            if whisperTranscriber.isReady {
                startLocalWhisper(
                    backend: .autoRobust,
                    useSherpaLive: true,
                    sessionID: sessionID,
                    onPartial: onPartial,
                    onMeter: onMeter,
                    onComplete: onComplete,
                    onError: onError
                )
                return
            }

            if sherpaLive.isReady {
                startSherpaOnly(
                    sessionID: sessionID,
                    onPartial: onPartial,
                    onComplete: onComplete,
                    onError: onError
                )
                return
            }

        case .sherpaWhisper:
            if whisperTranscriber.isReady {
                startLocalWhisper(
                    backend: .sherpaWhisper,
                    useSherpaLive: true,
                    sessionID: sessionID,
                    onPartial: onPartial,
                    onMeter: onMeter,
                    onComplete: onComplete,
                    onError: onError
                )
                return
            }

            if sherpaLive.isReady {
                startSherpaOnly(
                    sessionID: sessionID,
                    onPartial: onPartial,
                    onComplete: onComplete,
                    onError: onError
                )
                return
            }

        case .whisper:
            if whisperTranscriber.isReady {
                startLocalWhisper(
                    backend: .localWhisper,
                    useSherpaLive: false,
                    sessionID: sessionID,
                    onPartial: onPartial,
                    onMeter: onMeter,
                    onComplete: onComplete,
                    onError: onError
                )
                return
            }

        case .megaASR:
            if megaTranscriber.isReady {
                startLocalWhisper(
                    backend: .megaASR,
                    useSherpaLive: sherpaLive.isReady,
                    sessionID: sessionID,
                    onPartial: onPartial,
                    onMeter: onMeter,
                    onComplete: onComplete,
                    onError: onError
                )
                return
            }

        case .appleSpeech:
            break
        }

        if prefersLocalWhisper, whisperTranscriber.isReady {
            startLocalWhisper(
                backend: .localWhisper,
                useSherpaLive: false,
                sessionID: sessionID,
                onPartial: onPartial,
                onMeter: onMeter,
                onComplete: onComplete,
                onError: onError
            )
            return
        }

        activeBackend = .appleSpeech
        appleSpeech.start(
            onPartial: { [weak self] transcript in
                guard self?.recordingSessionID == sessionID else { return }
                onPartial(transcript)
            },
            onMeter: { [weak self] frame in
                guard self?.recordingSessionID == sessionID else { return }
                onMeter(frame)
            },
            onComplete: { [weak self] transcript in
                guard let self, self.recordingSessionID == sessionID else { return }
                self.recordingSessionID = UUID()
                self.activeBackend = nil
                onComplete(DictationResult(
                    transcript: transcript,
                    engine: .appleSpeech,
                    usedRobustRetry: false,
                    fallbackReason: nil,
                    asrDuration: nil,
                    inputSource: self.inputSource,
                    audioURL: nil
                ))
            },
            onError: { [weak self] error in
                guard let self, self.recordingSessionID == sessionID else { return }
                self.recordingSessionID = UUID()
                self.activeBackend = nil
                onError(error)
            }
        )
    }

    func stop() {
        switch activeBackend {
        case .autoRobust:
            stopLocalWhisper()
        case .sherpaWhisper:
            stopLocalWhisper()
        case .megaASR:
            stopLocalWhisper()
        case .sherpaOnly:
            stopSherpaOnly()
        case .localWhisper:
            stopLocalWhisper()
        case .appleSpeech:
            appleSpeech.stop()
        case nil:
            break
        }
    }

    func cancel() {
        recordingSessionID = UUID()
        sherpaLive.cancel()
        whisperRecorder.cancel()
        whisperRecorder.onMeter = nil
        activeRecorder?.cancel()
        activeRecorder = nil
        appleSpeech.cancel()
        clearHandlers()
        activeBackend = nil
    }

    private func startLocalWhisper(
        backend: ActiveBackend,
        useSherpaLive: Bool,
        sessionID: UUID,
        onPartial: @escaping (String) -> Void,
        onMeter: @escaping (VoiceMeterFrame) -> Void,
        onComplete: @escaping (DictationResult) -> Void,
        onError: @escaping (Error) -> Void
    ) {
        partialHandler = onPartial
        completionHandler = onComplete
        errorHandler = onError
        activeBackend = backend

        let selectedSource = inputSource
        let beginRecording: (Bool) -> Void = { [weak self] allowed in
            DispatchQueue.main.async {
                guard let self else { return }
                guard self.recordingSessionID == sessionID, self.activeBackend == backend else { return }
                guard allowed else {
                    self.failLocalWhisper(DictationError.permissionDenied)
                    return
                }

                do {
                    if useSherpaLive {
                        self.startSherpaLive(sessionID: sessionID, onPartial: onPartial)
                    }
                    let recorder: DictationAudioRecorder = selectedSource.isPadKeyHardware
                        ? PadKeyHardwareAudioRecorder(source: selectedSource)
                        : self.whisperRecorder
                    self.activeRecorder = recorder
                    recorder.onMeter = { [weak self] frame in
                        guard self?.recordingSessionID == sessionID else { return }
                        onMeter(frame)
                    }
                    try recorder.start()
                    onPartial(selectedSource.isPadKeyHardware
                        ? "Listening from \(selectedSource.displayName). Release fn to transcribe this PadKey hardware capture."
                        : useSherpaLive
                        ? "Listening locally. Sherpa is showing live words; Whisper will finalize when you release fn."
                        : "Recording locally. Press Option-Space again to transcribe with Whisper."
                    )
                } catch {
                    if useSherpaLive {
                        self.sherpaLive.cancel()
                    }
                    self.failLocalWhisper(error)
                }
            }
        }

        if selectedSource.isPadKeyHardware {
            beginRecording(true)
        } else {
            PermissionHelper.requestMicrophone(completion: beginRecording)
        }
    }

    private func startSherpaLive(sessionID: UUID, onPartial: @escaping (String) -> Void) {
        do {
            try sherpaLive.start(
                onPartial: { [weak self] transcript in
                    guard self?.recordingSessionID == sessionID else { return }
                    onPartial(transcript)
                },
                onError: { [weak self] _ in
                    guard self?.recordingSessionID == sessionID else { return }
                    onPartial("Sherpa live captions paused. Whisper final transcription is still recording.")
                }
            )
        } catch {
            onPartial("Sherpa live is unavailable. Whisper final transcription is still recording.")
        }
    }

    private func startSherpaOnly(
        sessionID: UUID,
        onPartial: @escaping (String) -> Void,
        onComplete: @escaping (DictationResult) -> Void,
        onError: @escaping (Error) -> Void
    ) {
        partialHandler = onPartial
        completionHandler = onComplete
        errorHandler = onError
        activeBackend = .sherpaOnly

        PermissionHelper.requestMicrophone { [weak self] allowed in
            DispatchQueue.main.async {
                guard let self else { return }
                guard self.recordingSessionID == sessionID, self.activeBackend == .sherpaOnly else { return }
                guard allowed else {
                    self.failSherpaOnly(DictationError.permissionDenied)
                    return
                }

                do {
                    try self.sherpaLive.start(
                        onPartial: { [weak self] transcript in
                            guard self?.recordingSessionID == sessionID else { return }
                            onPartial(transcript)
                        },
                        onError: { [weak self] error in
                            guard self?.recordingSessionID == sessionID else { return }
                            self?.failSherpaOnly(error)
                        }
                    )
                    onPartial("Listening locally with Sherpa. Release fn to finish.")
                } catch {
                    self.failSherpaOnly(error)
                }
            }
        }
    }

    private func stopLocalWhisper() {
        let liveTranscript = sherpaLive.stop()

        guard let recorder = activeRecorder, recorder.recordingActive else {
            recordingSessionID = UUID()
            activeRecorder?.onMeter = nil
            activeRecorder = nil
            let completion = completionHandler
            clearHandlers()
            activeBackend = nil
            completion?(DictationResult(
                transcript: liveTranscript,
                engine: .sherpaWhisper,
                usedRobustRetry: false,
                fallbackReason: "Whisper recorder was not active; used live transcript.",
                asrDuration: nil,
                inputSource: inputSource,
                audioURL: nil
            ))
            return
        }

        do {
            let audioURL = try recorder.stop()
            recorder.onMeter = nil
            activeRecorder = nil
            let backend = activeBackend ?? .localWhisper
            let engine = engine(for: backend)
            partialHandler?(backend == .megaASR ? "Transcribing robustly with Mega-ASR..." : "Transcribing offline with local Whisper...")
            let sessionID = recordingSessionID
            let asrStartedAt = Date()
            let source = inputSource

            transcribe(audioURL: audioURL, backend: backend, liveTranscript: liveTranscript) { [weak self] result in
                DispatchQueue.main.async {
                    guard let self else { return }
                    guard self.recordingSessionID == sessionID else {
                        return
                    }

                    switch result {
                    case .success(let dictationResult):
                        let completion = self.completionHandler
                        self.recordingSessionID = UUID()
                        self.clearHandlers()
                        self.activeBackend = nil
                        var enriched = dictationResult
                        enriched.asrDuration = Date().timeIntervalSince(asrStartedAt)
                        enriched.inputSource = source
                        enriched.audioURL = audioURL
                        completion?(enriched)
                    case .failure(let error):
                        if !liveTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            let completion = self.completionHandler
                            self.recordingSessionID = UUID()
                            self.clearHandlers()
                            self.activeBackend = nil
                            completion?(DictationResult(
                                transcript: liveTranscript,
                                engine: engine,
                                usedRobustRetry: false,
                                fallbackReason: error.localizedDescription,
                                asrDuration: Date().timeIntervalSince(asrStartedAt),
                                inputSource: source,
                                audioURL: audioURL
                            ))
                            return
                        }
                        self.failLocalWhisper(error)
                    }
                }
            }
        } catch {
            failLocalWhisper(error)
        }
    }

    private func stopSherpaOnly() {
        let transcript = sherpaLive.stop()
        let completion = completionHandler
        recordingSessionID = UUID()
        clearHandlers()
        activeBackend = nil
        completion?(DictationResult(
            transcript: transcript,
            engine: .sherpaWhisper,
            usedRobustRetry: false,
            fallbackReason: nil,
            asrDuration: nil
        ))
    }

    private func transcribe(
        audioURL: URL,
        backend: ActiveBackend,
        liveTranscript: String,
        completion: @escaping (Result<DictationResult, Error>) -> Void
    ) {
        switch backend {
        case .megaASR:
            megaTranscriber.transcribe(audioURL: audioURL) { result in
                completion(result.map {
                    DictationResult(
                        transcript: $0,
                        engine: .megaASR,
                        usedRobustRetry: true,
                        fallbackReason: nil,
                        asrDuration: nil
                    )
                })
            }

        case .autoRobust:
            whisperTranscriber.transcribe(audioURL: audioURL) { [weak self] result in
                guard let self else { return }
                switch result {
                case .success(let transcript):
                    let shouldRetry = self.robustRetryEnabled
                        && self.megaTranscriber.isReady
                        && TranscriptQuality.shouldRetryWithRobustASR(transcript, duration: nil, liveTranscript: liveTranscript)
                    guard shouldRetry else {
                        completion(.success(DictationResult(
                            transcript: transcript,
                            engine: .autoRobust,
                            usedRobustRetry: false,
                            fallbackReason: nil,
                            asrDuration: nil
                        )))
                        return
                    }

                    self.megaTranscriber.transcribe(audioURL: audioURL) { robustResult in
                        switch robustResult {
                        case .success(let robustTranscript):
                            completion(.success(DictationResult(
                                transcript: robustTranscript,
                                engine: .autoRobust,
                                usedRobustRetry: true,
                                fallbackReason: "Whisper output looked low-confidence.",
                                asrDuration: nil
                            )))
                        case .failure:
                            completion(.success(DictationResult(
                                transcript: transcript,
                                engine: .autoRobust,
                                usedRobustRetry: false,
                                fallbackReason: "Mega-ASR retry was unavailable.",
                                asrDuration: nil
                            )))
                        }
                    }

                case .failure(let error):
                    guard self.megaTranscriber.isReady else {
                        completion(.failure(error))
                        return
                    }
                    self.megaTranscriber.transcribe(audioURL: audioURL) { robustResult in
                        completion(robustResult.map {
                            DictationResult(
                                transcript: $0,
                                engine: .autoRobust,
                                usedRobustRetry: true,
                                fallbackReason: error.localizedDescription,
                                asrDuration: nil
                            )
                        })
                    }
                }
            }

        default:
            whisperTranscriber.transcribe(audioURL: audioURL) { result in
                completion(result.map {
                    DictationResult(
                        transcript: $0,
                        engine: self.engine(for: backend),
                        usedRobustRetry: false,
                        fallbackReason: nil,
                        asrDuration: nil
                    )
                })
            }
        }
    }

    private func engine(for backend: ActiveBackend) -> RecognitionEngine {
        switch backend {
        case .autoRobust:
            return .autoRobust
        case .sherpaWhisper, .sherpaOnly:
            return .sherpaWhisper
        case .megaASR:
            return .megaASR
        case .localWhisper:
            return .whisper
        case .appleSpeech:
            return .appleSpeech
        }
    }

    private func failLocalWhisper(_ error: Error) {
        recordingSessionID = UUID()
        sherpaLive.cancel()
        whisperRecorder.cancel()
        whisperRecorder.onMeter = nil
        activeRecorder?.cancel()
        activeRecorder = nil
        let handler = errorHandler
        clearHandlers()
        activeBackend = nil
        handler?(error)
    }

    private func failSherpaOnly(_ error: Error) {
        recordingSessionID = UUID()
        sherpaLive.cancel()
        let handler = errorHandler
        clearHandlers()
        activeBackend = nil
        handler?(error)
    }

    private func clearHandlers() {
        partialHandler = nil
        completionHandler = nil
        errorHandler = nil
    }
}
