import type { ChannelKey } from "./types";

export interface ChannelConfig {
  key: ChannelKey;
  label: string;
  shortLabel: string;
  pin: string;
  firmwareLabel: string;
  accent: "purple" | "blue" | "teal" | "gray";
  source: string;
  signalBand: string;
  sampleTarget: string;
  filterNote: string;
}

export const CHANNELS: ChannelConfig[] = [
  {
    key: "pz1",
    label: "PZ1 A0",
    shortLabel: "PZ1",
    pin: "A0",
    firmwareLabel: "PZ1",
    accent: "purple",
    source: "Vibration module 1",
    signalBand: "Contact speech/vibration: 85 Hz-4 kHz",
    sampleTarget: "8-16 kHz for FFT; 20 Hz here is telemetry",
    filterNote: "High-pass drift, then speech-band band-pass after high-rate capture."
  },
  {
    key: "mic",
    label: "MIC A1",
    shortLabel: "MIC",
    pin: "A1",
    firmwareLabel: "MIC",
    accent: "blue",
    source: "Electret microphone / preamp",
    signalBand: "Speech: 85 Hz-8 kHz",
    sampleTarget: "16 kHz preferred; 8 kHz minimum for intelligibility tests",
    filterNote: "Use noise gate plus 85 Hz-4/8 kHz speech band after high-rate capture."
  },
  {
    key: "qt",
    label: "QT A2",
    shortLabel: "QT",
    pin: "A2",
    firmwareLabel: "QT",
    accent: "teal",
    source: "QT BFF analog channel",
    signalBand: "Aux channel; characterize before trusting",
    sampleTarget: "Match the sensor's useful band after bench inspection",
    filterNote: "Keep optional until its physical meaning is confirmed."
  },
  {
    key: "pz2",
    label: "PZ2 A5",
    shortLabel: "PZ2",
    pin: "A5",
    firmwareLabel: "PZ2",
    accent: "purple",
    source: "Vibration module 2",
    signalBand: "Contact speech/vibration: 85 Hz-4 kHz",
    sampleTarget: "8-16 kHz for FFT; 20 Hz here is telemetry",
    filterNote: "High-pass drift, then speech-band band-pass after high-rate capture."
  },
  {
    key: "mus",
    label: "MUS A6",
    shortLabel: "MUS",
    pin: "A6",
    firmwareLabel: "MUS",
    accent: "teal",
    source: "Muscle / EMG channel",
    signalBand: "Jaw/throat EMG target: 500 Hz-2 kHz",
    sampleTarget: ">=4 kHz required; 8 kHz preferred",
    filterNote: "Use EMG band-pass only on high-rate raw capture, not this 20 Hz stream."
  },
  {
    key: "ext",
    label: "EXT A7",
    shortLabel: "EXT",
    pin: "A7",
    firmwareLabel: "EXT",
    accent: "gray",
    source: "Extra analog channel",
    signalBand: "Unassigned auxiliary input",
    sampleTarget: "Disable unless a real sensor is attached",
    filterNote: "Do not train on this channel unless it has a stable signal role."
  }
];

export const DEFAULT_ACTIVE_CHANNELS: Record<ChannelKey, boolean> = {
  pz1: true,
  mic: true,
  qt: true,
  pz2: true,
  mus: true,
  ext: true
};

export const FEATURE_COUNT = CHANNELS.length * 4;
