import { parseFrame } from "../ble/parser";
import type { AudioChannel, AudioPacket, DeviceStatusMessage, SensorFrame, TransportKind } from "../types";

export type TransportPacket =
  | { kind: "telemetry"; frame: SensorFrame }
  | { kind: "audio"; audio: AudioPacket }
  | { kind: "status"; status: DeviceStatusMessage };

function decodeBase64Pcm(base64: string) {
  const binary = window.atob(base64);
  const bytes = new Uint8Array(binary.length);
  for (let index = 0; index < binary.length; index += 1) {
    bytes[index] = binary.charCodeAt(index);
  }
  return pcmBytesToSamples(bytes.buffer);
}

function pcmBytesToSamples(buffer: ArrayBuffer, byteOffset = 0) {
  const sampleCount = Math.floor((buffer.byteLength - byteOffset) / 2);
  const view = new DataView(buffer, byteOffset);
  const samples = new Int16Array(sampleCount);
  for (let index = 0; index < sampleCount; index += 1) {
    samples[index] = view.getInt16(index * 2, true);
  }
  return samples;
}

function muLawBytesToSamples(buffer: ArrayBuffer, byteOffset: number) {
  const bytes = new Uint8Array(buffer, byteOffset);
  const samples = new Int16Array(bytes.length);
  const bias = 0x84;
  for (let index = 0; index < bytes.length; index += 1) {
    const value = (~bytes[index]) & 0xff;
    let magnitude = ((value & 0x0f) << 3) + bias;
    magnitude <<= (value & 0x70) >> 4;
    samples[index] = value & 0x80 ? bias - magnitude : magnitude - bias;
  }
  return samples;
}

function decodeImaAdpcmBlock(buffer: ArrayBuffer, byteOffset: number, sampleCount: number) {
  const view = new DataView(buffer);
  const bytes = new Uint8Array(buffer);
  const indexTable = [-1, -1, -1, -1, 2, 4, 6, 8, -1, -1, -1, -1, 2, 4, 6, 8];
  const stepTable = [
    7, 8, 9, 10, 11, 12, 13, 14, 16, 17, 19, 21, 23, 25, 28, 31, 34, 37, 41, 45, 50, 55,
    60, 66, 73, 80, 88, 97, 107, 118, 130, 143, 157, 173, 190, 209, 230, 253, 279,
    307, 337, 371, 408, 449, 494, 544, 598, 658, 724, 796, 876, 963, 1060, 1166,
    1282, 1411, 1552, 1707, 1878, 2066, 2272, 2499, 2749, 3024, 3327, 3660,
    4026, 4428, 4871, 5358, 5894, 6484, 7132, 7845, 8630, 9493, 10442, 11487,
    12635, 13899, 15289, 16818, 18500, 20350, 22385, 24623, 27086, 29794, 32767
  ];
  let predictor = view.getInt16(byteOffset, true);
  let stepIndex = Math.max(0, Math.min(88, bytes[byteOffset + 2]));
  const samples = new Int16Array(sampleCount);
  samples[0] = predictor;
  for (let sampleIndex = 1; sampleIndex < sampleCount; sampleIndex += 1) {
    const nibbleIndex = sampleIndex - 1;
    const packed = bytes[byteOffset + 3 + (nibbleIndex >> 1)];
    const code = (packed >> ((nibbleIndex & 1) * 4)) & 0x0f;
    const step = stepTable[stepIndex];
    let delta = step >> 3;
    if (code & 4) delta += step;
    if (code & 2) delta += step >> 1;
    if (code & 1) delta += step >> 2;
    predictor += code & 8 ? -delta : delta;
    predictor = Math.max(-32768, Math.min(32767, predictor));
    stepIndex = Math.max(0, Math.min(88, stepIndex + indexTable[code]));
    samples[sampleIndex] = predictor;
  }
  return samples;
}

function parseAudioChannel(value: unknown): AudioChannel {
  const normalized = String(value ?? "").trim().toLowerCase();
  if (["max4466", "analog", "analogmic", "analog-mic"].includes(normalized)) return "max4466";
  if (["piezo", "contact", "contact-sensor"].includes(normalized)) return "piezo";
  return "inmp441";
}

