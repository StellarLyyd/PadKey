/// <reference lib="webworker" />

import { processStudioAudio } from "./processStudioAudio";
import type { SoundAdjustments } from "./types";

interface ProcessRequest {
  type: "process";
  requestId: number;
  samples: ArrayBuffer;
  sampleRate: number;
  adjustments: SoundAdjustments;
}

self.onmessage = (event: MessageEvent<ProcessRequest>) => {
  if (event.data.type !== "process") return;
  const output = processStudioAudio(
    new Int16Array(event.data.samples),
    event.data.sampleRate,
    event.data.adjustments
  );
  self.postMessage(
    { type: "processed", requestId: event.data.requestId, samples: output.buffer },
    { transfer: [output.buffer] }
  );
};

export {};
