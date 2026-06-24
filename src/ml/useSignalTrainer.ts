import { useEffect, useRef, useState } from "react";
import { extractSignalBatchFeatures } from "./signalModel";
import type { BrowserSignalModel, SignalBatch } from "../types";

interface PendingTraining {
  resolve: (model: BrowserSignalModel) => void;
  reject: (error: Error) => void;
}

export function useSignalTrainer() {
  const workerRef = useRef<Worker | null>(null);
  const pendingRef = useRef<Map<number, PendingTraining>>(new Map());
  const requestIdRef = useRef(0);
  const [status, setStatus] = useState<"idle" | "training" | "ready" | "error">("idle");
  const [progress, setProgress] = useState(0);
  const [loss, setLoss] = useState<number | null>(null);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    const worker = new Worker(new URL("./signalTraining.worker.ts", import.meta.url), { type: "module" });
    workerRef.current = worker;
    worker.onmessage = (event) => {
      const message = event.data as Record<string, unknown>;
      const requestId = Number(message.requestId);
      if (message.type === "training-progress") {
        setProgress(Number(message.progress) || 0);
        setLoss(typeof message.loss === "number" ? message.loss : null);
      }
      if (message.type === "training-complete") {
        pendingRef.current.get(requestId)?.resolve(message.model as BrowserSignalModel);
        pendingRef.current.delete(requestId);
        setProgress(100);
        setStatus("ready");
      }
      if (message.type === "training-error") {
        const nextError = new Error(String(message.error ?? "Signal model training failed"));
        pendingRef.current.get(requestId)?.reject(nextError);
        pendingRef.current.delete(requestId);
        setError(nextError.message);
        setStatus("error");
      }
    };
    worker.onerror = (event) => {
      const nextError = new Error(event.message || "Signal training worker failed");
      pendingRef.current.forEach((pending) => pending.reject(nextError));
      pendingRef.current.clear();
      setError(nextError.message);
      setStatus("error");
    };
    return () => {
      worker.terminate();
      pendingRef.current.forEach((pending) => pending.reject(new Error("Signal trainer stopped")));
      pendingRef.current.clear();
    };
  }, []);

  function train(batches: SignalBatch[]) {
    const worker = workerRef.current;
    if (!worker) return Promise.reject(new Error("Signal trainer is not ready"));
    const requestId = ++requestIdRef.current;
    const batchSize = Math.round(batches.reduce((sum, batch) => sum + batch.frames.length, 0) / Math.max(1, batches.length));
    const examples = batches.map((batch) => ({
      label: batch.label,
      features: extractSignalBatchFeatures(batch.frames, batch.activeChannels)
    }));
    setStatus("training");
    setProgress(0);
    setLoss(null);
    setError(null);
    return new Promise<BrowserSignalModel>((resolve, reject) => {
      pendingRef.current.set(requestId, { resolve, reject });
      worker.postMessage({ type: "train", requestId, examples, batchSize });
    });
  }

  return { train, status, progress, loss, error };
}
