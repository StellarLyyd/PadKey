import { CHANNELS } from "../channels";
import type { BrowserSignalModel, CandidateProbability, ChannelKey, SensorFrame } from "../types";

export const SIGNAL_FEATURES_PER_CHANNEL = 8;
export const SIGNAL_FEATURE_COUNT = CHANNELS.length * SIGNAL_FEATURES_PER_CHANNEL;

function average(values: number[]) {
  return values.reduce((sum, value) => sum + value, 0) / Math.max(1, values.length);
}

function deviation(values: number[], mean: number) {
  return Math.sqrt(average(values.map((value) => (value - mean) ** 2)));
}

export function extractSignalBatchFeatures(
  frames: SensorFrame[],
  activeChannels?: Record<ChannelKey, boolean>
) {
  return CHANNELS.flatMap(({ key }) => {
    const values = activeChannels?.[key] === false ? frames.map(() => 0) : frames.map((frame) => Number(frame[key]) || 0);
    if (!values.length) return Array.from({ length: SIGNAL_FEATURES_PER_CHANNEL }, () => 0);

    const mean = average(values);
    const std = deviation(values, mean);
    const minimum = Math.min(...values);
    const maximum = Math.max(...values);
    const deltas = values.slice(1).map((value, index) => value - values[index]);
    const meanAbsoluteDelta = average(deltas.map(Math.abs));
    const maxAbsoluteDelta = deltas.length ? Math.max(...deltas.map(Math.abs)) : 0;
    const slope = values.length > 1 ? (values[values.length - 1] - values[0]) / (values.length - 1) : 0;

    return [mean, std, minimum, maximum, maximum - minimum, meanAbsoluteDelta, maxAbsoluteDelta, slope];
  });
}

function softmax(values: number[]) {
  const maximum = Math.max(...values);
  const exponentials = values.map((value) => Math.exp(value - maximum));
  const total = exponentials.reduce((sum, value) => sum + value, 0) || 1;
  return exponentials.map((value) => value / total);
}

export function predictBrowserSignalModel(model: BrowserSignalModel, rawFeatures: number[]) {
  if (rawFeatures.length !== model.featureCount) return null;
  const features = rawFeatures.map(
    (value, index) => (value - model.featureMean[index]) / Math.max(model.featureStd[index], 1e-6)
  );
  const logits = model.labels.map((_, labelIndex) => {
    return model.bias[labelIndex] + features.reduce((sum, value, featureIndex) => {
      return sum + value * model.weights[labelIndex][featureIndex];
    }, 0);
  });
  const probabilities = softmax(logits);
  const candidates: CandidateProbability[] = model.labels
    .map((word, index) => ({ word, probability: probabilities[index] ?? 0 }))
    .sort((left, right) => right.probability - left.probability);
  const top = candidates[0];
  return top ? { label: top.word, confidence: top.probability, probabilities: candidates } : null;
}

export function isBrowserSignalModel(value: unknown): value is BrowserSignalModel {
  if (!value || typeof value !== "object") return false;
  const model = value as Partial<BrowserSignalModel>;
  return (
    model.version === 1 &&
    Array.isArray(model.labels) &&
    model.labels.length >= 2 &&
    typeof model.featureCount === "number" &&
    Array.isArray(model.featureMean) &&
    Array.isArray(model.featureStd) &&
    Array.isArray(model.weights) &&
    Array.isArray(model.bias) &&
    typeof model.batchSize === "number"
  );
}
