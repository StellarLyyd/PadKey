/// <reference lib="webworker" />

import FFT from "fft.js";
import { NonRealTimeVAD } from "@ricky0123/vad-web";
import type { CaptureMode, SpeechSegment } from "../types";

interface ContactRange {
  startMs: number;
  endMs: number;
}

interface AnalysisOptions {
  mode: CaptureMode;
  gapMs: number;
  sileroThreshold: number;
  minSpeechMs: number;
  spectralGate: boolean;
  preEmphasis: boolean;
  rmsNormalize: boolean;
  contactRanges: ContactRange[];
}

interface AnalyzeMessage {
  type: "analyze";
  requestId: number;
  samples: ArrayBuffer;
  sampleRate: number;
  options: AnalysisOptions;
}

interface Range {
  startMs: number;
  endMs: number;
  sources: Set<"silero" | "energy">;
}

const sileroModelUrl = new URL(
  "../../node_modules/@ricky0123/vad-web/dist/silero_vad_legacy.onnx",
  import.meta.url
).href;
const ortModuleUrl = new URL(
  "../../node_modules/onnxruntime-web/dist/ort-wasm-simd-threaded.mjs",
  import.meta.url
).href;
const ortWasmUrl = new URL(
  "../../node_modules/onnxruntime-web/dist/ort-wasm-simd-threaded.wasm",
  import.meta.url
).href;

function toFloat32(samples: Int16Array) {
  return Float32Array.from(samples, (sample) => sample / 32768);
}

function resampleLinear(input: Float32Array, fromRate: number, toRate = 16000) {
  if (fromRate === toRate) return input;
  const outputLength = Math.max(1, Math.round((input.length * toRate) / fromRate));
  const output = new Float32Array(outputLength);
  const ratio = fromRate / toRate;
  for (let index = 0; index < outputLength; index += 1) {
    const position = index * ratio;
    const lower = Math.floor(position);
    const upper = Math.min(input.length - 1, lower + 1);
    const fraction = position - lower;
    output[index] = input[lower] * (1 - fraction) + input[upper] * fraction;
  }
  return output;
}

function rms(samples: Float32Array) {
  if (!samples.length) return 0;
  let sum = 0;
  for (const sample of samples) sum += sample * sample;
  return Math.sqrt(sum / samples.length);
}

function percentile(values: number[], percentileValue: number) {
  if (!values.length) return 0;
  const sorted = [...values].sort((a, b) => a - b);
  return sorted[Math.min(sorted.length - 1, Math.floor(sorted.length * percentileValue))];
}

function energyRanges(audio: Float32Array, sampleRate: number, options: AnalysisOptions) {
  const frameSize = Math.round(sampleRate * 0.02);
  const hopSize = Math.round(sampleRate * 0.01);
  const frameRms: number[] = [];
  for (let start = 0; start + frameSize <= audio.length; start += hopSize) {
    frameRms.push(rms(audio.subarray(start, start + frameSize)));
  }

  const floor = Math.max(0.0015, percentile(frameRms, 0.25));
  const multiplier = options.mode === "ingressive" ? 1.65 : 2.2;
  const threshold = Math.max(options.mode === "ingressive" ? 0.003 : 0.0045, floor * multiplier);
  const active: Range[] = [];
  let startFrame: number | null = null;

  for (let index = 0; index < frameRms.length; index += 1) {
    const isActive = frameRms[index] >= threshold;
    if (isActive && startFrame === null) startFrame = index;
    if (!isActive && startFrame !== null) {
      active.push({
        startMs: Math.max(0, startFrame * 10 - 80),
        endMs: Math.min((audio.length / sampleRate) * 1000, index * 10 + 120),
        sources: new Set(["energy"])
      });
      startFrame = null;
    }
  }
  if (startFrame !== null) {
    active.push({
      startMs: Math.max(0, startFrame * 10 - 80),
      endMs: (audio.length / sampleRate) * 1000,
      sources: new Set(["energy"])
    });
  }

  return { ranges: active, threshold };
}

