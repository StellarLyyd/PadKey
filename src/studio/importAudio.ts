import { DEFAULT_ADJUSTMENTS, STUDIO_SAMPLE_RATE } from "./presets";
import { createAudioChannelMap } from "./audioChannels";
import type { AudioProject, AudioSource } from "./types";
import type { AudioChannel, AudioChannelMap } from "../types";

const MAX_FILE_BYTES = 100 * 1024 * 1024;
const MAX_DURATION_SECONDS = 10 * 60;

function resampleLinear(input: Float32Array, fromRate: number, toRate: number) {
  if (fromRate === toRate) return input;
  const length = Math.max(1, Math.round((input.length * toRate) / fromRate));
  const output = new Float32Array(length);
  const ratio = fromRate / toRate;
  for (let index = 0; index < length; index += 1) {
    const position = index * ratio;
    const lower = Math.floor(position);
    const upper = Math.min(input.length - 1, lower + 1);
    const mix = position - lower;
    output[index] = input[lower] * (1 - mix) + input[upper] * mix;
  }
  return output;
}

function projectName(sourceName: string | null, source: AudioSource) {
  if (sourceName) return sourceName.replace(/\.[^.]+$/, "").slice(0, 80) || "Imported audio";
  return `Recording ${new Date().toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" })}`;
}

export function createAudioProject(
  samples: Int16Array,
  sampleRate: number,
  source: AudioSource,
  sourceName: string | null = null
): AudioProject {
  const now = Date.now();
  const durationMs = (samples.length / sampleRate) * 1000;
  return {
    id: `audio-${now}-${crypto.randomUUID?.() ?? Math.random().toString(36).slice(2)}`,
    name: projectName(sourceName, source),
    source,
    sourceName,
    createdAt: now,
    updatedAt: now,
    sampleRate,
    samples,
    durationMs,
    trimStartMs: 0,
    trimEndMs: durationMs,
    preset: "clear",
    adjustments: { ...DEFAULT_ADJUSTMENTS },
    transcript: "",
    transcriptStale: false
  };
}

export function createDeviceAudioProject(
  tracks: Partial<AudioChannelMap<Int16Array>>,
  sampleRate: number,
  preferredChannel: AudioChannel = "inmp441"
) {
  const availableChannels = (Object.keys(tracks) as AudioChannel[]).filter((channel) => Boolean(tracks[channel]?.length));
  const selectedChannel = availableChannels.includes(preferredChannel) ? preferredChannel : availableChannels[0];
  if (!selectedChannel) throw new Error("No recordable waveform was captured.");
  const primarySamples = tracks[selectedChannel] as Int16Array;
  const project = createAudioProject(primarySamples, sampleRate, "device");
  const longestSamples = availableChannels.reduce((longest, channel) => Math.max(longest, tracks[channel]?.length ?? 0), 0);
  const durationMs = (longestSamples / sampleRate) * 1000;
  return {
    ...project,
    samples: primarySamples,
    tracks,
    selectedChannel,
    visibleChannels: createAudioChannelMap((channel) => availableChannels.includes(channel)),
    durationMs,
    trimEndMs: durationMs
  } satisfies AudioProject;
}

export async function importAudioFile(file: File) {
  if (file.size > MAX_FILE_BYTES) throw new Error("Choose an audio file smaller than 100 MB.");
  if (!file.type.startsWith("audio/") && !/\.(wav|mp3)$/i.test(file.name)) {
    throw new Error("Choose a WAV or MP3 audio file.");
  }

  const context = new AudioContext();
  try {
    const decoded = await context.decodeAudioData(await file.arrayBuffer());
    if (decoded.duration > MAX_DURATION_SECONDS) throw new Error("Choose a recording shorter than 10 minutes.");
    const mono = new Float32Array(decoded.length);
    for (let channel = 0; channel < decoded.numberOfChannels; channel += 1) {
      const channelData = decoded.getChannelData(channel);
      for (let index = 0; index < mono.length; index += 1) mono[index] += channelData[index] / decoded.numberOfChannels;
    }
    const resampled = resampleLinear(mono, decoded.sampleRate, STUDIO_SAMPLE_RATE);
    const samples = Int16Array.from(resampled, (sample) => Math.round(Math.max(-1, Math.min(0.999969, sample)) * 32768));
    return createAudioProject(samples, STUDIO_SAMPLE_RATE, "import", file.name);
  } catch (error) {
    if (error instanceof Error && /Choose a/.test(error.message)) throw error;
    throw new Error("PadKey could not read this file. Try a standard WAV or MP3 recording.");
  } finally {
    await context.close().catch(() => undefined);
  }
}
