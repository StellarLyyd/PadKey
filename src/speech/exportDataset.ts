import { strToU8, zipSync } from "fflate";
import { downloadBlob, encodeWav } from "../audio/exportAudio";
import type { CaptureMode, SegmentTranscript, SpeechSegment } from "../types";

function floatToInt16(input: Float32Array) {
  return Int16Array.from(input, (sample) => Math.round(Math.max(-1, Math.min(0.999969, sample)) * 32768));
}

function cleanLabel(label: string) {
  return label.trim().toLowerCase().replace(/[^a-z0-9-_]+/g, "-").replace(/^-+|-+$/g, "") || "unlabeled";
}

export async function exportSpeechDataset(options: {
  segments: SpeechSegment[];
  transcripts: SegmentTranscript[];
  sampleRate: number;
  captureMode: CaptureMode;
  label: string;
  processing: Record<string, boolean | number | string>;
  droppedPackets: number;
}) {
  const transcriptMap = new Map(options.transcripts.map((item) => [item.segmentId, item]));
  const label = cleanLabel(options.label);
  const files: Record<string, Uint8Array> = {};
  const manifestSegments = [];

  for (let index = 0; index < options.segments.length; index += 1) {
    const segment = options.segments[index];
    const filename = `segments/${label}-${String(index + 1).padStart(3, "0")}.wav`;
    const wav = encodeWav(floatToInt16(segment.processedAudio), options.sampleRate);
    files[filename] = new Uint8Array(await wav.arrayBuffer());
    const transcript = transcriptMap.get(segment.id);
    manifestSegments.push({
      id: segment.id,
      file: filename,
      label,
      captureMode: options.captureMode,
      startMs: segment.startMs,
      endMs: segment.endMs,
      durationMs: segment.durationMs,
      detector: segment.source,
      signalScore: Number(segment.signalScore.toFixed(4)),
      transcript: transcript?.text ?? "",
      words: transcript?.words ?? []
    });
  }

  const manifest = {
    schema: "padkey-speech-dataset/v1",
    createdAt: new Date().toISOString(),
    sampleRate: options.sampleRate,
    channels: 1,
    format: "pcm_s16le_wav",
    captureMode: options.captureMode,
    label,
    droppedPackets: options.droppedPackets,
    processing: options.processing,
    segments: manifestSegments
  };
  files["manifest.json"] = strToU8(JSON.stringify(manifest, null, 2));
  files["transcripts.csv"] = strToU8([
    "segment_id,file,label,capture_mode,start_ms,end_ms,transcript",
    ...manifestSegments.map((segment) => [
      segment.id,
      segment.file,
      segment.label,
      segment.captureMode,
      segment.startMs,
      segment.endMs,
      JSON.stringify(segment.transcript)
    ].join(","))
  ].join("\n"));

  const archive = zipSync(files, { level: 6 });
  downloadBlob(new Blob([Uint8Array.from(archive).buffer], { type: "application/zip" }), `padkey-dataset-${label}-${Date.now()}.zip`);
}
