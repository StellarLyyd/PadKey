import type { BLEController } from "../../ble/useBLE";
import { BLE_SOURCE_OPTIONS } from "../../ble/bleProtocol";
import { useAppStore } from "../../store";

export function BleSourcePicker({ ble }: { ble: BLEController }) {
  const sourceId = useAppStore((state) => state.bleActiveSource);
  const sampleRate = useAppStore((state) => state.bleSampleRate);

  return (
    <label className="ble-source-picker">
      <span>Wireless recording input</span>
      <select value={sourceId} onChange={(event) => void ble.setSource(Number(event.target.value) as 0 | 1 | 2)}>
        {BLE_SOURCE_OPTIONS.map((source) => <option key={source.id} value={source.id}>{source.label}</option>)}
      </select>
      <small>One continuous channel · {(sampleRate / 1000).toFixed(0)} kHz</small>
    </label>
  );
}
