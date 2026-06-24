import { useCallback } from "react";
import { useAppStore } from "../store";
import { parseBinaryAudio, parseTransportLine } from "../transport/parsePacket";

function wifiErrorMessage(error: unknown) {
  if (error instanceof Error && error.message) {
    return error.message;
  }
  return "Wi-Fi WebSocket connection failed";
}

let activeSocket: WebSocket | null = null;
const wifiDecoder = new TextDecoder();

export function useWifi() {
  const pushFrame = useAppStore((state) => state.pushFrame);
  const pushAudioPacket = useAppStore((state) => state.pushAudioPacket);
  const setWifiConnected = useAppStore((state) => state.setWifiConnected);
  const setWifiStatus = useAppStore((state) => state.setWifiStatus);
  const setDeviceStatus = useAppStore((state) => state.setDeviceStatus);

  const disconnect = useCallback(() => {
    const socket = activeSocket;
    activeSocket = null;
    if (socket && socket.readyState < WebSocket.CLOSING) {
      socket.close(1000, "PadKey dashboard disconnected");
    }
    setWifiConnected(false);
  }, [setWifiConnected]);

  const connect = useCallback(
    async (url: string) => {
      if (!/^wss?:\/\//i.test(url)) {
        setWifiStatus("error", "Use a WebSocket URL beginning with ws:// or wss://");
        return;
      }

      disconnect();
      setWifiStatus("connecting");

      await new Promise<void>((resolve) => {
        try {
          const socket = new WebSocket(url);
          socket.binaryType = "arraybuffer";
          activeSocket = socket;

          const timeout = window.setTimeout(() => {
            if (socket.readyState !== WebSocket.OPEN) {
              socket.close();
              setWifiStatus("error", "Timed out waiting for the PadKey WebSocket");
              resolve();
            }
          }, 6000);

          socket.onopen = () => {
            window.clearTimeout(timeout);
            setWifiConnected(true, url);
            resolve();
          };

          socket.onmessage = async (event) => {
            if (typeof event.data === "string") {
              for (const line of event.data.split(/\r?\n/)) {
                const packet = parseTransportLine(line, "wifi");
                if (packet?.kind === "telemetry") pushFrame(packet.frame);
                if (packet?.kind === "audio") pushAudioPacket(packet.audio);
                if (packet?.kind === "status") setDeviceStatus(packet.status);
              }
              return;
            }

            const buffer = event.data instanceof Blob ? await event.data.arrayBuffer() : (event.data as ArrayBuffer);
            const audio = parseBinaryAudio(buffer);
            if (audio) {
              pushAudioPacket(audio);
              return;
            }

            const text = wifiDecoder.decode(buffer);
            const packet = parseTransportLine(text, "wifi");
            if (packet?.kind === "telemetry") pushFrame(packet.frame);
            if (packet?.kind === "audio") pushAudioPacket(packet.audio);
            if (packet?.kind === "status") setDeviceStatus(packet.status);
          };

          socket.onerror = () => {
            window.clearTimeout(timeout);
            setWifiStatus("error", "Could not reach the PadKey WebSocket");
            resolve();
          };

          socket.onclose = (event) => {
            window.clearTimeout(timeout);
            if (activeSocket === socket) {
              activeSocket = null;
              if (event.code === 1000) {
                setWifiConnected(false);
              } else {
                setWifiStatus("error", `Wi-Fi stream closed (${event.code})`);
              }
            }
            resolve();
          };
        } catch (error) {
          setWifiStatus("error", wifiErrorMessage(error));
          resolve();
        }
      });
    },
    [disconnect, pushAudioPacket, pushFrame, setDeviceStatus, setWifiConnected, setWifiStatus]
  );

  return { connect, disconnect };
}
