import { useEffect, useMemo, useRef, useState } from "react";
import {
  ArrowLeft,
  Bluetooth,
  Cable,
  Check,
  Circle,
  Clipboard,
  Download,
  Eye,
  EyeOff,
  FileAudio,
  FileText,
  Loader2,
  Mic2,
  Pause,
  Play,
  RotateCcw,
  Save,
  SlidersHorizontal,
  Sparkles,
  Square,
  Trash2,
  Upload,
  Wifi,
  X
} from "lucide-react";
import { downloadBlob, encodeMp3, encodeWav, mergePcmChunks } from "../../audio/exportAudio";
import type { MacMicrophoneController } from "../../audio/useMacMicrophone";
import type { BLEController } from "../../ble/useBLE";
import type { useSerial } from "../../serial/useSerial";
import { useTranscriber } from "../../speech/useTranscriber";
import { useAppStore } from "../../store";
import type { useWifi } from "../../wifi/useWifi";
import { createAudioProject, createDeviceAudioProject, importAudioFile } from "../../studio/importAudio";
import { deleteAudioProject, getAudioProject, listAudioProjects, saveAudioProject } from "../../studio/projectDb";
import { presetLabel, SOUND_PRESETS, STUDIO_SAMPLE_RATE } from "../../studio/presets";
import { audioChannelLabel, createAudioChannelMap, STUDIO_AUDIO_CHANNELS } from "../../studio/audioChannels";
import { trimPcm } from "../../studio/processStudioAudio";
import type { AudioProject, AudioProjectSummary, ProcessingPreset, SoundAdjustments } from "../../studio/types";
import { useAudioProcessor } from "../../studio/useAudioProcessor";
import { useStudioPlayer } from "../../studio/useStudioPlayer";
import type { AudioChannel, AudioChannelMap, SpeechSegment } from "../../types";
import { StudioWaveform } from "./StudioWaveform";

const ACTIVE_PROJECT_KEY = "padkey-active-audio-project";
const WHISPER_MODEL = "onnx-community/whisper-tiny.en";
const EMPTY_PCM = new Int16Array(0);

const adjustmentRows: Array<{
  key: keyof SoundAdjustments;
  label: string;
  low: string;
  high: string;
}> = [
  { key: "noise", label: "Reduce noise", low: "Natural", high: "Clean" },
  { key: "clarity", label: "Clarity", low: "Soft", high: "Crisp" },
  { key: "voice", label: "Voice strength", low: "Light", high: "Full" },
  { key: "loudness", label: "Loudness", low: "Quiet", high: "Loud" }
];

function formatTime(seconds: number) {
  if (!Number.isFinite(seconds)) return "0:00";
  const minutes = Math.floor(seconds / 60);
  const remainder = Math.floor(seconds % 60);
  return `${minutes}:${String(remainder).padStart(2, "0")}`;
}

function safeFilename(name: string) {
  return name.trim().replace(/[^a-z0-9-_]+/gi, "-").replace(/^-|-$/g, "") || "padkey-audio";
}

function isStorageError(error: unknown) {
  return error instanceof DOMException && ["QuotaExceededError", "UnknownError"].includes(error.name);
}

function CaptureChannelPicker({
  channels,
  onChange,
  macMicrophone
}: {
  channels: AudioChannelMap<boolean>;
  onChange: (channel: AudioChannel, enabled: boolean) => void | Promise<void>;
  macMicrophone: MacMicrophoneController;
}) {
  return (
    <fieldset className="studio-capture-channels">
      <legend>Record these inputs</legend>
      <div>
        {STUDIO_AUDIO_CHANNELS.map((channel) => (
          <label key={channel.key} className={channels[channel.key] ? "is-enabled" : ""}>
            <input
              type="checkbox"
              checked={channels[channel.key]}
              disabled={channel.key === "macbook" && macMicrophone.status === "requesting"}
              onChange={(event) => void onChange(channel.key, event.target.checked)}
            />
            <span className="studio-channel-mark" style={{ color: channel.color }} />
            <span>
              <b>{channel.label}</b>
              <small>{channel.key === "macbook"
                ? macMicrophone.status === "requesting"
                  ? "Waiting for permission…"
                  : macMicrophone.status === "live"
                    ? `Live · ${macMicrophone.deviceName ?? "Mac microphone"}`
                    : channel.description
                : channel.description}</small>
            </span>
          </label>
        ))}
      </div>
    </fieldset>
  );
}

