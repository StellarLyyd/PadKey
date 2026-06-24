import { useState } from "react";
import type { BLEController } from "../../ble/useBLE";
import { BLE_SOURCE_OPTIONS } from "../../ble/bleProtocol";
import { useAppStore } from "../../store";

export function BleSourcePicker({ ble }: { ble: BLEController }) {
  const sourceId = useAppStore((state) => state.bleActiveSource);
  const sampleRate = useAppStore((state) => state.bleSampleRate);
  const sessionRecording = useAppStore((state) => state.sessionRecording);
  const [switching, setSwitching] = useState(false);
  const [switchError, setSwitchError] = useState<string | null>(null);

  async function switchSource(nextSourceId: 0 | 1 | 2) {
    setSwitching(true);
    setSwitchError(null);
    try {
      await ble.setSource(nextSourceId);
    } catch {
      setSwitchError("Source switch failed. Reconnect BLE and try again.");
    } finally {
      setSwitching(false);
    }
  }

  return (
    <label className="ble-source-picker">
      <span>Wireless recording input</span>
      <select disabled={sessionRecording || switching} value={sourceId} onChange={(event) => void switchSource(Number(event.target.value) as 0 | 1 | 2)}>
        {BLE_SOURCE_OPTIONS.map((source) => <option key={source.id} value={source.id}>{source.label}</option>)}
      </select>
      <small>{switchError ?? (switching ? "Switching input…" : sessionRecording ? "Stop recording before switching" : `One continuous channel · ${(sampleRate / 1000).toFixed(0)} kHz`)}</small>
    </label>
  );
}
