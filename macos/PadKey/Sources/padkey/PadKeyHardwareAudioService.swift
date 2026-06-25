import Foundation

struct PadKeyAudioFrame {
    var channel: PadKeySensorChannel
    var sampleRate: Int
    var samples: [Int16]
    var sequence: UInt32?
    var receivedAt: Date
}

final class PadKeyHardwareAudioService {
    static let shared = PadKeyHardwareAudioService()

    private let queue = DispatchQueue(label: "com.stellarlyyd.padkey.hardware-audio")
    private var subscribers: [UUID: (PadKeyAudioFrame) -> Void] = [:]
    private var serialTextBuffer = Data()
    private(set) var status = PadKeyHardwareStreamStatus.empty

    private init() {}

    func subscribe(_ handler: @escaping (PadKeyAudioFrame) -> Void) -> UUID {
        let id = UUID()
        queue.async { self.subscribers[id] = handler }
        return id
    }

    func unsubscribe(_ id: UUID) {
        queue.async { self.subscribers[id] = nil }
    }

    func setSelectedChannel(_ channel: PadKeySensorChannel) {
        queue.async {
            self.status.selectedChannel = channel
            self.postStatus()
        }
    }

    func updateBLEConnection(connected: Bool, error: String? = nil) {
        queue.async {
            self.status.bleConnected = connected
            self.status.lastError = error
            self.postStatus()
        }
    }

    func updateUSBConnection(connected: Bool, error: String? = nil) {
        queue.async {
            self.status.usbConnected = connected
            self.status.lastError = error
            self.postStatus()
        }
    }

    func updateBattery(percent: Int) {
        queue.async {
            self.status.batteryPercent = max(0, min(100, percent))
            self.postStatus()
        }
    }

    func handleBLEAudio(_ data: Data) {
        handleBinaryAudio(data)
    }

    func handleSerialData(_ data: Data) {
        if data.starts(with: [0x50, 0x4B, 0x41, 0x55]) {
            handleBinaryAudio(data)
            return
        }

        queue.async {
            self.serialTextBuffer.append(data)
            while let newline = self.serialTextBuffer.firstIndex(of: 0x0A) {
                let lineData = self.serialTextBuffer.prefix(upTo: newline)
                self.serialTextBuffer.removeSubrange(...newline)
                guard let line = String(data: lineData, encoding: .utf8) else { continue }
                self.handleSerialLine(line)
            }
        }
    }

    private func handleSerialLine(_ line: String) {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (object["type"] as? String) == "audio",
              (object["format"] as? String) == "pcm_s16le"
        else {
            return
        }

        let channel = PadKeySensorChannel(rawValue: String(describing: object["channel"] ?? "inmp441")) ?? .inmp441
        let sampleRate = max(8_000, min(96_000, Int(truncating: object["sampleRate"] as? NSNumber ?? 16_000)))
        let samples: [Int16]
        if let base64 = object["pcm"] as? String, let decoded = Data(base64Encoded: base64) {
            samples = Self.pcmSamples(from: decoded, offset: 0)
        } else if let values = object["samples"] as? [NSNumber] {
            samples = values.map { Int16(clamping: $0.intValue) }
        } else {
            samples = []
        }

        guard !samples.isEmpty else { return }
        publish(PadKeyAudioFrame(channel: channel, sampleRate: sampleRate, samples: samples, sequence: object["sequence"] as? UInt32, receivedAt: Date()))
    }

    private func handleBinaryAudio(_ data: Data) {
        let frames = Self.parseBinaryAudioFrames(data)
        guard !frames.isEmpty else { return }
        queue.async {
            for frame in frames {
                self.publish(frame)
            }
        }
    }

    private func publish(_ frame: PadKeyAudioFrame) {
        let peak = frame.samples.reduce(0) { max($0, abs(Int($1))) }
        let squareSum = frame.samples.reduce(0.0) { $0 + Double($1) * Double($1) }
        status.lastChannel = frame.channel
        status.sampleRate = frame.sampleRate
        status.packetCount += 1
        status.lastPacketAt = frame.receivedAt
        status.latestPeak = peak
        status.latestRMS = frame.samples.isEmpty ? 0 : sqrt(squareSum / Double(frame.samples.count))
        status.lastError = nil
        let callbacks = subscribers.values
        for callback in callbacks {
            callback(frame)
        }
        postStatus()
    }

