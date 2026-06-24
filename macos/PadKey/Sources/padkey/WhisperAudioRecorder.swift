import AVFoundation
import Foundation

final class WhisperAudioRecorder {
    private let audioEngine = AVAudioEngine()
    private let recordingQueue = DispatchQueue(label: "com.stellarlyyd.padkey.whisper-recorder")

    private var converter: AVAudioConverter?
    private var outputFormat: AVAudioFormat?
    private var outputURL: URL?
    private var outputHandle: FileHandle?
    private var dataBytesWritten = 0
    private var tapInstalled = false
    private var isRecording = false
    var onMeter: ((VoiceMeterFrame) -> Void)?

    var recordingActive: Bool {
        isRecording
    }

    func start() throws {
        guard !isRecording else { return }

        let inputNode = audioEngine.inputNode
        if tapInstalled {
            inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        if audioEngine.isRunning {
            audioEngine.stop()
        }

        let inputFormat = inputNode.outputFormat(forBus: 0)
        guard inputFormat.channelCount > 0, inputFormat.sampleRate > 0 else {
            throw WhisperRecordingError.microphoneUnavailable
        }

        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ) else {
            throw WhisperRecordingError.outputFormatUnavailable
        }

        let temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("padkey-\(UUID().uuidString)")
            .appendingPathExtension("wav")

        FileManager.default.createFile(atPath: temporaryURL.path, contents: Self.wavHeader(dataSize: 0))
        let handle = try FileHandle(forWritingTo: temporaryURL)
        try handle.seekToEnd()

        converter = AVAudioConverter(from: inputFormat, to: targetFormat)
        outputFormat = targetFormat
        outputURL = temporaryURL
        outputHandle = handle
        dataBytesWritten = 0

        inputNode.installTap(onBus: 0, bufferSize: 2048, format: inputFormat) { [weak self] buffer, _ in
            guard let copiedBuffer = Self.copy(buffer) else { return }
            self?.onMeter?(VoiceMeterFrame.from(buffer: copiedBuffer))
            self?.write(copiedBuffer)
        }
        tapInstalled = true

        audioEngine.prepare()
        do {
            try audioEngine.start()
            isRecording = true
        } catch {
            cancel()
            throw error
        }
    }

    func stop() throws -> URL {
        guard isRecording, let outputURL else {
            throw WhisperRecordingError.notRecording
        }

        if tapInstalled {
            audioEngine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }

        audioEngine.stop()
        recordingQueue.sync {
            self.finalizeWAVFile()
            self.converter = nil
            self.outputFormat = nil
        }

        isRecording = false
        self.outputURL = nil
        onMeter?(.idle)
        return outputURL
    }

    func cancel() {
        if tapInstalled {
            audioEngine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }

        audioEngine.stop()

        let url = outputURL
        recordingQueue.sync {
            try? self.outputHandle?.close()
            self.outputHandle = nil
            self.converter = nil
            self.outputFormat = nil
            self.dataBytesWritten = 0
        }

        if let url {
            try? FileManager.default.removeItem(at: url)
        }

        outputURL = nil
        isRecording = false
        onMeter?(.idle)
    }

    private func write(_ buffer: AVAudioPCMBuffer) {
        recordingQueue.async { [weak self] in
            guard
                let self,
                let converter = self.converter,
                let outputFormat = self.outputFormat,
                let outputHandle = self.outputHandle
            else {
                return
            }

            let ratio = outputFormat.sampleRate / buffer.format.sampleRate
            let frameCapacity = AVAudioFrameCount(max(1, Double(buffer.frameLength) * ratio + 16))
            guard let convertedBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: frameCapacity) else {
                return
            }

            var didProvideInput = false
            var conversionError: NSError?
            let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
                if didProvideInput {
                    outStatus.pointee = .noDataNow
                    return nil
                }

                didProvideInput = true
                outStatus.pointee = .haveData
                return buffer
            }

            converter.convert(to: convertedBuffer, error: &conversionError, withInputFrom: inputBlock)

            guard conversionError == nil, convertedBuffer.frameLength > 0 else {
                return
            }

            guard let pcmData = Self.int16PCMData(from: convertedBuffer), !pcmData.isEmpty else {
                return
            }

