# PadKey Studio Frontend Code - Six-Channel Capture

Date: 2026-06-17

Purpose: make the frontend compatible with the working Arduino BLE payload:

```text
PZ1:<n> MIC:<n> QT:<n> PZ2:<n> MUS:<n> EXT:<n>
```

The frontend now supports:

- Six live channels: `PZ1`, `MIC`, `QT`, `PZ2`, `MUS`, `EXT`
- Per-channel on/off capture controls
- Raw live values visible even when a channel is disabled
- Disabled channels hidden from plot traces
- Disabled channels zeroed during training and inference feature extraction
- CSV export with `active_*` flags and `stream_rate_hz`
- 24-feature model input: six channels times `mean`, `max`, `min`, `std`

Important limitation: the current Arduino sketch streams at `20 Hz`. That is useful for live telemetry and coarse model labeling, but it is not enough for real speech-band or EMG frequency filtering. True speech/contact/EMG FFT work still needs high-rate raw capture around `4-16 kHz`.

## File Map

```text
padkey-studio/src/channels.ts
padkey-studio/src/types.ts
padkey-studio/src/ble/parser.ts
padkey-studio/src/components/ChannelControls.tsx
padkey-studio/src/components/panels/MonitorPanel.tsx
padkey-studio/src/components/SignalPlotter.tsx
padkey-studio/src/components/panels/TrainPanel.tsx
padkey-studio/src/ml/featureExtract.ts
padkey-studio/src/ml/useInference.ts
padkey-studio/src/store.ts
```

## `src/channels.ts`

```ts
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
```

## `src/types.ts`

```ts
export type ChannelKey = "pz1" | "mic" | "qt" | "pz2" | "mus" | "ext";

export interface SensorFrame {
  pz1: number;
  mic: number;
  qt: number;
  pz2: number;
  mus: number;
  ext: number;
  bat: number;
  batState: string;
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
```

## `src/ble/parser.ts`

```ts
import type { SensorFrame } from "../types";

const patterns = {
  pz1: /PZ1:\s*(-?\d+)/i,
  mic: /MIC:\s*(-?\d+)/i,
  qt: /QT:\s*(-?\d+)/i,
  pz2: /PZ2:\s*(-?\d+)/i,
  mus: /(?:MUS|MYO):\s*(?:[0-9.]+V\s*)?(-?\d+)%?/i,
  ext: /EXT:\s*(-?\d+)/i,
  bat: /BAT:\s*(?:[0-9.]+V\s*)?(-?\d+)%?/i,
  state: /\[([A-Z/]+)\]/i
};

function readNumber(raw: string, pattern: RegExp) {
  const match = raw.match(pattern);
  return match ? Number(match[1]) : null;
}

export function parseFrame(raw: string): SensorFrame | null {
  const csv = raw.trim().match(/^(-?\d+)\s*,\s*(-?\d+)$/);
  const pz1 = csv ? Number(csv[1]) : readNumber(raw, patterns.pz1);
  const pz2 = csv ? Number(csv[2]) : readNumber(raw, patterns.pz2);
  const mic = readNumber(raw, patterns.mic);
  const qt = readNumber(raw, patterns.qt);
  const mus = readNumber(raw, patterns.mus);
  const ext = readNumber(raw, patterns.ext);
  const bat = readNumber(raw, patterns.bat);
  const state = raw.match(patterns.state)?.[1] ?? null;

  if (pz1 === null || pz2 === null) {
    return null;
  }

  return {
    pz1,
    mic: mic ?? 0,
    qt: qt ?? 0,
    pz2,
    mus: mus ?? 0,
    ext: ext ?? 0,
    bat: bat ?? 0,
    batState: state ?? "OK",
    ts: Date.now()
  };
}
```

## `src/components/ChannelControls.tsx`

