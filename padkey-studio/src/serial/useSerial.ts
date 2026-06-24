import { useCallback, useEffect } from "react";
import { decodeBase64Bytes, hasNativePadKeyBridge, postNativePadKeyMessage, type PadKeyNativeEvent } from "../nativeBridge";
import { useAppStore } from "../store";
import { parseTransportLine } from "../transport/parsePacket";

type SerialStatus = "idle" | "connecting" | "connected" | "error";

interface SerialPortLike {
  readable: ReadableStream<Uint8Array> | null;
  writable?: WritableStream<Uint8Array> | null;
  open: (options: { baudRate: number }) => Promise<void>;
  close: () => Promise<void>;
  setSignals?: (signals: { dataTerminalReady?: boolean; requestToSend?: boolean }) => Promise<void>;
}

interface NavigatorWithSerial extends Navigator {
  serial?: {
    requestPort: () => Promise<SerialPortLike>;
  };
}

const ARDUINO_RESET_DELAY_MS = 1500;
let activePort: SerialPortLike | null = null;
let activeReader: ReadableStreamDefaultReader<Uint8Array> | null = null;
let shouldStop = false;
const serialDecoder = new TextDecoder();
let serialBuffer = "";

function sleep(ms: number) {
  return new Promise((resolve) => window.setTimeout(resolve, ms));
}

function serialErrorMessage(err: unknown) {
  if (!(err instanceof Error)) {
    return "Serial connection failed";
  }

  const name = "name" in err ? String((err as Error & { name?: string }).name) : "";
  const message = err.message || "Serial connection failed";

  if (name === "NotFoundError") {
    return "no USB port selected";
  }

  if (name === "SecurityError") {
    return "browser blocked Web Serial - use Chrome or Edge on localhost";
  }

  if (/already open|busy|failed to open|access denied|could not open/i.test(message)) {
    return "USB port is busy - close Arduino Serial Monitor/Plotter, then reconnect";
  }

  if (/readable stream unavailable/i.test(message)) {
    return "USB opened but no readable stream was exposed";
  }

  return message;
}

export function useSerial(baudRate = 115200): {
  connect: () => Promise<void>;
  disconnect: () => Promise<void>;
  status: SerialStatus;
  error: string | null;
} {
  const pushFrame = useAppStore((state) => state.pushFrame);
  const pushAudioPacket = useAppStore((state) => state.pushAudioPacket);
  const serialStatus = useAppStore((state) => state.serialStatus);
  const serialError = useAppStore((state) => state.serialError);
  const setSerialConnected = useAppStore((state) => state.setSerialConnected);
  const setSerialStatus = useAppStore((state) => state.setSerialStatus);
  const setDeviceStatus = useAppStore((state) => state.setDeviceStatus);

  const consumeSerialBytes = useCallback((bytes: Uint8Array) => {
    serialBuffer += serialDecoder.decode(bytes, { stream: true });
    const lines = serialBuffer.split(/\r?\n/);
    serialBuffer = lines.pop() ?? "";
    for (const line of lines) {
      const packet = parseTransportLine(line, "serial");
      if (packet?.kind === "telemetry") pushFrame(packet.frame);
      if (packet?.kind === "audio") pushAudioPacket(packet.audio);
      if (packet?.kind === "status") setDeviceStatus(packet.status);
    }
  }, [pushAudioPacket, pushFrame, setDeviceStatus]);

  useEffect(() => {
    if (!hasNativePadKeyBridge()) return;
    const listener = (rawEvent: Event) => {
      const event = rawEvent as PadKeyNativeEvent;
      if (event.detail.type === "serial-data") consumeSerialBytes(decodeBase64Bytes(event.detail.base64));
      if (event.detail.type === "serial-status") {
        const next = String(event.detail.status ?? "error");
        if (next === "connected") setSerialConnected(true, String(event.detail.name ?? "PadKey USB"));
        else if (next === "disconnected") setSerialConnected(false);
        else if (next === "error") setSerialStatus("error", String(event.detail.message ?? "USB connection failed"));
      }
    };
    window.addEventListener("padkey-native", listener);
    return () => window.removeEventListener("padkey-native", listener);
  }, [consumeSerialBytes, setSerialConnected, setSerialStatus]);

  const disconnect = useCallback(async () => {
    shouldStop = true;
    if (hasNativePadKeyBridge()) {
      postNativePadKeyMessage({ action: "disconnectSerial" });
      serialBuffer = "";
      setSerialConnected(false);
      return;
    }
    const reader = activeReader;
    activeReader = null;

    if (reader) {
      await reader.cancel().catch(() => undefined);
      try {
        reader.releaseLock();
      } catch {
        // The read loop may have already released the lock.
      }
    }

    const port = activePort;
    activePort = null;

    if (port) {
      await port.close().catch(() => undefined);
    }

    serialBuffer = "";
    setSerialConnected(false);
  }, [setSerialConnected]);

  const readLoop = useCallback(async () => {
    const port = activePort;
    if (!port?.readable) {
      throw new Error("Serial readable stream unavailable");
    }

    const reader = port.readable.getReader();
    activeReader = reader;

    try {
      while (!shouldStop) {
        const { value, done } = await reader.read();
        if (done || !value) {
          break;
        }

        consumeSerialBytes(value);
      }
    } finally {
      if (activeReader === reader) {
        activeReader = null;
      }

      try {
        reader.releaseLock();
      } catch {
        // The reader may already be released during manual disconnect.
      }
    }
  }, [consumeSerialBytes]);

  const connect = useCallback(async () => {
    if (hasNativePadKeyBridge()) {
      setSerialStatus("connecting");
      postNativePadKeyMessage({ action: "connectSerial", baudRate });
      return;
    }
    const serial = (navigator as NavigatorWithSerial).serial;
    if (!serial) {
      setSerialStatus("error", "Web Serial unavailable - use Chrome or Edge on localhost");
      return;
    }

    if (activePort) {
      setSerialConnected(true, "Arduino USB");
      return;
    }

    shouldStop = false;
    setSerialStatus("connecting");

    try {
      const port = await serial.requestPort();
      await port.open({ baudRate });
      activePort = port;
      await port.setSignals?.({ dataTerminalReady: true, requestToSend: true }).catch(() => undefined);
      await sleep(ARDUINO_RESET_DELAY_MS);
      serialBuffer = "";
      setSerialConnected(true, "Arduino USB");
      void readLoop().catch((err) => {
        if (!shouldStop) {
          const failedPort = activePort;
          activePort = null;
          serialBuffer = "";
          void failedPort?.close().catch(() => undefined);
          setSerialStatus("error", serialErrorMessage(err));
        }
      });
    } catch (err) {
      const failedPort = activePort;
      activePort = null;
      serialBuffer = "";
      await failedPort?.close().catch(() => undefined);
      setSerialStatus("error", serialErrorMessage(err));
    }
  }, [baudRate, readLoop, setSerialConnected, setSerialStatus]);

  return { connect, disconnect, status: serialStatus, error: serialError };
}