function WaveformChannelBar({
  available,
  visible,
  selected,
  liveTimes,
  now,
  onSelect,
  onVisibility
}: {
  available: AudioChannelMap<boolean>;
  visible: AudioChannelMap<boolean>;
  selected: AudioChannel;
  liveTimes?: AudioChannelMap<number | null>;
  now?: number;
  onSelect: (channel: AudioChannel) => void;
  onVisibility: (channel: AudioChannel, visible: boolean) => void;
}) {
  return (
    <div className="studio-channel-bar" aria-label="Recording channels">
      {STUDIO_AUDIO_CHANNELS.filter((channel) => available[channel.key]).map((channel) => {
        const isLive = Boolean(liveTimes && now && liveTimes[channel.key] && now - (liveTimes[channel.key] ?? 0) < 2000);
        return (
          <div key={channel.key} className={`${selected === channel.key ? "is-selected" : ""} ${visible[channel.key] ? "" : "is-hidden"}`}>
            <button type="button" className="studio-channel-select" aria-pressed={selected === channel.key} onClick={() => onSelect(channel.key)}>
              <span className={isLive ? "is-live" : ""} style={{ color: channel.color }} />
              <span><b>{channel.label}</b><small>{channel.shortLabel}</small></span>
            </button>
            <button
              type="button"
              className="studio-channel-visibility"
              aria-label={`${visible[channel.key] ? "Hide" : "Show"} ${channel.label} waveform`}
              aria-pressed={visible[channel.key]}
              onClick={() => onVisibility(channel.key, !visible[channel.key])}
            >
              {visible[channel.key] ? <Eye size={16} /> : <EyeOff size={16} />}
            </button>
          </div>
        );
      })}
    </div>
  );
}

function ConnectionDialog({
  onClose,
  serial,
  wifi,
  ble
}: {
  onClose: () => void;
  serial: ReturnType<typeof useSerial>;
  wifi: ReturnType<typeof useWifi>;
  ble: BLEController;
}) {
  const [mode, setMode] = useState<"usb" | "ble" | "wifi">("usb");
  const serialConnected = useAppStore((state) => state.serialConnected);
  const serialStatus = useAppStore((state) => state.serialStatus);
  const serialError = useAppStore((state) => state.serialError);
  const bleConnected = useAppStore((state) => state.bleConnected);
  const bleStatus = useAppStore((state) => state.bleStatus);
  const bleError = useAppStore((state) => state.bleError);
  const wifiConnected = useAppStore((state) => state.wifiConnected);
  const wifiStatus = useAppStore((state) => state.wifiStatus);
  const wifiError = useAppStore((state) => state.wifiError);
  const wifiUrl = useAppStore((state) => state.wifiUrl);
  const setWifiUrl = useAppStore((state) => state.setWifiUrl);
  const connected = mode === "usb" ? serialConnected : mode === "ble" ? bleConnected : wifiConnected;
  const connecting = mode === "usb" ? serialStatus === "connecting" : mode === "ble" ? bleStatus === "connecting" : wifiStatus === "connecting";
  const error = mode === "usb" ? serialError : mode === "ble" ? bleError : wifiError;

  async function toggleConnection() {
    if (mode === "usb") {
      if (serialConnected) await serial.disconnect();
      else {
        ble.disconnect();
        if (wifiConnected) wifi.disconnect();
        await serial.connect();
      }
    } else if (mode === "ble") {
      if (bleConnected) ble.disconnect();
      else {
        await serial.disconnect();
        wifi.disconnect();
        await ble.connect();
      }
    } else if (wifiConnected) {
      wifi.disconnect();
    } else {
      if (serialConnected) await serial.disconnect();
      ble.disconnect();
      await wifi.connect(wifiUrl.trim());
    }
  }

  return (
    <div className="studio-modal-backdrop" role="presentation" onMouseDown={(event) => event.target === event.currentTarget && onClose()}>
      <section className="studio-modal studio-connection-dialog" role="dialog" aria-modal="true" aria-labelledby="connection-dialog-title">
        <div className="studio-modal-heading">
          <div>
            <span className="studio-eyebrow">Input</span>
            <h2 id="connection-dialog-title">Connect PadKey</h2>
          </div>
          <button type="button" className="studio-icon-button" onClick={onClose} aria-label="Close connection settings"><X size={18} /></button>
        </div>
        <div className="studio-segmented studio-transport-tabs" role="tablist" aria-label="Connection type">
          <button type="button" role="tab" aria-selected={mode === "usb"} className={mode === "usb" ? "is-active" : ""} onClick={() => setMode("usb")}><Cable size={16} /> USB cable</button>
          <button type="button" role="tab" aria-selected={mode === "ble"} className={mode === "ble" ? "is-active" : ""} onClick={() => setMode("ble")}><Bluetooth size={16} /> BLE</button>
          <button type="button" role="tab" aria-selected={mode === "wifi"} className={mode === "wifi" ? "is-active" : ""} onClick={() => setMode("wifi")}><Wifi size={16} /> Wi-Fi</button>
        </div>
        {mode === "wifi" ? (
          <label className="studio-field">
            <span>PadKey address</span>
            <input value={wifiUrl} onChange={(event) => setWifiUrl(event.target.value)} placeholder="ws://padkey.local:81" spellCheck={false} />
          </label>
        ) : mode === "ble" ? (
          <div className="studio-ble-connect">
            <p className="studio-dialog-copy"><b>Efficient wireless recording.</b> BLE carries synchronized INMP441, MAX4466, and piezo audio at 8 kHz.</p>
          </div>
        ) : (
          <p className="studio-dialog-copy">Connect the board with its USB cable. Close Arduino Serial Monitor before opening PadKey.</p>
        )}
        {error ? <div className="studio-inline-error">{error}</div> : null}
        <button type="button" className="studio-button studio-button-primary studio-button-wide" disabled={connecting || (mode === "wifi" && !wifiUrl.trim())} onClick={() => void toggleConnection()}>
          {connecting ? <Loader2 className="spin" size={17} /> : connected ? <Check size={17} /> : mode === "usb" ? <Cable size={17} /> : mode === "ble" ? <Bluetooth size={17} /> : <Wifi size={17} />}
          {connecting ? "Connecting…" : connected ? `Disconnect ${mode === "usb" ? "USB" : mode === "ble" ? "BLE" : "Wi-Fi"}` : `Connect ${mode === "usb" ? "USB" : mode === "ble" ? "BLE" : "Wi-Fi"}`}
        </button>
      </section>
    </div>
  );
}

