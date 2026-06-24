import { useEffect, useRef, useState } from "react";
import type { CaptureMode, SpeechSegment } from "../types";

export interface SpeechAnalysisOptions {
  mode: CaptureMode;
  gapMs: number;
  sileroThreshold: number;
  minSpeechMs: number;
  spectralGate: boolean;
  preEmphasis: boolean;
  rmsNormalize: boolean;
  contactRanges: Array<{ startMs: number; endMs: number }>;
}

interface PendingAnalysis {
  resolve: (value: { segments: SpeechSegment[]; sileroAvailable: boolean; sileroError: string | null }) => void;
  reject: (reason: Error) => void;
}

export function useSpeechAnalysis() {
  const workerRef = useRef<Worker | null>(null);
  const pendingRef = useRef(new Map<number, PendingAnalysis>());
  const nextRequestRef = useRef(1);
  const [status, setStatus] = useState<"idle" | "analyzing" | "complete" | "error">("idle");
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    const worker = new Worker(new URL("./signal.worker.ts", import.meta.url), { type: "module" });
    workerRef.current = worker;
    worker.onmessage = (event) => {
      const pending = pendingRef.current.get(event.data.requestId);
      if (!pending) return;
      pendingRef.current.delete(event.data.requestId);
      if (event.data.type === "analysis-complete") {
        setStatus("complete");
        pending.resolve({
          segments: event.data.segments as SpeechSegment[],
          sileroAvailable: Boolean(event.data.sileroAvailable),
          sileroError: event.data.sileroError ? String(event.data.sileroError) : null
        });
      } else {
        const message = String(event.data.error ?? "Signal analysis failed");
        setStatus("error");
        setError(message);
        pending.reject(new Error(message));
      }
    };
    worker.onerror = (event) => {
      setStatus("error");
      setError(event.message || "Signal worker failed");
    };
    return () => {
      worker.terminate();
      for (const pending of pendingRef.current.values()) pending.reject(new Error("Signal worker stopped"));
      pendingRef.current.clear();
    };
  }, []);

  function analyze(samples: Int16Array, sampleRate: number, options: SpeechAnalysisOptions) {
    const worker = workerRef.current;
    if (!worker) return Promise.reject(new Error("Signal worker is not ready"));
    const requestId = nextRequestRef.current++;
    const transferable = Int16Array.from(samples);
    setStatus("analyzing");
    setError(null);
    return new Promise<{ segments: SpeechSegment[]; sileroAvailable: boolean; sileroError: string | null }>((resolve, reject) => {
      pendingRef.current.set(requestId, { resolve, reject });
      worker.postMessage(
        { type: "analyze", requestId, samples: transferable.buffer, sampleRate, options },
        [transferable.buffer]
      );
    });
  }

  return { analyze, status, error };
}
