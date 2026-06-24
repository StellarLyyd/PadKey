import { create } from "zustand";
import { PcmRingBuffer, livePcmRing } from "./audio/PcmRingBuffer";
import { DEFAULT_ACTIVE_CHANNELS } from "./channels";
import { createAudioChannelMap, DEFAULT_CAPTURE_CHANNELS } from "./studio/audioChannels";
import type {
  ActiveBatchCapture,
  AudioChannel,
  AudioChannelMap,
  AudioPacket,
  BrowserSignalModel,
  CandidateProbability,
  CaptureMode,
  DeviceStatusMessage,
  DictationToken,
  ModelMetadata,
  PredictionPoint,
  SensorFrame,
  SignalBatch,
  SignalPrediction,
  TrainingSample
} from "./types";
import type { ChannelKey } from "./types";

const defaultVocabulary = ["rest", "yes", "no", "help", "water"];
const channelPreviewRings = createAudioChannelMap(() => new PcmRingBuffer(16000 * 30));

interface AppState {
  bleConnected: boolean;
  bleDeviceName: string | null;
  bleStatus: "idle" | "connecting" | "connected" | "error";
  bleError: string | null;
  batteryVoltage: number | null;
  batteryPercent: number | null;
  powerMode: "battery" | "usb_or_charging" | "unknown";
  serialConnected: boolean;
  serialDeviceName: string | null;
  serialStatus: "idle" | "connecting" | "connected" | "error";
  serialError: string | null;
  serialBaudRate: number;
  wifiConnected: boolean;
  wifiStatus: "idle" | "connecting" | "connected" | "error";
  wifiUrl: string;
  wifiError: string | null;
  deviceStatus: DeviceStatusMessage | null;
  macMicrophoneStatus: "idle" | "requesting" | "live" | "error";
  macMicrophoneError: string | null;
  macMicrophoneDeviceName: string | null;
  latestFrame: SensorFrame | null;
  frameHistory: SensorFrame[];
  frameCount: number;
  activeChannels: Record<ChannelKey, boolean>;
  streamRateHz: number;
  vocabulary: string[];
  selectedWord: string;
  samples: TrainingSample[];
  recording: boolean;
  modelLoaded: boolean;
  lastPrediction: string | null;
  lastConfidence: number | null;
  predictionHistory: PredictionPoint[];
  candidateProbabilities: CandidateProbability[];
  modelMetadata: ModelMetadata | null;
  sessionRecording: boolean;
  sessionStartedAt: number | null;
  sessionEndedAt: number | null;
  sessionFrames: SensorFrame[];
  audioChunks: Int16Array[];
  audioPreview: Int16Array;
  captureChannels: AudioChannelMap<boolean>;
  channelAudioChunks: AudioChannelMap<Int16Array[]>;
  channelAudioPreviews: AudioChannelMap<Int16Array>;
  channelAudioSampleCounts: AudioChannelMap<number>;
  channelLastAudioPacketAt: AudioChannelMap<number | null>;
  channelLastRecordableAudioPacketAt: AudioChannelMap<number | null>;
  channelLastAudioSequence: AudioChannelMap<number | null>;
  audioSampleRate: number | null;
  audioSampleCount: number;
  lastAudioPacketAt: number | null;
  lastAudioSequence: number | null;
  receivedAudioPackets: number;
  droppedAudioPackets: number;
  captureMode: CaptureMode;
  sessionMode: CaptureMode;
  signalBatches: SignalBatch[];
  activeBatchCapture: ActiveBatchCapture | null;
  signalModel: BrowserSignalModel | null;
  signalPrediction: SignalPrediction | null;
  dictationTokens: DictationToken[];
  pushFrame: (frame: SensorFrame) => void;
  pushAudioPacket: (packet: AudioPacket) => void;
  startSession: () => void;
  stopSession: () => void;
  clearSession: () => void;
  setRecording: (v: boolean) => void;
  addSample: (s: TrainingSample) => void;
  setChannelEnabled: (channel: ChannelKey, enabled: boolean) => void;
  setCaptureChannelEnabled: (channel: AudioChannel, enabled: boolean) => void;
  addWord: (w: string) => void;
  setSelectedWord: (w: string) => void;
  setBLEConnected: (v: boolean, name?: string) => void;
  setBLEStatus: (status: "idle" | "connecting" | "connected" | "error", error?: string | null) => void;
  setBatteryStatus: (percent: number | null, voltage?: number | null, powerMode?: "battery" | "usb_or_charging" | "unknown") => void;
  setSerialConnected: (v: boolean, name?: string) => void;
  setSerialStatus: (status: "idle" | "connecting" | "connected" | "error", error?: string | null) => void;
  setSerialBaudRate: (baudRate: number) => void;
  setWifiConnected: (v: boolean, url?: string) => void;
  setWifiStatus: (status: "idle" | "connecting" | "connected" | "error", error?: string | null) => void;
  setWifiUrl: (url: string) => void;
  setDeviceStatus: (status: DeviceStatusMessage) => void;
  setMacMicrophoneState: (
    status: "idle" | "requesting" | "live" | "error",
    error?: string | null,
    deviceName?: string | null
  ) => void;
  setCaptureMode: (mode: CaptureMode) => void;
  setModelLoaded: (v: boolean) => void;
  setModelMetadata: (metadata: ModelMetadata | null) => void;
  setCandidateProbabilities: (items: CandidateProbability[]) => void;
  pushPrediction: (word: string, conf: number) => void;
  clearSamples: () => void;
  startSignalBatch: (label: string, targetFrames: number) => void;
  cancelSignalBatch: () => void;
  removeSignalBatch: (id: string) => void;
  clearSignalBatches: () => void;
  setSignalModel: (model: BrowserSignalModel | null) => void;
  setSignalPrediction: (prediction: SignalPrediction | null) => void;
  appendDictationToken: (text: string, confidence: number) => void;
  undoDictationToken: () => void;
  clearDictation: () => void;
}

