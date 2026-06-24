import type { SensorFrame } from "../types";
import { downloadBlob } from "./exportAudio";

export function exportTelemetryCsv(frames: SensorFrame[], filename: string) {
  const header = ["timestamp_ms", "inmp441_peak", "noise_floor", "mic_gate", "piezo", "threshold_piezo", "detected", "source"];
  const rows = frames.map((frame) => [
    frame.ts,
    frame.mic,
    frame.noiseFloor,
    frame.thresholdMic,
    frame.piezo,
    frame.thresholdPiezo,
    frame.soundDetected ? 1 : 0,
    frame.source
  ]);
  const csv = [header, ...rows].map((row) => row.join(",")).join("\n");
  downloadBlob(new Blob([csv], { type: "text/csv;charset=utf-8" }), filename);
}