            do {
                try outputHandle.write(contentsOf: pcmData)
                self.dataBytesWritten += pcmData.count
            } catch {
                return
            }
        }
    }

    private func finalizeWAVFile() {
        guard let outputHandle else { return }
        let dataSize = UInt32(min(dataBytesWritten, Int(UInt32.max)))
        do {
            try outputHandle.seek(toOffset: 0)
            try outputHandle.write(contentsOf: Self.wavHeader(dataSize: dataSize))
            try outputHandle.close()
        } catch {
            try? outputHandle.close()
        }
        self.outputHandle = nil
        dataBytesWritten = 0
    }

    private static func copy(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else {
            return nil
        }

        copy.frameLength = buffer.frameLength
        let sourceBuffers = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        let destinationBuffers = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)

        for index in 0..<min(sourceBuffers.count, destinationBuffers.count) {
            guard
                let source = sourceBuffers[index].mData,
                let destination = destinationBuffers[index].mData
            else {
                continue
            }

            let byteCount = Int(sourceBuffers[index].mDataByteSize)
            memcpy(destination, source, byteCount)
            destinationBuffers[index].mDataByteSize = sourceBuffers[index].mDataByteSize
        }

        return copy
    }

    private static func int16PCMData(from buffer: AVAudioPCMBuffer) -> Data? {
        guard let channel = buffer.floatChannelData?[0] else { return nil }

        let frameCount = Int(buffer.frameLength)
        var data = Data(capacity: frameCount * MemoryLayout<Int16>.size)
        let gain = Self.automaticGain(for: channel, frameCount: frameCount)

        for index in 0..<frameCount {
            let sample = max(-1, min(1, channel[index] * gain))
            let intSample: Int16 = sample <= -1 ? Int16.min : Int16(sample * Float(Int16.max))
            var littleEndianSample = intSample.littleEndian
            withUnsafeBytes(of: &littleEndianSample) { bytes in
                data.append(contentsOf: bytes)
            }
        }

        return data
    }

    private static func automaticGain(for channel: UnsafePointer<Float>, frameCount: Int) -> Float {
        guard frameCount > 0 else { return 1 }

        var squares = 0.0
        var peak: Float = 0
        for index in 0..<frameCount {
            let sample = channel[index]
            squares += Double(sample * sample)
            peak = max(peak, abs(sample))
        }

        let rms = sqrt(squares / Double(frameCount))
        guard rms > 0.004, peak > 0 else { return 1 }

        let targetRMS = 0.075
        let desiredGain = Float(targetRMS / rms)
        let quietBoost = min(3.8, max(1, desiredGain))
        let peakSafeGain = min(quietBoost, 0.98 / max(peak, 0.001))
        return max(1, peakSafeGain)
    }

    private static func wavHeader(dataSize: UInt32) -> Data {
        let sampleRate: UInt32 = 16_000
        let channels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let byteRate = sampleRate * UInt32(channels) * UInt32(bitsPerSample) / 8
        let blockAlign = channels * bitsPerSample / 8

        var data = Data(capacity: 44)
        data.append(contentsOf: [0x52, 0x49, 0x46, 0x46])
        data.appendLittleEndian(36 + dataSize)
        data.append(contentsOf: [0x57, 0x41, 0x56, 0x45])
        data.append(contentsOf: [0x66, 0x6D, 0x74, 0x20])
        data.appendLittleEndian(UInt32(16))
        data.appendLittleEndian(UInt16(1))
        data.appendLittleEndian(channels)
        data.appendLittleEndian(sampleRate)
        data.appendLittleEndian(byteRate)
        data.appendLittleEndian(blockAlign)
        data.appendLittleEndian(bitsPerSample)
        data.append(contentsOf: [0x64, 0x61, 0x74, 0x61])
        data.appendLittleEndian(dataSize)
        return data
    }
}

private extension Data {
    mutating func appendLittleEndian(_ value: UInt16) {
        var littleEndianValue = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndianValue) { append(contentsOf: $0) }
    }

    mutating func appendLittleEndian(_ value: UInt32) {
        var littleEndianValue = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndianValue) { append(contentsOf: $0) }
    }
}

enum WhisperRecordingError: LocalizedError {
    case microphoneUnavailable
    case outputFormatUnavailable
    case notRecording

    var errorDescription: String? {
        switch self {
        case .microphoneUnavailable:
            return "PadKey could not access a microphone input."
        case .outputFormatUnavailable:
            return "PadKey could not create a 16 kHz WAV recording for Whisper."
        case .notRecording:
            return "PadKey was not recording audio."
        }
    }
}
