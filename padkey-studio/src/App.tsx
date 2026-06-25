import { useEffect, useMemo, useState } from "react";
import { Activity, Battery, BatteryCharging, Bluetooth, Cable, Radio, Settings2, Wifi } from "lucide-react";
import { useMacMicrophone } from "./audio/useMacMicrophone";
import { useBLE } from "./ble/useBLE";
import { CapturePanel } from "./components/capture/CapturePanel";
import { AgentControlPanel } from "./components/agent/AgentControlPanel";
import { CaptureProfilePanel } from "./components/capture/CaptureProfilePanel";
import { ConnectionPanel } from "./components/capture/ConnectionPanel";
import { FirmwareBoundary } from "./components/capture/FirmwareBoundary";
import { SignalChart } from "./components/capture/SignalChart";
import { LearnHub } from "./components/learn/LearnHub";
import { SpeechLab } from "./components/speech/SpeechLab";
import { Studio } from "./components/studio/Studio";
import { SignalTrainingLab } from "./components/training/SignalTrainingLab";
import { useSerial } from "./serial/useSerial";
import { useAppStore } from "./store";
import { useWifi } from "./wifi/useWifi";

type AdvancedView = "signals" | "trainer" | "speech" | "agent" | "learn";

function Metric({ label, value, detail, tone = "neutral" }: { label: string; value: string; detail: string; tone?: "neutral" | "mic" | "piezo" | "detected" }) {
  return (
    <article className={`metric ${tone}`}>
      <div className="metric-label">{label}</div>
      <div className="metric-value mono">{value}</div>
      <div className="metric-detail">{detail}</div>
    </article>
  );
}