```tsx
import { CHANNELS } from "../channels";
import { useAppStore } from "../store";
import type { SensorFrame } from "../types";

const accentClasses = {
  purple: "bg-sensor-purple",
  blue: "bg-sensor-blue",
  teal: "bg-sensor-teal",
  gray: "bg-app-secondary dark:bg-app-darkSecondary"
};

const emptyFrame: SensorFrame = {
  pz1: 0,
  mic: 0,
  qt: 0,
  pz2: 0,
  mus: 0,
  ext: 0,
  bat: 0,
  batState: "OK",
  ts: 0
};

interface ChannelControlsProps {
  compact?: boolean;
}

export function ChannelControls({ compact = false }: ChannelControlsProps) {
  const latestFrame = useAppStore((state) => state.latestFrame);
  const activeChannels = useAppStore((state) => state.activeChannels);
  const setChannelEnabled = useAppStore((state) => state.setChannelEnabled);
  const streamRateHz = useAppStore((state) => state.streamRateHz);

  const frame = latestFrame ?? emptyFrame;
  const activeCount = CHANNELS.filter((channel) => activeChannels[channel.key]).length;

  return (
    <section className="thin-border rounded-xl bg-app-surface p-4 dark:bg-app-darkSurface">
      <div className="flex flex-wrap items-start justify-between gap-3">
        <div>
          <div className="tool-label">Capture channels</div>
          <h2 className="mt-2 text-[15px] font-medium text-app-ink dark:text-app-darkInk">
            {activeCount}/{CHANNELS.length} channels included in training
          </h2>
        </div>
        <div className="rounded-full border-[0.5px] border-app-border px-3 py-1 font-mono text-[11px] text-app-secondary dark:border-app-darkBorder dark:text-app-darkSecondary">
          live stream {streamRateHz} Hz
        </div>
      </div>

      <p className="mt-3 text-[12px] leading-5 text-app-secondary dark:text-app-darkSecondary">
        Current BLE/USB telemetry is for labeling and low-rate model features. True speech/EMG frequency filtering needs high-rate 4-16 kHz capture before downsampling.
      </p>

      <div className={compact ? "mt-4 grid gap-2" : "mt-4 grid gap-3 md:grid-cols-2 xl:grid-cols-3"}>
        {CHANNELS.map((channel) => {
          const enabled = activeChannels[channel.key];
          const value = frame[channel.key];
          return (
            <button
              key={channel.key}
              type="button"
              onClick={() => setChannelEnabled(channel.key, !enabled)}
              aria-pressed={enabled}
              className={[
                "focus-ring rounded-lg border-[0.5px] p-3 text-left transition-colors",
                enabled
                  ? "border-app-ink bg-white text-app-ink dark:border-app-darkInk dark:bg-app-darkBg dark:text-app-darkInk"
                  : "border-app-border bg-app-surface/60 text-app-secondary opacity-70 dark:border-app-darkBorder dark:bg-app-darkSurface/60 dark:text-app-darkSecondary"
              ].join(" ")}
            >
              <div className="flex items-center justify-between gap-3">
                <div className="flex items-center gap-2">
                  <span className={`h-2.5 w-2.5 rounded-full ${accentClasses[channel.accent]}`} aria-hidden="true" />
                  <span className="font-mono text-[13px] font-medium">{channel.label}</span>
                </div>
                <span className="rounded-full border-[0.5px] border-current px-2 py-0.5 text-[10px] uppercase tracking-[0.12em]">
                  {enabled ? "on" : "off"}
                </span>
              </div>
              <div className="mt-3 flex items-end justify-between gap-3">
                <span className="font-mono text-[22px] leading-none">{value}</span>
                <span className="text-[11px] text-app-secondary dark:text-app-darkSecondary">{channel.source}</span>
              </div>
              {!compact ? (
                <div className="mt-3 grid gap-1 text-[11px] leading-4 text-app-secondary dark:text-app-darkSecondary">
                  <div>{channel.signalBand}</div>
                  <div>{channel.sampleTarget}</div>
                  <div>{channel.filterNote}</div>
                </div>
              ) : null}
            </button>
          );
        })}
      </div>
    </section>
  );
}
```

## Store Integration

Add active-channel state and record the mask with every sample.

```ts
import { DEFAULT_ACTIVE_CHANNELS } from "./channels";
import type { ChannelKey } from "./types";

interface AppState {
  activeChannels: Record<ChannelKey, boolean>;
  streamRateHz: number;
  setChannelEnabled: (channel: ChannelKey, enabled: boolean) => void;
}

export const useAppStore = create<AppState>((set) => ({
  activeChannels: DEFAULT_ACTIVE_CHANNELS,
  streamRateHz: 20,

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

      return {
        latestFrame: frame,
        frameHistory,
        samples,
        frameCount: state.frameCount + 1
      };
    }),

  setChannelEnabled: (channel, enabled) =>
    set((state) => ({
      activeChannels: {
        ...state.activeChannels,
        [channel]: enabled
      }
    }))
}));
```

## `src/ml/featureExtract.ts`

