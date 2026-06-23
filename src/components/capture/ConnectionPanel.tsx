import { useEffect, useState } from "react";
import { Cable, Loader2, Radio, Wifi, WifiOff } from "lucide-react";
import { useSerial } from "../../serial/useSerial";
import { useAppStore } from "../../store";
import { useWifi } from "../../wifi/useWifi";

type ConnectionMode = "serial" | "wifi";

export function ConnectionPanel() {
  const [mode, setMode] = useState<ConnectionMode>("serial");
  const serialConnected = useAppStore((state) => state.serialConnected);
  const serialStatus = useAppStore((state) => state.serialStatus);
  const serialError = useAppStore((state) => state.serialError);
  const serialBaudRate = useAppStore((state) => state.serialBaudRate);
  const setSerialBaudRate = useAppStore((state) => state.setSerialBaudRate);
  const wifiConnected = useAppStore((state) => state.wifiConnected);
  const wifiStatus = useAppStore((state) => state.wifiStatus);
  const wifiUrl = useAppStore((state) => state.wifiUrl);
  const wifiError = useAppStore((state) => state.wifiError);
  const setWifiUrl = useAppStore((state) => state.setWifiUrl);
  const serial = useSerial(serialBaudRate);
  const wifi = useWifi();

  useEffect(() => {
    const saved = window.localStorage.getItem("padkey-wifi-url");
    if (saved) setWifiUrl(saved);
  }, [setWifiUrl]);

  function updateWifiUrl(value: string) {
    setWifiUrl(value);
    window.localStorage.setItem("padkey-wifi-url", value);
  }

  const activeStatus = mode === "serial" ? serialStatus : wifiStatus;
  const activeError = mode === "serial" ? serialError : wifiError;
  const connected = mode === "serial" ? serialConnected : wifiConnected;

  async function handleConnect() {
    if (mode === "serial") {
      if (serialConnected) await serial.disconnect();
      else {
        if (wifiConnected) wifi.disconnect();
        await serial.connect();
      }
      return;
    }
    if (wifiConnected) wifi.disconnect();
    else {
      if (serialConnected) await serial.disconnect();
      await wifi.connect(wifiUrl.trim());
    }
  }

  return (
    <section className="control-section" aria-labelledby="connection-title">
      <div className="section-kicker">Input</div>
      <h2 id="connection-title" className="section-title">Connect PadKey</h2>
      <p className="section-copy">Use USB for bench work or a WebSocket when the ESP32-S3 firmware is Wi-Fi enabled.</p>

      <div className="segmented" role="tablist" aria-label="Connection type">
        <button
          type="button"
          className={mode === "serial" ? "segmented-button is-active" : "segmented-button"}
          aria-selected={mode === "serial"}
          role="tab"
          onClick={() => setMode("serial")}
        >
          <Cable size={15} aria-hidden="true" />
          Wired USB
        </button>
        <button
          type="button"
          className={mode === "wifi" ? "segmented-button is-active" : "segmented-button"}
          aria-selected={mode === "wifi"}
          role="tab"
          onClick={() => setMode("wifi")}
        >
          <Wifi size={15} aria-hidden="true" />
          Wi-Fi
        </button>
      </div>

      {mode === "serial" ? (
        <div className="field-stack" role="tabpanel">
          <label className="field-label" htmlFor="serial-baud">Serial baud rate</label>
          <select
            id="serial-baud"
            className="field-control"
            value={serialBaudRate}
            disabled={serialConnected || serialStatus === "connecting"}
            onChange={(event) => setSerialBaudRate(Number(event.target.value))}
          >
            <option value={115200}>115200 — current telemetry sketch</option>
            <option value={921600}>921600 — raw PCM firmware</option>
          </select>
          <p className="field-hint">Chrome or Edge only. Close Arduino Serial Monitor before connecting.</p>
        </div>
      ) : (
        <div className="field-stack" role="tabpanel">
          <label className="field-label" htmlFor="wifi-url">Telemetry WebSocket URL</label>
          <input
            id="wifi-url"
            className="field-control mono"
            value={wifiUrl}
            disabled={wifiConnected || wifiStatus === "connecting"}
            onChange={(event) => updateWifiUrl(event.target.value)}
            placeholder="ws://padkey.local:81"
            spellCheck={false}
          />
          <p className="field-hint">Use this when Wi-Fi is enabled in the production firmware.</p>
        </div>
      )}

      <button
        type="button"
        className={connected ? "button button-secondary full-width" : "button button-primary full-width"}
        onClick={() => void handleConnect()}
        disabled={activeStatus === "connecting" || (mode === "wifi" && !wifiUrl.trim())}
      >
        {activeStatus === "connecting" ? <Loader2 size={16} className="spin" aria-hidden="true" /> : connected ? <WifiOff size={16} aria-hidden="true" /> : <Radio size={16} aria-hidden="true" />}
        {activeStatus === "connecting" ? "Connecting…" : connected ? "Disconnect" : `Connect ${mode === "serial" ? "USB" : "Wi-Fi"}`}
      </button>

      <div className={`connection-result ${connected ? "is-connected" : activeStatus === "error" ? "is-error" : ""}`} aria-live="polite">
        <span className="status-dot" aria-hidden="true" />
        <span>{connected ? `${mode === "serial" ? `USB · ${serialBaudRate} baud` : "Wi-Fi WebSocket"} connected` : activeStatus === "error" ? activeError : "Not connected"}</span>
      </div>
    </section>
  );
}