export function Studio({
  macMicrophone,
  serial,
  wifi,
  ble
}: {
  macMicrophone: MacMicrophoneController;
  serial: ReturnType<typeof useSerial>;
  wifi: ReturnType<typeof useWifi>;
  ble: BLEController;
}) {
  const fileInputRef = useRef<HTMLInputElement | null>(null);
  const [project, setProject] = useState<AudioProject | null>(null);
  const [recentProjects, setRecentProjects] = useState<AudioProjectSummary[]>([]);
  const [restoring, setRestoring] = useState(true);
  const [importing, setImporting] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [storageWarning, setStorageWarning] = useState<string | null>(null);
  const [enhanced, setEnhanced] = useState(true);
  const [inspectorTab, setInspectorTab] = useState<"sound" | "text">("sound");
  const [exportOpen, setExportOpen] = useState(false);
  const [connectionOpen, setConnectionOpen] = useState(false);
  const [copied, setCopied] = useState(false);
  const [now, setNow] = useState(Date.now());
  const [liveChannel, setLiveChannel] = useState<AudioChannel>("inmp441");
  const [liveVisibleChannels, setLiveVisibleChannels] = useState<AudioChannelMap<boolean>>(() => createAudioChannelMap(() => true));

  const serialConnected = useAppStore((state) => state.serialConnected);
  const wifiConnected = useAppStore((state) => state.wifiConnected);
  const bleConnected = useAppStore((state) => state.bleConnected);
  const serialStatus = useAppStore((state) => state.serialStatus);
  const wifiStatus = useAppStore((state) => state.wifiStatus);
  const bleStatus = useAppStore((state) => state.bleStatus);
  const sessionRecording = useAppStore((state) => state.sessionRecording);
  const sessionStartedAt = useAppStore((state) => state.sessionStartedAt);
  const captureChannels = useAppStore((state) => state.captureChannels);
  const channelAudioPreviews = useAppStore((state) => state.channelAudioPreviews);
  const channelAudioSampleCounts = useAppStore((state) => state.channelAudioSampleCounts);
  const channelLastAudioPacketAt = useAppStore((state) => state.channelLastAudioPacketAt);
  const channelLastRecordableAudioPacketAt = useAppStore((state) => state.channelLastRecordableAudioPacketAt);
  const latestFrame = useAppStore((state) => state.latestFrame);
  const deviceStatus = useAppStore((state) => state.deviceStatus);
  const droppedAudioPackets = useAppStore((state) => state.droppedAudioPackets);
  const startSession = useAppStore((state) => state.startSession);
  const stopSession = useAppStore((state) => state.stopSession);
  const clearSession = useAppStore((state) => state.clearSession);
  const setCaptureChannelEnabled = useAppStore((state) => state.setCaptureChannelEnabled);
  const setSerialBaudRate = useAppStore((state) => state.setSerialBaudRate);
  const transcriber = useTranscriber();

  const connected = serialConnected || wifiConnected || bleConnected;
  const connecting = serialStatus === "connecting" || wifiStatus === "connecting" || bleStatus === "connecting";
  const padkeySignalLive = (["inmp441", "max4466", "piezo"] as const)
    .some((channel) => Boolean(channelLastAudioPacketAt[channel] && now - (channelLastAudioPacketAt[channel] ?? 0) < 2000));
  const selectedInputReady = STUDIO_AUDIO_CHANNELS.some((channel) =>
    captureChannels[channel.key]
      && Boolean(channelLastRecordableAudioPacketAt[channel.key] && now - (channelLastRecordableAudioPacketAt[channel.key] ?? 0) < 2000));
  const telemetryLive = Boolean(latestFrame?.ts && now - latestFrame.ts < 2000);
  const connectionLabel = !connected
    ? "PadKey not connected"
    : bleConnected
      ? selectedInputReady ? "PadKey connected · BLE recording ready" : padkeySignalLive ? "PadKey connected · BLE signal" : "PadKey connected · Waiting for BLE audio"
    : droppedAudioPackets
      ? "PadKey connected · Check signal"
      : padkeySignalLive
        ? "PadKey connected · Signal good"
        : telemetryLive
          ? "PadKey connected · Recording unavailable"
          : "PadKey connected · Waiting for sensors";

  useEffect(() => {
    setSerialBaudRate(921600);
    const timer = window.setInterval(() => setNow(Date.now()), 250);
    return () => window.clearInterval(timer);
  }, [setSerialBaudRate]);


  async function refreshRecent() {
    try {
      setRecentProjects(await listAudioProjects(10));
    } catch {
      setStorageWarning("Recent recordings are unavailable, but you can still record and export audio.");
    }
  }

  useEffect(() => {
    void (async () => {
      await refreshRecent();
      const activeId = window.localStorage.getItem(ACTIVE_PROJECT_KEY);
      if (activeId) {
        try {
          const restored = await getAudioProject(activeId);
          if (restored) setProject(restored);
        } catch {
          setStorageWarning("Your last recording could not be restored.");
        }
      }
      setRestoring(false);
    })();
  }, []);

  useEffect(() => {
    if (!project) return;
    const timer = window.setTimeout(() => {
      void saveAudioProject(project)
        .then(() => {
          window.localStorage.setItem(ACTIVE_PROJECT_KEY, project.id);
          void refreshRecent();
          setStorageWarning(null);
        })
        .catch((saveError) => {
          setStorageWarning(isStorageError(saveError)
            ? "This recording is safe for now, but your browser storage is full. Export it before closing PadKey."
            : "PadKey could not auto-save this recording. Export it before closing the app.");
        });
    }, 500);
    return () => window.clearTimeout(timer);
  }, [project]);

  const projectChannel = project?.selectedChannel ?? "inmp441";
  const projectSamples = project?.tracks?.[projectChannel] ?? project?.samples ?? null;
  const { processed, processing } = useAudioProcessor(
    projectSamples,
    project?.sampleRate ?? STUDIO_SAMPLE_RATE,
    project?.adjustments ?? SOUND_PRESETS.clear
  );
  const playbackSamples = projectSamples ? (enhanced ? processed ?? projectSamples : projectSamples) : null;
  const player = useStudioPlayer(
    playbackSamples,
    project?.sampleRate ?? STUDIO_SAMPLE_RATE,
    project?.trimStartMs ?? 0,
    project?.trimEndMs ?? 0
  );

  const recordingSeconds = sessionStartedAt ? Math.max(0, (now - sessionStartedAt) / 1000) : 0;
  const liveWaveform = liveVisibleChannels[liveChannel] ? channelAudioPreviews[liveChannel] : EMPTY_PCM;
  const liveOverlays = STUDIO_AUDIO_CHANNELS
    .filter((channel) => channel.key !== liveChannel && captureChannels[channel.key] && liveVisibleChannels[channel.key])
    .map((channel) => ({ samples: channelAudioPreviews[channel.key], color: `${channel.color}45` }));
  const availableProjectChannels = createAudioChannelMap((channel) => Boolean(project?.tracks?.[channel]?.length));
  const projectVisibleChannels = project?.visibleChannels ?? createAudioChannelMap((channel) => project?.tracks ? availableProjectChannels[channel] : channel === projectChannel);
  const projectOverlays = project?.tracks
    ? STUDIO_AUDIO_CHANNELS
        .filter((channel) => channel.key !== projectChannel && projectVisibleChannels[channel.key] && project.tracks?.[channel.key]?.length)
        .map((channel) => ({ samples: project.tracks?.[channel.key] as Int16Array, color: `${channel.color}45` }))
    : [];
  const transcriptionBusy = transcriber.modelStatus === "loading"
    || (transcriber.transcriptionProgress.total > 0 && transcriber.transcriptionProgress.current < transcriber.transcriptionProgress.total);

  function updateProject(update: Partial<AudioProject>, audioChanged = false) {
    setProject((current) => current ? {
      ...current,
      ...update,
      updatedAt: Date.now(),
      transcriptStale: audioChanged && current.transcript ? true : (update.transcriptStale ?? current.transcriptStale)
    } : current);
  }

  function closeProject() {
    setProject(null);
    window.localStorage.removeItem(ACTIVE_PROJECT_KEY);
  }

  async function changeCaptureChannel(channel: AudioChannel, enabled: boolean) {
    const enabledCount = Object.values(captureChannels).filter(Boolean).length;
    if (!enabled && enabledCount === 1 && captureChannels[channel]) {
      setError("Keep at least one input turned on for recording.");
      return;
    }
    setError(null);
    if (channel === "macbook") {
      if (enabled) {
        const started = await macMicrophone.start();
        if (!started) {
          setError(macMicrophone.error ?? "The MacBook microphone could not be enabled.");
          return;
        }
      } else {
        await macMicrophone.stop();
      }
    }
    setCaptureChannelEnabled(channel, enabled);
    if (!enabled && liveChannel === channel) {
      const fallback = STUDIO_AUDIO_CHANNELS.find((item) => item.key !== channel && captureChannels[item.key])?.key;
      if (fallback) setLiveChannel(fallback);
    }
  }

  function selectProjectChannel(channel: AudioChannel) {
    if (!project?.tracks?.[channel]?.length) return;
    if (player.playing) player.toggle();
    updateProject({ selectedChannel: channel }, true);
  }

  function setProjectChannelVisibility(channel: AudioChannel, visible: boolean) {
    if (!project) return;
    updateProject({
      visibleChannels: {
        ...projectVisibleChannels,
        [channel]: visible
      }
    });
  }

  async function connectOrRecord() {
    setError(null);
    if (!connected && !(captureChannels.macbook && macMicrophone.status === "live")) {
      setConnectionOpen(true);
      return;
    }
    if (!selectedInputReady) {
      if (bleConnected) {
        setError("BLE is connected, but continuous audio has not arrived yet. Upload the recordable BLE firmware, confirm the selected sensor, and reconnect.");
        return;
      }
      setError(telemetryLive
        ? "PadKey is sending sensor readings, but the selected inputs are not sending recordable sound."
        : "The selected recording inputs are not ready yet. Wait a moment and try again.");
      return;
    }
    if (!Object.values(captureChannels).some(Boolean)) {
      setError("Turn on at least one input before recording.");
      return;
    }
    setProject(null);
    window.localStorage.removeItem(ACTIVE_PROJECT_KEY);
    clearSession();
    startSession();
  }

  function finishRecording() {
    const capture = useAppStore.getState();
    stopSession();
    const tracks = Object.fromEntries(
      STUDIO_AUDIO_CHANNELS
        .filter((channel) => capture.captureChannels[channel.key] && capture.channelAudioChunks[channel.key].length)
        .map((channel) => [channel.key, mergePcmChunks(capture.channelAudioChunks[channel.key])])
    ) as Partial<AudioChannelMap<Int16Array>>;
    if (!Object.values(tracks).some((samples) => samples?.length) || !capture.audioSampleRate) {
      setError("No recordable sound arrived. Your sensor readings may be live, but the waveform stream is missing. Upload the new firmware and reconnect.");
      clearSession();
      return;
    }
    setProject(createDeviceAudioProject(tracks, capture.audioSampleRate, liveChannel));
    setEnhanced(true);
    setInspectorTab("sound");
  }

  function cancelRecording() {
    clearSession();
    setError(null);
  }

  async function handleImport(file: File | undefined) {
    if (!file) return;
    setImporting(true);
    setError(null);
    try {
      const imported = await importAudioFile(file);
      setProject(imported);
      setEnhanced(true);
      setInspectorTab("sound");
    } catch (importError) {
      setError(importError instanceof Error ? importError.message : "PadKey could not import this recording.");
    } finally {
      setImporting(false);
      if (fileInputRef.current) fileInputRef.current.value = "";
    }
  }

  async function openRecent(id: string) {
    setError(null);
    try {
      const restored = await getAudioProject(id);
      if (restored) {
        setProject(restored);
        setEnhanced(true);
      }
    } catch {
      setError("PadKey could not open that recording.");
    }
  }

  async function removeRecent(id: string) {
    await deleteAudioProject(id);
    if (project?.id === id) {
      setProject(null);
      window.localStorage.removeItem(ACTIVE_PROJECT_KEY);
    }
    await refreshRecent();
  }

  function selectPreset(preset: Exclude<ProcessingPreset, "custom">) {
    updateProject({ preset, adjustments: { ...SOUND_PRESETS[preset] } }, true);
  }

  function setAdjustment(key: keyof SoundAdjustments, value: number) {
    if (!project) return;
    updateProject({ preset: "custom", adjustments: { ...project.adjustments, [key]: value } }, true);
  }

  function exportAudio(format: "wav" | "mp3") {
    if (!project || !processed) return;
    const samples = trimPcm(processed, project.sampleRate, project.trimStartMs, project.trimEndMs);
    const blob = format === "wav" ? encodeWav(samples, project.sampleRate) : encodeMp3(samples, project.sampleRate, 128);
    const channelSuffix = project.tracks ? `-${projectChannel}` : "";
    downloadBlob(blob, `${safeFilename(project.name)}${channelSuffix}.${format}`);
    setExportOpen(false);
  }

  async function makeText() {
    if (!project || !processed) return;
    setError(null);
    setInspectorTab("text");
    const trimmed = trimPcm(processed, project.sampleRate, project.trimStartMs, project.trimEndMs);
    const audio = Float32Array.from(trimmed, (sample) => sample / 32768);
    const segment: SpeechSegment = {
      id: "studio-project",
      startMs: 0,
      endMs: (audio.length / project.sampleRate) * 1000,
      durationMs: (audio.length / project.sampleRate) * 1000,
      source: "hybrid",
      signalScore: 1,
      processedAudio: audio
    };
    try {
      const results = await transcriber.transcribe(WHISPER_MODEL, [segment]);
      updateProject({ transcript: results.map((item) => item.text).join(" ").trim(), transcriptStale: false });
    } catch (transcriptionError) {
      const offline = !navigator.onLine;
      setError(offline
        ? "Connect to the internet once to prepare Make text. Audio editing and saving still work offline."
        : transcriptionError instanceof Error ? transcriptionError.message : "PadKey could not make text from this recording.");
    }
  }

  async function copyTranscript() {
    if (!project?.transcript) return;
    await navigator.clipboard.writeText(project.transcript);
    setCopied(true);
    window.setTimeout(() => setCopied(false), 1400);
  }

  function saveTranscript() {
    if (!project?.transcript) return;
    downloadBlob(new Blob([project.transcript], { type: "text/plain;charset=utf-8" }), `${safeFilename(project.name)}.txt`);
  }

  const editorDurationSeconds = project ? project.durationMs / 1000 : 0;
  const trimmedDurationSeconds = project ? (project.trimEndMs - project.trimStartMs) / 1000 : 0;

  if (restoring) {
    return <main className="studio-loading"><Loader2 className="spin" size={22} /><span>Opening Studio…</span></main>;
  }

  if (sessionRecording) {
    return (
      <main className="studio-recording-view">
        <div className="studio-recording-status"><span /> Recording</div>
        <h1>Speak naturally</h1>
        <p>PadKey is saving each input separately. Select an input to watch it live.</p>
        <WaveformChannelBar
          available={captureChannels}
          visible={liveVisibleChannels}
          selected={liveChannel}
          liveTimes={channelLastAudioPacketAt}
          now={now}
          onSelect={setLiveChannel}
          onVisibility={(channel, visible) => setLiveVisibleChannels((current) => ({ ...current, [channel]: visible }))}
        />
        <div className="studio-live-waveform">
          <StudioWaveform
            original={liveWaveform}
            processed={liveWaveform}
            overlays={liveOverlays}
            durationMs={Math.max(1000, recordingSeconds * 1000)}
            trimStartMs={0}
            trimEndMs={Math.max(1000, recordingSeconds * 1000)}
            positionSeconds={recordingSeconds}
            enhanced={false}
            onSeek={() => undefined}
            onTrimStart={() => undefined}
            onTrimEnd={() => undefined}
          />
        </div>
        <div className="studio-recording-counts">
          {STUDIO_AUDIO_CHANNELS.filter((channel) => captureChannels[channel.key]).map((channel) => (
            <span key={channel.key} className={channelAudioSampleCounts[channel.key] ? "is-receiving" : ""}>
              <i style={{ color: channel.color }} /> {channel.label} · {channelAudioSampleCounts[channel.key] ? "capturing" : "waiting"}
            </span>
          ))}
        </div>
        <div className="studio-recording-time">{formatTime(recordingSeconds)}</div>
        <div className="studio-recording-actions">
          <button type="button" className="studio-button studio-button-quiet" onClick={cancelRecording}><X size={17} /> Cancel</button>
          <button type="button" className="studio-button studio-button-stop" onClick={finishRecording}><Square size={16} fill="currentColor" /> Stop recording</button>
        </div>
      </main>
    );
  }

  if (!project) {
    return (
      <main className="studio-start" onDragOver={(event) => event.preventDefault()} onDrop={(event) => { event.preventDefault(); void handleImport(event.dataTransfer.files[0]); }}>
        <section className="studio-start-intro">
          <div className="studio-status-line">
            <button type="button" className={`studio-connection-pill ${connected ? "is-connected" : ""}`} onClick={() => setConnectionOpen(true)}>
              <span /> {connectionLabel}
            </button>
          </div>
          <h1>Make your voice easier to hear.</h1>
          <p>Record from PadKey or bring in an audio file. Then listen, improve, compare, and save.</p>
          <div className="studio-start-actions">
            <button type="button" className="studio-button studio-button-primary studio-start-button" disabled={connecting} onClick={() => void connectOrRecord()}>
              {connecting ? <Loader2 className="spin" size={19} /> : selectedInputReady ? <Circle size={18} fill="currentColor" /> : <Cable size={19} />}
              {connecting ? "Connecting…" : selectedInputReady ? "Record selected inputs" : connected ? "Recording not ready" : "Connect PadKey"}
            </button>
            <button type="button" className="studio-button studio-button-secondary studio-start-button" disabled={importing} onClick={() => fileInputRef.current?.click()}>
              {importing ? <Loader2 className="spin" size={19} /> : <Upload size={19} />}
              {importing ? "Opening audio…" : "Import audio"}
            </button>
            <input ref={fileInputRef} className="sr-only" type="file" accept="audio/wav,audio/mpeg,.wav,.mp3" onChange={(event) => void handleImport(event.target.files?.[0])} />
          </div>
          <CaptureChannelPicker channels={captureChannels} onChange={changeCaptureChannel} macMicrophone={macMicrophone} />
          {macMicrophone.error ? <div className="studio-stream-warning">{macMicrophone.error}</div> : null}
          {connected && telemetryLive && !padkeySignalLive ? (
            <div className="studio-stream-warning">
              {deviceStatus && (deviceStatus.level === "error" || deviceStatus.level === "fatal")
                ? `PadKey reported: ${deviceStatus.message}`
                : "Sensor values are arriving, but playable waveforms are not. Upload the corrected PadKey firmware, then reconnect."}
            </div>
          ) : null}
          <div className="studio-drop-hint">You can also drop a WAV or MP3 here.</div>
        </section>

        {error || storageWarning ? <div className="studio-message is-warning">{error ?? storageWarning}</div> : null}

        {recentProjects.length ? (
          <section className="studio-recent" aria-labelledby="recent-recordings-title">
            <div className="studio-section-heading">
              <div><span className="studio-eyebrow">Continue</span><h2 id="recent-recordings-title">Recent recordings</h2></div>
              <span>{recentProjects.length} saved locally</span>
            </div>
            <div className="studio-recent-list">
              {recentProjects.map((item) => (
                <article className="studio-recent-row" key={item.id}>
                  <button type="button" className="studio-recent-open" onClick={() => void openRecent(item.id)}>
                    <span className="studio-file-icon"><FileAudio size={18} /></span>
                    <span><b>{item.name}</b><small>{formatTime(item.durationMs / 1000)} · {item.source === "device" ? "Multi-input recording" : "Imported audio"}</small></span>
                  </button>
                  <button type="button" className="studio-icon-button" onClick={() => void removeRecent(item.id)} aria-label={`Delete ${item.name}`}><Trash2 size={16} /></button>
                </article>
              ))}
            </div>
          </section>
        ) : null}
        {connectionOpen ? <ConnectionDialog onClose={() => setConnectionOpen(false)} serial={serial} wifi={wifi} ble={ble} /> : null}
      </main>
    );
  }

  return (
    <main className="studio-editor">
      <div className="studio-editor-commandbar">
        <button type="button" className="studio-button studio-button-quiet" onClick={closeProject}><ArrowLeft size={17} /> Recordings</button>
        <div className="studio-editor-title">
          <input aria-label="Recording name" value={project.name} onChange={(event) => updateProject({ name: event.target.value })} />
          <span>{formatTime(trimmedDurationSeconds)} selected</span>
        </div>
        <div className="studio-command-actions">
          <button type="button" className="studio-button studio-button-secondary" onClick={() => { setInspectorTab("text"); if (!project.transcript) void makeText(); }}><FileText size={17} /> Make text</button>
          <button type="button" className="studio-button studio-button-primary" onClick={() => setExportOpen(true)}><Save size={17} /> Save audio</button>
        </div>
      </div>

      {error || storageWarning ? <div className="studio-message is-warning">{error ?? storageWarning}</div> : null}

      <div className="studio-editor-grid">
        <section className="studio-audio-canvas" aria-label="Audio editor">
          <div className="studio-canvas-topline">
            <div className="studio-source-label"><span className={project.source === "device" ? "is-device" : ""}>{project.source === "device" ? <Mic2 size={15} /> : <Upload size={15} />}{project.source === "device" ? `Recording · ${audioChannelLabel(projectChannel)}` : project.sourceName}</span></div>
            <div className="studio-segmented studio-compare" aria-label="Sound comparison">
              <button type="button" className={!enhanced ? "is-active" : ""} aria-pressed={!enhanced} onClick={() => setEnhanced(false)}>Original</button>
              <button type="button" className={enhanced ? "is-active" : ""} aria-pressed={enhanced} onClick={() => setEnhanced(true)}>Enhanced</button>
            </div>
          </div>

          {project.tracks ? (
            <WaveformChannelBar
              available={availableProjectChannels}
              visible={projectVisibleChannels}
              selected={projectChannel}
              onSelect={selectProjectChannel}
              onVisibility={setProjectChannelVisibility}
            />
          ) : null}

          <div className="studio-waveform-wrap">
            <StudioWaveform
              original={projectVisibleChannels[projectChannel] ? projectSamples ?? EMPTY_PCM : EMPTY_PCM}
              processed={projectVisibleChannels[projectChannel] ? processed ?? projectSamples ?? EMPTY_PCM : EMPTY_PCM}
              overlays={projectOverlays}
              durationMs={project.durationMs}
              trimStartMs={project.trimStartMs}
              trimEndMs={project.trimEndMs}
              positionSeconds={player.position}
              enhanced={enhanced}
              onSeek={player.seek}
              onTrimStart={(trimStartMs) => updateProject({ trimStartMs }, true)}
              onTrimEnd={(trimEndMs) => updateProject({ trimEndMs }, true)}
            />
            <div className="studio-waveform-times"><span>{formatTime(project.trimStartMs / 1000)}</span><span>{formatTime(project.trimEndMs / 1000)}</span></div>
          </div>

          <div className="studio-transport">
            <span>{formatTime(player.position)}</span>
            <button type="button" className="studio-play-button" onClick={player.toggle} aria-label={player.playing ? "Pause" : "Play"}>{player.playing ? <Pause size={22} fill="currentColor" /> : <Play size={22} fill="currentColor" />}</button>
            <span>{formatTime(editorDurationSeconds)}</span>
          </div>
          <div className="studio-canvas-note">
            <span>Drag the two handles to trim.</span>
            <span className={processing ? "is-processing" : ""}>{processing ? <><Loader2 className="spin" size={13} /> Updating sound…</> : <><Check size={13} /> Changes saved locally</>}</span>
          </div>
        </section>

        <aside className="studio-inspector">
          <div className="studio-inspector-tabs" role="tablist" aria-label="Editor tools">
            <button type="button" role="tab" aria-selected={inspectorTab === "sound"} className={inspectorTab === "sound" ? "is-active" : ""} onClick={() => setInspectorTab("sound")}><SlidersHorizontal size={16} /> Sound</button>
            <button type="button" role="tab" aria-selected={inspectorTab === "text"} className={inspectorTab === "text" ? "is-active" : ""} onClick={() => setInspectorTab("text")}><FileText size={16} /> Text</button>
          </div>

          {inspectorTab === "sound" ? (
            <div className="studio-inspector-body">
              <div className="studio-tool-heading"><div><span className="studio-eyebrow">Enhance</span><h2>How should it sound?</h2></div><button type="button" className="studio-icon-button" onClick={() => selectPreset("clear")} aria-label="Reset sound"><RotateCcw size={16} /></button></div>
              <div className="studio-preset-row" aria-label="Sound presets">
                {(["natural", "clear", "strong"] as const).map((preset) => <button type="button" key={preset} className={project.preset === preset ? "is-active" : ""} onClick={() => selectPreset(preset)}>{presetLabel(preset)}</button>)}
              </div>
              <div className="studio-adjustments">
                {adjustmentRows.map((row) => (
                  <label className="studio-adjustment" key={row.key}>
                    <span><b>{row.label}</b><output>{project.adjustments[row.key]}</output></span>
                    <input aria-label={row.label} type="range" min={0} max={100} value={project.adjustments[row.key]} onChange={(event) => setAdjustment(row.key, Number(event.target.value))} />
                    <small><span>{row.low}</span><span>{row.high}</span></small>
                  </label>
                ))}
              </div>
              <div className="studio-inspector-tip"><Sparkles size={16} /><span><b>{presetLabel(project.preset)}</b> keeps the original recording untouched. Switch to Original anytime to compare.</span></div>
            </div>
          ) : (
            <div className="studio-inspector-body studio-text-panel">
              <div className="studio-tool-heading"><div><span className="studio-eyebrow">Transcript</span><h2>Turn the recording into text</h2></div></div>
              {project.transcript ? (
                <>
                  {project.transcriptStale ? <button type="button" className="studio-transcript-stale" onClick={() => void makeText()}><RotateCcw size={15} /> Audio changed · Update text</button> : <div className="studio-transcript-ready"><Check size={15} /> Text matches this audio</div>}
                  <textarea aria-label="Recording transcript" value={project.transcript} onChange={(event) => updateProject({ transcript: event.target.value, transcriptStale: false })} />
                  <div className="studio-text-actions">
                    <button type="button" className="studio-button studio-button-secondary" onClick={() => void copyTranscript()}>{copied ? <Check size={16} /> : <Clipboard size={16} />}{copied ? "Copied" : "Copy"}</button>
                    <button type="button" className="studio-button studio-button-secondary" onClick={saveTranscript}><Download size={16} /> Save text</button>
                  </div>
                </>
              ) : (
                <div className="studio-transcript-empty">
                  <span><FileText size={24} /></span>
                  <h3>Make editable text</h3>
                  <p>PadKey listens to the selected part of your recording and writes what it hears.</p>
                  <button type="button" className="studio-button studio-button-primary studio-button-wide" disabled={transcriptionBusy} onClick={() => void makeText()}>{transcriptionBusy ? <Loader2 className="spin" size={17} /> : <Sparkles size={17} />}{transcriptionBusy ? `${transcriber.modelProgress || ""}% Preparing…` : "Make text"}</button>
                </div>
              )}
            </div>
          )}
        </aside>
      </div>

      {exportOpen ? (
        <div className="studio-modal-backdrop" role="presentation" onMouseDown={(event) => event.target === event.currentTarget && setExportOpen(false)}>
          <section className="studio-modal studio-export-dialog" role="dialog" aria-modal="true" aria-labelledby="export-dialog-title">
            <div className="studio-modal-heading"><div><span className="studio-eyebrow">Save {project.tracks ? audioChannelLabel(projectChannel) : "audio"}</span><h2 id="export-dialog-title">Choose a format</h2></div><button type="button" className="studio-icon-button" onClick={() => setExportOpen(false)} aria-label="Close save options"><X size={18} /></button></div>
            <button type="button" className="studio-format-option" onClick={() => exportAudio("wav")}><span className="studio-file-icon"><FileAudio size={19} /></span><span><b>WAV</b><small>Best quality for editing, research, and training</small></span><Download size={18} /></button>
            <button type="button" className="studio-format-option" onClick={() => exportAudio("mp3")}><span className="studio-file-icon"><FileAudio size={19} /></span><span><b>MP3</b><small>Smaller file for sharing and playback</small></span><Download size={18} /></button>
          </section>
        </div>
      ) : null}
    </main>
  );
}
