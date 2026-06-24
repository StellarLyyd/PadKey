import type { AudioChannel } from "../types";

export type BleSourceId = 0 | 1 | 2;

export const BLE_SOURCE_OPTIONS: Array<{ id: BleSourceId; label: string; channel: AudioChannel }> = [
  { id: 0, label: "INMP441", channel: "inmp441" },
  { id: 1, label: "MAX4466", channel: "max4466" },
  { id: 2, label: "Piezo", channel: "piezo" }
];

export function bleSourceChannel(sourceId: BleSourceId): AudioChannel {
  return BLE_SOURCE_OPTIONS.find((source) => source.id === sourceId)?.channel ?? "max4466";
}