export const useAppStore = create<AppState>((set) => ({
  bleConnected: false,
  bleDeviceName: null,
  bleStatus: "idle",
  bleError: null,
  batteryVoltage: null,
  batteryPercent: null,
  powerMode: "unknown",
  serialConnected: false,
  serialDeviceName: null,
  serialStatus: "idle",
  serialError: null,
  serialBaudRate: 921600,
  wifiConnected: false,
  wifiStatus: "idle",
  wifiUrl: "ws://padkey.local:81",
  wifiError: null,
  deviceStatus: null,
  macMicrophoneStatus: "idle",
  macMicrophoneError: null,
  macMicrophoneDeviceName: null,
  latestFrame: null,
  frameHistory: [],
  frameCount: 0,
  activeChannels: DEFAULT_ACTIVE_CHANNELS,
  streamRateHz: 20,
  vocabulary: defaultVocabulary,
  selectedWord: defaultVocabulary[0],
  samples: [],
  recording: false,
  modelLoaded: false,
  lastPrediction: null,
  lastConfidence: null,
  predictionHistory: [],
  candidateProbabilities: [],
  modelMetadata: null,
  sessionRecording: false,
  sessionStartedAt: null,
  sessionEndedAt: null,
  sessionFrames: [],
  audioChunks: [],
  audioPreview: new Int16Array(0),
  captureChannels: { ...DEFAULT_CAPTURE_CHANNELS },
  channelAudioChunks: createAudioChannelMap(() => []),
  channelAudioPreviews: createAudioChannelMap(() => new Int16Array(0)),
  channelAudioSampleCounts: createAudioChannelMap(() => 0),
  channelLastAudioPacketAt: createAudioChannelMap(() => null),
  channelLastRecordableAudioPacketAt: createAudioChannelMap(() => null),
  channelLastAudioSequence: createAudioChannelMap(() => null),
  audioSampleRate: null,
  audioSampleCount: 0,
  lastAudioPacketAt: null,
  lastAudioSequence: null,
  receivedAudioPackets: 0,
  droppedAudioPackets: 0,
  captureMode: "egressive",
  sessionMode: "egressive",
  signalBatches: [],
  activeBatchCapture: null,
  signalModel: null,
  signalPrediction: null,
  dictationTokens: [],
  pushFrame: (frame) =>
    set((state) => {
      const frameHistory = [...state.frameHistory, frame].slice(-120);
      const samples = state.recording
        ? [
            ...state.samples,
            {
              label: state.selectedWord,
              pz1: frame.pz1,
              mic: frame.mic,
              qt: frame.qt,
              pz2: frame.pz2,
              mus: frame.mus,
              ext: frame.ext,
              activePz1: state.activeChannels.pz1,
              activeMic: state.activeChannels.mic,
              activeQt: state.activeChannels.qt,
              activePz2: state.activeChannels.pz2,
              activeMus: state.activeChannels.mus,
              activeExt: state.activeChannels.ext,
              streamRateHz: state.streamRateHz,
              ts: frame.ts
            }
          ]
        : state.samples;

      let activeBatchCapture = state.activeBatchCapture;
      let signalBatches = state.signalBatches;
      if (activeBatchCapture) {
        const frames = [...activeBatchCapture.frames, frame];
        if (frames.length >= activeBatchCapture.targetFrames) {
          signalBatches = [
            ...state.signalBatches,
            {
              id: `batch-${Date.now()}-${state.signalBatches.length}`,
              label: activeBatchCapture.label,
              frames: frames.slice(0, activeBatchCapture.targetFrames),
              activeChannels: activeBatchCapture.activeChannels,
              startedAt: activeBatchCapture.startedAt,
              endedAt: frame.ts,
              source: frame.source
            }
          ];
          activeBatchCapture = null;
        } else {
          activeBatchCapture = { ...activeBatchCapture, frames };
        }
      }

      return {
        latestFrame: frame,
        frameHistory,
        batteryVoltage: frame.batteryVoltage > 0 ? frame.batteryVoltage : state.batteryVoltage,
        batteryPercent: frame.powerMode !== "unknown" ? frame.batteryPercent : state.batteryPercent,
        powerMode: frame.powerMode !== "unknown" ? frame.powerMode : state.powerMode,
        samples,
        activeBatchCapture,
        signalBatches,
        sessionFrames: state.sessionRecording ? [...state.sessionFrames, frame] : state.sessionFrames,
        frameCount: state.frameCount + 1
      };
    }),
  pushAudioPacket: (packet) =>
    set((state) => {
      channelPreviewRings[packet.channel].push(packet.samples);
      if (packet.channel === "inmp441") livePcmRing.push(packet.samples);
      let droppedAudioPackets = state.droppedAudioPackets;
      const previousSequence = state.channelLastAudioSequence[packet.channel];
      if (packet.recordable && packet.sequence !== null && previousSequence !== null) {
        const expected = (previousSequence + 1) >>> 0;
        const difference = (packet.sequence - expected) >>> 0;
        if (difference > 0 && difference < 100000) droppedAudioPackets += difference;
      }

      const shouldCapture = packet.recordable && state.sessionRecording && state.captureChannels[packet.channel];
      const nextChannelChunks = shouldCapture
        ? { ...state.channelAudioChunks, [packet.channel]: [...state.channelAudioChunks[packet.channel], packet.samples] }
        : state.channelAudioChunks;
      const nextChannelCounts = shouldCapture
        ? { ...state.channelAudioSampleCounts, [packet.channel]: state.channelAudioSampleCounts[packet.channel] + packet.samples.length }
        : state.channelAudioSampleCounts;

      return {
        audioPreview: packet.channel === "inmp441" ? livePcmRing.snapshot(4096) : state.audioPreview,
        channelAudioPreviews: {
          ...state.channelAudioPreviews,
          [packet.channel]: channelPreviewRings[packet.channel].snapshot(4096)
        },
        channelAudioChunks: nextChannelChunks,
        channelAudioSampleCounts: nextChannelCounts,
        channelLastAudioPacketAt: { ...state.channelLastAudioPacketAt, [packet.channel]: packet.ts },
        channelLastRecordableAudioPacketAt: packet.recordable
          ? { ...state.channelLastRecordableAudioPacketAt, [packet.channel]: packet.ts }
          : state.channelLastRecordableAudioPacketAt,
        channelLastAudioSequence: packet.recordable
          ? { ...state.channelLastAudioSequence, [packet.channel]: packet.sequence }
          : state.channelLastAudioSequence,
        audioSampleRate: packet.sampleRate,
        audioChunks: shouldCapture && packet.channel === "inmp441" ? [...state.audioChunks, packet.samples] : state.audioChunks,
        audioSampleCount: shouldCapture && packet.channel === "inmp441" ? state.audioSampleCount + packet.samples.length : state.audioSampleCount,
        lastAudioPacketAt: packet.ts,
        lastAudioSequence: packet.channel === "inmp441" ? packet.sequence ?? state.lastAudioSequence : state.lastAudioSequence,
        receivedAudioPackets: state.receivedAudioPackets + 1,
        droppedAudioPackets
      };
    }),
  startSession: () =>
    set((state) => ({
        sessionRecording: true,
        sessionStartedAt: Date.now(),
        sessionEndedAt: null,
        sessionFrames: [],
        audioChunks: [],
        channelAudioChunks: createAudioChannelMap(() => []),
        channelAudioSampleCounts: createAudioChannelMap(() => 0),
        audioSampleCount: 0,
        sessionMode: state.captureMode,
        droppedAudioPackets: 0,
        receivedAudioPackets: 0,
        lastAudioSequence: null,
        channelLastAudioSequence: createAudioChannelMap(() => null)
      })),
  stopSession: () => set({ sessionRecording: false, sessionEndedAt: Date.now() }),
  clearSession: () =>
    set({
      sessionRecording: false,
      sessionStartedAt: null,
      sessionEndedAt: null,
      sessionFrames: [],
      audioChunks: [],
      channelAudioChunks: createAudioChannelMap(() => []),
      channelAudioSampleCounts: createAudioChannelMap(() => 0),
      audioSampleCount: 0,
      droppedAudioPackets: 0,
      receivedAudioPackets: 0,
      lastAudioSequence: null,
      channelLastAudioSequence: createAudioChannelMap(() => null)
    }),
  setRecording: (recording) => set({ recording }),
  addSample: (sample) => set((state) => ({ samples: [...state.samples, sample] })),
  setChannelEnabled: (channel, enabled) =>
    set((state) => ({
      activeChannels: {
        ...state.activeChannels,
        [channel]: enabled
      }
    })),
  setCaptureChannelEnabled: (channel, enabled) =>
    set((state) => ({
      captureChannels: {
        ...state.captureChannels,
        [channel]: enabled
      }
    })),
  addWord: (word) =>
    set((state) => {
      const clean = word.trim().toLowerCase();
      if (!clean) {
        return state;
      }
      if (state.vocabulary.includes(clean)) {
        return { selectedWord: clean };
      }
      return {
        vocabulary: [...state.vocabulary, clean],
        selectedWord: clean
      };
    }),
  setSelectedWord: (selectedWord) => set({ selectedWord }),
  setBLEConnected: (bleConnected, name) =>
    set({
      bleConnected,
      bleDeviceName: bleConnected ? name ?? "PadKey-S3" : null,
      bleStatus: bleConnected ? "connected" : "idle",
      bleError: bleConnected ? null : null
    }),
  setBLEStatus: (bleStatus, bleError = null) =>
    set((state) => ({
      bleStatus,
      bleError,
      bleConnected: bleStatus === "connected" ? state.bleConnected : false,
      bleDeviceName: bleStatus === "error" || bleStatus === "idle" ? (state.bleConnected ? state.bleDeviceName : null) : state.bleDeviceName
    })),
  setBatteryStatus: (batteryPercent, batteryVoltage = null, powerMode = "unknown") => set((state) => ({
    batteryPercent: batteryPercent === null ? state.batteryPercent : Math.max(0, Math.min(100, Math.round(batteryPercent))),
    batteryVoltage: batteryVoltage ?? state.batteryVoltage,
    powerMode: powerMode === "unknown" ? state.powerMode : powerMode
  })),
  setSerialConnected: (serialConnected, name) =>
    set({
      serialConnected,
      serialDeviceName: serialConnected ? name ?? "Arduino USB" : null,
      serialStatus: serialConnected ? "connected" : "idle",
      serialError: null
    }),
  setSerialStatus: (serialStatus, serialError = null) =>
    set((state) => ({
      serialStatus,
      serialError,
      serialConnected: serialStatus === "connecting" || serialStatus === "error" || serialStatus === "idle" ? false : state.serialConnected,
      serialDeviceName:
        serialStatus === "connecting" || serialStatus === "error" || serialStatus === "idle" ? null : state.serialDeviceName
    })),
  setSerialBaudRate: (serialBaudRate) => set({ serialBaudRate }),
  setWifiConnected: (wifiConnected, url) =>
    set((state) => ({
      wifiConnected,
      wifiStatus: wifiConnected ? "connected" : "idle",
      wifiUrl: url ?? state.wifiUrl,
      wifiError: null
    })),
  setWifiStatus: (wifiStatus, wifiError = null) =>
    set((state) => ({
      wifiStatus,
      wifiError,
      wifiConnected: wifiStatus === "connected" ? state.wifiConnected : false
    })),
  setWifiUrl: (wifiUrl) => set({ wifiUrl }),
  setDeviceStatus: (deviceStatus) => set({ deviceStatus }),
  setMacMicrophoneState: (macMicrophoneStatus, macMicrophoneError = null, macMicrophoneDeviceName = null) => set({
    macMicrophoneStatus,
    macMicrophoneError,
    macMicrophoneDeviceName
  }),
  setCaptureMode: (captureMode) => set({ captureMode }),
  setModelLoaded: (modelLoaded) => set({ modelLoaded }),
  setModelMetadata: (modelMetadata) => set({ modelMetadata }),
  setCandidateProbabilities: (candidateProbabilities) => set({ candidateProbabilities }),
  pushPrediction: (word, conf) =>
    set((state) => ({
      lastPrediction: word,
      lastConfidence: conf,
      predictionHistory: [...state.predictionHistory, { word, conf, ts: Date.now() }].slice(-50)
    })),
  clearSamples: () => set({ samples: [] }),
  startSignalBatch: (label, targetFrames) =>
    set((state) => ({
      activeBatchCapture: {
        label: label.trim().toLowerCase(),
        targetFrames: Math.max(8, Math.min(120, Math.round(targetFrames))),
        frames: [],
        activeChannels: { ...state.activeChannels },
        startedAt: Date.now()
      }
    })),
  cancelSignalBatch: () => set({ activeBatchCapture: null }),
  removeSignalBatch: (id) => set((state) => ({ signalBatches: state.signalBatches.filter((batch) => batch.id !== id) })),
  clearSignalBatches: () => set({ signalBatches: [], activeBatchCapture: null }),
  setSignalModel: (signalModel) => set({ signalModel, signalPrediction: null }),
  setSignalPrediction: (signalPrediction) => set({ signalPrediction }),
  appendDictationToken: (text, confidence) =>
    set((state) => ({
      dictationTokens: [
        ...state.dictationTokens,
        { id: `token-${Date.now()}-${state.dictationTokens.length}`, text, confidence, ts: Date.now() }
      ]
    })),
  undoDictationToken: () => set((state) => ({ dictationTokens: state.dictationTokens.slice(0, -1) })),
  clearDictation: () => set({ dictationTokens: [] })
}));
