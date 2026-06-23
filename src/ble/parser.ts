import type { SensorFrame } from "../types";

const patterns = {
  pz1: /PZ1:\s*(-?\d+)/i,
  piezo: /PIEZO:\s*(-?\d+)/i,
  mic: /(?:INMP441|MIC):\s*(-?\d+)/i,
  max4466: /MAX4466:\s*(-?\d+)/i,
  noiseFloor: /NoiseFloor:\s*(-?\d+)/i,
  qt: /QT:\s*(-?\d+)/i,
  pz2: /PZ2:\s*(-?\d+)/i,
  mus: /(?:MUS|MYO):\s*(?:[0-9.]+V\s*)?(-?\d+)%?/i,
  ext: /EXT:\s*(-?\d+)/i,
  bat: /BAT:\s*(?:[0-9.]+V\s*)?(-?\d+)%?/i,
  state: /\[([A-Z/]+)\]/i,
  thresholdMic: /(?:Gate|THRESHOLD_MIC):\s*(-?\d+)/i,
  thresholdPiezo: /THRESHOLD_PIEZO:\s*(-?\d+)/i
};

function readNumber(raw: string, pattern: RegExp) {
  const match = raw.match(pattern);
  return match ? Number(match[1]) : null;
}

function frameFromJson(raw: string): SensorFrame | null {
  if (!raw.trim().startsWith("{")) {
    return null;
  }

  try {
    const value = JSON.parse(raw) as Record<string, unknown>;
    if (value.type && value.type !== "telemetry") {
      return null;
    }

    const mic = Number(value.inmp441 ?? value.mic ?? value.micPeak ?? 0);
    const max4466 = Number(value.max4466 ?? value.analogMic ?? 0);
    const piezo = Number(value.piezo ?? value.pz1 ?? 0);
    const noiseFloor = Number(value.noiseFloor ?? 0);
    const thresholdMic = Number(value.gate ?? value.thresholdMic ?? value.micThreshold ?? 1800);
    const thresholdPiezo = Number(value.thresholdPiezo ?? value.piezoThreshold ?? 100);
    if (![mic, max4466, piezo, noiseFloor, thresholdMic, thresholdPiezo].every(Number.isFinite)) {
      return null;
    }

    return {
      pz1: piezo,
      mic,
      max4466,
      qt: Number(value.qt ?? 0),
      pz2: Number(value.pz2 ?? 0),
      mus: Number(value.mus ?? 0),
      ext: Number(value.ext ?? 0),
      bat: Number(value.bat ?? 0),
      batState: String(value.batState ?? "OK"),
      piezo,
      noiseFloor,
      thresholdMic,
      thresholdPiezo,
      soundDetected: Boolean(value.soundDetected ?? (mic > thresholdMic || piezo > thresholdPiezo)),
      source: "unknown",
      ts: Date.now()
    };
  } catch {
    return null;
  }
}

export function parseFrame(raw: string): SensorFrame | null {
  const jsonFrame = frameFromJson(raw);
  if (jsonFrame) {
    return jsonFrame;
  }

  const csv = raw.trim().match(/^(-?\d+)\s*,\s*(-?\d+)$/);
  const explicitPiezo = readNumber(raw, patterns.piezo);
  const pz1 = csv ? Number(csv[1]) : (explicitPiezo ?? readNumber(raw, patterns.pz1));
  const pz2 = csv ? Number(csv[2]) : readNumber(raw, patterns.pz2);
  const mic = readNumber(raw, patterns.mic);
  const max4466 = readNumber(raw, patterns.max4466);
  const qt = readNumber(raw, patterns.qt);
  const mus = readNumber(raw, patterns.mus);
  const ext = readNumber(raw, patterns.ext);
  const bat = readNumber(raw, patterns.bat);
  const state = raw.match(patterns.state)?.[1] ?? null;
  const noiseFloor = readNumber(raw, patterns.noiseFloor) ?? 0;
  const thresholdMic = readNumber(raw, patterns.thresholdMic) ?? 1800;
  const thresholdPiezo = readNumber(raw, patterns.thresholdPiezo) ?? 100;

  // Supports the current INMP441/NoiseFloor/Gate/PIEZO sketch, the earlier
  // MIC/PIEZO and PZ1/PZ2 streams, and the fuller six-channel payload.
  if (pz1 === null && mic === null && max4466 === null) {
    return null;
  }

  const piezo = explicitPiezo ?? pz1 ?? 0;
  const micValue = mic ?? 0;

  return {
    pz1: pz1 ?? 0,
    mic: micValue,
    max4466: max4466 ?? 0,
    qt: qt ?? 0,
    pz2: pz2 ?? 0,
    mus: mus ?? 0,
    ext: ext ?? 0,
    bat: bat ?? 0,
    batState: state ?? "OK",
    piezo,
    noiseFloor,
    thresholdMic,
    thresholdPiezo,
    soundDetected: micValue > thresholdMic || piezo > thresholdPiezo,
    source: "unknown",
    ts: Date.now()
  };
}
