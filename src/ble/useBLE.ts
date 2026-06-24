import { useCallback, useRef } from "react";
import { useAppStore } from "../store";
import { parseBinaryAudio, parseTransportLine } from "../transport/parsePacket";

const PADKEY_SERVICE_UUID = "7f23c000-2c44-4e7d-9f53-000000000001";
const TELEMETRY_CHARACTERISTIC_UUID = "7f23c001-2c44-4e7d-9f53-000000000001";
const AUDIO_CHARACTERISTIC_UUID = "7f23c002-2c44-4e7d-9f53-000000000001";
const CONTROL_CHARACTERISTIC_UUID = "7f23c003-2c44-4e7d-9f53-000000000001";
const BATTERY_SERVICE_UUID = 0x180f;
const BATTERY_LEVEL_CHARACTERISTIC_UUID = 0x2a19;
const DEVICE_NAME_PREFIX = "PadKey";

type BLEStatus = "idle" | "connecting" | "connected" | "error";

export interface BLEController {
  connect: () => Promise<void>;
  disconnect: () => void;
  setSource: (sourceId: 0 | 1 | 2) => Promise<void>;
  setStreaming: (enabled: boolean) => Promise<void>;
  status: BLEStatus;
  error: string | null;
}

function characteristicBuffer(characteristic: BluetoothRemoteGATTCharacteristic) {
  const value = characteristic.value;
  if (!value) return null;
  return value.buffer.slice(value.byteOffset, value.byteOffset + value.byteLength) as ArrayBuffer;
}

function bleErrorMessage(error: unknown) {
  if (!(error instanceof Error)) return "BLE connection failed";
  if (error.name === "NotFoundError") return "No PadKey was selected";
  if (error.name === "SecurityError") return "Bluetooth access was blocked by the browser";
  if (/service|characteristic/i.test(error.message)) return "PadKey was found, but its BLE firmware does not match Studio";
  return error.message || "BLE connection failed";
}

async function writeControl(
  characteristic: BluetoothRemoteGATTCharacteristic | null,
  message: Record<string, unknown>
) {
  if (!characteristic) return;
  const payload = new TextEncoder().encode(JSON.stringify(message));
  const writable = characteristic as BluetoothRemoteGATTCharacteristic & {
    writeValueWithoutResponse?: (value: BufferSource) => Promise<void>;
  };
  if (writable.writeValueWithoutResponse) await writable.writeValueWithoutResponse(payload);
  else await characteristic.writeValue(payload);
}

