import { Mp3Encoder } from "@breezystack/lamejs";

export interface ProcessingOptions {
  removeDc: boolean;
  highPass: boolean;
  noiseGate: boolean;
  normalize: boolean;
  gateDb: number;
}

export function mergePcmChunks(chunks: Int16Array[]) {
  const length = chunks.reduce((sum, chunk) => sum + chunk.length, 0);
  const merged = new Int16Array(length);
  let offset = 0;
  for (const chunk of chunks) {
    merged.set(chunk, offset);
    offset += chunk.length;
  }
  return merged;
}

export function processPcm(input: Int16Array, sampleRate: number, options: ProcessingOptions) {
  if (!input.length) {
    return new Int16Array(0);
  }

  const working = Float32Array.from(input, (sample) => sample / 32768);

  if (options.removeDc) {
    const mean = working.reduce((sum, sample) => sum + sample, 0) / working.length;
    for (let index = 0; index < working.length; index += 1) {
      working[index] -= mean;
    }
  }

  if (options.highPass) {
    const cutoffHz = 80;
    const rc = 1 / (2 * Math.PI * cutoffHz);
    const dt = 1 / sampleRate;
    const alpha = rc / (rc + dt);
    let previousInput = working[0];
    let previousOutput = working[0];
    for (let index = 1; index < working.length; index += 1) {
      const current = working[index];
      const filtered = alpha * (previousOutput + current - previousInput);
      working[index] = filtered;
      previousInput = current;
      previousOutput = filtered;
    }
  }

  if (options.noiseGate) {
    const threshold = 10 ** (options.gateDb / 20);
    const release = Math.max(1, Math.round(sampleRate * 0.02));
    let envelope = 0;
    for (let index = 0; index < working.length; index += 1) {
      envelope = Math.max(Math.abs(working[index]), envelope - 1 / release);
      if (envelope < threshold) {
        working[index] = 0;
      }
    }
  }

  if (options.normalize) {
    let peak = 0;
    for (const sample of working) {
      peak = Math.max(peak, Math.abs(sample));
    }
    if (peak > 0) {
      const gain = Math.min(12, 0.891 / peak); // -1 dBFS target, capped at +21.6 dB.
      for (let index = 0; index < working.length; index += 1) {
        working[index] *= gain;
      }
    }
  }

  return Int16Array.from(working, (sample) => Math.round(Math.max(-1, Math.min(0.999969, sample)) * 32768));
}

export function encodeWav(samples: Int16Array, sampleRate: number) {
  const bytesPerSample = 2;
  const dataLength = samples.length * bytesPerSample;
  const buffer = new ArrayBuffer(44 + dataLength);
  const view = new DataView(buffer);

  function writeText(offset: number, text: string) {
    for (let index = 0; index < text.length; index += 1) {
      view.setUint8(offset + index, text.charCodeAt(index));
    }
  }

  writeText(0, "RIFF");
  view.setUint32(4, 36 + dataLength, true);
  writeText(8, "WAVE");
  writeText(12, "fmt ");
  view.setUint32(16, 16, true);
  view.setUint16(20, 1, true);
  view.setUint16(22, 1, true);
  view.setUint32(24, sampleRate, true);
  view.setUint32(28, sampleRate * bytesPerSample, true);
  view.setUint16(32, bytesPerSample, true);
  view.setUint16(34, 16, true);
  writeText(36, "data");
  view.setUint32(40, dataLength, true);

  for (let index = 0; index < samples.length; index += 1) {
    view.setInt16(44 + index * 2, samples[index], true);
  }

  return new Blob([buffer], { type: "audio/wav" });
}

export function encodeMp3(samples: Int16Array, sampleRate: number, kbps = 96) {
  const encoder = new Mp3Encoder(1, sampleRate, kbps);
  const chunks: ArrayBuffer[] = [];
  const blockSize = 1152;

  for (let offset = 0; offset < samples.length; offset += blockSize) {
    const encoded = encoder.encodeBuffer(samples.subarray(offset, Math.min(offset + blockSize, samples.length)));
    if (encoded.length) {
      chunks.push(Uint8Array.from(encoded).buffer);
    }
  }

  const flushed = encoder.flush();
  if (flushed.length) {
    chunks.push(Uint8Array.from(flushed).buffer);
  }

  return new Blob(chunks, { type: "audio/mpeg" });
}

export function downloadBlob(blob: Blob, filename: string) {
  const url = URL.createObjectURL(blob);
  const anchor = document.createElement("a");
  anchor.href = url;
  anchor.download = filename;
  document.body.appendChild(anchor);
  anchor.click();
  anchor.remove();
  window.setTimeout(() => URL.revokeObjectURL(url), 1000);
}
