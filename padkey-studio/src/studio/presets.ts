import type { ProcessingPreset, SoundAdjustments } from "./types";

export const STUDIO_SAMPLE_RATE = 16000;

export const SOUND_PRESETS: Record<Exclude<ProcessingPreset, "custom">, SoundAdjustments> = {
  natural: { noise: 20, clarity: 20, voice: 15, loudness: 50 },
  clear: { noise: 45, clarity: 55, voice: 35, loudness: 55 },
  strong: { noise: 65, clarity: 70, voice: 60, loudness: 65 }
};

export const DEFAULT_ADJUSTMENTS = SOUND_PRESETS.clear;

export function presetLabel(preset: ProcessingPreset) {
  return preset.charAt(0).toUpperCase() + preset.slice(1);
}