export function useBLE(): BLEController {
  const deviceRef = useRef<BluetoothDevice | null>(null);
  const telemetryRef = useRef<BluetoothRemoteGATTCharacteristic | null>(null);
  const audioRef = useRef<BluetoothRemoteGATTCharacteristic | null>(null);
  const controlRef = useRef<BluetoothRemoteGATTCharacteristic | null>(null);
  const batteryRef = useRef<BluetoothRemoteGATTCharacteristic | null>(null);
  const telemetryBufferRef = useRef("");
  const decoderRef = useRef(new TextDecoder("utf-8"));

  const status = useAppStore((state) => state.bleStatus);
  const error = useAppStore((state) => state.bleError);
  const activeSource = useAppStore((state) => state.bleActiveSource);
  const pushFrame = useAppStore((state) => state.pushFrame);
  const pushAudioPacket = useAppStore((state) => state.pushAudioPacket);
  const setDeviceStatus = useAppStore((state) => state.setDeviceStatus);
  const setBatteryStatus = useAppStore((state) => state.setBatteryStatus);
  const setBLEConnected = useAppStore((state) => state.setBLEConnected);
  const setBLEStatus = useAppStore((state) => state.setBLEStatus);
  const setBleStreamConfig = useAppStore((state) => state.setBleStreamConfig);

  const handleTelemetry = useCallback((event: Event) => {
    const characteristic = event.target as BluetoothRemoteGATTCharacteristic;
    const buffer = characteristicBuffer(characteristic);
    if (!buffer) return;

    telemetryBufferRef.current += decoderRef.current.decode(buffer, { stream: true });
    const lines = telemetryBufferRef.current.split(/\r?\n/);
    telemetryBufferRef.current = lines.pop() ?? "";
    for (const line of lines) {
      const packet = parseTransportLine(line, "ble");
      if (packet?.kind === "telemetry") pushFrame(packet.frame);
      if (packet?.kind === "audio") pushAudioPacket(packet.audio);
      if (packet?.kind === "status") setDeviceStatus(packet.status);
    }
  }, [pushAudioPacket, pushFrame, setDeviceStatus]);

  const handleAudio = useCallback((event: Event) => {
    const characteristic = event.target as BluetoothRemoteGATTCharacteristic;
    const buffer = characteristicBuffer(characteristic);
    if (!buffer) return;
    const packet = parseBinaryAudio(buffer);
    if (packet) pushAudioPacket(packet);
  }, [pushAudioPacket]);

  const handleBattery = useCallback((event: Event) => {
    const characteristic = event.target as BluetoothRemoteGATTCharacteristic;
    const value = characteristic.value;
    if (value?.byteLength) setBatteryStatus(value.getUint8(0));
  }, [setBatteryStatus]);

  const handleDisconnect = useCallback(() => {
    telemetryRef.current = null;
    audioRef.current = null;
    controlRef.current = null;
    batteryRef.current = null;
    telemetryBufferRef.current = "";
    deviceRef.current = null;
    setBLEConnected(false);
  }, [setBLEConnected]);

  const disconnect = useCallback(() => {
    const telemetry = telemetryRef.current;
    const audio = audioRef.current;
    const battery = batteryRef.current;
    telemetry?.removeEventListener("characteristicvaluechanged", handleTelemetry);
    audio?.removeEventListener("characteristicvaluechanged", handleAudio);
    battery?.removeEventListener("characteristicvaluechanged", handleBattery);
    void telemetry?.stopNotifications().catch(() => undefined);
    void audio?.stopNotifications().catch(() => undefined);
    void battery?.stopNotifications().catch(() => undefined);

    const device = deviceRef.current;
    if (device) device.removeEventListener("gattserverdisconnected", handleDisconnect);
    if (device?.gatt?.connected) device.gatt.disconnect();
    handleDisconnect();
  }, [handleAudio, handleBattery, handleDisconnect, handleTelemetry]);

  const connect = useCallback(async () => {
    if (!navigator.bluetooth) {
      setBLEStatus("error", "Web Bluetooth is unavailable - use Chrome or Edge on macOS");
      return;
    }

    disconnect();
    setBLEStatus("connecting");

    try {
      const device = await navigator.bluetooth.requestDevice({
        filters: [{ namePrefix: DEVICE_NAME_PREFIX }],
        optionalServices: [PADKEY_SERVICE_UUID, BATTERY_SERVICE_UUID]
      });
      deviceRef.current = device;
      device.addEventListener("gattserverdisconnected", handleDisconnect);

      const server = await device.gatt?.connect();
      if (!server) throw new Error("PadKey GATT server unavailable");

      const service = await server.getPrimaryService(PADKEY_SERVICE_UUID);
      const telemetry = await service.getCharacteristic(TELEMETRY_CHARACTERISTIC_UUID);
      const audio = await service.getCharacteristic(AUDIO_CHARACTERISTIC_UUID);
      const control = await service.getCharacteristic(CONTROL_CHARACTERISTIC_UUID);
      telemetryRef.current = telemetry;
      audioRef.current = audio;
      controlRef.current = control;
      telemetry.addEventListener("characteristicvaluechanged", handleTelemetry);
      audio.addEventListener("characteristicvaluechanged", handleAudio);
      await telemetry.startNotifications();
      await audio.startNotifications();
      await writeControl(control, { type: "set_source", sourceId: activeSource });
      await writeControl(control, { type: "set_streaming", enabled: true });

      try {
        const batteryService = await server.getPrimaryService(BATTERY_SERVICE_UUID);
        const battery = await batteryService.getCharacteristic(BATTERY_LEVEL_CHARACTERISTIC_UUID);
        batteryRef.current = battery;
        battery.addEventListener("characteristicvaluechanged", handleBattery);
        const initialLevel = await battery.readValue();
        if (initialLevel.byteLength) setBatteryStatus(initialLevel.getUint8(0));
        await battery.startNotifications();
      } catch {
        // Battery telemetry also arrives in the PadKey JSON stream, so the
        // standard Battery Service remains an optional enhancement.
      }

      setBLEConnected(true, device.name ?? "PadKey-S3");
    } catch (connectionError) {
      const failedDevice = deviceRef.current;
      if (failedDevice?.gatt?.connected) failedDevice.gatt.disconnect();
      telemetryRef.current = null;
      audioRef.current = null;
      controlRef.current = null;
      batteryRef.current = null;
      telemetryBufferRef.current = "";
      deviceRef.current = null;
      setBLEStatus("error", bleErrorMessage(connectionError));
    }
  }, [activeSource, disconnect, handleAudio, handleBattery, handleDisconnect, handleTelemetry, setBatteryStatus, setBLEConnected, setBLEStatus]);

  const setSource = useCallback(async (sourceId: 0 | 1 | 2) => {
    setBleStreamConfig(sourceId, 8000);
    await writeControl(controlRef.current, { type: "set_source", sourceId });
  }, [setBleStreamConfig]);

  const setStreaming = useCallback(async (enabled: boolean) => {
    await writeControl(controlRef.current, { type: "set_streaming", enabled });
  }, []);

  return { connect, disconnect, setSource, setStreaming, status, error };
}
