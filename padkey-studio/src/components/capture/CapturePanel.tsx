import { useEffect, useMemo, useState } from "react";
import { Circle, Download, FileAudio, Loader2, Play, RotateCcw, Square } from "lucide-react";
import { downloadBlob, encodeMp3, encodeWav, mergePcmChunks, processPcm } from "../../audio/exportAudio";
import type { ProcessingOptions } from "../../audio/exportAudio";
import type { MacMicrophoneController } from "../../audio/useMacMicrophone";
import { exportTelemetryCsv } from "../../audio/exportTelemetry";
import { useAppStore } from "../../store";
import { audioChannelLabel, STUDIO_AUDIO_CHANNELS } from "../../studio/audioChannels";
import type { AudioChannel } from "../../types";
import { AudioWaveform } from "./AudioWaveform";

const initialProcessing: ProcessingOptions = {
  removeDc: true,
  highPass: true,
  noiseGate: false,
  normalize: true,
  gateDb: -48
};

function timestampName() {
  return new Date().toISOString().replace(/[:.]/g, "-");
}

function formatDuration(seconds: number) {
  const minutes = Math.floor(seconds / 60);
  return `${String(minutes).padStart(2, "0")}:${String(Math.floor(seconds % 60)).padStart(2, "0")}`;
}

