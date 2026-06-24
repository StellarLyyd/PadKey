/// <reference lib="webworker" />

import type { BrowserSignalModel } from "../types";

interface TrainingExample {
  label: string;
  features: number[];
}

interface TrainMessage {
  type: "train";
  requestId: number;
  examples: TrainingExample[];
  batchSize: number;
}

interface PreparedExample {
  labelIndex: number;
  features: number[];
}

function mean(values: number[]) {
  return values.reduce((sum, value) => sum + value, 0) / Math.max(1, values.length);
}

function softmax(values: number[]) {
  const maximum = Math.max(...values);
  const exponentials = values.map((value) => Math.exp(value - maximum));
  const total = exponentials.reduce((sum, value) => sum + value, 0) || 1;
  return exponentials.map((value) => value / total);
}

function accuracy(examples: PreparedExample[], weights: number[][], bias: number[]) {
  if (!examples.length) return 0;
  let correct = 0;
  for (const example of examples) {
    const logits = weights.map((row, labelIndex) => {
      return bias[labelIndex] + row.reduce((sum, weight, featureIndex) => sum + weight * example.features[featureIndex], 0);
    });
    const prediction = logits.indexOf(Math.max(...logits));
    if (prediction === example.labelIndex) correct += 1;
  }
  return correct / examples.length;
}

function splitExamples(examples: TrainingExample[], labels: string[]) {
  const training: TrainingExample[] = [];
  const validation: TrainingExample[] = [];
  for (const label of labels) {
    const group = examples.filter((example) => example.label === label);
    const validationCount = group.length >= 5 ? Math.max(1, Math.floor(group.length * 0.2)) : 1;
    validation.push(...group.slice(-validationCount));
    training.push(...group.slice(0, -validationCount));
  }
  return { training, validation };
}

self.onmessage = (event: MessageEvent<TrainMessage>) => {
  const message = event.data;
  if (message.type !== "train") return;

  try {
    const labels = [...new Set(message.examples.map((example) => example.label))].sort((a, b) => {
      if (a === "rest") return -1;
      if (b === "rest") return 1;
      return a.localeCompare(b);
    });
    if (labels.length < 2) throw new Error("Capture at least two labels before training.");
    const featureCount = message.examples[0]?.features.length ?? 0;
    if (!featureCount || message.examples.some((example) => example.features.length !== featureCount)) {
      throw new Error("Training batches do not share one feature shape.");
    }

    const { training, validation } = splitExamples(message.examples, labels);
    const labelIndex = new Map(labels.map((label, index) => [label, index]));
    const featureMean = Array.from({ length: featureCount }, (_, index) => mean(training.map((item) => item.features[index])));
    const featureStd = Array.from({ length: featureCount }, (_, index) => {
      const variance = mean(training.map((item) => (item.features[index] - featureMean[index]) ** 2));
      return Math.max(Math.sqrt(variance), 1e-6);
    });
    const prepare = (example: TrainingExample): PreparedExample => ({
      labelIndex: labelIndex.get(example.label) ?? 0,
      features: example.features.map((value, index) => (value - featureMean[index]) / featureStd[index])
    });
    const trainSet = training.map(prepare);
    const validationSet = validation.map(prepare);
    const weights = labels.map(() => Array.from({ length: featureCount }, () => 0));
    const bias = labels.map(() => 0);
    const counts = labels.map((_, index) => Math.max(1, trainSet.filter((item) => item.labelIndex === index).length));
    const classWeights = counts.map((count) => trainSet.length / (labels.length * count));
    const epochs = 320;
    let loss = 0;

    for (let epoch = 0; epoch < epochs; epoch += 1) {
      const weightGradient = labels.map(() => Array.from({ length: featureCount }, () => 0));
      const biasGradient = labels.map(() => 0);
      loss = 0;
      for (const example of trainSet) {
        const logits = weights.map((row, classIndex) => {
          return bias[classIndex] + row.reduce((sum, weight, featureIndex) => sum + weight * example.features[featureIndex], 0);
        });
        const probabilities = softmax(logits);
        const sampleWeight = classWeights[example.labelIndex];
        loss -= Math.log(Math.max(1e-9, probabilities[example.labelIndex])) * sampleWeight;
        for (let classIndex = 0; classIndex < labels.length; classIndex += 1) {
          const error = (probabilities[classIndex] - (classIndex === example.labelIndex ? 1 : 0)) * sampleWeight;
          biasGradient[classIndex] += error;
          for (let featureIndex = 0; featureIndex < featureCount; featureIndex += 1) {
            weightGradient[classIndex][featureIndex] += error * example.features[featureIndex];
          }
        }
      }

      const learningRate = 0.075 / Math.sqrt(1 + epoch / 48);
      const scale = 1 / Math.max(1, trainSet.length);
      for (let classIndex = 0; classIndex < labels.length; classIndex += 1) {
        bias[classIndex] -= learningRate * biasGradient[classIndex] * scale;
        for (let featureIndex = 0; featureIndex < featureCount; featureIndex += 1) {
          const regularized = weightGradient[classIndex][featureIndex] * scale + weights[classIndex][featureIndex] * 0.001;
          weights[classIndex][featureIndex] -= learningRate * regularized;
        }
      }

      if (epoch % 16 === 0 || epoch === epochs - 1) {
        self.postMessage({
          type: "training-progress",
          requestId: message.requestId,
          progress: Math.round(((epoch + 1) / epochs) * 100),
          loss: loss / Math.max(1, trainSet.length)
        });
      }
    }

    const model: BrowserSignalModel = {
      version: 1,
      labels,
      featureCount,
      batchSize: message.batchSize,
      featureMean,
      featureStd,
      weights,
      bias,
      accuracy: accuracy(validationSet.length ? validationSet : trainSet, weights, bias),
      trainedAt: Date.now(),
      trainingBatches: message.examples.length
    };
    self.postMessage({ type: "training-complete", requestId: message.requestId, model });
  } catch (error) {
    self.postMessage({
      type: "training-error",
      requestId: message.requestId,
      error: error instanceof Error ? error.message : "Signal model training failed"
    });
  }
};

export {};
