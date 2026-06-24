import AVFoundation
import Foundation

struct VoiceMeterFrame {
    static let bandCount = 32
    static let idle = VoiceMeterFrame(level: 0, bands: Array(repeating: 0, count: bandCount))

    let level: Double
    let bands: [Double]

    static func from(buffer: AVAudioPCMBuffer, bandCount: Int = Self.bandCount) -> VoiceMeterFrame {
        guard
            bandCount > 0,
            buffer.frameLength > 0,
            let channels = buffer.floatChannelData
        else {
            return .idle
        }

        let frameCount = Int(buffer.frameLength)
        let channelCount = max(1, Int(buffer.format.channelCount))
        let framesPerBand = max(1, frameCount / bandCount)
        var bands = Array(repeating: 0.0, count: bandCount)
        var totalSquares = 0.0
        var totalSamples = 0

        for band in 0..<bandCount {
            let start = band * framesPerBand
            let end = band == bandCount - 1 ? frameCount : min(frameCount, start + framesPerBand)
            guard start < end else { continue }

            var squares = 0.0
            var samples = 0
            for channelIndex in 0..<channelCount {
                let channel = channels[channelIndex]
                for frameIndex in start..<end {
                    let sample = Double(channel[frameIndex])
                    squares += sample * sample
                    samples += 1
                }
            }

            guard samples > 0 else { continue }
            totalSquares += squares
            totalSamples += samples
            bands[band] = compressedLevel(rootMeanSquare: sqrt(squares / Double(samples)))
        }

        let rms = totalSamples > 0 ? sqrt(totalSquares / Double(totalSamples)) : 0
        return VoiceMeterFrame(level: compressedLevel(rootMeanSquare: rms), bands: bands)
    }

    private static func compressedLevel(rootMeanSquare rms: Double) -> Double {
        let noiseFloor = 0.006
        let normalized = max(0, rms - noiseFloor) * 9.5
        return min(1, pow(normalized, 0.58))
    }
}