async function sileroRanges(audio: Float32Array, options: AnalysisOptions) {
  const ranges: Range[] = [];
  const vad = await NonRealTimeVAD.new({
    modelURL: sileroModelUrl,
    ortConfig: (ort) => {
      // Vite workers cannot infer ONNX Runtime's sidecar locations reliably.
      // Pin the CPU/SIMD runtime to emitted assets and avoid nested workers.
      ort.env.wasm.numThreads = 1;
      ort.env.wasm.proxy = false;
      ort.env.wasm.wasmPaths = { mjs: ortModuleUrl, wasm: ortWasmUrl };
    },
    positiveSpeechThreshold: options.sileroThreshold,
    negativeSpeechThreshold: Math.max(0.05, options.sileroThreshold - 0.15),
    redemptionMs: options.gapMs,
    preSpeechPadMs: 100,
    minSpeechMs: options.minSpeechMs
  });
  for await (const segment of vad.run(audio, 16000)) {
    ranges.push({ startMs: segment.start, endMs: segment.end, sources: new Set(["silero"]) });
  }
  return ranges;
}

function mergeRanges(ranges: Range[], gapMs: number, maxMs: number, minSpeechMs: number) {
  if (!ranges.length) return [];
  const sorted = ranges
    .map((range) => ({
      startMs: Math.max(0, range.startMs),
      endMs: Math.min(maxMs, range.endMs),
      sources: new Set(range.sources)
    }))
    .filter((range) => range.endMs > range.startMs)
    .sort((a, b) => a.startMs - b.startMs);

  const merged: Range[] = [];
  for (const range of sorted) {
    const previous = merged[merged.length - 1];
    if (previous && range.startMs <= previous.endMs + gapMs) {
      previous.endMs = Math.max(previous.endMs, range.endMs);
      for (const source of range.sources) previous.sources.add(source);
    } else {
      merged.push(range);
    }
  }
  return merged.filter((range) => range.endMs - range.startMs >= minSpeechMs);
}

function removeDc(input: Float32Array) {
  if (!input.length) return input;
  let mean = 0;
  for (const sample of input) mean += sample;
  mean /= input.length;
  return Float32Array.from(input, (sample) => sample - mean);
}

function preEmphasis(input: Float32Array, coefficient = 0.97) {
  if (!input.length) return input;
  const output = new Float32Array(input.length);
  output[0] = input[0];
  for (let index = 1; index < input.length; index += 1) {
    output[index] = input[index] - coefficient * input[index - 1];
  }
  return output;
}

function buildNoiseProfile(noiseAudio: Float32Array, fftSize: number) {
  const fft = new FFT(fftSize);
  const profile = new Float32Array(fftSize / 2 + 1);
  const spectrum = fft.createComplexArray();
  const frame = new Array<number>(fftSize).fill(0);
  const frameCount = Math.max(1, Math.ceil(noiseAudio.length / fftSize));
  for (let frameIndex = 0; frameIndex < frameCount; frameIndex += 1) {
    frame.fill(0);
    const start = frameIndex * fftSize;
    for (let index = 0; index < fftSize && start + index < noiseAudio.length; index += 1) {
      frame[index] = noiseAudio[start + index];
    }
    fft.realTransform(spectrum, frame);
    for (let bin = 0; bin <= fftSize / 2; bin += 1) {
      profile[bin] += Math.hypot(spectrum[bin * 2], spectrum[bin * 2 + 1]) / frameCount;
    }
  }
  return profile;
}