    private func postStatus() {
        let snapshot = status
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .padKeyHardwareStreamDidUpdate, object: self, userInfo: ["status": snapshot])
        }
    }

    private static func parseBinaryAudioFrames(_ data: Data) -> [PadKeyAudioFrame] {
        guard data.count >= 12,
              data[0] == 0x50, data[1] == 0x4B, data[2] == 0x41, data[3] == 0x55
        else {
            return []
        }

        let version = Int(data[4])
        let channels = Int(data[5])
        let sampleRate = Int(data.uint32LE(at: 6))
        guard [1, 2, 3, 4, 5, 6].contains(version), sampleRate >= 8_000, sampleRate <= 96_000 else {
            return []
        }

        let now = Date()
        if version == 6 {
            guard data.count >= 15, channels == 3 else { return [] }
            let sequence = data.uint32LE(at: 10)
            let sampleCount = Int(data[14])
            let encodedBytes = Int(ceil(Double(sampleCount - 1) / 2.0))
            let blockBytes = 3 + encodedBytes
            guard sampleCount >= 2, data.count >= 15 + channels * blockBytes else { return [] }

            let channelNames: [PadKeySensorChannel] = [.inmp441, .max4466, .piezo]
            return channelNames.enumerated().map { index, channel in
                let offset = 15 + index * blockBytes
                return PadKeyAudioFrame(
                    channel: channel,
                    sampleRate: sampleRate,
                    samples: decodeImaADPCMBlock(data, offset: offset, sampleCount: sampleCount),
                    sequence: sequence,
                    receivedAt: now
                )
            }
        }

        guard channels == 1 else { return [] }
        let sequence: UInt32? = version >= 2 ? data.uint32LE(at: 10) : nil
        let hasSensorId = version >= 3
        let channel = hasSensorId ? PadKeySensorChannel.fromBLESourceId(Int(data[14])) : .inmp441
        let offset = hasSensorId ? 15 : (version == 2 ? 14 : 10)
        guard data.count > offset else { return [] }
        let samples = version == 5 ? muLawSamples(from: data, offset: offset) : pcmSamples(from: data, offset: offset)
        return samples.isEmpty ? [] : [PadKeyAudioFrame(channel: channel, sampleRate: sampleRate, samples: samples, sequence: sequence, receivedAt: now)]
    }

    private static func pcmSamples(from data: Data, offset: Int) -> [Int16] {
        guard data.count > offset else { return [] }
        var samples: [Int16] = []
        samples.reserveCapacity((data.count - offset) / 2)
        var index = offset
        while index + 1 < data.count {
            samples.append(Int16(bitPattern: UInt16(data[index]) | (UInt16(data[index + 1]) << 8)))
            index += 2
        }
        return samples
    }

    private static func muLawSamples(from data: Data, offset: Int) -> [Int16] {
        guard data.count > offset else { return [] }
        let bias = 0x84
        return data[offset...].map { byte in
            let value = Int((~byte) & 0xFF)
            var magnitude = ((value & 0x0F) << 3) + bias
            magnitude <<= (value & 0x70) >> 4
            return Int16(clamping: (value & 0x80) != 0 ? bias - magnitude : magnitude - bias)
        }
    }

    private static func decodeImaADPCMBlock(_ data: Data, offset: Int, sampleCount: Int) -> [Int16] {
        let indexTable = [-1, -1, -1, -1, 2, 4, 6, 8, -1, -1, -1, -1, 2, 4, 6, 8]
        let stepTable = [
            7, 8, 9, 10, 11, 12, 13, 14, 16, 17, 19, 21, 23, 25, 28, 31, 34, 37, 41, 45, 50, 55,
            60, 66, 73, 80, 88, 97, 107, 118, 130, 143, 157, 173, 190, 209, 230, 253, 279,
            307, 337, 371, 408, 449, 494, 544, 598, 658, 724, 796, 876, 963, 1060, 1166,
            1282, 1411, 1552, 1707, 1878, 2066, 2272, 2499, 2749, 3024, 3327, 3660,
            4026, 4428, 4871, 5358, 5894, 6484, 7132, 7845, 8630, 9493, 10442, 11487,
            12635, 13899, 15289, 16818, 18500, 20350, 22385, 24623, 27086, 29794, 32767
        ]
        guard data.count >= offset + 3, sampleCount > 0 else { return [] }
        var predictor = Int(Int16(bitPattern: UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)))
        var stepIndex = max(0, min(88, Int(data[offset + 2])))
        var samples = [Int16](repeating: 0, count: sampleCount)
        samples[0] = Int16(clamping: predictor)

        for sampleIndex in 1..<sampleCount {
            let nibbleIndex = sampleIndex - 1
            let packedIndex = offset + 3 + (nibbleIndex >> 1)
            guard packedIndex < data.count else { break }
            let code = Int((data[packedIndex] >> UInt8((nibbleIndex & 1) * 4)) & 0x0F)
            let step = stepTable[stepIndex]
            var delta = step >> 3
            if (code & 4) != 0 { delta += step }
            if (code & 2) != 0 { delta += step >> 1 }
            if (code & 1) != 0 { delta += step >> 2 }
            predictor += (code & 8) != 0 ? -delta : delta
            predictor = max(-32768, min(32767, predictor))
            stepIndex = max(0, min(88, stepIndex + indexTable[code]))
            samples[sampleIndex] = Int16(clamping: predictor)
        }

        return samples
    }
}

private extension Data {
    func uint32LE(at offset: Int) -> UInt32 {
        guard count >= offset + 4 else { return 0 }
        return UInt32(self[offset])
            | (UInt32(self[offset + 1]) << 8)
            | (UInt32(self[offset + 2]) << 16)
            | (UInt32(self[offset + 3]) << 24)
    }
}
