import AppKit
import CoreBluetooth
import WebKit

final class PadKeySensorBridge: NSObject, WKScriptMessageHandler, CBCentralManagerDelegate, CBPeripheralDelegate {
    private static let serviceUUID = CBUUID(string: "7f23c000-2c44-4e7d-9f53-000000000001")
    private static let telemetryUUID = CBUUID(string: "7f23c001-2c44-4e7d-9f53-000000000001")
    private static let audioUUID = CBUUID(string: "7f23c002-2c44-4e7d-9f53-000000000001")
    private static let controlUUID = CBUUID(string: "7f23c003-2c44-4e7d-9f53-000000000001")
    private static let batteryServiceUUID = CBUUID(string: "180F")
    private static let batteryLevelUUID = CBUUID(string: "2A19")

    private weak var webView: WKWebView?
    private lazy var central = CBCentralManager(delegate: self, queue: .main)
    private var shouldConnectBLE = false
    private var peripheral: CBPeripheral?
    private var controlCharacteristic: CBCharacteristic?
    private var serialHandle: FileHandle?
    private var serialPath: String?

    func attach(webView: WKWebView) {
        self.webView = webView
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let action = body["action"] as? String else { return }
        switch action {
        case "connectBLE": connectBLE()
        case "disconnectBLE": disconnectBLE()
        case "setBLEStreaming":
            let enabled = body["enabled"] as? Bool ?? true
            writeControl(["type": "set_streaming", "enabled": enabled])
        case "setBLESource":
            let sourceID = body["sourceId"] as? Int ?? 0
            PadKeyHardwareAudioService.shared.setSelectedChannel(PadKeySensorChannel.fromBLESourceId(sourceID))
            writeControl(["type": "set_source", "sourceId": sourceID])
        case "connectSerial":
            connectSerial(baudRate: body["baudRate"] as? Int ?? 921_600)
        case "disconnectSerial": disconnectSerial()
        default: break
        }
    }

    func shutdown() {
        disconnectSerial()
        disconnectBLE()
    }

