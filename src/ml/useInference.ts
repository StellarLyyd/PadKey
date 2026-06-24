import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import * as ort from "onnxruntime-web";
import { FEATURE_COUNT } from "../channels";
import { useAppStore } from "../store";
import type { CandidateProbability, ModelMetadata } from "../types";
import { extractFeatures } from "./featureExtract";

type PredictionResult = { word: string; confidence: number } | null;

type MetadataFile = {
  classes?: unknown;
  accuracy?: unknown;
  features?: unknown;
};

function softmax(values: number[]) {
  const max = Math.max(...values);
  const exp = values.map((value) => Math.exp(value - max));
  const sum = exp.reduce((total, value) => total + value, 0);
  return exp.map((value) => value / sum);
}

function normalizeProbabilities(values: number[]) {
  if (values.length === 0) {
    return values;
  }

  const hasLogits = values.some((value) => value < 0 || value > 1);
  if (hasLogits) {
    return softmax(values);
  }

  const sum = values.reduce((total, value) => total + value, 0);
  if (sum <= 0) {
    return values.map(() => 0);
  }

  if (Math.abs(sum - 1) > 0.02) {
    return values.map((value) => value / sum);
  }

  return values;
}

function readFromMap(value: unknown, classes: string[]) {
  if (!(value instanceof Map)) {
    return null;
  }

  return classes.map((word, index) => {
    const direct = value.get(word);
    const numeric = value.get(index);
    return Number(direct ?? numeric ?? 0);
  });
}

function readFromObject(value: unknown, classes: string[]) {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    return null;
  }

  const record = value as Record<string, unknown>;
  return classes.map((word, index) => Number(record[word] ?? record[index] ?? 0));
}

function tensorNumbers(tensor: ort.Tensor, count: number) {
  const data = Array.from(tensor.data as ArrayLike<unknown>).slice(0, count);
  if (data.some((value) => typeof value !== "number" && typeof value !== "bigint")) {
    return null;
  }
  return data.map((value) => Number(value));
}

function readProbabilities(results: ort.InferenceSession.OnnxValueMapType, classes: string[]) {
  const values = Object.values(results);
  const tensor = values.find((value): value is ort.Tensor => {
    return Boolean(value && typeof value === "object" && "data" in value && (value as ort.Tensor).data.length >= classes.length);
  });

  if (tensor) {
    const numbers = tensorNumbers(tensor, classes.length);
    return numbers ? normalizeProbabilities(numbers) : null;
  }

  for (const value of values) {
    if (Array.isArray(value) && value.length > 0) {
      const fromMap = readFromMap(value[0], classes);
      if (fromMap) {
        return normalizeProbabilities(fromMap);
      }

      const fromObject = readFromObject(value[0], classes);
      if (fromObject) {
        return normalizeProbabilities(fromObject);
      }
    }

    const fromMap = readFromMap(value, classes);
    if (fromMap) {
      return normalizeProbabilities(fromMap);
    }

    const fromObject = readFromObject(value, classes);
    if (fromObject) {
      return normalizeProbabilities(fromObject);
    }
  }

  return null;
}

async function readMetadata(file: File | undefined, fallbackName: string): Promise<ModelMetadata> {
  if (!file) {
    return { classes: [], accuracy: null, features: null, filename: fallbackName };
  }

  const parsed = JSON.parse(await file.text()) as MetadataFile;
  const classes = Array.isArray(parsed.classes) ? parsed.classes.filter((item): item is string => typeof item === "string") : [];
  const accuracy = typeof parsed.accuracy === "number" ? parsed.accuracy : null;
  const features = typeof parsed.features === "number" ? parsed.features : null;

  return {
    classes,
    accuracy,
    features,
    filename: fallbackName
  };
}

