import { useEffect, useState } from "react";
import { Bluetooth, Cable, Loader2, Radio, Wifi, WifiOff } from "lucide-react";
import type { BLEController } from "../../ble/useBLE";
import type { useSerial } from "../../serial/useSerial";
import { useAppStore } from "../../store";
import type { useWifi } from "../../wifi/useWifi";
import { BleSourcePicker } from "./BleSourcePicker";

type ConnectionMode = "serial" | "ble" | "wifi";

export function ConnectionPanel({
  serial,
  wifi,
  ble
}: {
  serial: ReturnType<typeof useSerial>;
  wifi: ReturnType<typeof useWifi>;
  ble: BLEController;
}) {
  const [mode, setMode] = useState<ConnectionMode>("serial");
  const serialConnected = useAppStore((state) => state.serialConnected);
  const serialStatus = useAppStore((state) => state.serialStatus);
  const serialError = useAppStore((state) => state.serialError);
  const serialBaudRate = useAppStore((state) => state.serialBaudRate);
  const setSerialBaudRate = useAppStore((state) => state.setSerialBaudRate);
  const bleConnected = useAppStore((state) => state.bleConnected);
  const bleStatus = useAppStore((state) => state.bleStatus);
  const bleError = useAppStore((state) => state.bleError);
  const wifiConnected = useAppStore((state) => state.wifiConnected);
  const wifiStatus = useAppStore((state) => state.wifiStatus);
  const wifiUrl = useAppStore((state) => state.wifiUrl);
  const wifiError = useAppStore((state) => state.wifiError);
  const setWifiUrl = useAppStore((state) => state.setWifiUrl);

  useEffect(() => {
    const saved = window.localStorage.getItem("padkey-wifi-url");
    if (saved) setWifiUrl(saved);
  }, [setWifiUrl]);

  useEffect(() => {
    if (serialConnected) setMode("serial");
    else if (bleConnected) setMode("ble");
    else if (wifiConnected) setMode("wifi");
  }, [bleConnected, serialConnected, wifiConnected]);

  function updateWifiUrl(value: string) {
    setWifiUrl(value);
    window.localStorage.setItem("padkey-wifi-url", value);
  }

  const activeStatus = mode === "serial" ? serialStatus : mode === "ble" ? bleStatus : wifiStatus;
  const activeError = mode === "serial" ? serialError : mode === "ble" ? bleError : wifiError;
  const connected = mode === "serial" ? serialConnected : mode === "ble" ? bleConnected : wifiConnected;

  async function handleConnect() {
    if (connected) {
      if (mode === "serial") await serial.disconnect();
      else if (mode === "ble") ble.disconnect();
      else wifi.disconnect();
      return;
    }

    if (mode === "serial") {
      ble.disconnect();
      wifi.disconnect();
      await serial.connect();
    } else if (mode === "ble") {
      await serial.disconnect();
      wifi.disconnect();
      await ble.connect();
    } else {
      await serial.disconnect();
      ble.disconnect();
      await wifi.connect(wifiUrl.trim());
    }
  }

  const modeLabel = mode === "serial" ? "USB" : mode === "ble" ? "BLE" : "Wi-Fi";

  return (
    <section className="control-section" aria-labelledby="connection-title">
      <div className="section-kicker">Input</div>
      <h2 id="connection-title" className="section-title">Connect PadKey</h2>
      <p className="section-copy">USB records all sensors. BLE records one wireless channel. Wi-Fi records all sensors wirelessly.</p>

      <div className="segmented transport-segmented" role="tablist" aria-label="Connection type">
        <button type="button" className={mode === "serial" ? "segmented-button is-active" : "segmented-button"} aria-selected={mode === "serial"} role="tab" onClick={() => setMode("serial")}>
          <Cable size={15} aria-hidden="true" /> USB
        </button>
        <button type="button" className={mode === "ble" ? "segmented-button is-active" : "segmented-button"} aria-selected={mode === "ble"} role="tab" onClick={() => setMode("ble")}>
          <Bluetooth size={15} aria-hidden="true" /> BLE
        </button>
        <button type="button" className={mode === "wifi" ? "segmented-button is-active" : "segmented-button"} aria-selected={mode === "wifi"} role="tab" onClick={() => setMode("wifi")}>
          <Wifi size={15} aria-hidden="true" /> Wi-Fi
        </button>
      </div>

      {mode === "serial" ? (
        <div className="field-stack" role="tabpanel">
          <label className="field-label" htmlFor="serial-baud">Serial speed</label>
          <select id="serial-baud" className="field-control" value={serialBaudRate} disabled={serialConnected || serialStatus === "connecting"} onChange={(event) => setSerialBaudRate(Number(event.target.value))}>
            <option value={921600}>921600 - recording firmware</option>
            <option value={115200}>115200 - telemetry only</option>
          </select>
          <p className="field-hint">Best reliability and recording quality. Close Arduino Serial Monitor first.</p>
        </div>
      ) : mode === "ble" ? (
        <div className="field-stack" role="tabpanel">
          <p className="transport-explainer"><b>Wireless recording</b><span>BLE sends one continuous 8 kHz sensor channel to keep bandwidth and battery use predictable.</span></p>
          <BleSourcePicker ble={ble} />
          <p className="field-hint">Chrome or Edge will open a Bluetooth device picker. Choose PadKey-S3.</p>
        </div>
      ) : (
        <div className="field-stack" role="tabpanel">
          <label className="field-label" htmlFor="wifi-url">PadKey address</label>
          <input id="wifi-url" className="field-control mono" value={wifiUrl} disabled={wifiConnected || wifiStatus === "connecting"} onChange={(event) => updateWifiUrl(event.target.value)} placeholder="ws://padkey.local:81" spellCheck={false} />
          <p className="field-hint">Wireless full-waveform recording. PadKey and this Mac must be on the same network.</p>
        </div>
      )}

      <button type="button" className={connected ? "button button-secondary full-width" : "button button-primary full-width"} onClick={() => void handleConnect()} disabled={activeStatus === "connecting" || (mode === "wifi" && !wifiUrl.trim())}>
        {activeStatus === "connecting" ? <Loader2 size={16} className="spin" aria-hidden="true" /> : connected ? <WifiOff size={16} aria-hidden="true" /> : mode === "ble" ? <Bluetooth size={16} aria-hidden="true" /> : <Radio size={16} aria-hidden="true" />}
        {activeStatus === "connecting" ? "Connecting…" : connected ? "Disconnect" : `Connect ${modeLabel}`}
      </button>

      <div className={`connection-result ${connected ? "is-connected" : activeStatus === "error" ? "is-error" : ""}`} aria-live="polite">
        <span className="status-dot" aria-hidden="true" />
        <span>{connected ? `${modeLabel} connected` : activeStatus === "error" ? activeError : "Not connected"}</span>
      </div>
    </section>
  );
}
