/// <reference lib="webworker" />

import type { SegmentTranscript, TranscriptWord } from "../types";

type Pipeline = (audio: Float32Array, options?: Record<string, unknown>) => Promise<unknown>;

let transcriber: Pipeline | null = null;
let loadedModel: string | null = null;

function wordsFromResult(result: Record<string, unknown>): TranscriptWord[] {
  const chunks = Array.isArray(result.chunks) ? result.chunks : [];
  return chunks.map((chunk) => {
    const value = chunk as Record<string, unknown>;
    const timestamp = Array.isArray(value.timestamp) ? value.timestamp : [null, null];
    return {
      text: String(value.text ?? ""),
      start: typeof timestamp[0] === "number" ? timestamp[0] : null,
      end: typeof timestamp[1] === "number" ? timestamp[1] : null,
      confidence: typeof value.score === "number" ? value.score : null
    };
  });
}

async function loadModel(model: string) {
  if (transcriber && loadedModel === model) return;
  self.postMessage({ type: "model-status", status: "loading", model, progress: 0 });
  const { env, pipeline } = await import("@huggingface/transformers");
  env.allowLocalModels = false;
  transcriber = (await pipeline("automatic-speech-recognition", model, {
    device: "wasm",
    dtype: "q8",
    // ORT's aggressive QDQ rewrite currently rejects Whisper's shared
    // embedding scale. The quantized graph runs correctly without that pass.
    session_options: { graphOptimizationLevel: "disabled" },
    progress_callback: (progress: Record<string, unknown>) => {
      self.postMessage({
        type: "model-status",
        status: String(progress.status ?? "loading"),
        model,
        progress: typeof progress.progress === "number" ? progress.progress : null,
        file: typeof progress.file === "string" ? progress.file : null
      });
    }
  })) as unknown as Pipeline;
  loadedModel = model;
  self.postMessage({ type: "model-status", status: "ready", model, progress: 100 });
}

self.onmessage = async (event: MessageEvent) => {
  const message = event.data as Record<string, unknown>;
  try {
    if (message.type === "load") {
      await loadModel(String(message.model));
      return;
    }
    if (message.type !== "transcribe") return;
    const model = String(message.model);
    await loadModel(model);
    const items = Array.isArray(message.segments) ? message.segments : [];
    const results: SegmentTranscript[] = [];
    for (let index = 0; index < items.length; index += 1) {
      const item = items[index] as { id: string; audio: ArrayBuffer };
      self.postMessage({ type: "transcription-progress", current: index, total: items.length });
      const output = await transcriber!(new Float32Array(item.audio), {
        // The compact browser checkpoints expose timestamp tokens but not the
        // decoder cross-attentions required for word-level alignment.
        return_timestamps: true,
        chunk_length_s: 30,
        stride_length_s: 5
      });
      const result = (Array.isArray(output) ? output[0] : output) as Record<string, unknown>;
      results.push({
        segmentId: item.id,
        text: String(result?.text ?? "").trim(),
        words: wordsFromResult(result ?? {})
      });
      self.postMessage({ type: "transcription-progress", current: index + 1, total: items.length });
    }
    self.postMessage({ type: "transcription-complete", results });
  } catch (error) {
    self.postMessage({
      type: "transcription-error",
      error: error instanceof Error ? error.message : "Transcription failed"
    });
  }
};

export {};