export function App() {
  const macMicrophone = useMacMicrophone();
  const [now, setNow] = useState(Date.now());
  const [area, setArea] = useState<"studio" | "advanced">("studio");
  const [advancedView, setAdvancedView] = useState<AdvancedView>("signals");
  const latestFrame = useAppStore((state) => state.latestFrame);
  const frameHistory = useAppStore((state) => state.frameHistory);
  const serialConnected = useAppStore((state) => state.serialConnected);
  const wifiConnected = useAppStore((state) => state.wifiConnected);
  const bleConnected = useAppStore((state) => state.bleConnected);
  const serialBaudRate = useAppStore((state) => state.serialBaudRate);
  const batteryPercent = useAppStore((state) => state.batteryPercent);
  const batteryVoltage = useAppStore((state) => state.batteryVoltage);
  const powerMode = useAppStore((state) => state.powerMode);
  const sessionRecording = useAppStore((state) => state.sessionRecording);
  const channelLastAudioPacketAt = useAppStore((state) => state.channelLastAudioPacketAt);
  const channelLastRecordableAudioPacketAt = useAppStore((state) => state.channelLastRecordableAudioPacketAt);
  const droppedAudioPackets = useAppStore((state) => state.droppedAudioPackets);
  const serial = useSerial(serialBaudRate);
  const wifi = useWifi();
  const ble = useBLE();

  useEffect(() => {
    const interval = window.setInterval(() => setNow(Date.now()), 500);
    return () => window.clearInterval(interval);
  }, []);

  useEffect(() => {
    function applyHashRoute() {
      const hash = window.location.hash.replace(/^#\/?/, "").toLowerCase();
      if (!hash) return;
      if (hash.startsWith("advanced")) {
        setArea("advanced");
        const requested = hash.split("/")[1] as AdvancedView | undefined;
        if (requested && ["signals", "trainer", "speech", "agent", "learn"].includes(requested)) {
          setAdvancedView(requested);
        }
      } else if (hash.startsWith("studio")) {
        setArea("studio");
      }
    }

    applyHashRoute();
    window.addEventListener("hashchange", applyHashRoute);
    window.addEventListener("padkey-native-route", ((event: Event) => {
      const detail = (event as CustomEvent<{ area?: "studio" | "advanced"; advancedView?: AdvancedView }>).detail;
      if (detail?.area) setArea(detail.area);
      if (detail?.advancedView) setAdvancedView(detail.advancedView);
    }) as EventListener);
    return () => window.removeEventListener("hashchange", applyHashRoute);
  }, []);

  const fps = useMemo(() => frameHistory.filter((frame) => frame.ts >= now - 1000).length, [frameHistory, now]);
  const connected = serialConnected || wifiConnected || bleConnected;
  const source = latestFrame?.source === "wifi" ? "Wi-Fi" : latestFrame?.source === "serial" ? "USB" : latestFrame?.source === "ble" ? "BLE" : serialConnected ? "USB" : wifiConnected ? "Wi-Fi" : bleConnected ? "BLE" : "Offline";
  const recentFrame = Boolean(latestFrame && now - latestFrame.ts < 2000);
  const deviceChannels = (["inmp441", "max4466", "piezo"] as const);
  const rawAudioLive = deviceChannels
    .some((channel) => Boolean(channelLastAudioPacketAt[channel] && now - (channelLastAudioPacketAt[channel] ?? 0) < 2000));
  const recordableAudioLive = deviceChannels
    .some((channel) => Boolean(channelLastRecordableAudioPacketAt[channel] && now - (channelLastRecordableAudioPacketAt[channel] ?? 0) < 2000));
  const micValue = latestFrame?.mic ?? 0;
  const max4466Value = latestFrame?.max4466 ?? 0;
  const piezoValue = latestFrame?.piezo ?? 0;
  const micThreshold = latestFrame?.thresholdMic ?? 1800;
  const noiseFloor = latestFrame?.noiseFloor ?? 0;
  const piezoThreshold = latestFrame?.thresholdPiezo ?? 100;
  const detected = Boolean(latestFrame?.soundDetected && recentFrame);
  const statusLabel = !connected
    ? "PadKey not connected"
    : bleConnected
      ? recordableAudioLive ? "PadKey connected · BLE recording ready" : rawAudioLive ? "PadKey connected · BLE signal" : "PadKey connected · Waiting for BLE audio"
    : droppedAudioPackets
      ? "PadKey connected · Check signal"
      : recordableAudioLive
        ? "PadKey connected · Signal good"
        : recentFrame
          ? "PadKey connected · Recording unavailable"
          : "PadKey connected · Waiting for sensors";

  return (
    <div className={`app-shell ${area === "studio" ? "is-studio" : "is-advanced"}`}>
      <header className="app-header app-header-v2">
        <div className="brand-lockup">
          <img className="brand-logo" src="/padkey-logo.svg" alt="PadKey" />
          <div>
            <div className="brand-product">Voice Studio</div>
          </div>
        </div>
        <nav className="shell-tabs" aria-label="PadKey areas">
          <button type="button" className={area === "studio" ? "is-active" : ""} aria-current={area === "studio" ? "page" : undefined} onClick={() => setArea("studio")}><Radio size={16} /> Studio</button>
          <button type="button" className={area === "advanced" ? "is-active" : ""} aria-current={area === "advanced" ? "page" : undefined} onClick={() => setArea("advanced")}><Settings2 size={16} /> Advanced</button>
        </nav>
        <div className="header-statuses" aria-label="PadKey status">
          <div className={`header-status studio-header-status ${connected ? "is-live" : ""}`}>
            {serialConnected ? <Cable size={15} aria-hidden="true" /> : wifiConnected ? <Wifi size={15} aria-hidden="true" /> : bleConnected ? <Bluetooth size={15} aria-hidden="true" /> : <Radio size={15} aria-hidden="true" />}
            <span>{statusLabel}</span>
          </div>
          {batteryPercent !== null ? (
            <div className={`header-status battery-status ${powerMode === "usb_or_charging" ? "is-charging" : ""}`} title={batteryVoltage ? `${batteryVoltage.toFixed(2)} V estimated` : "Battery estimate"}>
              {powerMode === "usb_or_charging" ? <BatteryCharging size={15} aria-hidden="true" /> : <Battery size={15} aria-hidden="true" />}
              <span>{powerMode === "usb_or_charging" ? "External power" : `${batteryPercent}%`}</span>
            </div>
          ) : null}
          {sessionRecording ? <div className="recording-chip"><span /> Recording</div> : null}
        </div>
      </header>

      {area === "studio" ? <Studio macMicrophone={macMicrophone} serial={serial} wifi={wifi} ble={ble} /> : (
        <>
          <nav className="advanced-tabs" aria-label="Advanced workspace">
            {([
              ["signals", "Signals"],
              ["trainer", "Signal trainer"],
              ["speech", "Speech lab"],
              ["agent", "Mac control"],
              ["learn", "Learn"]
            ] as Array<[AdvancedView, string]>).map(([id, label]) => (
              <button type="button" key={id} className={advancedView === id ? "is-active" : ""} aria-current={advancedView === id ? "page" : undefined} onClick={() => setAdvancedView(id)}>{label}</button>
            ))}
          </nav>
          <div className={advancedView === "learn" || advancedView === "agent" ? "workspace is-learn" : "workspace"}>
            <aside className="control-rail">
              <ConnectionPanel serial={serial} wifi={wifi} ble={ble} />
              <CaptureProfilePanel />
              <FirmwareBoundary />
            </aside>

            <main className="main-workspace">
              {advancedView === "signals" ? <>
                <section className="signal-section" aria-labelledby="signal-title">
                  <div className="panel-heading signal-heading">
                    <div>
                      <div className="section-kicker">Live signal</div>
                      <h1 id="signal-title" className="workspace-title">Microphones + contact vibration</h1>
                      <p className="panel-copy">INMP441, MAX4466, and piezo values from the XIAO ESP32-S3.</p>
                    </div>
                    <div className="legend" aria-label="Chart legend">
                      <span><i className="legend-line mic-line" /> INMP441</span>
                      <span><i className="legend-line max4466-line" /> MAX4466</span>
                      <span><i className="legend-line piezo-line" /> Piezo</span>
                      <span><i className="legend-line noise-line" /> Noise floor</span>
                      <span><i className="legend-line threshold-line" /> Adaptive gate</span>
                    </div>
                  </div>

                  <div className="metric-row">
                    <Metric label="INMP441 peak" value={micValue.toLocaleString()} detail={`${micValue > micThreshold ? "Above" : "Below"} ${micThreshold.toLocaleString()} gate${noiseFloor ? ` · floor ${noiseFloor.toLocaleString()}` : ""}`} tone="mic" />
                    <Metric label="MAX4466 peak" value={max4466Value.toLocaleString()} detail="Analog microphone on A5" />
                    <Metric label="Piezo" value={piezoValue.toLocaleString()} detail={`${piezoValue > piezoThreshold ? "Above" : "Below"} ${piezoThreshold.toLocaleString()} threshold`} tone="piezo" />
                    <Metric label="Detection" value={detected ? "ACTIVE" : "QUIET"} detail={recentFrame ? `${fps} frames/sec · ${source}` : "Waiting for live frames"} tone={detected ? "detected" : "neutral"} />
                  </div>

                  <SignalChart frames={frameHistory} />
                  <div className="chart-footer">
                    <span><Activity size={14} aria-hidden="true" /> 120-frame rolling window</span>
                    <span>Noise floor and adaptive gate come directly from firmware</span>
                  </div>
                </section>
                <CapturePanel macMicrophone={macMicrophone} />
              </> : advancedView === "trainer" ? <SignalTrainingLab /> : advancedView === "speech" ? <SpeechLab /> : advancedView === "agent" ? <AgentControlPanel /> : <LearnHub />}
            </main>
          </div>

          <footer className="app-footer mono">
            <span className={recentFrame ? "footer-live" : ""}><i /> {recentFrame ? `Receiving ${fps} fps from ${source}` : connected ? "Connected; waiting for telemetry" : "Ready for USB, BLE, or Wi-Fi"}</span>
            <span>PadKey protocol · PCM S16LE mono · 16 kHz target</span>
          </footer>
        </>
      )}
    </div>
  );
}
