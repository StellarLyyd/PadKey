import type { SoundAdjustments } from "./types";

function clamp(value: number, minimum: number, maximum: number) {
  return Math.max(minimum, Math.min(maximum, value));
}

function removeDc(samples: Float32Array) {
  let mean = 0;
  for (const sample of samples) mean += sample;
  mean /= Math.max(1, samples.length);
  for (let index = 0; index < samples.length; index += 1) samples[index] -= mean;
}

function highPass(samples: Float32Array, sampleRate: number, cutoffHz: number) {
  if (samples.length < 2) return;
  const rc = 1 / (2 * Math.PI * cutoffHz);
  const dt = 1 / sampleRate;
  const alpha = rc / (rc + dt);
  let previousInput = samples[0];
  let previousOutput = samples[0];
  for (let index = 1; index < samples.length; index += 1) {
    const input = samples[index];
    const output = alpha * (previousOutput + input - previousInput);
    samples[index] = output;
    previousInput = input;
    previousOutput = output;
  }
}

function percentile(values: number[], fraction: number) {
  if (!values.length) return 0;
  values.sort((left, right) => left - right);
  return values[Math.min(values.length - 1, Math.floor(values.length * fraction))];
}

function reduceNoise(samples: Float32Array, sampleRate: number, amount: number) {
  if (amount <= 0 || !samples.length) return;
  const frameSize = Math.max(1, Math.round(sampleRate * 0.02));
  const levels: number[] = [];
  for (let start = 0; start < samples.length; start += frameSize) {
    let energy = 0;
    const end = Math.min(samples.length, start + frameSize);
    for (let index = start; index < end; index += 1) energy += samples[index] * samples[index];
    levels.push(Math.sqrt(energy / Math.max(1, end - start)));
  }

  const strength = clamp(amount / 100, 0, 1);
  const floor = Math.max(0.00035, percentile(levels, 0.25));
  const threshold = floor * (1.35 + strength * 2.65);
  const minimumGain = 1 - strength * 0.88;
  const attack = 1 - Math.exp(-1 / Math.max(1, sampleRate * 0.004));
  const release = 1 - Math.exp(-1 / Math.max(1, sampleRate * 0.06));
  let envelope = 0;
  let gain = 1;

  for (let index = 0; index < samples.length; index += 1) {
    const magnitude = Math.abs(samples[index]);
    envelope += (magnitude - envelope) * (magnitude > envelope ? attack : release);
    const softWidth = threshold * 0.6;
    const speechMix = clamp((envelope - threshold + softWidth) / Math.max(1e-6, softWidth * 2), 0, 1);
    const targetGain = minimumGain + (1 - minimumGain) * speechMix;
    gain += (targetGain - gain) * (targetGain > gain ? attack : release);
    samples[index] *= gain;
  }
}

function addClarity(samples: Float32Array, amount: number) {
  if (amount <= 0 || samples.length < 2) return;
  const strength = clamp(amount / 100, 0, 1) * 0.58;
  let previous = samples[0];
  for (let index = 1; index < samples.length; index += 1) {
    const input = samples[index];
    const detail = input - previous;
    samples[index] = input + detail * strength;
    previous = input;
  }
}

function strengthenVoice(samples: Float32Array, amount: number) {
  if (amount <= 0) return;
  const strength = clamp(amount / 100, 0, 1);
  const threshold = 0.3 - strength * 0.22;
  const ratio = 1 + strength * 3;
  const makeup = 1 + strength * 0.55;
  for (let index = 0; index < samples.length; index += 1) {
    const sign = samples[index] < 0 ? -1 : 1;
    const magnitude = Math.abs(samples[index]);
    const compressed = magnitude <= threshold
      ? magnitude
      : threshold + (magnitude - threshold) / ratio;
    samples[index] = sign * compressed * makeup;
  }
}

function applyLoudnessAndLimit(samples: Float32Array, loudness: number) {
  const decibels = (clamp(loudness, 0, 100) - 50) * 0.18;
  const gain = 10 ** (decibels / 20);
  let peak = 0;
  for (let index = 0; index < samples.length; index += 1) {
    samples[index] *= gain;
    peak = Math.max(peak, Math.abs(samples[index]));
  }

  const ceiling = 10 ** (-1 / 20);
  const limiter = peak > ceiling ? ceiling / peak : 1;
  for (let index = 0; index < samples.length; index += 1) {
    samples[index] = clamp(samples[index] * limiter, -1, 0.999969);
  }
}

export function processStudioAudio(
  input: Int16Array,
  sampleRate: number,
  adjustments: SoundAdjustments
) {
  if (!input.length) return new Int16Array(0);
  const samples = Float32Array.from(input, (sample) => sample / 32768);
  removeDc(samples);
  highPass(samples, sampleRate, 45 + adjustments.noise * 0.75);
  reduceNoise(samples, sampleRate, adjustments.noise);
  addClarity(samples, adjustments.clarity);
  strengthenVoice(samples, adjustments.voice);
  applyLoudnessAndLimit(samples, adjustments.loudness);
  return Int16Array.from(samples, (sample) => Math.round(sample * 32768));
}

export function trimPcm(samples: Int16Array, sampleRate: number, startMs: number, endMs: number) {
  const start = clamp(Math.floor((startMs / 1000) * sampleRate), 0, samples.length);
  const end = clamp(Math.ceil((endMs / 1000) * sampleRate), start, samples.length);
  return samples.slice(start, end);
}
