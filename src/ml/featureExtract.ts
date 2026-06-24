import { CHANNELS } from "../channels";
import type { SensorFrame } from "../types";
import type { ChannelKey } from "../types";

const sensorKeys = CHANNELS.map((channel) => channel.key);

function mean(values: number[]) {
  return values.reduce((sum, value) => sum + value, 0) / values.length;
}

function standardDeviation(values: number[], average: number) {
  const variance = values.reduce((sum, value) => sum + (value - average) ** 2, 0) / values.length;
  return Math.sqrt(variance);
}

export function extractFeatures(frames: SensorFrame[], windowSize = 20, activeChannels?: Record<ChannelKey, boolean>): number[] {
  const window = frames.slice(-windowSize);
  if (window.length === 0) {
    return Array.from({ length: 24 }, () => 0);
  }

  return sensorKeys.flatMap((key) => {
    const values = activeChannels?.[key] === false ? window.map(() => 0) : window.map((frame) => frame[key]);
    const average = mean(values);
    return [average, Math.max(...values), Math.min(...values), standardDeviation(values, average)];
  });
}