    private func connectBLE() {
        shouldConnectBLE = true
        _ = central
        if central.state == .poweredOn {
            central.scanForPeripherals(withServices: [Self.serviceUUID], options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
            emit(type: "ble-status", values: ["status": "connecting"])
        }
    }

    private func disconnectBLE() {
        shouldConnectBLE = false
        central.stopScan()
        if let peripheral { central.cancelPeripheralConnection(peripheral) }
        peripheral = nil
        controlCharacteristic = nil
        PadKeyHardwareAudioService.shared.updateBLEConnection(connected: false)
        emit(type: "ble-status", values: ["status": "disconnected"])
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard shouldConnectBLE else { return }
        guard central.state == .poweredOn else {
            emit(type: "ble-status", values: ["status": "error", "message": "Bluetooth is unavailable or disabled on this Mac."])
            return
        }
        central.scanForPeripherals(withServices: [Self.serviceUUID], options: nil)
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard peripheral.name?.hasPrefix("PadKey") == true || (advertisementData[CBAdvertisementDataLocalNameKey] as? String)?.hasPrefix("PadKey") == true else { return }
        central.stopScan()
        self.peripheral = peripheral
        peripheral.delegate = self
        central.connect(peripheral, options: nil)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices([Self.serviceUUID, Self.batteryServiceUUID])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        PadKeyHardwareAudioService.shared.updateBLEConnection(connected: false, error: error?.localizedDescription ?? "PadKey BLE connection failed.")
        emit(type: "ble-status", values: ["status": "error", "message": error?.localizedDescription ?? "PadKey BLE connection failed."])
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        self.peripheral = nil
        controlCharacteristic = nil
        PadKeyHardwareAudioService.shared.updateBLEConnection(connected: false, error: error?.localizedDescription)
        emit(type: "ble-status", values: ["status": error == nil ? "disconnected" : "error", "message": error?.localizedDescription ?? ""])
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error {
            emit(type: "ble-status", values: ["status": "error", "message": error.localizedDescription])
            return
        }
        for service in peripheral.services ?? [] {
            if service.uuid == Self.serviceUUID {
                peripheral.discoverCharacteristics([Self.telemetryUUID, Self.audioUUID, Self.controlUUID], for: service)
            } else if service.uuid == Self.batteryServiceUUID {
                peripheral.discoverCharacteristics([Self.batteryLevelUUID], for: service)
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error {
            emit(type: "ble-status", values: ["status": "error", "message": error.localizedDescription])
            return
        }
        for characteristic in service.characteristics ?? [] {
            switch characteristic.uuid {
            case Self.telemetryUUID, Self.audioUUID, Self.batteryLevelUUID:
                peripheral.setNotifyValue(true, for: characteristic)
                if characteristic.uuid == Self.batteryLevelUUID { peripheral.readValue(for: characteristic) }
            case Self.controlUUID:
                controlCharacteristic = characteristic
                writeControl(["type": "set_streaming", "enabled": true])
            default: break
            }
        }
        if service.uuid == Self.serviceUUID {
            PadKeyHardwareAudioService.shared.updateBLEConnection(connected: true)
            emit(type: "ble-status", values: ["status": "connected", "name": peripheral.name ?? "PadKey-S3"])
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil, let data = characteristic.value else { return }
        switch characteristic.uuid {
        case Self.telemetryUUID:
            emit(type: "ble-telemetry", values: ["text": String(data: data, encoding: .utf8) ?? ""])
        case Self.audioUUID:
            PadKeyHardwareAudioService.shared.handleBLEAudio(data)
            emit(type: "ble-audio", values: ["base64": data.base64EncodedString()])
        case Self.batteryLevelUUID:
            if let level = data.first {
                PadKeyHardwareAudioService.shared.updateBattery(percent: Int(level))
                emit(type: "ble-battery", values: ["percent": Int(level)])
            }
        default: break
        }
    }

    private func writeControl(_ object: [String: Any]) {
        guard let peripheral, let characteristic = controlCharacteristic,
              let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        let type: CBCharacteristicWriteType = characteristic.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse
        peripheral.writeValue(data, for: characteristic, type: type)
    }

    private func connectSerial(baudRate: Int) {
        disconnectSerial()
        let candidates = (try? FileManager.default.contentsOfDirectory(atPath: "/dev")) ?? []
        let names = candidates.filter {
            $0.hasPrefix("cu.usbmodem") || $0.hasPrefix("cu.usbserial") || $0.hasPrefix("cu.wchusbserial") || $0.hasPrefix("cu.SLAB_USBtoUART")
        }.sorted()
        guard let name = names.first else {
            PadKeyHardwareAudioService.shared.updateUSBConnection(connected: false, error: "No PadKey USB serial device was found.")
            emit(type: "serial-status", values: ["status": "error", "message": "No PadKey USB serial device was found."])
            return
        }
        let path = "/dev/\(name)"
        do {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/stty")
            process.arguments = ["-f", path, String(baudRate), "raw", "-echo"]
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw CocoaError(.fileReadNoPermission) }
            let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
            serialHandle = handle
            serialPath = path
            PadKeyHardwareAudioService.shared.updateUSBConnection(connected: true)
            handle.readabilityHandler = { [weak self] source in
                let data = source.availableData
                guard !data.isEmpty else { return }
                PadKeyHardwareAudioService.shared.handleSerialData(data)
                self?.emit(type: "serial-data", values: ["base64": data.base64EncodedString()])
            }
            emit(type: "serial-status", values: ["status": "connected", "name": name])
        } catch {
            PadKeyHardwareAudioService.shared.updateUSBConnection(connected: false, error: error.localizedDescription)
            emit(type: "serial-status", values: ["status": "error", "message": "Could not open \(name): \(error.localizedDescription)"])
        }
    }

    private func disconnectSerial() {
        serialHandle?.readabilityHandler = nil
        try? serialHandle?.close()
        serialHandle = nil
        serialPath = nil
        PadKeyHardwareAudioService.shared.updateUSBConnection(connected: false)
        emit(type: "serial-status", values: ["status": "disconnected"])
    }

    private func emit(type: String, values: [String: Any]) {
        var payload = values
        payload["type"] = type
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else { return }
        DispatchQueue.main.async { [weak self] in
            self?.webView?.evaluateJavaScript("window.dispatchEvent(new CustomEvent('padkey-native', { detail: \(json) }));")
        }
    }
}
