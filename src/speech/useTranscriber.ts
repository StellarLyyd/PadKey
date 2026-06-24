import { useEffect, useRef, useState } from "react";
import type { SegmentTranscript, SpeechSegment } from "../types";

interface PendingTranscription {
  resolve: (results: SegmentTranscript[]) => void;
  reject: (error: Error) => void;
}

export function useTranscriber() {
  const workerRef = useRef<Worker | null>(null);
  const pendingRef = useRef<PendingTranscription | null>(null);
  const [modelStatus, setModelStatus] = useState<"idle" | "loading" | "ready" | "error">("idle");
  const [modelProgress, setModelProgress] = useState(0);
  const [modelFile, setModelFile] = useState<string | null>(null);
  const [transcriptionProgress, setTranscriptionProgress] = useState({ current: 0, total: 0 });
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    const worker = new Worker(new URL("./transcription.worker.ts", import.meta.url), { type: "module" });
    workerRef.current = worker;
    worker.onmessage = (event) => {
      const message = event.data;
      if (message.type === "model-status") {
        if (message.status === "ready") setModelStatus("ready");
        else setModelStatus("loading");
        if (typeof message.progress === "number") setModelProgress(Math.round(message.progress));
        if (message.file) setModelFile(String(message.file));
      }
      if (message.type === "transcription-progress") {
        setTranscriptionProgress({ current: Number(message.current), total: Number(message.total) });
      }
      if (message.type === "transcription-complete") {
        pendingRef.current?.resolve(message.results as SegmentTranscript[]);
        pendingRef.current = null;
        setTranscriptionProgress((current) => ({ ...current, current: current.total }));
      }
      if (message.type === "transcription-error") {
        const nextError = new Error(String(message.error ?? "Transcription failed"));
        pendingRef.current?.reject(nextError);
        pendingRef.current = null;
        setError(nextError.message);
        setModelStatus("error");
      }
    };
    worker.onerror = (event) => {
      const nextError = new Error(event.message || "Transcription worker failed");
      pendingRef.current?.reject(nextError);
      pendingRef.current = null;
      setError(nextError.message);
      setModelStatus("error");
    };
    return () => {
      worker.terminate();
      pendingRef.current?.reject(new Error("Transcription worker stopped"));
      pendingRef.current = null;
    };
  }, []);

  function load(model: string) {
    setModelStatus("loading");
    setModelProgress(0);
    setError(null);
    workerRef.current?.postMessage({ type: "load", model });
  }

  function transcribe(model: string, segments: SpeechSegment[]) {
    const worker = workerRef.current;
    if (!worker) return Promise.reject(new Error("Transcription worker is not ready"));
    if (pendingRef.current) return Promise.reject(new Error("A transcription is already running"));
    const copies = segments.map((segment) => ({ id: segment.id, audio: Float32Array.from(segment.processedAudio) }));
    setError(null);
    setTranscriptionProgress({ current: 0, total: segments.length });
    return new Promise<SegmentTranscript[]>((resolve, reject) => {
      pendingRef.current = { resolve, reject };
      worker.postMessage(
        { type: "transcribe", model, segments: copies.map((item) => ({ id: item.id, audio: item.audio.buffer })) },
        copies.map((item) => item.audio.buffer)
      );
    });
  }

  return { load, transcribe, modelStatus, modelProgress, modelFile, transcriptionProgress, error };
}
