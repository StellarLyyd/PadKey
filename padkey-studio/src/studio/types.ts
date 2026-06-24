import type { AudioChannel, AudioChannelMap } from "../types";

export type AudioSource = "device" | "import";

export type ProcessingPreset = "natural" | "clear" | "strong" | "custom";

export interface SoundAdjustments {
  noise: number;
  clarity: number;
  voice: number;
  loudness: number;
}

export interface AudioProject {
  id: string;
  name: string;
  source: AudioSource;
  sourceName: string | null;
  createdAt: number;
  updatedAt: number;
  sampleRate: number;
  samples: Int16Array;
  tracks?: Partial<AudioChannelMap<Int16Array>>;
  selectedChannel?: AudioChannel;
  visibleChannels?: AudioChannelMap<boolean>;
  durationMs: number;
  trimStartMs: number;
  trimEndMs: number;
  preset: ProcessingPreset;
  adjustments: SoundAdjustments;
  transcript: string;
  transcriptStale: boolean;
}

export interface AudioProjectSummary {
  id: string;
  name: string;
  source: AudioSource;
  createdAt: number;
  updatedAt: number;
  durationMs: number;
}