function spectralGate(input: Float32Array, noiseProfile: Float32Array) {
  const fftSize = 512;
  const hop = 256;
  const fft = new FFT(fftSize);
  const output = new Float32Array(input.length + fftSize);
  const weight = new Float32Array(input.length + fftSize);
  const frame = new Array<number>(fftSize).fill(0);
  const spectrum = fft.createComplexArray();
  const inverse = fft.createComplexArray();
  const window = Float32Array.from({ length: fftSize }, (_, index) => 0.5 - 0.5 * Math.cos((2 * Math.PI * index) / (fftSize - 1)));

  for (let start = 0; start < input.length; start += hop) {
    frame.fill(0);
    for (let index = 0; index < fftSize && start + index < input.length; index += 1) {
      frame[index] = input[start + index] * window[index];
    }
    fft.realTransform(spectrum, frame);
    fft.completeSpectrum(spectrum);
    for (let bin = 0; bin < fftSize; bin += 1) {
      const profileBin = Math.min(bin, fftSize - bin);
      const magnitude = Math.hypot(spectrum[bin * 2], spectrum[bin * 2 + 1]);
      const threshold = noiseProfile[Math.min(profileBin, noiseProfile.length - 1)] * 1.8;
      const gain = magnitude >= threshold ? 1 : 0.16;
      spectrum[bin * 2] *= gain;
      spectrum[bin * 2 + 1] *= gain;
    }
    fft.inverseTransform(inverse, spectrum);
    for (let index = 0; index < fftSize && start + index < output.length; index += 1) {
      const sample = inverse[index * 2] * window[index];
      output[start + index] += sample;
      weight[start + index] += window[index] * window[index];
    }
  }

  const trimmed = output.subarray(0, input.length);
  for (let index = 0; index < trimmed.length; index += 1) {
    if (weight[index] > 1e-6) trimmed[index] /= weight[index];
  }
  return Float32Array.from(trimmed);
}

function normalizeRms(input: Float32Array, targetRms = 0.08) {
  const current = rms(input);
  if (current < 1e-6) return input;
  const gain = Math.min(8, targetRms / current);
  return Float32Array.from(input, (sample) => Math.max(-1, Math.min(0.999969, sample * gain)));
}

function processSegment(input: Float32Array, noiseProfile: Float32Array, options: AnalysisOptions) {
  let output = removeDc(input);
  if (options.preEmphasis) output = preEmphasis(output);
  if (options.spectralGate) output = spectralGate(output, noiseProfile);
  if (options.rmsNormalize) output = normalizeRms(output);
  return output;
}

self.onmessage = async (event: MessageEvent<AnalyzeMessage>) => {
  if (event.data.type !== "analyze") return;
  const { requestId, sampleRate, options } = event.data;
  try {
    const audio = resampleLinear(toFloat32(new Int16Array(event.data.samples)), sampleRate, 16000);
    const maxMs = (audio.length / 16000) * 1000;
    const energy = energyRanges(audio, 16000, options);
    let silero: Range[] = [];
    let sileroAvailable = true;
    let sileroError: string | null = null;
    try {
      silero = await sileroRanges(audio, options);
    } catch (error) {
      sileroAvailable = false;
      sileroError = error instanceof Error ? error.message : String(error);
      console.warn("Silero VAD unavailable; using energy/contact fallback", error);
    }

    const contact: Range[] = options.contactRanges.map((range) => ({
      startMs: range.startMs,
      endMs: range.endMs,
      sources: new Set(["energy"])
    }));
    const merged = mergeRanges([...silero, ...energy.ranges, ...contact], options.gapMs, maxMs, options.minSpeechMs);
    const noiseLength = Math.min(audio.length, Math.round(16000 * 0.3));
    const noiseProfile = buildNoiseProfile(audio.subarray(0, noiseLength), 512);
    const segments: SpeechSegment[] = merged.map((range, index) => {
      const startSample = Math.max(0, Math.floor((range.startMs / 1000) * 16000));
      const endSample = Math.min(audio.length, Math.ceil((range.endMs / 1000) * 16000));
      const raw = audio.slice(startSample, endSample);
      const segmentRms = rms(raw);
      const signalScore = Math.max(0, Math.min(1, segmentRms / Math.max(energy.threshold * 2.5, 0.001)));
      const source = range.sources.size > 1 ? "hybrid" : range.sources.has("silero") ? "silero" : "energy";
      return {
        id: `segment-${index + 1}`,
        startMs: Math.round(range.startMs),
        endMs: Math.round(range.endMs),
        durationMs: Math.round(range.endMs - range.startMs),
        source,
        signalScore,
        processedAudio: processSegment(raw, noiseProfile, options)
      };
    });

    const transfer = segments.map((segment) => segment.processedAudio.buffer);
    self.postMessage({ type: "analysis-complete", requestId, segments, sileroAvailable, sileroError }, { transfer });
  } catch (error) {
    self.postMessage({
      type: "analysis-error",
      requestId,
      error: error instanceof Error ? error.message : "Signal analysis failed"
    });
  }
};

export {};
