import XCTest
@testable import padkey

final class PipelineDiagnosticsTests: XCTestCase {
    func testTranscriptQualityRetriesEmptyOrRepeatedText() {
        XCTAssertTrue(TranscriptQuality.shouldRetryWithRobustASR("", duration: 3))
        XCTAssertTrue(TranscriptQuality.shouldRetryWithRobustASR("hello hello hello hello hello hello", duration: 5))
        XCTAssertFalse(TranscriptQuality.shouldRetryWithRobustASR("This is a clear dictated sentence with enough signal.", duration: 5))
    }

    func testPipelineSettingsDefaultsToAutoRobustWithRetry() {
        let settings = PipelineSettings(
            recognitionEngine: nil,
            sessionTimeoutSeconds: 999,
            autoPolishAfterDictation: false,
            commandModeEnabled: true,
            copyFallbackEnabled: true,
            keepRawHistory: true,
            robustRetryEnabled: nil,
            robustRetryMinDurationSeconds: nil
        ).normalized()

        XCTAssertEqual(settings.effectiveRecognitionEngine, .autoRobust)
        XCTAssertTrue(settings.effectiveRobustRetryEnabled)
        XCTAssertEqual(settings.sessionTimeoutSeconds, PipelineSettings.defaults.sessionTimeoutSeconds)
    }

    func testPolishPromptIncludesTargetContextAndVoiceProfile() {
        let prompt = PolishPromptBuilder.prompt(
            input: "um send this tomorrow",
            instruction: "Polish without changing meaning.",
            voiceContext: "Preferred spellings: PadKey.",
            context: PolishContext(targetAppName: "Slack", targetBundleID: "com.tinyspeck.slackmacgap")
        )

        XCTAssertTrue(prompt.contains("Slack"))
        XCTAssertTrue(prompt.contains("chat"))
        XCTAssertTrue(prompt.contains("Preferred spellings: PadKey."))
        XCTAssertTrue(prompt.contains("um send this tomorrow"))
    }

    func testMegaASRCleansDiagnosticLines() {
        let output = """
        crispasr system info
        loading model
        qwen3_asr: loaded mega-asr-1.7b-q4_k.gguf
        ggml_metal_init: allocating
        crispasr: audio: 91307 samples
        language EnglishThis is the transcript.
        whisper_model_load: loading model
        crisp_audio: loaded dialect=qwen_omni
        ggml_metal_free: deallocating
        warning: ignored
        It continues here.
        """

        XCTAssertEqual(MegaASRTranscriber.cleanedTranscript(output), "This is the transcript. It continues here.")
    }

    func testTextCleanupCourseCorrectionBasics() {
        XCTAssertEqual(TextCleanup.clean("um hello comma new line bullet point ship it"), "hello,\n- ship it")
    }
}
