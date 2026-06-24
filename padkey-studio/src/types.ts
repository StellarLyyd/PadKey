export type ChannelKey = "pz1" | "mic" | "qt" | "pz2" | "mus" | "ext";

export type AudioChannel = "inmp441" | "max4466" | "piezo" | "macbook";

export type AudioChannelMap<T> = Record<AudioChannel, T>;

export interface SensorFrame {
  pz1: number;
  mic: number;
  max4466: number;
  qt: number;
  pz2: number;
  mus: number;
  ext: number;
  bat: number;
  batState: string;
  batteryVoltage: number;
  batteryPercent: number;
  powerMode: "battery" | "usb_or_charging" | "unknown";
  piezo: number;
  noiseFloor: number;
  thresholdMic: number;
  thresholdPiezo: number;
  soundDetected: boolean;
  source: "serial" | "wifi" | "ble" | "unknown";
  ts: number;
}

export interface AudioPacket {
  samples: Int16Array;
  sampleRate: number;
  channels: 1;
  channel: AudioChannel;
  sequence: number | null;
  recordable: boolean;
  ts: number;
}

export type CaptureMode = "egressive" | "ingressive";

export interface SpeechSegment {
  id: string;
  startMs: number;
  endMs: number;
  durationMs: number;
  source: "silero" | "energy" | "hybrid";
  signalScore: number;
  processedAudio: Float32Array;
}

export interface TranscriptWord {
  text: string;
  start: number | null;
  end: number | null;
  confidence: number | null;
}

export interface SegmentTranscript {
  segmentId: string;
  text: string;
  words: TranscriptWord[];
}

export type TransportKind = "serial" | "wifi" | "ble";
export type TransportStatus = "idle" | "connecting" | "connected" | "error";

export interface DeviceStatusMessage {
  level: "info" | "ready" | "error" | "fatal";
  message: string;
  ts: number;
}

export interface TrainingSample {
  label: string;
  pz1: number;
  mic: number;
  qt: number;
  pz2: number;
  mus: number;
  ext: number;
  activePz1: boolean;
  activeMic: boolean;
  activeQt: boolean;
  activePz2: boolean;
  activeMus: boolean;
  activeExt: boolean;
  streamRateHz: number;
  ts: number;
}

export type AppTab = "monitor" | "train" | "inference";

export interface PredictionPoint {
  word: string;
  conf: number;
  ts: number;
}

export interface ModelMetadata {
  classes: string[];
  accuracy: number | null;
  features: number | null;
  filename: string | null;
}

export interface CandidateProbability {
  word: string;
  probability: number;
}

export interface SignalBatch {
  id: string;
  label: string;
  frames: SensorFrame[];
  activeChannels: Record<ChannelKey, boolean>;
  startedAt: number;
  endedAt: number;
  source: SensorFrame["source"];
}

export interface ActiveBatchCapture {
  label: string;
  targetFrames: number;
  frames: SensorFrame[];
  activeChannels: Record<ChannelKey, boolean>;
  startedAt: number;
}

export interface BrowserSignalModel {
  version: 1;
  labels: string[];
  featureCount: number;
  batchSize: number;
  featureMean: number[];
  featureStd: number[];
  weights: number[][];
  bias: number[];
  accuracy: number;
  trainedAt: number;
  trainingBatches: number;
}

export interface SignalPrediction {
  label: string;
  confidence: number;
  probabilities: CandidateProbability[];
  ts: number;
}

export interface DictationToken {
  id: string;
  text: string;
  confidence: number;
  ts: number;
}
