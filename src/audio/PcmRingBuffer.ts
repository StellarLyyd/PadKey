export class PcmRingBuffer {
  private readonly data: Int16Array;
  private writeIndex = 0;
  private sampleCount = 0;

  constructor(readonly capacity: number) {
    if (!Number.isInteger(capacity) || capacity <= 0) {
      throw new Error("PCM ring-buffer capacity must be a positive integer");
    }
    this.data = new Int16Array(capacity);
  }

  get length() {
    return this.sampleCount;
  }

  clear() {
    this.writeIndex = 0;
    this.sampleCount = 0;
  }

  push(samples: Int16Array) {
    if (samples.length >= this.capacity) {
      this.data.set(samples.subarray(samples.length - this.capacity));
      this.writeIndex = 0;
      this.sampleCount = this.capacity;
      return;
    }

    const firstLength = Math.min(samples.length, this.capacity - this.writeIndex);
    this.data.set(samples.subarray(0, firstLength), this.writeIndex);
    if (firstLength < samples.length) {
      this.data.set(samples.subarray(firstLength), 0);
    }
    this.writeIndex = (this.writeIndex + samples.length) % this.capacity;
    this.sampleCount = Math.min(this.capacity, this.sampleCount + samples.length);
  }

  snapshot(maxSamples = this.sampleCount) {
    const length = Math.min(this.sampleCount, Math.max(0, maxSamples));
    const output = new Int16Array(length);
    if (!length) return output;

    const start = (this.writeIndex - length + this.capacity) % this.capacity;
    const firstLength = Math.min(length, this.capacity - start);
    output.set(this.data.subarray(start, start + firstLength));
    if (firstLength < length) {
      output.set(this.data.subarray(0, length - firstLength), firstLength);
    }
    return output;
  }
}

// Thirty seconds at the PadKey 16 kHz target. This is the live processing
// ring, separate from the lossless chunks retained for an active session.
export const livePcmRing = new PcmRingBuffer(16000 * 30);
