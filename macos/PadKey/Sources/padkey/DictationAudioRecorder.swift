import Foundation

protocol DictationAudioRecorder: AnyObject {
    var recordingActive: Bool { get }
    var onMeter: ((VoiceMeterFrame) -> Void)? { get set }
    func start() throws
    func stop() throws -> URL
    func cancel()
}

enum PadKeyAudioFileWriter {
    static func capturesDirectory() throws -> URL {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("PadKey/Captures", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    static func newCaptureURL(prefix: String = "padkey-capture") throws -> URL {
        try capturesDirectory()
            .appendingPathComponent("\(prefix)-\(Self.timestamp())-\(UUID().uuidString.prefix(8))")
            .appendingPathExtension("wav")
    }

    static func wavHeader(dataSize: UInt32, sampleRate: UInt32 = 16_000) -> Data {
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

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }
}

final class PadKeyHardwareAudioRecorder: DictationAudioRecorder {
    private let source: PadKeyInputSource
    private let service: PadKeyHardwareAudioService
    private let queue = DispatchQueue(label: "com.stellarlyyd.padkey.hardware-recorder")
    private var outputURL: URL?
    private var outputHandle: FileHandle?
    private var dataBytesWritten = 0
    private var subscriptionID: UUID?
    private var isRecording = false
    private var samplesWritten = 0

    var onMeter: ((VoiceMeterFrame) -> Void)?

    var recordingActive: Bool {
        isRecording
    }

    init(source: PadKeyInputSource, service: PadKeyHardwareAudioService = .shared) {
        self.source = source
        self.service = service
    }

    func start() throws {
        guard !isRecording else { return }
        guard let channel = source.channel else {
            throw WhisperRecordingError.microphoneUnavailable
        }

        let status = service.status
        switch source {
        case .padKeyBLE:
            guard status.bleConnected else { throw PadKeyHardwareRecordingError.hardwareDisconnected(source.displayName) }
        case .padKeyUSB:
            guard status.usbConnected else { throw PadKeyHardwareRecordingError.hardwareDisconnected(source.displayName) }
        case .padKeyWiFi:
            guard status.wifiConnected else { throw PadKeyHardwareRecordingError.hardwareDisconnected(source.displayName) }
        case .systemAudio:
            throw WhisperRecordingError.microphoneUnavailable
        }

        let url = try PadKeyAudioFileWriter.newCaptureURL(prefix: source.commandSource)
        FileManager.default.createFile(atPath: url.path, contents: PadKeyAudioFileWriter.wavHeader(dataSize: 0))
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()

        outputURL = url
        outputHandle = handle
        dataBytesWritten = 0
        samplesWritten = 0
        isRecording = true
        service.setSelectedChannel(channel)
        subscriptionID = service.subscribe { [weak self] frame in
            self?.handle(frame: frame)
        }
    }

    func stop() throws -> URL {
        guard isRecording, let outputURL else {
            throw WhisperRecordingError.notRecording
        }

        if let subscriptionID {
            service.unsubscribe(subscriptionID)
        }
        subscriptionID = nil

        queue.sync {
            self.finalize()
        }

        isRecording = false
        self.outputURL = nil
        onMeter?(.idle)

        guard samplesWritten > 0 else {
            throw PadKeyHardwareRecordingError.noHardwareAudio(source.displayName)
        }

        return outputURL
    }

    func cancel() {
        if let subscriptionID {
            service.unsubscribe(subscriptionID)
        }
        subscriptionID = nil
        let url = outputURL
        queue.sync {
            try? self.outputHandle?.close()
            self.outputHandle = nil
            self.dataBytesWritten = 0
            self.samplesWritten = 0
        }
        if let url {
            try? FileManager.default.removeItem(at: url)
        }
        outputURL = nil
        isRecording = false
        onMeter?(.idle)
    }

    private func handle(frame: PadKeyAudioFrame) {
        guard isRecording, frame.channel == source.channel else { return }
        let targetSamples = Self.resampleTo16k(frame.samples, from: frame.sampleRate)
        guard !targetSamples.isEmpty else { return }
        onMeter?(VoiceMeterFrame.from(int16Samples: targetSamples))
        queue.async { [weak self] in
            guard let self, let outputHandle = self.outputHandle else { return }
            var data = Data(capacity: targetSamples.count * MemoryLayout<Int16>.size)
            for sample in targetSamples {
                var littleEndianSample = sample.littleEndian
                withUnsafeBytes(of: &littleEndianSample) { bytes in
                    data.append(contentsOf: bytes)
                }
            }
            do {
                try outputHandle.write(contentsOf: data)
                self.dataBytesWritten += data.count
                self.samplesWritten += targetSamples.count
            } catch {
                return
            }
        }
    }

    private func finalize() {
        guard let outputHandle else { return }
        let dataSize = UInt32(min(dataBytesWritten, Int(UInt32.max)))
        do {
            try outputHandle.seek(toOffset: 0)
            try outputHandle.write(contentsOf: PadKeyAudioFileWriter.wavHeader(dataSize: dataSize))
            try outputHandle.close()
        } catch {
            try? outputHandle.close()
        }
        self.outputHandle = nil
        dataBytesWritten = 0
    }

    private static func resampleTo16k(_ samples: [Int16], from sourceRate: Int) -> [Int16] {
        guard !samples.isEmpty else { return [] }
        guard sourceRate != 16_000 else { return samples }
        guard sourceRate > 0 else { return samples }

        let ratio = Double(16_000) / Double(sourceRate)
        let outputCount = max(1, Int((Double(samples.count) * ratio).rounded()))
        var output = [Int16]()
        output.reserveCapacity(outputCount)
        for index in 0..<outputCount {
            let sourcePosition = Double(index) / ratio
            let left = min(samples.count - 1, Int(sourcePosition.rounded(.down)))
            let right = min(samples.count - 1, left + 1)
            let fraction = sourcePosition - Double(left)
            let interpolated = Double(samples[left]) * (1 - fraction) + Double(samples[right]) * fraction
            output.append(Int16(clamping: Int(interpolated.rounded())))
        }
        return output
    }
}

enum PadKeyHardwareRecordingError: LocalizedError {
    case hardwareDisconnected(String)
    case noHardwareAudio(String)

    var errorDescription: String? {
        switch self {
        case .hardwareDisconnected(let source):
            return "\(source) is selected, but the PadKey hardware stream is not connected. Connect that transport or explicitly select MacBook microphone."
        case .noHardwareAudio(let source):
            return "\(source) was selected, but no audio frames arrived during capture. Check BLE streaming, selected sensor, and firmware."
        }
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
