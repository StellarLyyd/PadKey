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
// recording. Version 5 carries G.711 mu-law samples for the current
// bandwidth-efficient BLE stream; Studio expands them to signed 16-bit PCM.
export function parseBinaryAudio(buffer: ArrayBuffer): AudioPacket | null {
  if (buffer.byteLength < 12) {
    return null;
  }

  const view = new DataView(buffer);
  const magic = String.fromCharCode(view.getUint8(0), view.getUint8(1), view.getUint8(2), view.getUint8(3));
  const version = view.getUint8(4);
  const channels = view.getUint8(5);
  const sampleRate = view.getUint32(6, true);
  if (magic !== "PKAU" || ![1, 2, 3, 4, 5].includes(version) || channels !== 1 || sampleRate < 8000 || sampleRate > 96000) {
    return null;
  }
  if ((version === 2 && buffer.byteLength < 16) || (version >= 3 && buffer.byteLength < 17)) return null;

  const sequence = version >= 2 ? view.getUint32(10, true) : null;
  const hasSensorId = version >= 3;
  const channel = hasSensorId ? parseAudioChannel(["inmp441", "max4466", "piezo"][view.getUint8(14)]) : "inmp441";
  const payloadOffset = hasSensorId ? 15 : version === 2 ? 14 : 10;
  const samples = version === 5
    ? muLawBytesToSamples(buffer, payloadOffset)
    : pcmBytesToSamples(buffer, payloadOffset);
  return samples.length ? { samples, sampleRate, channels: 1, channel, sequence, recordable: version !== 4, ts: Date.now() } : null;
}
