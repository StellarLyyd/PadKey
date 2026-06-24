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
  max4466: 0,
  inmp441Rms: 0,
  max4466Rms: 0,
  piezoRms: 0,
  qt: 0,
  pz2: 0,
  mus: 0,
  ext: 0,
  bat: 0,
  batState: "OK",
  batteryVoltage: 0,
  batteryPercent: 0,
  powerMode: "unknown",
  sourceId: 1,
  sampleRate: 16000,
  piezo: 0,
  noiseFloor: 0,
  thresholdMic: 1800,
  thresholdPiezo: 100,
  soundDetected: false,
  source: "unknown",
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