export function useInference(): {
  loadModel: (file: File, metadataFile?: File) => Promise<void>;
  predict: (features: number[]) => Promise<PredictionResult>;
  modelLoaded: boolean;
  vocabulary: string[];
  loading: boolean;
  error: string | null;
} {
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const sessionRef = useRef<ort.InferenceSession | null>(null);
  const inputNameRef = useRef("float_input");
  const lastRunFrameCountRef = useRef(0);
  const inFlightRef = useRef(false);

  const frameHistory = useAppStore((state) => state.frameHistory);
  const frameCount = useAppStore((state) => state.frameCount);
  const activeChannels = useAppStore((state) => state.activeChannels);
  const bleConnected = useAppStore((state) => state.bleConnected);
  const serialConnected = useAppStore((state) => state.serialConnected);
  const modelLoaded = useAppStore((state) => state.modelLoaded);
  const storeVocabulary = useAppStore((state) => state.vocabulary);
  const modelMetadata = useAppStore((state) => state.modelMetadata);
  const setModelLoaded = useAppStore((state) => state.setModelLoaded);
  const setModelMetadata = useAppStore((state) => state.setModelMetadata);
  const pushPrediction = useAppStore((state) => state.pushPrediction);
  const setCandidateProbabilities = useAppStore((state) => state.setCandidateProbabilities);

  const vocabulary = useMemo(() => {
    return modelMetadata?.classes.length ? modelMetadata.classes : storeVocabulary;
  }, [modelMetadata, storeVocabulary]);

  const loadModel = useCallback(
    async (file: File, metadataFile?: File) => {
      setLoading(true);
      setError(null);

      try {
        const buffer = await file.arrayBuffer();
        const session = await ort.InferenceSession.create(buffer);
        sessionRef.current = session;
        inputNameRef.current = session.inputNames[0] ?? "float_input";

        const metadata = await readMetadata(metadataFile, file.name);
        setModelMetadata(metadata);
        setCandidateProbabilities([]);
        setModelLoaded(true);
        lastRunFrameCountRef.current = frameCount;
      } catch (err) {
        sessionRef.current = null;
        setModelLoaded(false);
        setModelMetadata(null);
        setCandidateProbabilities([]);
        setError(err instanceof Error ? err.message : "Could not load model");
      } finally {
        setLoading(false);
      }
    },
    [frameCount, setCandidateProbabilities, setModelLoaded, setModelMetadata]
  );

  const predict = useCallback(
    async (features: number[]): Promise<PredictionResult> => {
      const session = sessionRef.current;
      if (!session || features.length !== FEATURE_COUNT) {
        return null;
      }

      const classes = vocabulary.length ? vocabulary : storeVocabulary;
      const input = new ort.Tensor("float32", Float32Array.from(features), [1, FEATURE_COUNT]);
      const results = await session.run({ [inputNameRef.current]: input });
      const probabilities = readProbabilities(results, classes);

      if (!probabilities) {
        return null;
      }

      const candidates: CandidateProbability[] = classes
        .map((word, index) => ({ word, probability: probabilities[index] ?? 0 }))
        .sort((a, b) => b.probability - a.probability);

      setCandidateProbabilities(candidates);
      const top = candidates[0];
      return top ? { word: top.word, confidence: top.probability } : null;
    },
    [setCandidateProbabilities, storeVocabulary, vocabulary]
  );

  useEffect(() => {
    if (!modelLoaded || (!bleConnected && !serialConnected) || frameHistory.length < 20 || inFlightRef.current) {
      return;
    }

    if (frameCount - lastRunFrameCountRef.current < 20) {
      return;
    }

    lastRunFrameCountRef.current = frameCount;
    inFlightRef.current = true;

    const features = extractFeatures(frameHistory.slice(-20), 20, activeChannels);
    void predict(features)
      .then((result) => {
        if (result) {
          pushPrediction(result.word, result.confidence);
        }
      })
      .catch((err) => {
        setError(err instanceof Error ? err.message : "Inference failed");
      })
      .finally(() => {
        inFlightRef.current = false;
      });
  }, [activeChannels, bleConnected, frameCount, frameHistory, modelLoaded, predict, pushPrediction, serialConnected]);

  return { loadModel, predict, modelLoaded, vocabulary, loading, error };
}