function parseJsonAudio(raw: string): AudioPacket | null {
  if (!raw.trim().startsWith("{")) {
    return null;
  }

  try {
    const value = JSON.parse(raw) as Record<string, unknown>;
    if (value.type !== "audio" || value.format !== "pcm_s16le") {
      return null;
    }

    const sampleRate = Number(value.sampleRate ?? 16000);
    const channels = Number(value.channels ?? 1);
    if (!Number.isFinite(sampleRate) || sampleRate < 8000 || sampleRate > 96000 || channels !== 1) {
      return null;
    }

    let samples: Int16Array | null = null;
    if (typeof value.pcm === "string") {
      samples = decodeBase64Pcm(value.pcm);
    } else if (Array.isArray(value.samples)) {
      samples = Int16Array.from(value.samples.map((sample) => Math.max(-32768, Math.min(32767, Number(sample) || 0))));
    }

    if (!samples?.length) {
      return null;
    }

    const parsedSequence = Number(value.sequence);
    const sequence = Number.isInteger(parsedSequence) && parsedSequence >= 0 ? parsedSequence >>> 0 : null;
    return { samples, sampleRate, channels: 1, channel: parseAudioChannel(value.channel), sequence, recordable: true, ts: Date.now() };
  } catch {
    return null;
  }
}

function parseJsonStatus(raw: string): DeviceStatusMessage | null {
  if (!raw.trim().startsWith("{")) return null;
  try {
    const value = JSON.parse(raw) as Record<string, unknown>;
    if (value.type !== "status" || typeof value.message !== "string") return null;
    const level = String(value.level ?? "info").toLowerCase();
    return {
      level: level === "fatal" || level === "error" || level === "ready" ? level : "info",
      message: value.message,
      ts: Date.now()
    };
  } catch {
    return null;
  }
}

export function parseTransportLine(raw: string, source: TransportKind): TransportPacket | null {
  const audio = parseJsonAudio(raw);
  if (audio) {
    return { kind: "audio", audio };
  }

  const status = parseJsonStatus(raw);
  if (status) return { kind: "status", status };

  const frame = parseFrame(raw);
  if (!frame) {
    return null;
  }

  return { kind: "telemetry", frame: { ...frame, source } };
}

// Optional binary WebSocket packet for efficient Wi-Fi audio:
// Version 1: bytes 0-3 "PKAU", byte 4 version=1, byte 5 channels=1,
// bytes 6-9 sample rate, bytes 10+ PCM signed 16-bit LE.
// Version 2 adds a uint32 packet sequence at bytes 10-13; PCM begins at 14.
// Version 3 adds a sensor id at byte 14 (0=INMP441, 1=MAX4466,
// 2=piezo); PCM begins at byte 15. Version 4 uses the same framing for
// legacy sparse BLE monitor audio, which must not be exported as a continuous
// recording. Version 5 carries legacy G.711 mu-law. Version 6 carries all
// three synchronized sensors as IMA ADPCM within one 180-byte notification.
export function parseBinaryAudioPackets(buffer: ArrayBuffer): AudioPacket[] {
  if (buffer.byteLength < 12) {
    return [];
  }

  const view = new DataView(buffer);
  const magic = String.fromCharCode(view.getUint8(0), view.getUint8(1), view.getUint8(2), view.getUint8(3));
  const version = view.getUint8(4);
  const channels = view.getUint8(5);
  const sampleRate = view.getUint32(6, true);
  if (magic !== "PKAU" || ![1, 2, 3, 4, 5, 6].includes(version) || sampleRate < 8000 || sampleRate > 96000) {
    return [];
  }
  if (version === 6) {
    const sampleCount = view.getUint8(14);
    const encodedBytes = Math.ceil((sampleCount - 1) / 2);
    const blockBytes = 3 + encodedBytes;
    if (channels !== 3 || sampleCount < 2 || buffer.byteLength < 15 + channels * blockBytes) return [];
    const sequence = view.getUint32(10, true);
    const channelNames: AudioChannel[] = ["inmp441", "max4466", "piezo"];
    return channelNames.map((channel, index) => ({
      samples: decodeImaAdpcmBlock(buffer, 15 + index * blockBytes, sampleCount),
      sampleRate,
      channels: 1,
      channel,
      sequence,
      recordable: true,
      ts: Date.now()
    }));
  }
  if (channels !== 1 || (version === 2 && buffer.byteLength < 16) || (version >= 3 && buffer.byteLength < 17)) return [];

  const sequence = version >= 2 ? view.getUint32(10, true) : null;
  const hasSensorId = version >= 3;
  const channel = hasSensorId ? parseAudioChannel(["inmp441", "max4466", "piezo"][view.getUint8(14)]) : "inmp441";
  const payloadOffset = hasSensorId ? 15 : version === 2 ? 14 : 10;
  const samples = version === 5
    ? muLawBytesToSamples(buffer, payloadOffset)
    : pcmBytesToSamples(buffer, payloadOffset);
  return samples.length ? [{ samples, sampleRate, channels: 1, channel, sequence, recordable: version !== 4, ts: Date.now() }] : [];
}

export function parseBinaryAudio(buffer: ArrayBuffer): AudioPacket | null {
  return parseBinaryAudioPackets(buffer)[0] ?? null;
}
