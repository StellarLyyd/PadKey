import { useEffect, useRef, useState } from "react";
import type { SoundAdjustments } from "./types";

export function useAudioProcessor(
  input: Int16Array | null,
  sampleRate: number,
  adjustments: SoundAdjustments
) {
  const workerRef = useRef<Worker | null>(null);
  const latestRequestRef = useRef(0);
  const lastInputRef = useRef<Int16Array | null>(input);
  const [processed, setProcessed] = useState<Int16Array | null>(input);
  const [processing, setProcessing] = useState(false);

  useEffect(() => {
    const worker = new Worker(new URL("./audio-processing.worker.ts", import.meta.url), { type: "module" });
    workerRef.current = worker;
    worker.onmessage = (event) => {
      if (event.data.type !== "processed" || event.data.requestId !== latestRequestRef.current) return;
      setProcessed(new Int16Array(event.data.samples));
      setProcessing(false);
    };
    return () => worker.terminate();
  }, []);

  useEffect(() => {
    if (!input?.length) {
      lastInputRef.current = input;
      setProcessed(input);
      setProcessing(false);
      return;
    }

    if (lastInputRef.current !== input) {
      lastInputRef.current = input;
      // Never expose a completed result from the previously selected sensor.
      // The untouched current track is a safe preview while its enhancement
      // job runs.
      setProcessed(input);
    }

    setProcessing(true);
    const requestId = latestRequestRef.current + 1;
    latestRequestRef.current = requestId;
    const timeout = window.setTimeout(() => {
      const copy = input.slice();
      workerRef.current?.postMessage(
        { type: "process", requestId, samples: copy.buffer, sampleRate, adjustments },
        [copy.buffer]
      );
    }, 75);
    return () => window.clearTimeout(timeout);
  }, [input, sampleRate, adjustments]);

  return { processed, processing };
}
