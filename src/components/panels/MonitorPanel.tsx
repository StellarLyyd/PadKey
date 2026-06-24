import { useAppStore } from "../../store";
import { ChannelControls } from "../ChannelControls";
import { SensorCard } from "../SensorCard";
import { SignalPlotter } from "../SignalPlotter";

export function MonitorPanel() {
  const latestFrame = useAppStore((state) => state.latestFrame);
  const frameHistory = useAppStore((state) => state.frameHistory);
  const bleConnected = useAppStore((state) => state.bleConnected);
  const bleDeviceName = useAppStore((state) => state.bleDeviceName);
  const serialConnected = useAppStore((state) => state.serialConnected);
  const serialDeviceName = useAppStore((state) => state.serialDeviceName);

  const frame = latestFrame ?? { pz1: 0, mic: 0, qt: 0, pz2: 0, mus: 0, ext: 0, bat: 0, batState: "OK", ts: 0 };
  const liveSource = serialConnected
    ? `USB ${serialDeviceName ?? "Arduino"}`
    : bleConnected
      ? `BLE ${bleDeviceName ?? "OWO-Sensor"}`
      : "Disconnected";

  return (
    <div className="grid gap-5">
      <section className="thin-border rounded-xl bg-app-surface p-4 dark:bg-app-darkSurface">
        <div className="flex flex-wrap items-start justify-between gap-4">
          <div>
            <div className="tool-label">Live capture</div>
            <h1 className="mt-2 text-[20px] font-medium leading-tight text-app-ink dark:text-app-darkInk">Signal monitor</h1>
          </div>
          <div className="grid min-w-[280px] gap-2 rounded-lg border-[0.5px] border-app-border bg-white/60 px-4 py-3 dark:border-app-darkBorder dark:bg-app-darkBg/60">
            <div className="flex items-center justify-between gap-4 text-[13px]">
              <span className="text-app-secondary dark:text-app-darkSecondary">Source</span>
              <span className={serialConnected || bleConnected ? "font-medium text-sensor-green" : "font-medium text-app-ink dark:text-app-darkInk"}>
                {liveSource}
              </span>
            </div>
            <div className="flex items-center justify-between gap-4 text-[13px]">
              <span className="text-app-secondary dark:text-app-darkSecondary">Active stream</span>
              <span className="font-medium text-app-ink dark:text-app-darkInk">Six analog channels</span>
            </div>
            <div className="flex items-center justify-between gap-4 text-[13px]">
              <span className="text-app-secondary dark:text-app-darkSecondary">Scale</span>
              <span className="font-medium text-app-ink dark:text-app-darkInk">0-1023 ADC</span>
            </div>
          </div>
        </div>
      </section>

      <section className="grid grid-cols-1 gap-3 sm:grid-cols-2 xl:grid-cols-3">
        <SensorCard label="PZ1 A0" value={frame.pz1} percent={(frame.pz1 / 1023) * 100} accent="purple" hint="Vibration module 1" />
        <SensorCard label="MIC A1" value={frame.mic} percent={(frame.mic / 1023) * 100} accent="blue" hint="Electret microphone / preamp" />
        <SensorCard label="QT A2" value={frame.qt} percent={(frame.qt / 1023) * 100} accent="teal" hint="QT BFF analog channel" />
        <SensorCard label="PZ2 A5" value={frame.pz2} percent={(frame.pz2 / 1023) * 100} accent="purple" hint="Vibration module 2" />
        <SensorCard label="MUS A6" value={frame.mus} percent={(frame.mus / 1023) * 100} accent="teal" hint="Muscle / EMG channel" />
        <SensorCard label="EXT A7" value={frame.ext} percent={(frame.ext / 1023) * 100} accent="gray" hint="Extra analog channel" />
      </section>

      <ChannelControls />

      <SignalPlotter frames={frameHistory} />

      <section className="grid gap-4 xl:grid-cols-[minmax(0,1fr)_340px]">
        <div className="thin-border rounded-xl bg-app-surface p-5 dark:bg-app-darkSurface">
          <div className="tool-label">Session diagnostics</div>
          <dl className="mt-3 grid gap-3 text-[13px]">
            <div className="grid grid-cols-[112px_minmax(0,1fr)] gap-3">
              <dt className="text-app-muted dark:text-app-darkSecondary">Buffer</dt>
              <dd className="text-app-ink dark:text-app-darkInk">120-frame rolling window for visualization and feature extraction.</dd>
            </div>
            <div className="grid grid-cols-[112px_minmax(0,1fr)] gap-3">
              <dt className="text-app-muted dark:text-app-darkSecondary">Placement</dt>
              <dd className="text-app-ink dark:text-app-darkInk">Firmware payload: PZ1, MIC, QT, PZ2, MUS, EXT at 20 Hz.</dd>
            </div>
          </dl>
        </div>
      </section>
    </div>
  );
}
