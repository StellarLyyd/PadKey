import { useCallback, useRef, useState } from "react";
import { useAppStore } from "../store";
import { parseFrame } from "./parser";

const SERVICE_UUID = "6e400001-b5a3-f393-e0a9-e50e24dcca9e";
const CHAR_UUID = "6e400003-b5a3-f393-e0a9-e50e24dcca9e";
const DEVICE_NAME = "OWO-SensorNode";
const DEVICE_NAME_PREFIX = "OWO-Sensor";

type BLEStatus = "idle" | "connecting" | "connected" | "error";

export function useBLE(): {
  connect: () => Promise<void>;
  disconnect: () => void;
  status: BLEStatus;
  error: string | null;
} {
  const [status, setStatus] = useState<BLEStatus>("idle");
  const [error, setError] = useState<string | null>(null);
  const deviceRef = useRef<BluetoothDevice | null>(null);
  const characteristicRef = useRef<BluetoothRemoteGATTCharacteristic | null>(null);
  const decoderRef = useRef(new TextDecoder("utf-8"));
  const pushFrame = useAppStore((state) => state.pushFrame);
  const setBLEConnected = useAppStore((state) => state.setBLEConnected);
  const setBLEStatus = useAppStore((state) => state.setBLEStatus);

  const handleDisconnect = useCallback(() => {
    setBLEConnected(false);
    setBLEStatus("idle");
    characteristicRef.current = null;
    deviceRef.current = null;
    setStatus("idle");
  }, [setBLEConnected, setBLEStatus]);

  const handleValueChanged = useCallback(
    (event: Event) => {
      const characteristic = event.target as BluetoothRemoteGATTCharacteristic;
      if (!characteristic.value) {
        return;
      }
      const raw = decoderRef.current.decode(characteristic.value);
      const frame = parseFrame(raw);
      if (frame) {
        pushFrame(frame);
      }
    },
    [pushFrame]
  );

  const disconnect = useCallback(() => {
    const characteristic = characteristicRef.current;
    if (characteristic) {
      characteristic.removeEventListener("characteristicvaluechanged", handleValueChanged);
      void characteristic.stopNotifications().catch(() => undefined);
    }

    if (deviceRef.current?.gatt?.connected) {
      deviceRef.current.gatt.disconnect();
    }

    handleDisconnect();
  }, [handleDisconnect, handleValueChanged]);

  const connect = useCallback(async () => {
    if (!navigator.bluetooth) {
      setStatus("error");
      setError("Web Bluetooth unavailable");
      setBLEConnected(false);
      setBLEStatus("error", "Web Bluetooth unavailable");
      return;
    }

    setStatus("connecting");
    setError(null);
    setBLEStatus("connecting");

    try {
      const device = await navigator.bluetooth.requestDevice({
        filters: [{ name: DEVICE_NAME }, { namePrefix: DEVICE_NAME_PREFIX }],
        optionalServices: [SERVICE_UUID]
      });
      deviceRef.current = device;
      device.addEventListener("gattserverdisconnected", handleDisconnect);

      const server = await device.gatt?.connect();
      if (!server) {
        throw new Error("GATT server unavailable");
      }

      const service = await server.getPrimaryService(SERVICE_UUID);
      const characteristic = await service.getCharacteristic(CHAR_UUID);
      characteristicRef.current = characteristic;
      characteristic.addEventListener("characteristicvaluechanged", handleValueChanged);
      await characteristic.startNotifications();

      setBLEConnected(true, device.name ?? DEVICE_NAME);
      setStatus("connected");
      setBLEStatus("connected");
    } catch (err) {
      const message = err instanceof Error ? err.message : "Connection failed";
      setError(message);
      setStatus("error");
      setBLEConnected(false);
      setBLEStatus("error", message);
    }
  }, [handleDisconnect, handleValueChanged, setBLEConnected, setBLEStatus]);

  return { connect, disconnect, status, error };
}