export function CapturePanel({ macMicrophone }: { macMicrophone: MacMicrophoneController }) {
  const [processing, setProcessing] = useState(initialProcessing);
  const [selectedChannel, setSelectedChannel] = useState<AudioChannel>("inmp441");
  const [now, setNow] = useState(Date.now());
  const [exporting, setExporting] = useState<"wav" | "mp3" | null>(null);
  const [previewUrl, setPreviewUrl] = useState<string | null>(null);
  const connected = useAppStore((state) => state.serialConnected || state.wifiConnected);
  const sessionRecording = useAppStore((state) => state.sessionRecording);
  const sessionStartedAt = useAppStore((state) => state.sessionStartedAt);
  const sessionEndedAt = useAppStore((state) => state.sessionEndedAt);
  const sessionFrames = useAppStore((state) => state.sessionFrames);
  const audioChunks = useAppStore((state) => state.audioChunks);
  const audioPreview = useAppStore((state) => state.audioPreview);
  const channelAudioChunks = useAppStore((state) => state.channelAudioChunks);
  const channelAudioPreviews = useAppStore((state) => state.channelAudioPreviews);
  const channelAudioSampleCounts = useAppStore((state) => state.channelAudioSampleCounts);
  const channelLastAudioPacketAt = useAppStore((state) => state.channelLastAudioPacketAt);
  const setCaptureChannelEnabled = useAppStore((state) => state.setCaptureChannelEnabled);
  const audioSampleRate = useAppStore((state) => state.audioSampleRate);
  const audioSampleCount = useAppStore((state) => state.audioSampleCount);
  const lastAudioPacketAt = useAppStore((state) => state.lastAudioPacketAt);
  const receivedAudioPackets = useAppStore((state) => state.receivedAudioPackets);
  const droppedAudioPackets = useAppStore((state) => state.droppedAudioPackets);
  const sessionMode = useAppStore((state) => state.sessionMode);
  const startSession = useAppStore((state) => state.startSession);
  const stopSession = useAppStore((state) => state.stopSession);
  const clearSession = useAppStore((state) => state.clearSession);

  useEffect(() => {
    if (!sessionRecording) return;
    const interval = window.setInterval(() => setNow(Date.now()), 250);
    return () => window.clearInterval(interval);
  }, [sessionRecording]);

  const selectedChunks = selectedChannel === "inmp441" ? audioChunks : channelAudioChunks[selectedChannel];
  const selectedPreview = selectedChannel === "inmp441" ? audioPreview : channelAudioPreviews[selectedChannel];
  const selectedSampleCount = selectedChannel === "inmp441" ? audioSampleCount : channelAudioSampleCounts[selectedChannel];
  const selectedLastPacketAt = selectedChannel === "inmp441" ? lastAudioPacketAt : channelLastAudioPacketAt[selectedChannel];
  const rawAudioLive = Boolean(selectedLastPacketAt && now - selectedLastPacketAt < 2000);
  const duration = audioSampleRate && selectedSampleCount
    ? selectedSampleCount / audioSampleRate
    : sessionStartedAt
      ? ((sessionRecording ? now : sessionEndedAt ?? now) - sessionStartedAt) / 1000
      : 0;
  const hasAudio = selectedSampleCount > 0 && Boolean(audioSampleRate);
  const hasSession = sessionFrames.length > 0 || Object.values(channelAudioSampleCounts).some((count) => count > 0);

  const processedPreview = useMemo(() => {
    if (!hasAudio || !audioSampleRate || sessionRecording) return null;
    return processPcm(mergePcmChunks(selectedChunks), audioSampleRate, processing);
  }, [selectedChunks, audioSampleRate, hasAudio, processing, sessionRecording]);

  useEffect(() => {
    if (previewUrl) URL.revokeObjectURL(previewUrl);
    if (!processedPreview || !audioSampleRate) {
      setPreviewUrl(null);
      return;
    }
    const nextUrl = URL.createObjectURL(encodeWav(processedPreview, audioSampleRate));
    setPreviewUrl(nextUrl);
    return () => URL.revokeObjectURL(nextUrl);
    // previewUrl is deliberately excluded so cleanup follows the generated URL.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [processedPreview, audioSampleRate]);

  function toggleOption(key: keyof Pick<ProcessingOptions, "removeDc" | "highPass" | "noiseGate" | "normalize">) {
    setProcessing((current) => ({ ...current, [key]: !current[key] }));
  }

  function processedAudio() {
    if (!audioSampleRate) return null;
    return processPcm(mergePcmChunks(selectedChunks), audioSampleRate, processing);
  }

  async function handleAudioExport(format: "wav" | "mp3") {
    const samples = processedAudio();
    if (!samples || !audioSampleRate) return;
    setExporting(format);
    await new Promise((resolve) => window.setTimeout(resolve, 30));
    const blob = format === "wav" ? encodeWav(samples, audioSampleRate) : encodeMp3(samples, audioSampleRate);
    downloadBlob(blob, `padkey-${selectedChannel}-${timestampName()}.${format}`);
    setExporting(null);
  }

  async function toggleMacBaseline() {
    if (macMicrophone.status === "live") {
      await macMicrophone.stop();
      setCaptureChannelEnabled("macbook", false);
      return;
    }
    const started = await macMicrophone.start();
    if (started) {
      setCaptureChannelEnabled("macbook", true);
      setSelectedChannel("macbook");
    }
  }

  return (
    <section className="audio-section" aria-labelledby="capture-title">
      <div className="panel-heading">
        <div>
          <div className="section-kicker">Recording</div>
          <h2 id="capture-title" className="panel-title">Device audio & session export</h2>
          <p className="panel-copy">Record telemetry today. WAV and MP3 activate automatically when raw 16-bit PCM arrives from the board.</p>
        </div>
        <div className={`audio-stream-state ${rawAudioLive ? "is-live" : ""}`}>
          <span className="status-dot" aria-hidden="true" />
          {rawAudioLive ? `${audioChannelLabel(selectedChannel)} live` : `${audioChannelLabel(selectedChannel)} waiting`}
        </div>
      </div>

      <div className="advanced-audio-channels" aria-label="Audio channel">
        {STUDIO_AUDIO_CHANNELS.map((channel) => (
          <button type="button" key={channel.key} className={selectedChannel === channel.key ? "is-active" : ""} aria-pressed={selectedChannel === channel.key} onClick={() => setSelectedChannel(channel.key)}>
            <span style={{ color: channel.color }} /> {channel.label}
          </button>
        ))}
        <button type="button" className={macMicrophone.status === "live" ? "mac-baseline-action is-live" : "mac-baseline-action"} disabled={macMicrophone.status === "requesting" || sessionRecording} onClick={() => void toggleMacBaseline()}>
          {macMicrophone.status === "requesting" ? "Requesting access…" : macMicrophone.status === "live" ? "Disable Mac baseline" : "Enable Mac baseline"}
        </button>
      </div>
      {macMicrophone.error ? <div className="capture-inline-warning">{macMicrophone.error}</div> : null}

      <div className="audio-stage">
        <AudioWaveform samples={selectedPreview} />
        {!selectedPreview.length ? (
          <div className="audio-stage-empty">
            <FileAudio size={20} aria-hidden="true" />
            <span>{selectedChannel === "macbook" ? "Enable the Mac baseline to see its waveform." : "Peak telemetry is not audio. Recordable waveform packets will draw here."}</span>
          </div>
        ) : null}
      </div>

      <div className="capture-toolbar">
        <button
          type="button"
          className={sessionRecording ? "button button-stop" : "button button-primary"}
          disabled={!(connected || macMicrophone.status === "live") && !sessionRecording}
          onClick={sessionRecording ? stopSession : startSession}
        >
          {sessionRecording ? <Square size={15} fill="currentColor" aria-hidden="true" /> : <Circle size={15} fill="currentColor" aria-hidden="true" />}
          {sessionRecording ? "Stop session" : "Start session"}
        </button>
        <div className="capture-clock mono">{formatDuration(duration)}</div>
        <div className="capture-counts">
          <span>{sessionFrames.length.toLocaleString()} telemetry frames</span>
          <span>{selectedSampleCount.toLocaleString()} {audioChannelLabel(selectedChannel)} samples</span>
          <span>{receivedAudioPackets.toLocaleString()} PCM packets · {droppedAudioPackets ? `${droppedAudioPackets} dropped` : "no drops"}</span>
          <span>{sessionMode} profile</span>
        </div>
        <button type="button" className="icon-button" onClick={clearSession} disabled={!hasSession || sessionRecording} aria-label="Clear captured session" title="Clear captured session">
          <RotateCcw size={16} aria-hidden="true" />
        </button>
      </div>

      <div className="processing-grid">
        <div>
          <div className="processing-title">Post-processing</div>
          <p className="field-hint">Applied to playback and exports; the captured PCM remains untouched.</p>
        </div>
        <div className="processing-options">
          {([
            ["removeDc", "Remove DC offset"],
            ["highPass", "80 Hz high-pass"],
            ["noiseGate", "Noise gate"],
            ["normalize", "Normalize to −1 dB"]
          ] as const).map(([key, label]) => (
            <label className="check-row" key={key}>
              <input type="checkbox" checked={processing[key]} onChange={() => toggleOption(key)} />
              <span>{label}</span>
            </label>
          ))}
          {processing.noiseGate ? (
            <label className="gate-control">
              <span>Gate threshold <b className="mono">{processing.gateDb} dB</b></span>
              <input type="range" min={-60} max={-30} step={3} value={processing.gateDb} onChange={(event) => setProcessing((current) => ({ ...current, gateDb: Number(event.target.value) }))} />
            </label>
          ) : null}
        </div>
      </div>

      <div className="export-row">
        {previewUrl ? (
          <audio className="audio-player" controls src={previewUrl}>
            <track kind="captions" />
          </audio>
        ) : (
          <div className="export-note"><Play size={15} aria-hidden="true" /> Playback appears after raw audio is captured.</div>
        )}
        <div className="export-actions">
          <button type="button" className="button button-secondary" disabled={!sessionFrames.length || sessionRecording} onClick={() => exportTelemetryCsv(sessionFrames, `padkey-${timestampName()}.csv`)}>
            <Download size={15} aria-hidden="true" /> CSV
          </button>
          <button type="button" className="button button-secondary" disabled={!hasAudio || sessionRecording || Boolean(exporting)} onClick={() => void handleAudioExport("wav")}>
            {exporting === "wav" ? <Loader2 size={15} className="spin" aria-hidden="true" /> : <Download size={15} aria-hidden="true" />} WAV
          </button>
          <button type="button" className="button button-secondary" disabled={!hasAudio || sessionRecording || Boolean(exporting)} onClick={() => void handleAudioExport("mp3")}>
            {exporting === "mp3" ? <Loader2 size={15} className="spin" aria-hidden="true" /> : <Download size={15} aria-hidden="true" />} MP3
          </button>
        </div>
      </div>
    </section>
  );
}