```ts
import { CHANNELS } from "../channels";
import type { SensorFrame } from "../types";
import type { ChannelKey } from "../types";

const sensorKeys = CHANNELS.map((channel) => channel.key);

function mean(values: number[]) {
  return values.reduce((sum, value) => sum + value, 0) / values.length;
}

function standardDeviation(values: number[], average: number) {
  const variance = values.reduce((sum, value) => sum + (value - average) ** 2, 0) / values.length;
  return Math.sqrt(variance);
}

export function extractFeatures(frames: SensorFrame[], windowSize = 20, activeChannels?: Record<ChannelKey, boolean>): number[] {
  const window = frames.slice(-windowSize);
  if (window.length === 0) {
    return Array.from({ length: 24 }, () => 0);
  }

  return sensorKeys.flatMap((key) => {
    const values = activeChannels?.[key] === false ? window.map(() => 0) : window.map((frame) => frame[key]);
    const average = mean(values);
    return [average, Math.max(...values), Math.min(...values), standardDeviation(values, average)];
  });
}
```

## Training CSV Export

```ts
function exportCsv(samples: TrainingSample[]) {
  const header = [
    "label",
    "pz1",
    "mic",
    "qt",
    "pz2",
    "mus",
    "ext",
    "active_pz1",
    "active_mic",
    "active_qt",
    "active_pz2",
    "active_mus",
    "active_ext",
    "stream_rate_hz",
    "timestamp"
  ];
  const rows = samples.map((sample) => [
    sample.label,
    sample.pz1,
    sample.mic,
    sample.qt,
    sample.pz2,
    sample.mus,
    sample.ext,
    sample.activePz1 ? 1 : 0,
    sample.activeMic ? 1 : 0,
    sample.activeQt ? 1 : 0,
    sample.activePz2 ? 1 : 0,
    sample.activeMus ? 1 : 0,
    sample.activeExt ? 1 : 0,
    sample.streamRateHz,
    sample.ts
  ]);
}
```

## Python Training Script Core

```python
df = pd.read_csv('padkey_training_data.csv')
sensor_cols = ['pz1','mic','qt','pz2','mus','ext']
active_cols = ['active_pz1','active_mic','active_qt','active_pz2','active_mus','active_ext']

def extract_features(group, window=20):
    rows = []
    vals = group[sensor_cols].astype(float).values.copy()
    for col, active_col in enumerate(active_cols):
        if active_col in group.columns:
            vals[:, col] *= group[active_col].astype(int).values
    for i in range(window, len(vals)):
        w = vals[i-window:i]
        row = []
        for col in range(len(sensor_cols)):
            row += [w[:,col].mean(), w[:,col].max(),
                    w[:,col].min(), w[:,col].std()]
        rows.append(row)
    return rows

initial_type = [('float_input', FloatTensorType([None, 24]))]
json.dump({'classes': classes, 'accuracy': round(acc,4), 'features': 24},
          open('metadata.json','w'))
```

## Monitor Panel Usage

```tsx
import { ChannelControls } from "../ChannelControls";

const frame = latestFrame ?? { pz1: 0, mic: 0, qt: 0, pz2: 0, mus: 0, ext: 0, bat: 0, batState: "OK", ts: 0 };

<SensorCard label="PZ1 A0" value={frame.pz1} percent={(frame.pz1 / 1023) * 100} accent="purple" hint="Vibration module 1" />
<SensorCard label="MIC A1" value={frame.mic} percent={(frame.mic / 1023) * 100} accent="blue" hint="Electret microphone / preamp" />
<SensorCard label="QT A2" value={frame.qt} percent={(frame.qt / 1023) * 100} accent="teal" hint="QT BFF analog channel" />
<SensorCard label="PZ2 A5" value={frame.pz2} percent={(frame.pz2 / 1023) * 100} accent="purple" hint="Vibration module 2" />
<SensorCard label="MUS A6" value={frame.mus} percent={(frame.mus / 1023) * 100} accent="teal" hint="Muscle / EMG channel" />
<SensorCard label="EXT A7" value={frame.ext} percent={(frame.ext / 1023) * 100} accent="gray" hint="Extra analog channel" />

<ChannelControls />
```

## Inference Input Shape

```ts
import { FEATURE_COUNT } from "../channels";

const input = new ort.Tensor("float32", Float32Array.from(features), [1, FEATURE_COUNT]);

const features = extractFeatures(frameHistory.slice(-20), 20, activeChannels);
```

## Operational Notes

- Toggle channels before recording each label.
- If a channel is noisy or physically disconnected, turn it off so the model does not learn garbage.
- The app still displays raw levels even for disabled channels so you can diagnose wiring.
- Do not use this `20 Hz` BLE stream for FFT claims. Use a separate high-rate wired capture path for speech-band and EMG-band experiments.
