import type { AudioChannel, AudioChannelMap } from "../types";

export interface StudioAudioChannel {
  key: AudioChannel;
  label: string;
  shortLabel: string;
  description: string;
  color: string;
}

export const STUDIO_AUDIO_CHANNELS: StudioAudioChannel[] = [
  {
    key: "inmp441",
    label: "INMP441",
    shortLabel: "Digital mic",
    description: "Clear room and voice sound",
    color: "#252b31"
  },
  {
    key: "max4466",
    label: "MAX4466",
    shortLabel: "Analog mic",
    description: "Adjustable close voice sound",
    color: "#2f69a7"
  },
  {
    key: "piezo",
    label: "Piezo",
    shortLabel: "Contact sensor",
    description: "Vibration through the surface",
    color: "#2d7666"
  },
  {
    key: "macbook",
    label: "MacBook baseline",
    shortLabel: "Baseline reference",
    description: "Built-in microphone comparison",
    color: "#8a633f"
  }
];

export const DEFAULT_CAPTURE_CHANNELS: AudioChannelMap<boolean> = {
  inmp441: true,
  max4466: true,
  piezo: true,
  macbook: false
};

export function createAudioChannelMap<T>(factory: (channel: AudioChannel) => T): AudioChannelMap<T> {
  return {
    inmp441: factory("inmp441"),
    max4466: factory("max4466"),
    piezo: factory("piezo"),
    macbook: factory("macbook")
  };
}

export function audioChannelLabel(channel: AudioChannel) {
  return STUDIO_AUDIO_CHANNELS.find((item) => item.key === channel)?.label ?? channel;
}
