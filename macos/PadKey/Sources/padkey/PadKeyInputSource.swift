import Foundation

enum PadKeySensorChannel: String, Codable, CaseIterable {
    case inmp441
    case max4466
    case piezo

    var displayName: String {
        switch self {
        case .inmp441: return "INMP441"
        case .max4466: return "MAX4466"
        case .piezo: return "Piezo"
        }
    }

    var bleSourceId: Int {
        switch self {
        case .inmp441: return 0
        case .max4466: return 1
        case .piezo: return 2
        }
    }

    static func fromBLESourceId(_ sourceId: Int) -> PadKeySensorChannel {
        switch sourceId {
        case 0: return .inmp441
        case 2: return .piezo
        default: return .max4466
        }
    }
}

enum PadKeyInputSource: Codable, Equatable {
    case padKeyBLE(channel: PadKeySensorChannel)
    case padKeyUSB(channel: PadKeySensorChannel)
    case padKeyWiFi(channel: PadKeySensorChannel)
    case systemAudio(deviceID: String?)

    private enum CodingKeys: String, CodingKey {
        case kind
        case channel
        case deviceID
    }

    private enum Kind: String, Codable {
        case padKeyBLE
        case padKeyUSB
        case padKeyWiFi
        case systemAudio
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .kind)
        let channel = try container.decodeIfPresent(PadKeySensorChannel.self, forKey: .channel) ?? .inmp441
        switch kind {
        case .padKeyBLE:
            self = .padKeyBLE(channel: channel)
        case .padKeyUSB:
            self = .padKeyUSB(channel: channel)
        case .padKeyWiFi:
            self = .padKeyWiFi(channel: channel)
        case .systemAudio:
            self = .systemAudio(deviceID: try container.decodeIfPresent(String.self, forKey: .deviceID))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .padKeyBLE(let channel):
            try container.encode(Kind.padKeyBLE, forKey: .kind)
            try container.encode(channel, forKey: .channel)
        case .padKeyUSB(let channel):
            try container.encode(Kind.padKeyUSB, forKey: .kind)
            try container.encode(channel, forKey: .channel)
        case .padKeyWiFi(let channel):
            try container.encode(Kind.padKeyWiFi, forKey: .kind)
            try container.encode(channel, forKey: .channel)
        case .systemAudio(let deviceID):
            try container.encode(Kind.systemAudio, forKey: .kind)
            try container.encodeIfPresent(deviceID, forKey: .deviceID)
        }
    }

    var channel: PadKeySensorChannel? {
        switch self {
        case .padKeyBLE(let channel), .padKeyUSB(let channel), .padKeyWiFi(let channel):
            return channel
        case .systemAudio:
            return nil
        }
    }

    var transportName: String {
        switch self {
        case .padKeyBLE: return "Bluetooth"
        case .padKeyUSB: return "USB"
        case .padKeyWiFi: return "Wi‑Fi"
        case .systemAudio: return "System mic"
        }
    }

    var isPadKeyHardware: Bool {
        switch self {
        case .padKeyBLE, .padKeyUSB, .padKeyWiFi: return true
        case .systemAudio: return false
        }
    }

    var displayName: String {
        switch self {
        case .padKeyBLE(let channel): return "PadKey BLE · \(channel.displayName)"
        case .padKeyUSB(let channel): return "PadKey USB · \(channel.displayName)"
        case .padKeyWiFi(let channel): return "PadKey Wi‑Fi · \(channel.displayName)"
        case .systemAudio: return "MacBook microphone"
        }
    }

    var commandSource: String {
        switch self {
        case .padKeyBLE(let channel): return "padkey_ble_\(channel.rawValue)"
        case .padKeyUSB(let channel): return "padkey_usb_\(channel.rawValue)"
        case .padKeyWiFi(let channel): return "padkey_wifi_\(channel.rawValue)"
        case .systemAudio: return "system_microphone"
        }
    }

    var statusDetail: String {
        isPadKeyHardware
            ? "Commands and dictation use PadKey hardware. MacBook mic fallback is off."
            : "Commands and dictation use the selected Mac audio input."
    }

    static let defaultHardware = PadKeyInputSource.padKeyBLE(channel: .inmp441)
}

struct PadKeyHardwareStreamStatus: Codable, Equatable {
    var bleConnected: Bool
    var usbConnected: Bool
    var wifiConnected: Bool
    var selectedChannel: PadKeySensorChannel
    var lastChannel: PadKeySensorChannel?
    var sampleRate: Int
    var packetCount: Int
    var lastPacketAt: Date?
    var batteryPercent: Int?
    var latestPeak: Int
    var latestRMS: Double
    var lastError: String?

    static let empty = PadKeyHardwareStreamStatus(
        bleConnected: false,
        usbConnected: false,
        wifiConnected: false,
        selectedChannel: .inmp441,
        lastChannel: nil,
        sampleRate: 0,
        packetCount: 0,
        lastPacketAt: nil,
        batteryPercent: nil,
        latestPeak: 0,
        latestRMS: 0,
        lastError: nil
    )
}

extension Notification.Name {
    static let padKeyInputSourceDidChange = Notification.Name("PadKeyInputSourceDidChange")
    static let padKeyHardwareStreamDidUpdate = Notification.Name("PadKeyHardwareStreamDidUpdate")
}
